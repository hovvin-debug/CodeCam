import AVFoundation
import CryptoKit
import Foundation
import Security
import SwiftData
import UIKit

@MainActor
enum TaskBootstrapper {
    static func seedIfNeeded(in context: ModelContext) {
        let sessionDescriptor = FetchDescriptor<UserSessionRecord>()
        if (try? context.fetchCount(sessionDescriptor)) == 0 {
            let installationID = InstallationIDStore.value
            context.insert(UserSessionRecord(userID: "anonymous", terminalID: installationID, installationID: installationID))
            context.insert(DeviceRegistration(terminalID: installationID, serialNumber: DeviceIdentity.serialNumber))
        }
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
        let previousVersion = list.sourceVersion
        list.title = (listObject["title"] as? String) ?? list.title
        list.sourceVersion = (listObject["version"] as? String) ?? list.sourceVersion
        list.assignmentDescription = (listObject["assignment"] as? String) ?? list.assignmentDescription
        list.lastRefreshError = nil
        list.updatedAt = .now

        let payloadItems = (listObject["items"] as? [[String: Any]]) ?? []
        let incomingItemIDs = Set(payloadItems.compactMap { ($0["workItemId"] as? String) ?? ($0["id"] as? String) })
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
            let existingItem = try? context.fetch(itemDescriptor).first
            let item = existingItem ?? ExecutionItem(id: workItemID, listID: list.id, draftID: draft.id, codeValue: code)
            if item.modelContext == nil { context.insert(item) }
            let incomingTemplateVersion = (payload["templateVersion"] as? String) ?? draft.templateVersion
            let hasLocalCapture = item.captureID != nil || item.state == .inProgress || item.state == .captured
            if existingItem != nil, !item.templateVersion.isEmpty, item.templateVersion != incomingTemplateVersion {
                item.changeNotice = hasLocalCapture
                    ? "任务模板已更新；已开始的采集继续保留原模板上下文。"
                    : "任务模板已更新，请确认新的采集要求。"
            }
            if !hasLocalCapture {
                draft.templateVersion = incomingTemplateVersion
            }
            item.listID = list.id
            item.draftID = draft.id
            item.codeID = (payload["codeId"] as? String) ?? item.codeID
            item.codeValue = code
            item.productName = (payload["productName"] as? String) ?? item.productName
            item.productModel = (payload["productModel"] as? String) ?? (payload["model"] as? String) ?? item.productModel
            item.orderSummary = (payload["orderSummary"] as? String) ?? (payload["orderNo"] as? String) ?? item.orderSummary
            item.templateVersion = incomingTemplateVersion
            item.priority = TaskPriority(rawValue: ((payload["priority"] as? String) ?? "NORMAL").uppercased()) ?? .normal
            item.dueAt = (payload["dueAt"] as? String).flatMap(PlatformDateParser.parse)
            item.taskStateRaw = (payload["taskState"] as? String) ?? item.taskStateRaw
            if let requirements = payload["requirements"] as? [String: Any] {
                let evidence = (requirements["evidence"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                    guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
                    let minimum = entry["minimum"] as? Int ?? 1
                    return "\(label) ≥ \(minimum)"
                }
                let fields = (requirements["fields"] as? [String] ?? []).filter { !$0.isEmpty }
                if let evidenceData = try? JSONSerialization.data(withJSONObject: requirements["evidence"] ?? []),
                   let encodedEvidence = String(data: evidenceData, encoding: .utf8) {
                    item.requiredEvidenceJSON = encodedEvidence
                }
                let evidenceCount = requirements["evidenceCount"] as? Int ?? evidence.count
                let fieldCount = requirements["fieldCount"] as? Int ?? fields.count
                let parts = evidence + fields.map { "填写：\($0)" }
                item.requirementSummary = parts.isEmpty
                    ? "无额外采集要求"
                    : parts.joined(separator: " · ") + "（" + String(evidenceCount) + " 项取证，" + String(fieldCount) + " 项填写）"
            }
            if let changeNotice = payload["changeNotice"] as? String, !changeNotice.isEmpty {
                item.changeNotice = changeNotice
            }
            if let rawState = payload["status"] as? String, let state = ExecutionItemState(rawValue: rawState.uppercased()) {
                if state == .cancelled || !hasLocalCapture || state != .pending {
                    item.state = state
                }
            }
            item.updatedAt = .now
        }
        if previousVersion != list.sourceVersion {
            let localItems = (try? context.fetch(FetchDescriptor<ExecutionItem>())) ?? []
            let missingItems = localItems.filter {
                $0.listID == list.id && !incomingItemIDs.contains($0.id) && ($0.captureID != nil || $0.state == .inProgress || $0.state == .captured)
            }
            for item in missingItems where (item.changeNotice ?? "").isEmpty {
                item.changeNotice = "该任务已从最新清单移除；本地采集记录已保留。"
            }
            if !missingItems.isEmpty {
                list.lastChangeNotice = "清单已更新：" + String(missingItems.count) + " 项本地任务不再出现在最新清单中。"
            } else {
                list.lastChangeNotice = "清单已更新，请留意任务要求和优先级。"
            }
        }
        try context.save()
    }
}

