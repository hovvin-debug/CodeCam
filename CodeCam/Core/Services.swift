import AVFoundation
import CryptoKit
import Foundation
import Security
import SwiftData
import UIKit

@MainActor
enum TaskBootstrapper {
    static func seedIfNeeded(in context: ModelContext) {
        let descriptor = FetchDescriptor<TaskDraft>()
        if (try? context.fetchCount(descriptor)) == 0 {
            let installationID = InstallationIDStore.value
            context.insert(UserSessionRecord(userID: "anonymous", terminalID: installationID, installationID: installationID))
            context.insert(DeviceRegistration(terminalID: installationID, serialNumber: DeviceIdentity.serialNumber))
            context.insert(TaskCache(taskID: "install-001", templateID: "installation-v1", templateVersion: "1.0"))
            context.insert(TaskDraft(taskID: "install-001", title: "安装验收 · A 区 1201", taskType: "安装", templateID: "installation-v1", templateVersion: "1.0"))
            context.insert(TaskDraft(taskID: "service-002", title: "售后巡检 · 东仓", taskType: "售后", templateID: "after-service-v1", templateVersion: "1.0"))
            context.insert(TaskDraft(taskID: "logistics-003", title: "物流签收 · 华东线", taskType: "物流", templateID: "delivery-v1", templateVersion: "1.0"))
        }
        ExecutionListService.seedTodayIfNeeded(in: context)
        try? context.save()
    }
}

