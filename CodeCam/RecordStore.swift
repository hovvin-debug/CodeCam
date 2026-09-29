import Foundation
import Combine

struct Photo: Codable, Identifiable, Equatable {
    var id = UUID()
    var capturedAt = Date()
    var filename: String { id.uuidString + ".jpg" }
}

struct CloudBinding: Codable, Equatable {
    var server: String
    var userID: UUID
    var spaceID: UUID
    var username: String
}

struct CaptureRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var spaceID: UUID
    var operatorID: UUID
    var terminalID: UUID
    var serial: String
    var taskID: UUID?
    var note = ""
    var createdAt = Date()
    var submittedAt: Date?
    var photos: [Photo] = []
    var syncedAt: Date?
    var syncError: String?
}

struct Archive: Codable {
    var version = 1
    var spaceID = UUID()
    var operatorID = UUID()
    var terminalID = UUID()
    var records: [CaptureRecord] = []
    var cloudBinding: CloudBinding?
    var activeSpaceID: UUID?
}

enum StoreError: LocalizedError {
    case invalidSerial, emptyRecord, unavailable, newerVersion
    var errorDescription: String? {
        switch self {
        case .invalidSerial: return "请输入 1–200 个字符的序列号。"
        case .emptyRecord: return "请至少添加一张照片或填写备注。"
        case .unavailable: return "当前记录无法修改，请返回后重试。"
        case .newerVersion: return "数据由更新版本创建，请更新 App 后再打开。"
        }
    }
}

@MainActor
final class RecordStore: ObservableObject {
    @Published private(set) var archive = Archive()
    @Published private(set) var loadError: String?
    let root: URL
    var records: [CaptureRecord] { archive.records.sorted { $0.createdAt > $1.createdAt } }
    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appending(path: "CodeCam")
        reload()
    }
    func reload() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "records.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let decoded = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard decoded.version == 1 else { throw StoreError.newerVersion }
                archive = decoded
            } else {
                try persist(archive)
            }
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }
    private func persist(_ value: Archive) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: root.appending(path: "records.json"), options: .atomic)
    }
    private func commit(_ value: Archive) throws {
        guard loadError == nil else { throw StoreError.unavailable }
        try persist(value)
        archive = value
    }
    func create(serial: String, taskID: UUID? = nil) throws -> UUID {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty, serial.count <= 200 else { throw StoreError.invalidSerial }
        let record = CaptureRecord(spaceID: archive.activeSpaceID ?? archive.spaceID, operatorID: archive.operatorID,
                                   terminalID: archive.terminalID, serial: serial, taskID: taskID)
        var next = archive; next.records.append(record); try commit(next)
        return record.id
    }
    func record(_ id: UUID) -> CaptureRecord? { archive.records.first { $0.id == id } }
    func updateNote(_ id: UUID, note: String) throws {
        try mutate(id) { $0.note = note }
    }
    private func mutate(_ id: UUID, change: (inout CaptureRecord) throws -> Void) throws {
        var next = archive
        guard let index = next.records.firstIndex(where: { $0.id == id }), next.records[index].submittedAt == nil else { throw StoreError.unavailable }
        try change(&next.records[index]); try commit(next)
    }
    func addPhoto(_ id: UUID, jpeg: Data) throws {
        let photo = Photo()
        let url = photoURL(photo)
        try jpeg.write(to: url, options: .atomic)
        do { try mutate(id) { $0.photos.append(photo) } }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func complete(_ id: UUID) throws {
        try mutate(id) {
            guard !$0.photos.isEmpty || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyRecord }
            $0.submittedAt = Date()
        }
    }
    func discardUnfinished(_ id: UUID) throws {
        var next = archive
        guard let index = next.records.firstIndex(where: { $0.id == id }), next.records[index].submittedAt == nil else { throw StoreError.unavailable }
        let removed = next.records.remove(at: index)
        try commit(next)
        for photo in removed.photos { try? FileManager.default.removeItem(at: photoURL(photo)) }
    }
    func discardUnfinished(except preserved: Set<UUID>) throws {
        let targets = archive.records.filter { $0.submittedAt == nil && !preserved.contains($0.id) }.map(\.id)
        for id in targets { try discardUnfinished(id) }
    }
    func associateTask(_ id: UUID, taskID: UUID) throws {
        var next = archive
        guard let index = next.records.firstIndex(where: { $0.id == id }),
              next.records[index].taskID == nil || next.records[index].taskID == taskID else { throw StoreError.unavailable }
        next.records[index].taskID = taskID
        try commit(next)
    }
    func clearTask(_ id: UUID, taskID: UUID) throws {
        var next = archive
        guard let index = next.records.firstIndex(where: { $0.id == id }),
              next.records[index].taskID == taskID, next.records[index].syncedAt == nil else { throw StoreError.unavailable }
        next.records[index].taskID = nil
        next.records[index].syncError = nil
        try commit(next)
    }
    func bindCloud(_ binding: CloudBinding) throws {
        if let existing = archive.cloudBinding {
            guard existing.server == binding.server, existing.userID == binding.userID else { throw StoreError.unavailable }
            var next = archive
            next.cloudBinding = binding
            next.activeSpaceID = binding.spaceID
            try commit(next)
            return
        }
        var next = archive
        let oldSpace = next.spaceID
        next.spaceID = binding.spaceID
        for index in next.records.indices where next.records[index].spaceID == oldSpace {
            next.records[index].spaceID = binding.spaceID
        }
        next.cloudBinding = binding
        next.activeSpaceID = binding.spaceID
        try commit(next)
    }
    func selectSpace(_ spaceID: UUID) throws {
        var next = archive
        next.activeSpaceID = spaceID
        if var binding = next.cloudBinding { binding.spaceID = spaceID; next.cloudBinding = binding }
        try commit(next)
    }
    func prepareCloudSpaces(personalSpaceID: UUID) throws {
        guard archive.cloudBinding == nil else { return }
        var next=archive
        let localSpace=next.spaceID
        for index in next.records.indices where next.records[index].spaceID == localSpace {
            next.records[index].spaceID=personalSpaceID
        }
        next.activeSpaceID=personalSpaceID
        try commit(next)
    }
    func updateSync(_ id: UUID, synced: Bool, error: String? = nil) throws {
        var next = archive
        guard let index = next.records.firstIndex(where: { $0.id == id }),
              next.records[index].submittedAt != nil else { throw StoreError.unavailable }
        next.records[index].syncedAt = synced ? Date() : nil
        next.records[index].syncError = error
        try commit(next)
    }
    func photoURL(_ photo: Photo) -> URL { root.appending(path: photo.filename) }
}