@MainActor
enum TaskDraftService {
    /// Creates the v1 local-first unit of work: exactly one task row for one external SN.
    static func createScannedTask(_ code: String, in context: ModelContext) throws -> (ExecutionItem, CaptureSession) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = CodeValidator.validate(normalized) {
            throw TaskDraftServiceError.invalidCode(failure)
        }

        let captures = (try? context.fetch(FetchDescriptor<CaptureSession>())) ?? []
        if let existingCapture = captures.first(where: {
            !$0.isCompleted && $0.codeValue.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }), let itemID = existingCapture.executionItemID {
            let items = (try? context.fetch(FetchDescriptor<ExecutionItem>())) ?? []
            if let existingItem = items.first(where: { $0.id == itemID }) {
                return (existingItem, existingCapture)
            }
        }

        let key = ExecutionListService.todayKey()
        let lists = (try? context.fetch(FetchDescriptor<ExecutionList>())) ?? []
        let list: ExecutionList
        if let existing = lists.first(where: { $0.workDateKey == key }) {
            list = existing
        } else {
            list = ExecutionList(workDateKey: key, title: "今日扫码任务", assignmentDescription: "CodeCam 本地")
            context.insert(list)
        }

        let taskID = ClientEventIdentity.make()
        let draft = TaskDraft(
            taskID: taskID,
            title: normalized,
            taskType: "SN_EVIDENCE",
            templateID: "codecam-sn-v1",
            templateVersion: "1.0"
        )
        draft.codeValue = normalized
        draft.codeValidation = .locallyValid
        context.insert(draft)