@MainActor
enum ExecutionListService {
    static func todayKey(for timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    static func seedTodayIfNeeded(in context: ModelContext) {
        let key = todayKey()
        let listDescriptor = FetchDescriptor<ExecutionList>(predicate: #Predicate { $0.workDateKey == key })
        guard (try? context.fetch(listDescriptor).isEmpty) == true else { return }
        let draftDescriptor = FetchDescriptor<TaskDraft>(sortBy: [SortDescriptor(\TaskDraft.updatedAt, order: .reverse)])
        guard let primaryDraft = try? context.fetch(draftDescriptor).first else { return }

        let list = ExecutionList(workDateKey: key, title: "今日现场清单", assignmentDescription: "当前设备 · 本地缓存")
        context.insert(list)
        let examples = [
            ("CC-20260907-001", "控制柜", "CC-24A", "订单 SO-20260907-A"),
            ("CC-20260907-002", "控制柜", "CC-24A", "订单 SO-20260907-A"),
            ("CC-20260907-003", "配电组件", "PD-08", "订单 SO-20260907-A"),
            ("CC-20260907-004", "配电组件", "PD-08", "订单 SO-20260907-A"),
        ]
        for (code, name, model, order) in examples {
            context.insert(ExecutionItem(
                listID: list.id,
                draftID: primaryDraft.id,
                codeValue: code,
                productName: name,
                productModel: model,
                orderSummary: order
            ))
        }
    }

    static func item(matching code: String, in list: ExecutionList?, from items: [ExecutionItem]) -> ExecutionItem? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return items.first {
            $0.listID == list?.id && $0.codeValue.uppercased() == normalized && $0.state != .cancelled
        }
    }

    static func markStarted(_ item: ExecutionItem, capture: CaptureSession) {
        item.captureID = capture.id
        if item.state == .pending { item.state = .inProgress }
        item.updatedAt = .now
    }

    static func markCaptured(for capture: CaptureSession, in context: ModelContext) {
        guard let itemID = capture.executionItemID else { return }
        let descriptor = FetchDescriptor<ExecutionItem>(predicate: #Predicate { $0.id == itemID })
        guard let item = try? context.fetch(descriptor).first else { return }
        item.captureID = capture.id
        item.completedAt = capture.completedAt
        item.state = .captured
        item.updatedAt = .now
    }

    static func markSynced(for captureID: String, in context: ModelContext) {
        let captureDescriptor = FetchDescriptor<CaptureSession>(predicate: #Predicate { $0.id == captureID })
        guard let capture = try? context.fetch(captureDescriptor).first,
              let itemID = capture.executionItemID else { return }
        let itemDescriptor = FetchDescriptor<ExecutionItem>(predicate: #Predicate { $0.id == itemID })
        guard let item = try? context.fetch(itemDescriptor).first else { return }
        item.state = .synced
        item.updatedAt = .now
    }

    static func refreshToday(in context: ModelContext) async throws {
        let key = todayKey()
        let object = try await EdgeFlowClient.get(
            "/api/terminal/v1/execution-lists",
            queryItems: [
                URLQueryItem(name: "workDate", value: key),
                URLQueryItem(name: "terminalId", value: InstallationIDStore.value),
                URLQueryItem(name: "deviceId", value: InstallationIDStore.value),
            ]
        )
        let listObject = (object["list"] as? [String: Any]) ?? object
        let listID = (listObject["listId"] as? String) ?? (listObject["id"] as? String) ?? "edgeflow-\(key)"
        let descriptor = FetchDescriptor<ExecutionList>(predicate: #Predicate { $0.id == listID })
        let list = (try? context.fetch(descriptor).first) ?? ExecutionList(
            id: listID,
            workDateKey: (listObject["workDate"] as? String) ?? key,
            factoryTimeZoneID: (listObject["factoryTimeZoneId"] as? String) ?? TimeZone.current.identifier,
            title: (listObject["title"] as? String) ?? "今日现场清单",
            sourceVersion: (listObject["version"] as? String) ?? "1",
            assignmentDescription: (listObject["assignment"] as? String) ?? "当前设备"
        )
        if list.modelContext == nil { context.insert(list) }
        list.title = (listObject["title"] as? String) ?? list.title
        list.sourceVersion = (listObject["version"] as? String) ?? list.sourceVersion
        list.assignmentDescription = (listObject["assignment"] as? String) ?? list.assignmentDescription
        list.lastRefreshError = nil
        list.updatedAt = .now

        let payloadItems = (listObject["items"] as? [[String: Any]]) ?? []
        var drafts = (try? context.fetch(FetchDescriptor<TaskDraft>())) ?? []
        for payload in payloadItems {
            guard let workItemID = (payload["workItemId"] as? String) ?? (payload["id"] as? String),
                  let code = (payload["codeValue"] as? String) ?? (payload["sn"] as? String) else { continue }
            let taskID = (payload["taskId"] as? String) ?? "unassigned"
            let draft = drafts.first { $0.taskID == taskID } ?? {
                let titleParts = [
                    payload["productName"] as? String,
                    payload["orderSummary"] as? String,
                ].compactMap { $0 }.filter { !$0.isEmpty }
                let created = TaskDraft(
                    taskID: taskID,
                    title: titleParts.isEmpty ? "现场任务" : titleParts.joined(separator: " · "),
                    taskType: (payload["taskType"] as? String) ?? "现场",
                    templateID: (payload["templateId"] as? String) ?? "field-v1",
                    templateVersion: (payload["templateVersion"] as? String) ?? "1.0"
                )
                context.insert(created)
                drafts.append(created)
                let cacheDescriptor = FetchDescriptor<TaskCache>(predicate: #Predicate { $0.taskID == taskID })
                if (try? context.fetch(cacheDescriptor).first) == nil {
                    context.insert(TaskCache(taskID: taskID, templateID: created.templateID, templateVersion: created.templateVersion))
                }
                return created
            }()
            let itemDescriptor = FetchDescriptor<ExecutionItem>(predicate: #Predicate { $0.id == workItemID })
            let item = (try? context.fetch(itemDescriptor).first) ?? ExecutionItem(id: workItemID, listID: list.id, draftID: draft.id, codeValue: code)
            if item.modelContext == nil { context.insert(item) }
            item.listID = list.id
            item.draftID = draft.id
            item.codeID = (payload["codeId"] as? String) ?? item.codeID
            item.codeValue = code
            item.productName = (payload["productName"] as? String) ?? item.productName
            item.productModel = (payload["productModel"] as? String) ?? (payload["model"] as? String) ?? item.productModel
            item.orderSummary = (payload["orderSummary"] as? String) ?? (payload["orderNo"] as? String) ?? item.orderSummary
            if let rawState = payload["status"] as? String, let state = ExecutionItemState(rawValue: rawState.uppercased()) {
                item.state = state
            }
            item.updatedAt = .now
        }
        try context.save()
    }
}

@MainActor
enum TaskDraftService {
    static func startCapture(_ code: String, for draft: TaskDraft, executionItem: ExecutionItem? = nil, in context: ModelContext) throws -> CaptureSession {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = CodeValidator.validate(trimmedCode) {
            throw TaskDraftServiceError.invalidCode(failure)
        }

        let capture = CaptureSession(draftID: draft.id, codeValue: trimmedCode)
        capture.executionListID = executionItem?.listID
        capture.executionItemID = executionItem?.id
        context.insert(capture)
        if let executionItem { ExecutionListService.markStarted(executionItem, capture: capture) }
        draft.syncState = .queued
        draft.updatedAt = .now
        recordEvent(kind: "code.scanned", draft: draft, captureID: capture.id, codeValue: capture.codeValue, payload: ["code": trimmedCode], enqueue: true, in: context)
        try context.save()
        return capture
    }

    static func saveForm(_ form: FixedTaskForm, for draft: TaskDraft, submitting: Bool, in context: ModelContext) throws {
        if submitting {
            let missing = FixedTaskFormValidator.missingFields(for: form)
            guard missing.isEmpty else { throw TaskDraftServiceError.missingFields(missing) }
            guard draft.codeValidation != .notChecked, draft.codeValidation != .invalid else {
                throw TaskDraftServiceError.codeRequired
            }
        }

        draft.form = form
        draft.syncState = .queued
        draft.updatedAt = .now
        recordEvent(
            kind: submitting ? "form.submitted" : "form.saved",
            draft: draft,
            payload: ["templateId": draft.templateID, "templateVersion": draft.templateVersion],
            enqueue: true,
            in: context
        )
        try context.save()
    }

    static func addPhoto(_ image: UIImage, category: String, location: MediaLocationSnapshot, to capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws {
        try insertMedia(image: image, videoURL: nil, category: category, location: location, capture: capture, relatedScan: nil, draft: draft, in: context)
    }

    static func addVideo(at fileURL: URL, category: String, location: MediaLocationSnapshot, to capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws {
        try insertMedia(image: nil, videoURL: fileURL, category: category, location: location, capture: capture, relatedScan: nil, draft: draft, in: context)
    }

    static func addRelatedScan(_ code: String, kind: RelatedScanKind, to capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws -> RelatedScan {
        let trimmedCode = CodeValidator.normalizeRelated(code)
        if let failure = CodeValidator.validateRelated(trimmedCode) {
            throw TaskDraftServiceError.invalidCode(failure)
        }
        if trimmedCode.compare(capture.codeValue, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            throw TaskDraftServiceError.relatedCodeIsProductSN
        }
        let related = RelatedScan(parentCaptureID: capture.id, draftID: draft.id, codeValue: trimmedCode, kind: kind)
        context.insert(related)
        capture.updatedAt = .now
        draft.syncState = .queued
        draft.updatedAt = .now
        recordEvent(
            kind: "related.scanned",
            draft: draft,
            captureID: capture.id,
            codeValue: capture.codeValue,
            payload: [
                "relatedScanId": related.id,
                "relatedCode": trimmedCode,
                "relatedKind": kind.rawValue,
                "parentCode": capture.codeValue,
            ],
            enqueue: true,
            in: context
        )
        try context.save()
        return related
    }

    static func addRelatedPhoto(_ image: UIImage, location: MediaLocationSnapshot, to related: RelatedScan, capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws {
        try insertMedia(image: image, videoURL: nil, category: "关联图片", location: location, capture: capture, relatedScan: related, draft: draft, in: context)
    }

    static func addRelatedVideo(at fileURL: URL, location: MediaLocationSnapshot, to related: RelatedScan, capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws {
        try insertMedia(image: nil, videoURL: fileURL, category: "关联录像", location: location, capture: capture, relatedScan: related, draft: draft, in: context)
    }

    private static func insertMedia(image: UIImage?, videoURL: URL?, category: String, location: MediaLocationSnapshot, capture: CaptureSession, relatedScan: RelatedScan?, draft: TaskDraft, in context: ModelContext) throws {
        if relatedScan == nil {
            guard !capture.isCompleted, (capture.codeValidation == .locallyValid || capture.codeValidation == .serverConfirmed) else {
                throw TaskDraftServiceError.codeRequired
            }
        }
        let mediaID = ClientEventIdentity.make()
        let stored: StoredMedia
        if let image {
            stored = try MediaFileStore.store(image: image, mediaID: mediaID)
        } else if let videoURL {
            stored = try MediaFileStore.store(videoAt: videoURL, mediaID: mediaID)
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
        let media = LocalMedia(
            mediaID: mediaID,
            draftID: draft.id,
            captureID: capture.id,
            relatedScanID: relatedScan?.id,
            category: category,
            mediaType: stored.mediaType,
            originalPath: stored.originalPath,
            thumbnailPath: stored.thumbnailPath,
            checksum: stored.checksum,
            pixelWidth: stored.pixelWidth,
            pixelHeight: stored.pixelHeight,
            location: location
        )
        context.insert(media)
        relatedScan?.updatedAt = .now
        draft.mediaCount += 1
        draft.syncState = .queued
        draft.updatedAt = .now
        var payload = mediaEventPayload(for: media)
        if let relatedScan {
            payload["relatedScanId"] = relatedScan.id
            payload["relatedCode"] = relatedScan.codeValue
        }
        recordEvent(
            kind: stored.mediaType == "video" ? "media.recorded" : "media.captured",
            draft: draft,
            captureID: capture.id,
            codeValue: capture.codeValue,
            payload: payload,
            enqueue: true,
            in: context
        )
        try context.save()
    }

    static func completeCapture(_ capture: CaptureSession, for draft: TaskDraft, in context: ModelContext) throws {
        guard !capture.isCompleted else { return }
        capture.completedAt = .now
        capture.updatedAt = .now
        ExecutionListService.markCaptured(for: capture, in: context)
        draft.syncState = .queued
        draft.updatedAt = .now
        recordEvent(kind: "capture.completed", draft: draft, captureID: capture.id, codeValue: capture.codeValue, payload: ["mediaCount": "\(mediaCount(for: capture, in: context))"], enqueue: true, in: context)
        try context.save()
    }

    static func addNote(_ text: String, to capture: CaptureSession, draft: TaskDraft, in context: ModelContext) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw TaskDraftServiceError.emptyNote }
        context.insert(CaptureNote(captureID: capture.id, text: trimmedText))
        capture.updatedAt = .now
        draft.syncState = .queued
        draft.updatedAt = .now
        recordEvent(kind: "note.added", draft: draft, captureID: capture.id, codeValue: capture.codeValue, payload: ["note": trimmedText], enqueue: true, in: context)
        try context.save()
    }

    private static func mediaCount(for capture: CaptureSession, in context: ModelContext) -> Int {
        let captureID = capture.id
        let descriptor = FetchDescriptor<LocalMedia>(predicate: #Predicate { $0.captureID == captureID })
        return (try? context.fetch(descriptor))?.filter { !$0.isRelatedMedia }.count ?? 0
    }

    private static func mediaEventPayload(for media: LocalMedia) -> [String: String] {
        var payload = [
            "mediaId": media.mediaID,
            "checksum": media.checksum,
            "category": media.category,
            "locationStatus": media.locationStatusRaw,
        ]
        if let latitude = media.latitude { payload["latitude"] = String(latitude) }
        if let longitude = media.longitude { payload["longitude"] = String(longitude) }
        if let horizontalAccuracy = media.horizontalAccuracy { payload["horizontalAccuracy"] = String(horizontalAccuracy) }
        if let capturedAt = media.locationCapturedAt { payload["locationCapturedAt"] = ISO8601DateFormatter().string(from: capturedAt) }
        return payload
    }

    private static func recordEvent(kind: String, draft: TaskDraft, captureID: String? = nil, codeValue: String? = nil, payload: [String: String], enqueue: Bool, in context: ModelContext) {
        let eventID = ClientEventIdentity.make()
        var enrichedPayload = payload
        if let captureID {
            enrichedPayload["captureId"] = captureID
            let descriptor = FetchDescriptor<CaptureSession>(predicate: #Predicate { $0.id == captureID })
            if let capture = try? context.fetch(descriptor).first {
                if let listID = capture.executionListID { enrichedPayload["listId"] = listID }
                if let itemID = capture.executionItemID { enrichedPayload["workItemId"] = itemID }
                enrichedPayload["code"] = capture.codeValue
                enrichedPayload["codeValue"] = capture.codeValue
            }
        }
        let data = (try? JSONEncoder().encode(enrichedPayload)) ?? Data("{}".utf8)
        let body = String(decoding: data, as: UTF8.self)
        let event = LocalEvent(eventID: eventID, draftID: draft.id, captureID: captureID, kind: kind, codeValue: codeValue ?? draft.codeValue, payloadJSON: body)
        context.insert(event)
        if enqueue {
            context.insert(OutboxItem(eventID: eventID, kind: kind, bodyJSON: body))
            SyncScheduler.schedule(in: context)
        }
    }

}

enum TaskDraftServiceError: LocalizedError {
    case invalidCode(String)
    case missingFields([String])
    case codeRequired
    case emptyNote
    case relatedCodeIsProductSN

    var errorDescription: String? {
        switch self {
        case .invalidCode(let message): message
        case .missingFields(let fields): "请先填写：\(fields.joined(separator: "、"))。"
        case .codeRequired: "请先扫描或输入有效产品码，再继续采集。"
        case .emptyNote: "备注不能为空。"
        case .relatedCodeIsProductSN: "关联码不能与当前产品序列号相同。"
        }
    }
}

struct StoredMedia {
    let mediaType: String
    let originalPath: String
    let thumbnailPath: String
    let checksum: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Media files live under Application Support. We persist relative file names so paths
/// survive container UUID changes after reinstall / Xcode redeploy.
enum MediaFileStore {
    private static let maximumPhotoEdge: CGFloat = 1_920
    private static let photoCompressionQuality: CGFloat = 0.74

    static func store(image: UIImage, mediaID: String) throws -> StoredMedia {
        let storedImage = image.scaledToFit(maximumEdge: maximumPhotoEdge)
        guard let originalData = storedImage.jpegData(compressionQuality: photoCompressionQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let thumbnailImage = storedImage.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? storedImage
        guard let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.72) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = try mediaDirectory()
        let originalName = "\(mediaID).jpg"
        let thumbnailName = "\(mediaID)-thumb.jpg"
        try originalData.write(to: directory.appendingPathComponent(originalName), options: .atomic)
        try thumbnailData.write(to: directory.appendingPathComponent(thumbnailName), options: .atomic)
        let checksum = SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()

        return StoredMedia(
            mediaType: "image",
            originalPath: originalName,
            thumbnailPath: thumbnailName,
            checksum: checksum,
            pixelWidth: Int(storedImage.size.width),
            pixelHeight: Int(storedImage.size.height)
        )
    }

    static func store(videoAt sourceURL: URL, mediaID: String) throws -> StoredMedia {
        let videoData = try Data(contentsOf: sourceURL)
        let directory = try mediaDirectory()
        let originalName = "\(mediaID).mov"
        let thumbnailName = "\(mediaID)-thumb.jpg"
        try videoData.write(to: directory.appendingPathComponent(originalName), options: .atomic)

        let thumbnail = videoThumbnail(for: sourceURL) ?? UIImage(systemName: "video") ?? UIImage()
        guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.72) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try thumbnailData.write(to: directory.appendingPathComponent(thumbnailName), options: .atomic)
        let checksum = SHA256.hash(data: videoData).map { String(format: "%02x", $0) }.joined()

        return StoredMedia(
            mediaType: "video",
            originalPath: originalName,
            thumbnailPath: thumbnailName,
            checksum: checksum,
            pixelWidth: Int(thumbnail.size.width * thumbnail.scale),
            pixelHeight: Int(thumbnail.size.height * thumbnail.scale)
        )
    }

    static func resolveOriginalURL(mediaID: String, mediaType: String, storedPath: String) -> URL? {
        let candidates = originalCandidates(mediaID: mediaID, mediaType: mediaType, storedPath: storedPath)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func resolveThumbnailURL(mediaID: String, storedPath: String) -> URL? {
        let candidates = thumbnailCandidates(mediaID: mediaID, storedPath: storedPath)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Rewrite absolute legacy paths to relative names when the file is still reachable.
    static func healStoredPaths(for media: LocalMedia) {
        if let url = resolveOriginalURL(mediaID: media.mediaID, mediaType: media.mediaType, storedPath: media.originalPath) {
            let name = url.lastPathComponent
            if media.originalPath != name { media.originalPath = name }
        }
        if let url = resolveThumbnailURL(mediaID: media.mediaID, storedPath: media.thumbnailPath) {
            let name = url.lastPathComponent
            if media.thumbnailPath != name { media.thumbnailPath = name }
        }
    }

    private static func mediaDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CodeCam/Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func originalCandidates(mediaID: String, mediaType: String, storedPath: String) -> [URL] {
        var urls: [URL] = []
        if storedPath.hasPrefix("/") {
            urls.append(URL(fileURLWithPath: storedPath))
        }
        if let directory = try? mediaDirectory() {
            let fileName = (storedPath as NSString).lastPathComponent
            if !fileName.isEmpty { urls.append(directory.appendingPathComponent(fileName)) }
            let ext = mediaType == "video" ? "mov" : "jpg"
            urls.append(directory.appendingPathComponent("\(mediaID).\(ext)"))
            if mediaType != "video" {
                urls.append(directory.appendingPathComponent("\(mediaID).jpeg"))
                urls.append(directory.appendingPathComponent("\(mediaID).png"))
            }
        }
        return urls
    }

    private static func thumbnailCandidates(mediaID: String, storedPath: String) -> [URL] {
        var urls: [URL] = []
        if storedPath.hasPrefix("/") {
            urls.append(URL(fileURLWithPath: storedPath))
        }
        if let directory = try? mediaDirectory() {
            let fileName = (storedPath as NSString).lastPathComponent
            if !fileName.isEmpty { urls.append(directory.appendingPathComponent(fileName)) }
            urls.append(directory.appendingPathComponent("\(mediaID)-thumb.jpg"))
        }
        return urls
    }

    private static func videoThumbnail(for url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension LocalMedia {
    var resolvedOriginalURL: URL? {
        MediaFileStore.resolveOriginalURL(mediaID: mediaID, mediaType: mediaType, storedPath: originalPath)
    }

    var resolvedThumbnailURL: URL? {
        MediaFileStore.resolveThumbnailURL(mediaID: mediaID, storedPath: thumbnailPath)
    }

    var thumbnailImage: UIImage? {
        guard let url = resolvedThumbnailURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

private extension UIImage {
    /// Produces an orientation-normalized image whose longest edge does not exceed the storage limit.
    func scaledToFit(maximumEdge: CGFloat) -> UIImage {
        let sourceSize = size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return self }

        let scale = min(1, maximumEdge / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: (sourceSize.width * scale).rounded(.down),
            height: (sourceSize.height * scale).rounded(.down)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

enum ProductProfileService {
    static func fetch(code: String) async -> ProductProfile {
        do {
            let object = try await EdgeFlowClient.post(
                "/api/terminal/v1/codes/validate",
                body: ["codeValue": code, "terminalId": InstallationIDStore.value, "deviceId": InstallationIDStore.value]
            )
            let fields = (object["fields"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
            var profile = ProductProfile.platform(
                code: object["codeValue"] as? String ?? code,
                productReference: object["productRef"] as? String ?? object["productName"] as? String ?? "",
                status: object["profileStatus"] as? String ?? object["status"] as? String ?? "",
                fields: fields
            )
            profile.productName = object["productName"] as? String
            profile.productModel = object["productModel"] as? String ?? object["model"] as? String
            return profile
        } catch let error as EdgeFlowServiceError {
            return .pending(for: code, message: error.errorDescription ?? "当前无法连接平台，已保留本地扫码记录。")
        } catch {
            return .pending(for: code, message: "当前无法连接平台，已保留本地扫码记录。")
        }
    }
}

enum InstallationIDStore {
    private static let key = "codecam.installation-id"

    static var value: String {
        if let current = UserDefaults.standard.string(forKey: key) { return current }
        let created = ClientEventIdentity.make()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

enum KeychainStore {
    static func save(_ data: Data, account: String, service: String = "com.codecam.credentials") throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        let addQuery = query.merging([kSecValueData: data]) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func read(account: String, service: String = "com.codecam.credentials") throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    static func delete(account: String, service: String = "com.codecam.credentials") {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法访问设备安全凭证（状态码 \(status)）。" }
}

enum DeviceIdentity {
    static var serialNumber: String {
        let suffix = InstallationIDStore.value.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
        return "CODECAM-\(suffix)"
    }

    static var version: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var operatingSystem: String { "iOS \(UIDevice.current.systemVersion)" }
    static let capabilities = ["camera", "scanner", "photo", "video", "location", "background-sync"]
}

enum EdgeFlowServiceError: LocalizedError {
    case invalidBaseURL
    case rejected(status: Int, message: String)
    case invalidResponse
    case missingUploadURL
    case localMediaMissing

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "平台地址无效。"
        case .rejected(let status, let message):
            message.isEmpty ? "平台拒绝了请求（\(status)）。" : message
        case .invalidResponse: "平台响应格式无法识别。"
        case .missingUploadURL: "平台未返回可用的临时上传地址。"
        case .localMediaMissing: "本地媒体文件已不存在。"
        }
    }
}

enum PlatformDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }
}

enum EdgeFlowClient {
    static let baseURLKey = "codecam.edgeflow-base-url"
    static let defaultBaseURL = "http://192.168.1.5:8000"
    static let deviceTokenAccount = "edgeflow-device-token"
    static let userTokenAccount = "edgeflow-user-token"

    enum TokenKind {
        case none
        case device
        case user
    }

    static var baseURL: URL? {
        let value = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
        return URL(string: value)
    }

    static func post(_ path: String, body: [String: Any], idempotencyKey: String? = nil, usesDeviceToken: Bool = true) async throws -> [String: Any] {
        try await post(path, body: body, idempotencyKey: idempotencyKey, token: usesDeviceToken ? .device : .none)
    }

    static func post(_ path: String, body: [String: Any], idempotencyKey: String? = nil, token: TokenKind) async throws -> [String: Any] {
        var request = try request(path: path, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await performJSON(request)
    }

    static func get(_ path: String, queryItems: [URLQueryItem] = [], usesDeviceToken: Bool = true) async throws -> [String: Any] {
        try await get(path, queryItems: queryItems, token: usesDeviceToken ? .device : .none)
    }

    static func get(_ path: String, queryItems: [URLQueryItem] = [], token: TokenKind) async throws -> [String: Any] {
        var request = try request(path: path, method: "GET", token: token)
        guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw EdgeFlowServiceError.invalidBaseURL }
        components.queryItems = queryItems
        request.url = components.url
        return try await performJSON(request)
    }

    static func upload(fileURL: URL, to uploadURL: URL, method: String, headers: [String: String]) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw EdgeFlowServiceError.localMediaMissing }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EdgeFlowServiceError.rejected(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "对象存储未接受媒体文件。")
        }
    }

    private static func request(path: String, method: String, token: TokenKind) throws -> URLRequest {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw EdgeFlowServiceError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let account: String?
        switch token {
        case .none: account = nil
        case .device: account = deviceTokenAccount
        case .user: account = userTokenAccount
        }
        if let account,
           let tokenData = try? KeychainStore.read(account: account),
           let bearer = String(data: tokenData, encoding: .utf8), !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func performJSON(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw EdgeFlowServiceError.invalidResponse }
            guard 200..<300 ~= http.statusCode else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(platformMessage) ?? ""
                throw EdgeFlowServiceError.rejected(status: http.statusCode, message: message)
            }
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EdgeFlowServiceError.invalidResponse }
            return unwrap(raw)
        } catch let error as EdgeFlowServiceError {
            throw error
        } catch {
            throw EdgeFlowServiceError.rejected(status: -1, message: "无法连接平台：\(error.localizedDescription)")
        }
    }

    static func unwrap(_ value: [String: Any]) -> [String: Any] {
        for key in ["data", "result", "payload"] where value[key] is [String: Any] {
            return value[key] as! [String: Any]
        }
        return value
    }

    private static func platformMessage(_ object: [String: Any]) -> String? {
        if let nested = object["error"] as? [String: Any] {
            return nested["message"] as? String ?? nested["code"] as? String
        }
        return object["message"] as? String
            ?? (object["error"] as? String)
            ?? object["detail"] as? String
    }
}

@MainActor
enum AccountAuthService {
    static func session(in context: ModelContext) -> UserSessionRecord {
        let installationID = InstallationIDStore.value
        let descriptor = FetchDescriptor<UserSessionRecord>()
        if let existing = try? context.fetch(descriptor).first {
            if existing.installationID.isEmpty { existing.installationID = installationID }
            if existing.terminalID.isEmpty { existing.terminalID = installationID }
            return existing
        }
        let created = UserSessionRecord(userID: "anonymous", terminalID: installationID, installationID: installationID)
        context.insert(created)
        try? context.save()
        return created
    }

    static func register(username: String, password: String, displayName: String, in context: ModelContext) async throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = AccountCredentialsValidator.validateUsername(trimmedUsername) {
            throw EdgeFlowServiceError.rejected(status: 400, message: failure)
        }
        if let failure = AccountCredentialsValidator.validatePassword(password) {
            throw EdgeFlowServiceError.rejected(status: 400, message: failure)
        }
        if let failure = AccountCredentialsValidator.validateDisplayName(trimmedDisplayName) {
            throw EdgeFlowServiceError.rejected(status: 400, message: failure)
        }

        let object = try await EdgeFlowClient.post(
            "/api/v1/auth/register",
            body: [
                "username": trimmedUsername,
                "password": password,
                "displayName": trimmedDisplayName,
                "contextType": "STAFF",
            ],
            token: .none
        )
        try apply(object, username: trimmedUsername, displayName: trimmedDisplayName, in: context)
    }

    static func login(username: String, password: String, in context: ModelContext) async throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = AccountCredentialsValidator.validateUsername(trimmedUsername) {
            throw EdgeFlowServiceError.rejected(status: 400, message: failure)
        }
        if password.isEmpty {
            throw EdgeFlowServiceError.rejected(status: 400, message: "请输入密码。")
        }

        let object = try await EdgeFlowClient.post(
            "/api/v1/auth/login",
            body: [
                "username": trimmedUsername,
                "password": password,
                "contextType": "STAFF",
            ],
            token: .none
        )
        let displayName = (object["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        try apply(
            object,
            username: trimmedUsername,
            displayName: (displayName?.isEmpty == false ? displayName! : trimmedUsername),
            in: context
        )
    }

    static func logout(in context: ModelContext) {
        KeychainStore.delete(account: EdgeFlowClient.userTokenAccount)
        let session = session(in: context)
        session.userID = "anonymous"
        session.username = ""
        session.displayName = ""
        session.platformOperator = false
        session.isAuthenticated = false
        session.expiresAt = nil
        session.updatedAt = .now
        try? context.save()
    }

    private static func apply(_ object: [String: Any], username: String, displayName: String, in context: ModelContext) throws {
        guard let userID = object["userId"] as? String, !userID.isEmpty else {
            throw EdgeFlowServiceError.invalidResponse
        }
        guard let token = object["token"] as? String, !token.isEmpty else {
            throw EdgeFlowServiceError.invalidResponse
        }
        try KeychainStore.save(Data(token.utf8), account: EdgeFlowClient.userTokenAccount)

        let session = session(in: context)
        session.userID = userID
        session.username = username
        session.displayName = (object["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? displayName
        session.platformOperator = (object["platformOperator"] as? Bool) ?? false
        session.isAuthenticated = true
        session.updatedAt = .now
        try context.save()
    }
}

@MainActor
enum DeviceRegistrationService {
    static func registration(in context: ModelContext) -> DeviceRegistration {
        let terminalID = InstallationIDStore.value
        let descriptor = FetchDescriptor<DeviceRegistration>(predicate: #Predicate { $0.terminalID == terminalID })
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = DeviceRegistration(terminalID: terminalID, serialNumber: DeviceIdentity.serialNumber)
        context.insert(created)
        try? context.save()
        return created
    }

    static func beginPairing(_ registration: DeviceRegistration, in context: ModelContext, forceRefresh: Bool = false) async throws {
        registration.state = .pairing
        registration.lastError = nil
        registration.updatedAt = .now
        try context.save()
        var body = devicePayload(for: registration)
        if forceRefresh { body["forceRefresh"] = true }
        let object = try await EdgeFlowClient.post("/api/terminal/v1/pair/hello", body: body, usesDeviceToken: false)
        apply(object, to: registration)
        let nextState = state(in: object, fallback: .pairing)
        registration.state = nextState
        registration.updatedAt = .now
        try context.save()
        if nextState == .claimed || nextState == .registered || nextState == .online || deviceTokenExists {
            _ = try await finishConnection(registration, in: context)
        }
    }

    static func refreshVerificationCode(_ registration: DeviceRegistration, in context: ModelContext) async throws {
        try await beginPairing(registration, in: context, forceRefresh: true)
    }

    /// Poll pair/status and silently advance to registered/online when the factory has claimed the device.
    /// Returns true when the device is connected enough to stop polling.
    @discardableResult
    static func pollAndAdvance(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        var items = [URLQueryItem(name: "terminalId", value: registration.terminalID)]
        if let pairingID = registration.pairingID {
            items.append(URLQueryItem(name: "pairingId", value: pairingID))
        }
        let object = try await EdgeFlowClient.get(
            "/api/terminal/v1/pair/status",
            queryItems: items,
            usesDeviceToken: deviceTokenExists
        )
        apply(object, to: registration)
        let nextState = state(in: object, fallback: registration.state)
        registration.state = nextState
        registration.lastError = nil
        registration.updatedAt = .now
        try context.save()

        if nextState == .pairing {
            return false
        }
        if nextState == .claimed || nextState == .registered || nextState == .online || deviceTokenExists {
            return try await finishConnection(registration, in: context)
        }
        return nextState == .registered || nextState == .online
    }

    @discardableResult
    static func finishConnection(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        if registration.state == .online {
            return true
        }
        if registration.state == .registered {
            try await sendHeartbeat(registration, in: context)
            return registration.state == .online || registration.state == .registered
        }
        if !deviceTokenExists {
            // Ask status again so the platform can mint a bootstrap token.
            var items = [URLQueryItem(name: "terminalId", value: registration.terminalID)]
            if let pairingID = registration.pairingID {
                items.append(URLQueryItem(name: "pairingId", value: pairingID))
            }
            let object = try await EdgeFlowClient.get("/api/terminal/v1/pair/status", queryItems: items, usesDeviceToken: false)
            apply(object, to: registration)
            registration.state = state(in: object, fallback: registration.state)
            registration.updatedAt = .now
            try context.save()
        }
        guard deviceTokenExists else {
            throw EdgeFlowServiceError.rejected(status: 401, message: "尚未拿到设备凭证，请稍后再试或刷新验证码。")
        }
        try await register(registration, in: context)
        try await sendHeartbeat(registration, in: context)
        return registration.state == .online || registration.state == .registered
    }

    static func register(_ registration: DeviceRegistration, in context: ModelContext) async throws {
        registration.lastError = nil
        registration.updatedAt = .now
        try context.save()
        let object = try await EdgeFlowClient.post("/api/terminal/v1/devices/register", body: devicePayload(for: registration), usesDeviceToken: true)
        apply(object, to: registration)
        registration.state = state(in: object, fallback: .registered)
        registration.updatedAt = .now
        try context.save()
        try? await refreshStorageConfig(registration, in: context)
    }

    static func sendHeartbeat(_ registration: DeviceRegistration, in context: ModelContext) async throws {
        guard registration.state == .registered || registration.state == .online || registration.state == .offline || registration.state == .failed else { return }
        let nextSequence = registration.heartbeatSequence + 1
        let health: [String: Any] = [
            "status": "healthy",
            "network": "online",
            "storage": availableStorageStatus(),
            "camera": cameraStatus(),
        ]
        do {
            let object = try await EdgeFlowClient.post("/api/terminal/v1/heartbeat", body: [
                "terminalId": registration.terminalID,
                "deviceId": registration.terminalID,
                "seq": nextSequence,
                "event": "heartbeat",
                "occurredAt": ISO8601DateFormatter().string(from: .now),
                "health": health,
            ])
            apply(object, to: registration)
            registration.heartbeatSequence = nextSequence
            registration.lastHeartbeatAt = .now
            registration.lastError = nil
            registration.state = state(in: object, fallback: .online)
            registration.updatedAt = .now
            try context.save()
            try? await refreshStorageConfig(registration, in: context)
        } catch let error as EdgeFlowServiceError {
            if case .rejected(let status, _) = error, status == 401 || status == 403 {
                if try await refreshDeviceToken(registration, in: context) {
                    try await sendHeartbeat(registration, in: context)
                    return
                }
            }
            throw error
        }
    }

    static func refreshStorageConfig(_ registration: DeviceRegistration, in context: ModelContext) async throws {
        let object = try await EdgeFlowClient.get("/api/terminal/v1/storage-config")
        applyStorage(object, to: registration)
        registration.updatedAt = .now
        try context.save()
    }

    /// Soft connectivity loss: keep the device recoverable without showing “连接异常”.
    static func markOffline(_ error: Error, for registration: DeviceRegistration, in context: ModelContext) {
        registration.lastError = error.localizedDescription
        if registration.state == .registered || registration.state == .online || registration.state == .offline {
            registration.state = .offline
        }
        registration.updatedAt = .now
        try? context.save()
    }

    static func recordError(_ error: Error, for registration: DeviceRegistration, in context: ModelContext) {
        registration.lastError = error.localizedDescription
        // Keep recoverable in-progress states so automatic polling can continue.
        if registration.state != .pairing && registration.state != .claimed {
            registration.state = .failed
        }
        registration.updatedAt = .now
        try? context.save()
    }

    @discardableResult
    private static func refreshDeviceToken(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        guard deviceTokenExists else { return false }
        let serial = registration.serialNumber.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? registration.serialNumber
        do {
            let object = try await EdgeFlowClient.post(
                "/api/terminal/v1/terminals/\(serial)/token/refresh",
                body: [
                    "terminalId": registration.terminalID,
                    "deviceId": registration.terminalID,
                ],
                usesDeviceToken: true
            )
            let token = (object["terminalToken"] as? String)
                ?? (object["deviceToken"] as? String)
                ?? (object["accessToken"] as? String)
                ?? (object["token"] as? String)
            guard let token, !token.isEmpty else { return false }
            try KeychainStore.save(Data(token.utf8), account: EdgeFlowClient.deviceTokenAccount)
            registration.lastError = nil
            registration.updatedAt = .now
            try context.save()
            return true
        } catch {
            var items = [URLQueryItem(name: "terminalId", value: registration.terminalID)]
            if let pairingID = registration.pairingID {
                items.append(URLQueryItem(name: "pairingId", value: pairingID))
            }
            guard let object = try? await EdgeFlowClient.get(
                "/api/terminal/v1/pair/status",
                queryItems: items,
                usesDeviceToken: true
            ) else { return false }
            apply(object, to: registration)
            registration.updatedAt = .now
            try? context.save()
            return deviceTokenExists
        }
    }

    private static func devicePayload(for registration: DeviceRegistration) -> [String: Any] {
        [
            "terminalId": registration.terminalID,
            "deviceId": registration.terminalID,
            "serialNumber": registration.serialNumber,
            "terminalType": "CODE_CAM",
            "version": DeviceIdentity.version,
            "os": DeviceIdentity.operatingSystem,
            "capabilities": DeviceIdentity.capabilities,
        ]
    }

    private static var deviceTokenExists: Bool {
        guard let token = try? KeychainStore.read(account: EdgeFlowClient.deviceTokenAccount) else { return false }
        return !token.isEmpty
    }

    private static func apply(_ object: [String: Any], to registration: DeviceRegistration) {
        registration.pairingID = (object["pairingId"] as? String) ?? (object["pairId"] as? String) ?? registration.pairingID
        registration.verificationCode = (object["verificationCode"] as? String) ?? (object["pairingCode"] as? String) ?? (object["code"] as? String) ?? registration.verificationCode
        registration.factoryName = (object["factoryName"] as? String) ?? (object["factory"] as? String) ?? registration.factoryName
        if let expiresAt = object["expiresAt"] as? String {
            registration.pairingExpiresAt = PlatformDateParser.parse(expiresAt)
        }
        let token = (object["deviceToken"] as? String) ?? (object["accessToken"] as? String) ?? (object["token"] as? String)
        if let token, !token.isEmpty { try? KeychainStore.save(Data(token.utf8), account: EdgeFlowClient.deviceTokenAccount) }
        applyStorage(object, to: registration)
    }

    private static func applyStorage(_ object: [String: Any], to registration: DeviceRegistration) {
        let storage = object["storage"] ?? object["config"]
        let configured = object["configured"]
        guard storage != nil || configured != nil else { return }
        var payload: [String: Any] = [:]
        if let configured { payload["configured"] = configured }
        if let storage { payload["storage"] = storage }
        if let config = object["config"] { payload["config"] = config }
        if let credentials = object["credentials"] { payload["credentials"] = credentials }
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            registration.storageConfigJSON = text
        }
    }

    private static func state(in object: [String: Any], fallback: DeviceConnectionState) -> DeviceConnectionState {
        let raw = (object["status"] as? String) ?? (object["state"] as? String) ?? fallback.rawValue
        return DeviceConnectionState(rawValue: raw.uppercased()) ?? fallback
    }

    private static func availableStorageStatus() -> String {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage, available > 256 * 1024 * 1024 else { return "low" }
        return "normal"
    }

    private static func cameraStatus() -> String {
        AVCaptureDevice.authorizationStatus(for: .video) == .denied ? "unavailable" : "online"
    }
}

@MainActor
enum SyncScheduler {
    private static var pending: Task<Void, Never>?

    /// Debounce burst captures (photo + note) into one sync pass.
    static func schedule(in context: ModelContext, delayNanoseconds: UInt64 = 1_500_000_000) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            let registration = DeviceRegistrationService.registration(in: context)
            guard registration.state == .registered || registration.state == .online || registration.state == .offline else { return }
            _ = try? await EdgeFlowSyncService.syncAll(in: context)
        }
    }
}

@MainActor
enum EdgeFlowSyncService {
    static func healAllMediaPaths(in context: ModelContext) {
        let descriptor = FetchDescriptor<LocalMedia>()
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }
        var changed = false
        for media in items {
            let beforeOriginal = media.originalPath
            let beforeThumbnail = media.thumbnailPath
            MediaFileStore.healStoredPaths(for: media)
            if media.originalPath != beforeOriginal || media.thumbnailPath != beforeThumbnail {
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    static func syncAll(in context: ModelContext) async throws -> Int {
        let registration = DeviceRegistrationService.registration(in: context)
        guard registration.state == .registered || registration.state == .online || registration.state == .offline else {
            throw EdgeFlowServiceError.rejected(status: 401, message: "请先完成设备注册，再同步现场数据。")
        }
        healAllMediaPaths(in: context)
        reclaimRetriableItems(in: context)
        let descriptor = FetchDescriptor<OutboxItem>(sortBy: [SortDescriptor(\OutboxItem.createdAt)])
        let now = Date.now
        let queue = try context.fetch(descriptor)
            .filter {
                ($0.state == .queued || $0.state == .failed)
                    && ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
            }
            .sorted {
                let left = syncPriority(for: $0.kind)
                let right = syncPriority(for: $1.kind)
                return left == right ? $0.createdAt < $1.createdAt : left < right
            }
        var completed = 0
        for item in queue {
            do {
                try await sync(item, registration: registration, in: context)
                completed += 1
            } catch {
                item.state = failureState(for: error)
                item.retryCount += 1
                item.lastError = error.localizedDescription
                item.nextRetryAt = item.state == .failed
                    ? Date.now.addingTimeInterval(min(pow(2, Double(item.retryCount)) * 15, 15 * 60))
                    : nil
                try context.save()
            }
        }
        return completed
    }

    static func retry(_ item: OutboxItem, in context: ModelContext) {
        item.state = .queued
        item.nextRetryAt = nil
        item.lastError = nil
        try? context.save()
        SyncScheduler.schedule(in: context, delayNanoseconds: 300_000_000)
    }

    static func abandon(_ item: OutboxItem, in context: ModelContext) {
        item.state = .abandoned
        item.nextRetryAt = nil
        if item.lastError == nil || item.lastError?.isEmpty == true {
            item.lastError = "已在本机放弃同步，本地记录仍保留。"
        }
        try? context.save()
    }

    /// Historical items often got stuck as NEEDS_REVIEW (401 before device login)
    /// or UPLOADING/REGISTERING if the app was interrupted mid-sync. Requeue them once
    /// the device is online so "立即同步" can drain the backlog.
    private static func reclaimRetriableItems(in context: ModelContext) {
        let descriptor = FetchDescriptor<OutboxItem>()
        guard let items = try? context.fetch(descriptor) else { return }
        var changed = false
        for item in items {
            switch item.state {
            case .uploading, .registering:
                item.state = .queued
                item.nextRetryAt = nil
                changed = true
            case .needsReview:
                // Device is online now; give historical backlog another chance.
                // Permanent problems (missing local media, bad payload) will fall back to needsReview.
                if item.lastError?.contains("本地媒体文件已不存在") == true {
                    continue
                }
                item.state = .queued
                item.nextRetryAt = nil
                changed = true
            default:
                continue
            }
        }
        if changed { try? context.save() }
    }

    private static func sync(_ item: OutboxItem, registration: DeviceRegistration, in context: ModelContext) async throws {
        let eventID = item.eventID
        let eventDescriptor = FetchDescriptor<LocalEvent>(predicate: #Predicate { $0.eventID == eventID })
        guard let event = try context.fetch(eventDescriptor).first else {
            item.state = .synced
            try context.save()
            return
        }
        let draftID = event.draftID
        let draftDescriptor = FetchDescriptor<TaskDraft>(predicate: #Predicate { $0.id == draftID })
        guard let draft = try context.fetch(draftDescriptor).first else { throw EdgeFlowServiceError.invalidResponse }
        item.state = .uploading
        try context.save()
        let payload = (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any]) ?? [:]
        let body: [String: Any] = [
            "eventId": event.eventID,
            "eventType": eventType(for: event.kind),
            "taskId": draft.taskID,
            "codeValue": event.codeValue ?? NSNull(),
            "captureId": event.captureID ?? NSNull(),
            "terminalId": registration.terminalID,
            "deviceId": registration.terminalID,
            "occurredAt": ISO8601DateFormatter().string(from: event.occurredAt),
            "payload": payload,
        ]
        _ = try await EdgeFlowClient.post("/api/terminal/v1/events", body: body, idempotencyKey: event.eventID)
        event.syncStateRaw = SyncState.synced.rawValue

        if event.kind == "capture.completed", let captureID = event.captureID {
            ExecutionListService.markSynced(for: captureID, in: context)
        }

        if let mediaID = payload["mediaId"] as? String {
            let mediaIdentifier = mediaID
            let mediaDescriptor = FetchDescriptor<LocalMedia>(predicate: #Predicate { $0.mediaID == mediaIdentifier })
            if let media = try context.fetch(mediaDescriptor).first {
                try await upload(media, event: event, draft: draft, registration: registration)
                media.syncState = .synced
            }
        }
        item.state = .synced
        item.lastError = nil
        try context.save()
    }

    private static func upload(_ media: LocalMedia, event: LocalEvent, draft: TaskDraft, registration: DeviceRegistration) async throws {
        media.syncState = .uploading
        MediaFileStore.healStoredPaths(for: media)
        guard let fileURL = media.resolvedOriginalURL else { throw EdgeFlowServiceError.localMediaMissing }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ticket = try await EdgeFlowClient.post("/api/terminal/v1/media/upload-ticket", body: [
            "mediaId": media.mediaID,
            "eventId": event.eventID,
            "taskId": draft.taskID,
            "codeValue": event.codeValue ?? NSNull(),
            "captureId": event.captureID ?? NSNull(),
            "terminalId": registration.terminalID,
            "deviceId": registration.terminalID,
            "mediaType": media.mediaType,
            "category": media.category,
            "checksum": media.checksum,
            "fileSize": size,
            "capturedAt": ISO8601DateFormatter().string(from: media.capturedAt),
            "location": locationPayload(for: media),
        ], idempotencyKey: media.mediaID)
        guard let uploadURLText = ticket["uploadUrl"] as? String, let uploadURL = URL(string: uploadURLText) else {
            throw EdgeFlowServiceError.missingUploadURL
        }
        let headers = (ticket["headers"] as? [String: Any] ?? ticket["uploadHeaders"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        try await EdgeFlowClient.upload(fileURL: fileURL, to: uploadURL, method: (ticket["method"] as? String) ?? "PUT", headers: headers)
        media.syncState = .registering
        _ = try await EdgeFlowClient.post("/api/terminal/v1/media/\(media.mediaID)/complete", body: [
            "mediaId": media.mediaID,
            "eventId": event.eventID,
            "taskId": draft.taskID,
            "codeValue": event.codeValue ?? NSNull(),
            "captureId": event.captureID ?? NSNull(),
            "mediaType": media.mediaType,
            "category": media.category,
            "objectKey": (ticket["objectKey"] as? String) ?? "",
            "storageProvider": (ticket["storageProvider"] as? String) ?? "COS",
            "checksum": media.checksum,
            "fileSize": size,
            "capturedAt": ISO8601DateFormatter().string(from: media.capturedAt),
            "location": locationPayload(for: media),
        ], idempotencyKey: media.mediaID)
    }

    private static func locationPayload(for media: LocalMedia) -> [String: Any] {
        [
            "status": media.locationStatusRaw,
            "latitude": media.latitude ?? NSNull(),
            "longitude": media.longitude ?? NSNull(),
            "horizontalAccuracy": media.horizontalAccuracy ?? NSNull(),
            "capturedAt": media.locationCapturedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
        ]
    }

    private static func eventType(for kind: String) -> String {
        switch kind {
        case "code.scanned": "SCAN"
        case "media.captured", "media.recorded": "MEDIA_CAPTURED"
        case "capture.completed": "CAPTURE_COMPLETED"
        case "form.submitted": "FORM_SUBMITTED"
        case "related.scanned": "RELATED_CODE"
        case "note.added": "NOTE_ADDED"
        default: "FORM_SAVED"
        }
    }

    private static func syncPriority(for kind: String) -> Int {
        switch kind {
        case "code.scanned": 0
        case "related.scanned", "media.captured", "media.recorded", "note.added", "form.saved", "form.submitted": 1
        case "capture.completed": 2
        default: 1
        }
    }

    private static func failureState(for error: Error) -> SyncState {
        guard let serviceError = error as? EdgeFlowServiceError else { return .failed }
        switch serviceError {
        case .rejected(let status, _):
            if status == 409 { return .conflict }
            // Auth / temporary client errors should remain retryable after device reconnects.
            if status == 401 || status == 403 { return .failed }
            if (400..<500).contains(status) { return .needsReview }
            return .failed
        case .localMediaMissing:
            return .needsReview
        case .invalidBaseURL, .invalidResponse, .missingUploadURL:
            return .failed
        }
    }
}
