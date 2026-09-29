import Foundation
import Combine
import Security
import CryptoKit

struct CloudSession: Codable {
    var server: String
    var token: String
    var userID: UUID
    var spaceID: UUID
    var username: String
    var storage: String
    var binding: CloudBinding { CloudBinding(server: server, userID: userID, spaceID: spaceID, username: username) }
}
struct AuthReply: Decodable {
    let token: String
    let userID: UUID
    let spaceID: UUID
    let username: String
    let storage: String
}
struct RemotePhoto: Decodable, Identifiable {
    let id: UUID
    let capturedAt: String
}
struct RemoteRecord: Decodable, Identifiable {
    let id: UUID
    let spaceID: UUID
    let serial: String
    let note: String
    let taskID: UUID?
    let createdAt: String
    let state: String
    let photos: [RemotePhoto]
}
struct RemotePage: Decodable {
    let records: [RemoteRecord]
    let nextOffset: Int?
}
struct RemoteTask: Decodable, Identifiable {
    let id: UUID
    let spaceID: UUID
    let serial: String
    let note: String
    let assigneeID: UUID
    let assigneeUsername: String
    let createdAt: String
    let status: String
    let recordID: UUID?
    let completedAt: String?
    let cancelledAt: String?
}
struct RemoteTaskPage: Decodable {
    let tasks: [RemoteTask]
    let nextOffset: Int?
}
struct TaskSummary: Decodable {
    let todayAssigned: Int
    let todayCompleted: Int
    let pending: Int
    let cancelled: Int
}
struct TaskBatchReply: Decodable {
    let tasks: [RemoteTask]
    let createdCount: Int
    let existingCount: Int
}
struct TaskBulkReply: Decodable {
    let serialCount: Int
    let recipientCount: Int
    let createdCount: Int
    let existingCount: Int
}
struct OrganizationMember: Decodable, Identifiable {
    let id: UUID
    let username: String
    let role: String
}
private struct OrganizationMembers: Decodable { let members: [OrganizationMember] }
struct CloudSpace: Decodable, Identifiable {
    let id: UUID
    let name: String
    let kind: String
    var organizationID: UUID?
    var role: String?
}
private struct SpaceList: Decodable { let spaces: [CloudSpace] }
struct OrganizationReply: Decodable {
    let id: UUID
    let spaceID: UUID
    let name: String
    var joinCode: String?
    let role: String
}
struct ServerHealth: Decodable {
    let service: String
    let version: Int
    let storage: String
}
struct CloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class CloudService: ObservableObject {
    @Published private(set) var session: CloudSession?
    @Published private(set) var syncing = false
    @Published private(set) var spaces: [CloudSpace] = []
    @Published private(set) var latestJoinCode: String?
    @Published var message: String?
    private let network = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    private let keychainService = "linden.CodeCam.Minimal.cloud"
    init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "session",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            session = try? JSONDecoder().decode(CloudSession.self, from: data)
        }
    }
    static func normalizedServer(_ raw: String) throws -> String {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw CloudError(message: "请输入服务根地址，例如 https://camflow.example.com") }
        let local = host == "localhost" || host.hasSuffix(".local") || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1) && host.hasPrefix("172.")
        guard parts.scheme == "https" || (parts.scheme == "http" && local) else { throw CloudError(message: "远程服务必须使用 HTTPS；HTTP 仅用于局域网联调。") }
        parts.path = ""; parts.host = host.lowercased()
        guard let url = parts.url else { throw CloudError(message: "服务地址无效") }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private func save(_ value: CloudSession?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"]
        if let value {
            let data = try JSONEncoder().encode(value)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query; insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CloudError(message: "登录凭证无法安全保存") }
            } else if status != errSecSuccess { throw CloudError(message: "登录凭证无法安全保存") }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError(message: "无法清除登录凭证") }
        }
        session = value
        if value == nil { spaces=[]; latestJoinCode=nil }
    }
    func login(server: String, username: String, password: String, register: Bool, store: RecordStore) async throws {
        let server = try Self.normalizedServer(server)
        let data = try await request(server: server, token: nil, path: "/api/auth/\(register ? "register" : "login")", method: "POST", body: JSONSerialization.data(withJSONObject: ["username": username, "password": password]))
        let reply = try JSONDecoder().decode(AuthReply.self, from: data)
        let binding = store.archive.cloudBinding
        let retainedSpace = binding?.server == server && binding?.userID == reply.userID ? binding!.spaceID : reply.spaceID
        let value = CloudSession(server: server, token: reply.token, userID: reply.userID, spaceID: retainedSpace, username: reply.username, storage: reply.storage)
        if let binding, binding.server != server || binding.userID != reply.userID {
            throw CloudError(message: "本机资料已绑定 \(binding.username)，请使用原服务和原账号登录，避免资料误传。")
        }
        try save(value); try store.selectSpace(retainedSpace); message = nil
    }
    func logout() async throws {
        guard !syncing else { return }
        if let session { _ = try await request(server: session.server, token: session.token, path: "/api/logout", method: "POST") }
        try save(nil)
    }
    private func request(server: String, token: String?, path: String, method: String = "GET", body: Data? = nil, jpeg: Bool = false, spaceID: UUID? = nil) async throws -> Data {
        guard let url = URL(string: server + path) else { throw CloudError(message: "服务地址无效") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 90; request.httpBody = body
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let spaceID { request.setValue(spaceID.uuidString, forHTTPHeaderField: "X-Space-ID") }
        if body != nil { request.setValue(jpeg ? "image/jpeg" : "application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CloudError(message: "服务响应异常，请检查地址后重试")
        }
        guard (200..<300).contains(response.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = error?["error"] as? String ?? "服务响应异常，请检查地址后重试"
            throw CloudError(message: "HTTP \(response.statusCode)：\(detail)")
        }
        return data
    }
    func sync(store: RecordStore, recordID: UUID? = nil) async {
        guard !syncing else {
            message = "另一批记录正在同步，请稍后重试。"
            if let recordID { try? store.updateSync(recordID, synced: false, error: message) }
            return
        }
        guard let session else {
            message = "请先登录后同步。"
            if let recordID { try? store.updateSync(recordID, synced: false, error: message) }
            return
        }
        syncing = true; message = recordID == nil ? "正在同步全部待上传记录…" : "正在重试这条记录…"
        defer { syncing = false }
        do {
            // Revalidate identity before permanently binding any local data.
            let me = try await request(server: session.server, token: session.token, path: "/api/me")
            let identity = try JSONSerialization.jsonObject(with: me) as? [String: Any]
            guard (identity?["userID"] as? String)?.lowercased() == session.userID.uuidString.lowercased() else { throw CloudError(message: "云端账号身份发生变化，请重新登录") }
            try store.bindCloud(session.binding)
            let pending = store.records.filter {
                $0.submittedAt != nil && $0.syncedAt == nil && (recordID == nil || $0.id == recordID)
            }
            guard !pending.isEmpty else { message = "没有待上传的已完成记录"; return }
            var done = 0; var failed = 0
            for record in pending {
                do {
                    let matchedTask = try await upload(record, store: store, session: session)
                    if let matchedTask { try store.associateTask(record.id, taskID: matchedTask) }
                    try store.updateSync(record.id, synced: true); done += 1
                } catch {
                    failed += 1
                    let reason = error.localizedDescription
                    try store.updateSync(record.id, synced: false, error: reason)
                    message = "\(record.serial)：\(reason)"
                }
            }
            if failed == 0 {
                message = "同步完成，本次上传 \(done) 条记录"
            } else if recordID == nil {
                message = "已同步 \(done) 条，\(failed) 条未完成。列表中显示了失败阶段和原因，可单独重试。"
            }
        } catch {
            let reason = error.localizedDescription
            if let recordID, store.records.contains(where: { $0.id == recordID && $0.submittedAt != nil && $0.syncedAt == nil }) {
                try? store.updateSync(recordID, synced: false, error: reason)
            }
            message = reason
        }
    }
    private func upload(_ record: CaptureRecord, store: RecordStore, session: CloudSession) async throws -> UUID? {
        let iso = ISO8601DateFormatter()
        var photos: [[String: Any]] = []
        for (index, photo) in record.photos.enumerated() {
            let data: Data
            do { data = try Data(contentsOf: store.photoURL(photo)) }
            catch { throw CloudError(message: "本机照片 \(index + 1)/\(record.photos.count) 无法读取：\(error.localizedDescription)") }
            photos.append(["id": photo.id.uuidString, "capturedAt": iso.string(from: photo.capturedAt), "size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        var payload: [String: Any] = ["id": record.id.uuidString, "serial": record.serial, "note": record.note,
            "terminalID": record.terminalID.uuidString, "createdAt": iso.string(from: record.createdAt),
            "submittedAt": iso.string(from: record.submittedAt!), "photos": photos]
        if let taskID = record.taskID { payload["taskID"] = taskID.uuidString }
        let path = "/api/records/" + record.id.uuidString
        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = try await request(server: session.server, token: session.token, path: path, method: "PUT", body: body, spaceID: record.spaceID)
        } catch { throw CloudError(message: "记录登记失败：\(error.localizedDescription)") }
        for (index, photo) in record.photos.enumerated() {
            do {
                let data = try Data(contentsOf: store.photoURL(photo))
                _ = try await request(server: session.server, token: session.token, path: path + "/photos/" + photo.id.uuidString, method: "PUT", body: data, jpeg: true, spaceID: record.spaceID)
            } catch {
                throw CloudError(message: "照片上传失败（第 \(index + 1)/\(record.photos.count) 张）：\(error.localizedDescription)")
            }
        }
        let data: Data
        do { data = try await request(server: session.server, token: session.token, path: path + "/complete", method: "POST", spaceID: record.spaceID) }
        catch { throw CloudError(message: "照片已上传，但服务端尚未确认记录：\(error.localizedDescription)") }
        let result: RemoteRecord
        do { result = try JSONDecoder().decode(RemoteRecord.self, from: data) }
        catch { throw CloudError(message: "服务已响应，但完成回执无法读取：\(error.localizedDescription)") }
        guard result.id == record.id, result.state == "ready" else { throw CloudError(message: "服务尚未确认记录完成") }
        return result.taskID
    }
    func records(serial: String = "", offset: Int = 0) async throws -> RemotePage {
        guard let session else { throw CloudError(message: "请先登录") }
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        if !serial.isEmpty { query.queryItems?.append(URLQueryItem(name: "serial", value: serial)) }
        return try JSONDecoder().decode(RemotePage.self, from: await request(server: session.server, token: session.token, path: "/api/records?" + (query.percentEncodedQuery ?? ""), spaceID: session.spaceID))
    }
    func tasks(offset: Int = 0) async throws -> RemoteTaskPage {
        guard let session else { throw CloudError(message: "请先登录") }
        let data=try await request(server: session.server, token: session.token, path: "/api/tasks?offset=\(offset)", spaceID: session.spaceID)
        return try JSONDecoder().decode(RemoteTaskPage.self, from: data)
    }
    func taskSummary(timezone: String) async throws -> TaskSummary {
        guard let session else { throw CloudError(message: "请先登录") }
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "timezone", value: timezone)]
        let path = "/api/tasks/summary?" + (components.percentEncodedQuery ?? "")
        return try JSONDecoder().decode(TaskSummary.self, from: await request(server: session.server, token: session.token, path: path, spaceID: session.spaceID))
    }
    func cancelTask(_ task: RemoteTask, organizationID: UUID) async throws -> RemoteTask {
        guard let session, spaces.contains(where: { $0.id == task.spaceID && $0.organizationID == organizationID && $0.role == "owner" }) else {
            throw CloudError(message: "只有当前组织的管理员可以撤销任务")
        }
        let data = try await request(server: session.server, token: session.token,
            path: "/api/organizations/\(organizationID.uuidString)/tasks/\(task.id.uuidString)/cancel", method: "POST")
        return try JSONDecoder().decode(RemoteTask.self, from: data)
    }
    func organizationMembers() async throws -> [OrganizationMember] {
        guard let session, let org = spaces.first(where: { $0.id == session.spaceID && $0.kind == "organization" })?.organizationID else {
            throw CloudError(message: "请先选择组织空间")
        }
        let data = try await request(server: session.server, token: session.token, path: "/api/organizations/\(org.uuidString)/manage")
        return try JSONDecoder().decode(OrganizationMembers.self, from: data).members
    }
    func assignTask(id: UUID, serial: String, note: String, assigneeID: UUID, organizationID: UUID) async throws -> RemoteTask {
        guard let session, spaces.contains(where: { $0.id == session.spaceID && $0.organizationID == organizationID && $0.role == "owner" }) else {
            throw CloudError(message: "只有当前组织的管理员可以分配任务")
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "serial": serial, "note": note, "assigneeID": assigneeID.uuidString])
        let data = try await request(server: session.server, token: session.token, path: "/api/organizations/\(organizationID.uuidString)/tasks", method: "POST", body: body)
        return try JSONDecoder().decode(RemoteTask.self, from: data)
    }
    func assignTasks(id: UUID, serial: String, note: String, assigneeIDs: [UUID], organizationID: UUID) async throws -> TaskBatchReply {
        guard let session, spaces.contains(where: { $0.id == session.spaceID && $0.organizationID == organizationID && $0.role == "owner" }) else {
            throw CloudError(message: "只有当前组织的管理员可以分配任务")
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "serial": serial, "note": note,
            "assigneeIDs": assigneeIDs.map(\.uuidString)])
        let data = try await request(server: session.server, token: session.token,
            path: "/api/organizations/\(organizationID.uuidString)/tasks/batch", method: "POST", body: body)
        return try JSONDecoder().decode(TaskBatchReply.self, from: data)
    }
    func assignBulkTasks(id: UUID, serials: [String], note: String, assigneeIDs: [UUID], organizationID: UUID) async throws -> TaskBulkReply {
        guard let session, spaces.contains(where: { $0.id == session.spaceID && $0.organizationID == organizationID && $0.role == "owner" }) else {
            throw CloudError(message: "只有当前组织的管理员可以分配任务")
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "serials": serials, "note": note,
            "assigneeIDs": assigneeIDs.map(\.uuidString)])
        let data = try await request(server: session.server, token: session.token,
            path: "/api/organizations/\(organizationID.uuidString)/tasks/bulk", method: "POST", body: body)
        return try JSONDecoder().decode(TaskBulkReply.self, from: data)
    }
    func record(id: UUID, spaceID: UUID) async throws -> RemoteRecord {
        guard let session else { throw CloudError(message: "请先登录") }
        let data=try await request(server: session.server, token: session.token, path: "/api/records/\(id.uuidString)", spaceID: spaceID)
        return try JSONDecoder().decode(RemoteRecord.self, from: data)
    }
    func photo(record: UUID, photo: UUID, spaceID: UUID) async throws -> Data {
        guard let session else { throw CloudError(message: "请先登录") }
        return try await request(server: session.server, token: session.token, path: "/api/records/\(record.uuidString)/photos/\(photo.uuidString)", spaceID: spaceID)
    }
    func refreshSpaces() async throws {
        guard let session else { throw CloudError(message: "请先登录") }
        let data=try await request(server: session.server, token: session.token, path: "/api/spaces")
        let received=try JSONDecoder().decode(SpaceList.self, from: data).spaces
        if self.session?.token == session.token { spaces=received }
    }
    func selectSpace(_ space: CloudSpace, store: RecordStore) throws {
        guard let session else { throw CloudError(message: "请先登录") }
        try store.prepareCloudSpaces(personalSpaceID: session.spaceID)
        try store.selectSpace(space.id)
        var next=session; next.spaceID=space.id
        try save(next); message="已切换到：\(space.name)"
    }
    func createOrganization(name: String, store: RecordStore) async throws -> OrganizationReply {
        guard let session else { throw CloudError(message: "请先登录") }
        let body=try JSONSerialization.data(withJSONObject: ["name":name])
        let data=try await request(server:session.server,token:session.token,path:"/api/organizations",method:"POST",body:body)
        let result=try JSONDecoder().decode(OrganizationReply.self,from:data)
        latestJoinCode=result.joinCode
        try await refreshSpaces()
        if let space=spaces.first(where:{$0.id==result.spaceID}) { try selectSpace(space,store:store) }
        return result
    }
    func joinOrganization(code: String, store: RecordStore) async throws -> OrganizationReply {
        guard let session else { throw CloudError(message: "请先登录") }
        let body=try JSONSerialization.data(withJSONObject: ["joinCode":code])
        let data=try await request(server:session.server,token:session.token,path:"/api/organizations/join",method:"POST",body:body)
        let result=try JSONDecoder().decode(OrganizationReply.self,from:data)
        latestJoinCode=nil
        try await refreshSpaces()
        if let space=spaces.first(where:{$0.id==result.spaceID}) { try selectSpace(space,store:store) }
        return result
    }
    func checkServer(_ address: String) async throws -> ServerHealth {
        let server = try Self.normalizedServer(address)
        let data = try await request(server: server, token: nil, path: "/api/health")
        let health = try JSONDecoder().decode(ServerHealth.self, from: data)
        guard health.version == 2 else { throw CloudError(message: "服务器版本不匹配，请确认地址指向新版 CamFlow。") }
        return health
    }
}