        let item = ExecutionItem(
            listID: list.id,
            draftID: draft.id,
            codeValue: normalized,
            state: .pending
        )
        context.insert(item)
        let capture = try startCapture(normalized, for: draft, executionItem: item, in: context)
        return (item, capture)
    }

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
        var eventPayload: [String: Any] = [
            "templateId": draft.templateID,
            "templateVersion": draft.templateVersion,
        ]
        if submitting {
            eventPayload["fields"] = form.eventFields
        }
        recordEvent(
            kind: submitting ? "form.submitted" : "form.saved",
            draft: draft,
            payload: eventPayload,
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
        if let executionItemID = capture.executionItemID {
            let itemDescriptor = FetchDescriptor<ExecutionItem>(predicate: #Predicate { $0.id == executionItemID })
            if let item = try? context.fetch(itemDescriptor).first {
                let captureID: String? = capture.id
                let mediaDescriptor = FetchDescriptor<LocalMedia>(predicate: #Predicate<LocalMedia> { media in
                    media.captureID == captureID
                })
                let localMedia = (try? context.fetch(mediaDescriptor))?.filter { !$0.isRelatedMedia } ?? []
                let missing = item.requiredEvidence.compactMap { requirement -> String? in
                    let available = localMedia.filter { $0.category == requirement.label }.count
                    return available < requirement.minimum ? "\(requirement.label)（还差 \(requirement.minimum - available) 项）" : nil
                }
                if !missing.isEmpty { throw TaskDraftServiceError.missingEvidence(missing) }
            }
        }
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

    private static func recordEvent(kind: String, draft: TaskDraft, captureID: String? = nil, codeValue: String? = nil, payload: [String: Any], enqueue: Bool, in context: ModelContext) {
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
        let data = (try? JSONSerialization.data(withJSONObject: enrichedPayload)) ?? Data("{}".utf8)
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
    case missingEvidence([String])

    var errorDescription: String? {
        switch self {
        case .invalidCode(let message): message
        case .missingFields(let fields): "请先填写：\(fields.joined(separator: "、"))。"
        case .codeRequired: "请先扫描或输入有效产品码，再继续采集。"
        case .emptyNote: "备注不能为空。"
        case .relatedCodeIsProductSN: "关联码不能与当前产品序列号相同。"
        case .missingEvidence(let items): "请先补齐：\(items.joined(separator: "、"))。"
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
    private static let defaultMaximumPhotoEdge: CGFloat = 720
    private static let defaultPhotoCompressionQuality: CGFloat = 0.78
    private static let defaultThumbnailMaximumBytes = 262_144

    private static var thumbnailMaximumEdge: CGFloat {
        let value = UserDefaults.standard.double(forKey: "thumbnail.maxEdge")
        return value > 0 ? min(max(value, 160), 2048) : defaultMaximumPhotoEdge
    }

    private static var thumbnailQuality: CGFloat {
        let value = UserDefaults.standard.double(forKey: "thumbnail.quality")
        return value > 0 ? min(max(value, 0.35), 0.95) : defaultPhotoCompressionQuality
    }

    private static var thumbnailMaximumBytes: Int {
        let value = UserDefaults.standard.integer(forKey: "thumbnail.maxBytes")
        return value > 0 ? min(max(value, 32 * 1024), 1024 * 1024) : defaultThumbnailMaximumBytes
    }

    private static var photoCompressionQuality: CGFloat {
        defaultPhotoCompressionQuality
    }

    static func applyThumbnailPolicy(_ object: [String: Any]) {
        guard let image = object["image"] as? [String: Any] else { return }
        if let value = image["maxEdge"] as? NSNumber { UserDefaults.standard.set(value.doubleValue, forKey: "thumbnail.maxEdge") }
        if let value = image["quality"] as? NSNumber { UserDefaults.standard.set(value.doubleValue, forKey: "thumbnail.quality") }
        if let value = image["maxBytes"] as? NSNumber { UserDefaults.standard.set(value.intValue, forKey: "thumbnail.maxBytes") }
        if let value = object["version"] as? NSNumber { UserDefaults.standard.set(value.intValue, forKey: "thumbnail.policyVersion") }
    }

    static func store(image: UIImage, mediaID: String) throws -> StoredMedia {
        let storedImage = image.scaledToFit(maximumEdge: max(thumbnailMaximumEdge, 1920))
        guard let originalData = storedImage.jpegData(compressionQuality: photoCompressionQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let thumbnailImage = storedImage.scaledToFit(maximumEdge: thumbnailMaximumEdge)
        guard let thumbnailData = boundedJPEGData(image: thumbnailImage, quality: thumbnailQuality, maxBytes: thumbnailMaximumBytes) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = try mediaDirectory()
        let originalName = "\(mediaID).jpg"
        let thumbnailName = "\(mediaID)-thumb.jpg"
        try originalData.write(to: directory.appendingPathComponent(originalName), options: Data.WritingOptions.atomic)
        try thumbnailData.write(to: directory.appendingPathComponent(thumbnailName), options: Data.WritingOptions.atomic)
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
        try videoData.write(to: directory.appendingPathComponent(originalName), options: Data.WritingOptions.atomic)

        let thumbnail = videoThumbnail(for: sourceURL) ?? UIImage(systemName: "video") ?? UIImage()
        let resizedThumbnail = thumbnail.scaledToFit(maximumEdge: thumbnailMaximumEdge)
        guard let thumbnailData = boundedJPEGData(image: resizedThumbnail, quality: thumbnailQuality, maxBytes: thumbnailMaximumBytes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try thumbnailData.write(to: directory.appendingPathComponent(thumbnailName), options: Data.WritingOptions.atomic)
        let checksum = SHA256.hash(data: videoData).map { String(format: "%02x", $0) }.joined()

        return StoredMedia(
            mediaType: "video",
            originalPath: originalName,
            thumbnailPath: thumbnailName,
            checksum: checksum,
            pixelWidth: Int(resizedThumbnail.size.width * resizedThumbnail.scale),
            pixelHeight: Int(resizedThumbnail.size.height * resizedThumbnail.scale)
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

    private static func boundedJPEGData(image: UIImage, quality: CGFloat, maxBytes: Int) -> Data? {
        var currentQuality = quality
        for _ in 0..<6 {
            if let data = image.jpegData(compressionQuality: currentQuality), data.count <= maxBytes { return data }
            currentQuality -= 0.08
        }
        return image.jpegData(compressionQuality: 0.35)
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
        EntityCode.codeCamSerial(terminalId: InstallationIDStore.value)
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

    private static let mediaUploadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await mediaUploadSession.upload(for: request, fromFile: fileURL)
        } catch {
            throw EdgeFlowServiceError.rejected(status: -1, message: mediaUploadConnectionMessage(error, host: uploadURL.host))
        }
        guard let http = response as? HTTPURLResponse else { throw EdgeFlowServiceError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw EdgeFlowServiceError.rejected(
                status: http.statusCode,
                message: mediaUploadHTTPMessage(status: http.statusCode, body: data, host: uploadURL.host)
            )
        }
    }

    private static func mediaUploadConnectionMessage(_ error: Error, host: String?) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "上传时无网络连接，请检查 Wi‑Fi 或蜂窝数据。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                let target = host ?? "对象存储"
                return "无法解析上传地址（\(target)），请检查 DNS 或网络。"
            case NSURLErrorTimedOut:
                return "上传超时，文件较大时可稍后重试。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "上传 HTTPS 连接失败，请检查系统时间是否正确。"
            default:
                break
            }
        }
        return "上传连接失败：\(error.localizedDescription)"
    }

    private static func mediaUploadHTTPMessage(status: Int, body: Data, host: String?) -> String {
        let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .ascii)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isCOS = (host ?? "").contains("myqcloud.com")
        if trimmed.contains("SignatureDoesNotMatch") {
            return "COS 签名无效（\(status)），请重启 EdgeFlow 后重试同步。"
        }
        if trimmed.contains("InvalidAccessKeyId") {
            return "COS 临时密钥无效（\(status)），请重试同步。"
        }
        if trimmed.contains("AccessDenied") || trimmed.contains("Access Denied") {
            return "COS 拒绝上传（\(status)），请检查存储桶权限。"
        }
        if !trimmed.isEmpty {
            return "媒体上传失败（\(status)）：\(String(trimmed.prefix(200)))"
        }
        if isCOS {
            return "COS 上传失败（HTTP \(status)）。"
        }
        return "媒体上传失败（HTTP \(status)），请确认 App 中平台地址正确。"
    }

    static func uploadMultipart(path: String, fileData: Data, fileName: String, contentType: String, token: TokenKind) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try request(path: path, method: "POST", token: token)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(fileData); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); request.httpBody = body
        return try await performJSON(request)
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
            if account == deviceTokenAccount {
                request.setValue(bearer, forHTTPHeaderField: "X-Terminal-Token")
            }
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

enum QRLoginService {
    static func approve(challenge: String) async throws -> [String: Any] {
        try await EdgeFlowClient.post(
            "/api/v1/auth/qr-login/challenge/\(challenge)/approve",
            body: [:],
            token: .user
        )
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

    static func register(username: String, password: String, displayName: String, contextType: String = "STAFF", in context: ModelContext) async throws {
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
                "contextType": contextType,
            ],
            token: .none
        )
        try apply(object, username: trimmedUsername, displayName: trimmedDisplayName, contextType: contextType, in: context)
    }

    static func login(username: String, password: String, contextType: String = "STAFF", in context: ModelContext) async throws {
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
                "contextType": contextType,
            ],
            token: .none
        )
        let displayName = (object["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        try apply(
            object,
            username: trimmedUsername,
            displayName: (displayName?.isEmpty == false ? displayName! : trimmedUsername),
            contextType: contextType, in: context
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

    private static func apply(_ object: [String: Any], username: String, displayName: String, contextType: String, in context: ModelContext) throws {
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
        session.contextTypeRaw = (object["contextType"] as? String) ?? contextType
        session.isAuthenticated = true
        session.updatedAt = .now
        try context.save()
    }
}

@MainActor
enum DeviceRegistrationService {
    private static var finishConnectionTasks: [String: Task<Bool, Error>] = [:]

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
        KeychainStore.delete(account: EdgeFlowClient.deviceTokenAccount)
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
        if nextState == .claimed || nextState == .registered || nextState == .online {
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
        if nextState == .claimed {
            return false
        }
        return nextState == .registered || nextState == .online
    }

    @discardableResult
    static func finishConnection(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        let terminalID = registration.terminalID
        if let existing = finishConnectionTasks[terminalID] {
            return try await existing.value
        }
        let task = Task { @MainActor in
            defer { finishConnectionTasks[terminalID] = nil }
            return try await performFinishConnection(registration, in: context)
        }
        finishConnectionTasks[terminalID] = task
        return try await task.value
    }

    @discardableResult
    private static func performFinishConnection(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        if registration.state == .online {
            return true
        }
        if registration.state == .registered {
            try await sendHeartbeat(registration, in: context)
            return registration.state == .online || registration.state == .registered
        }
        try await syncDeviceToken(for: registration, in: context)
        try await registerWithRetry(registration, in: context)
        try await sendHeartbeat(registration, in: context)
        return registration.state == .online || registration.state == .registered
    }

    private static func syncDeviceToken(for registration: DeviceRegistration, in context: ModelContext) async throws {
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
        registration.state = state(in: object, fallback: registration.state)
        registration.updatedAt = .now
        try context.save()
        guard deviceTokenExists else {
            throw EdgeFlowServiceError.rejected(status: 401, message: "尚未拿到设备凭证，请稍后再试或刷新验证码。")
        }
    }

    private static func registerWithRetry(_ registration: DeviceRegistration, in context: ModelContext) async throws {
        do {
            try await register(registration, in: context)
        } catch let error as EdgeFlowServiceError {
            guard case .rejected(let status, _) = error, status == 401 else { throw error }
            try await syncDeviceToken(for: registration, in: context)
            try await register(registration, in: context)
        }
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
        try? await refreshThumbnailPolicy()
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
            try? await refreshThumbnailPolicy()
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

    static func refreshThumbnailPolicy() async throws {
        let object = try await EdgeFlowClient.get("/api/terminal/v1/media-policy")
        if let policy = object["policy"] as? [String: Any] {
            MediaFileStore.applyThumbnailPolicy(policy)
        } else {
            MediaFileStore.applyThumbnailPolicy(object)
        }
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
    static func refreshCredentials(_ registration: DeviceRegistration, in context: ModelContext) async throws -> Bool {
        try await refreshDeviceToken(registration, in: context)
    }

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
        if let serial = (object["serialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty {
            registration.serialNumber = serial
        }
        registration.pairingID = (object["pairingId"] as? String) ?? (object["pairId"] as? String) ?? registration.pairingID
        registration.verificationCode = (object["verificationCode"] as? String) ?? (object["pairingCode"] as? String) ?? (object["code"] as? String) ?? registration.verificationCode
        registration.factoryName = (object["factoryName"] as? String) ?? (object["factory"] as? String) ?? registration.factoryName
        if let expiresAt = object["expiresAt"] as? String {
            registration.pairingExpiresAt = PlatformDateParser.parse(expiresAt)
        }
        let token = (object["deviceToken"] as? String)
            ?? (object["terminalToken"] as? String)
            ?? (object["accessToken"] as? String)
            ?? (object["token"] as? String)
        if let token, !token.isEmpty {
            try? KeychainStore.save(Data(token.utf8), account: EdgeFlowClient.deviceTokenAccount)
        }
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

    static func syncAll(in context: ModelContext, forceRetry: Bool = false) async throws -> Int {
        let registration = DeviceRegistrationService.registration(in: context)
        guard registration.state == .registered || registration.state == .online || registration.state == .offline else {
            throw EdgeFlowServiceError.rejected(status: 401, message: "请先完成设备注册，再同步现场数据。")
        }
        if registration.state == .offline {
            try? await DeviceRegistrationService.sendHeartbeat(registration, in: context)
        }
        healAllMediaPaths(in: context)
        healMissingOutboxItems(in: context)
        healStaleEventSyncState(in: context)
        reclaimRetriableItems(in: context, force: forceRetry)
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
    private static func healMissingOutboxItems(in context: ModelContext) {
        guard let events = try? context.fetch(FetchDescriptor<LocalEvent>()),
              let outboxItems = try? context.fetch(FetchDescriptor<OutboxItem>()) else { return }
        let existingIDs = Set(outboxItems.map(\.eventID))
        var changed = false
        for event in events where event.syncStateRaw != SyncState.synced.rawValue && !existingIDs.contains(event.eventID) {
            context.insert(OutboxItem(eventID: event.eventID, kind: event.kind, bodyJSON: event.payloadJSON))
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func healStaleEventSyncState(in context: ModelContext) {
        guard let events = try? context.fetch(FetchDescriptor<LocalEvent>()),
              let outboxItems = try? context.fetch(FetchDescriptor<OutboxItem>()) else { return }
        let pendingOutbox = outboxItems.filter { $0.state != .synced && $0.state != .abandoned }
        var changed = false
        for item in pendingOutbox {
            guard let event = events.first(where: { $0.eventID == item.eventID }),
                  event.syncStateRaw == SyncState.synced.rawValue else { continue }
            event.syncStateRaw = SyncState.queued.rawValue
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func reclaimRetriableItems(in context: ModelContext, force: Bool = false) {
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
                if item.lastError?.contains("本地媒体文件已不存在") == true {
                    continue
                }
                item.state = .queued
                item.nextRetryAt = nil
                changed = true
            case .failed, .conflict where force:
                if item.lastError?.contains("本地媒体文件已不存在") == true {
                    continue
                }
                item.state = .queued
                item.nextRetryAt = nil
                item.lastError = nil
                changed = true
            default:
                if force, item.state != .synced, item.state != .abandoned {
                    item.nextRetryAt = nil
                    changed = true
                }
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
        var body: [String: Any] = [
            "eventId": event.eventID,
            "eventType": eventType(for: event.kind),
            "taskId": draft.taskID,
            "captureId": event.captureID ?? "",
            "terminalId": registration.terminalID,
            "deviceId": registration.terminalID,
            "occurredAt": ISO8601DateFormatter().string(from: event.occurredAt),
            "payload": payload,
        ]
        if let codeValue = event.codeValue, !codeValue.isEmpty {
            body["codeValue"] = codeValue
        }
        try await performWithCredentialRecovery(registration: registration, in: context) {
            _ = try await EdgeFlowClient.post("/api/terminal/v1/events", body: body, idempotencyKey: event.eventID)
        }

        if let mediaID = payload["mediaId"] as? String {
            let mediaIdentifier = mediaID
            let mediaDescriptor = FetchDescriptor<LocalMedia>(predicate: #Predicate { $0.mediaID == mediaIdentifier })
            if let media = try context.fetch(mediaDescriptor).first {
                try await upload(media, event: event, draft: draft, registration: registration, in: context)
                media.syncState = .synced
            }
        }

        event.syncStateRaw = SyncState.synced.rawValue
        if event.kind == "capture.completed", let captureID = event.captureID {
            ExecutionListService.markSynced(for: captureID, in: context)
        }
        item.state = .synced
        item.lastError = nil
        try context.save()
    }

    private static func performWithCredentialRecovery<T>(
        registration: DeviceRegistration,
        in context: ModelContext,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as EdgeFlowServiceError {
            guard case .rejected(let status, _) = error, status == 401 || status == 403 else { throw error }
            guard try await DeviceRegistrationService.refreshCredentials(registration, in: context) else { throw error }
            return try await operation()
        }
    }

    private static func upload(_ media: LocalMedia, event: LocalEvent, draft: TaskDraft, registration: DeviceRegistration, in context: ModelContext) async throws {
        media.syncState = .uploading
        MediaFileStore.healStoredPaths(for: media)
        guard let fileURL = media.resolvedOriginalURL else { throw EdgeFlowServiceError.localMediaMissing }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw EdgeFlowServiceError.localMediaMissing }
        let ticket = try await performWithCredentialRecovery(registration: registration, in: context) {
            try await EdgeFlowClient.post(
                "/api/terminal/v1/media/upload-ticket",
                body: mediaTicketBody(media: media, event: event, draft: draft, registration: registration, size: size),
                idempotencyKey: media.mediaID
            )
        }
        if let policy = ticket["thumbnailPolicy"] as? [String: Any] {
            MediaFileStore.applyThumbnailPolicy(policy)
        }
        guard let uploadURLText = ticket["uploadUrl"] as? String, let uploadURL = URL(string: uploadURLText) else {
            throw EdgeFlowServiceError.missingUploadURL
        }
        let resolvedURL = resolvedUploadURL(uploadURL, storageProvider: ticket["storageProvider"] as? String)
        let headers = uploadHeaders(
            from: ticket,
            uploadURL: resolvedURL,
            storageProvider: ticket["storageProvider"] as? String
        )
        try await EdgeFlowClient.upload(
            fileURL: fileURL,
            to: resolvedURL,
            method: (ticket["method"] as? String) ?? "PUT",
            headers: headers
        )
        media.syncState = .registering
        var completeBody: [String: Any] = [
            "mediaId": media.mediaID,
            "eventId": event.eventID,
            "taskId": draft.taskID,
            "captureId": event.captureID ?? "",
            "mediaType": media.mediaType,
            "category": media.category,
            "objectKey": (ticket["objectKey"] as? String) ?? "",
            "storageProvider": (ticket["storageProvider"] as? String) ?? "COS",
            "checksum": media.checksum,
            "fileSize": size,
            "capturedAt": ISO8601DateFormatter().string(from: media.capturedAt),
            "location": locationPayload(for: media),
        ]
        if let codeValue = event.codeValue, !codeValue.isEmpty {
            completeBody["codeValue"] = codeValue
        }
        _ = try await performWithCredentialRecovery(registration: registration, in: context) {
            try await EdgeFlowClient.post("/api/terminal/v1/media/\(media.mediaID)/complete", body: completeBody, idempotencyKey: media.mediaID)
        }
        if let thumbnailURL = media.resolvedThumbnailURL,
           let thumbnailData = try? Data(contentsOf: thumbnailURL), !thumbnailData.isEmpty {
            try? await performWithCredentialRecovery(registration: registration, in: context) {
                try await EdgeFlowClient.uploadMultipart(
                    path: "/api/terminal/v1/media/\(media.mediaID)/thumbnail",
                    fileData: thumbnailData,
                    fileName: "\(media.mediaID)-thumb.jpg",
                    contentType: "image/jpeg",
                    token: .device
                )
            }
        }
    }

    private static func uploadHeaders(from ticket: [String: Any], uploadURL: URL, storageProvider: String?) -> [String: String] {
        (ticket["headers"] as? [String: Any] ?? ticket["uploadHeaders"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    private static func mediaTicketBody(
        media: LocalMedia,
        event: LocalEvent,
        draft: TaskDraft,
        registration: DeviceRegistration,
        size: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "mediaId": media.mediaID,
            "eventId": event.eventID,
            "taskId": draft.taskID,
            "captureId": event.captureID ?? "",
            "terminalId": registration.terminalID,
            "deviceId": registration.terminalID,
            "mediaType": media.mediaType,
            "mimeType": mimeType(for: media),
            "category": media.category,
            "checksum": media.checksum,
            "fileSize": size,
            "capturedAt": ISO8601DateFormatter().string(from: media.capturedAt),
            "location": locationPayload(for: media),
        ]
        if let codeValue = event.codeValue, !codeValue.isEmpty {
            body["codeValue"] = codeValue
        }
        return body
    }

    private static func mimeType(for media: LocalMedia) -> String {
        switch media.mediaType {
        case "video": "video/quicktime"
        default: "image/jpeg"
        }
    }

    private static func resolvedUploadURL(_ uploadURL: URL, storageProvider: String?) -> URL {
        let provider = (storageProvider ?? "").uppercased()
        let isDirectUpload = provider == "EDGEFLOW_DIRECT" || uploadURL.path.contains("/media/direct/")
        guard isDirectUpload,
              let base = EdgeFlowClient.baseURL,
              var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let uploadHost = components.host?.lowercased(),
              let baseHost = baseComponents.host?.lowercased() else {
            return uploadURL
        }
        let loopbackHosts = ["127.0.0.1", "localhost", "0.0.0.0"]
        guard loopbackHosts.contains(uploadHost) || uploadHost != baseHost else { return uploadURL }
        components.scheme = baseComponents.scheme
        components.host = baseComponents.host
        components.port = baseComponents.port
        return components.url ?? uploadURL
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
