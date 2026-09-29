import Foundation
import SwiftData
import SwiftUI

enum SyncState: String, Codable, CaseIterable {
    case localOnly = "LOCAL_ONLY"
    case queued = "QUEUED"
    case uploading = "UPLOADING"
    case registering = "REGISTERING"
    case synced = "SYNCED"
    case failed = "FAILED"
    case conflict = "CONFLICT"
    case needsReview = "NEEDS_REVIEW"
    case abandoned = "ABANDONED"

    var title: String {
        switch self {
        case .localOnly: "仅本地"
        case .queued: "等待同步"
        case .uploading: "上传中"
        case .registering: "登记中"
        case .synced: "已同步"
        case .failed: "同步失败"
        case .conflict: "存在冲突"
        case .needsReview: "待人工复核"
        case .abandoned: "已放弃"
        }
    }

    var tint: Color {
        switch self {
        case .synced: .green
        case .failed, .conflict: .red
        case .needsReview, .abandoned: .orange
        case .uploading, .registering: .blue
        case .queued, .localOnly: .secondary
        }
    }
}

enum CodeValidationState: String, Codable {
    case notChecked = "NOT_CHECKED"
    case locallyValid = "LOCALLY_VALID"
    case invalid = "INVALID"
    case serverConfirmed = "SERVER_CONFIRMED"
    case serverRejected = "SERVER_REJECTED"

    var title: String {
        switch self {
        case .notChecked: "待校验"
        case .locallyValid: "待服务端校验"
        case .invalid: "格式不正确"
        case .serverConfirmed: "服务端已确认"
        case .serverRejected: "服务端已拒绝"
        }
    }
}

enum DeviceConnectionState: String, Codable {
    case unpaired = "UNPAIRED"
    case pairing = "PAIRING"
    case claimed = "CLAIMED"
    case registered = "REGISTERED"
    case online = "ONLINE"
    case offline = "OFFLINE"
    case revoked = "REVOKED"
    case failed = "FAILED"

    var title: String {
        switch self {
        case .unpaired: "未连接"
        case .pairing: "等待工厂认领"
        case .claimed: "正在连接工厂…"
        case .registered: "已连接"
        case .online: "在线"
        case .offline: "离线"
        case .revoked: "已撤销"
        case .failed: "连接异常"
        }
    }

    var tint: Color {
        switch self {
        case .online: .green
        case .registered, .claimed: .blue
        case .pairing, .offline: .orange
        case .revoked, .failed: .red
        case .unpaired: .secondary
        }
    }
}

nonisolated struct FixedTaskForm: Codable, Equatable {
    var location = ""
    var contactName = ""
    var note = ""

    static let empty = FixedTaskForm()

    var eventFields: [String: String] {
        [
            "location": location,
            "contactName": contactName,
            "note": note,
            "现场地点": location,
            "联系人": contactName,
            "现场说明": note,
        ]
    }
}

enum RelatedScanKind: String, Codable, CaseIterable, Identifiable {
    case logistics = "LOGISTICS"
    case other = "OTHER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logistics: "物流快递"
        case .other: "其它"
        }
    }
}

enum CodeValidator {
    static func validate(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= 6 else { return "产品码至少需要 6 个字符。" }
        guard code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return "产品码只能包含字母、数字、连字符或下划线。"
        }
        return nil
    }

    /// Logistics / other related codes are messier than product SNs (GS1, spaces, punctuation).
    static func normalizeRelated(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{001D}", with: "")
            .replacingOccurrences(of: "\u{001E}", with: "")
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    }

    static func validateRelated(_ value: String) -> String? {
        let code = normalizeRelated(value)
        guard code.count >= 4 else { return "关联码至少需要 4 个字符。" }
        guard code.count <= 128 else { return "关联码过长。" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./()+"))
        guard code.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "关联码包含无法识别的字符。"
        }
        return nil
    }
}

enum AccountCredentialsValidator {
    static func validateUsername(_ value: String) -> String? {
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.count >= 3 else { return "用户名至少需要 3 个字符。" }
        guard username.count <= 64 else { return "用户名不能超过 64 个字符。" }
        guard username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "@" || $0 == "." }) else {
            return "用户名只能包含字母、数字、下划线、连字符、@ 或点号。"
        }
        return nil
    }

    static func validatePassword(_ value: String) -> String? {
        guard value.count >= 8 else { return "密码至少需要 8 个字符。" }
        guard value.count <= 128 else { return "密码不能超过 128 个字符。" }
        return nil
    }

    static func validateDisplayName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "请填写显示名称。" }
        guard name.count <= 64 else { return "显示名称不能超过 64 个字符。" }
        return nil
    }
}

enum FixedTaskFormValidator {
    static func missingFields(for form: FixedTaskForm) -> [String] {
        var missing: [String] = []
        if form.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("现场地点") }
        if form.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("现场说明") }
        return missing
    }
}

enum ClientEventIdentity {
    static func make() -> String { UUID().uuidString.lowercased() }
}

struct ProductField: Identifiable, Equatable {
    let name: String
    let value: String
    var id: String { name }
}

struct ProductProfile: Identifiable, Equatable {
    var productName: String? = nil
    var productModel: String? = nil
    let id: String
    let serialNumber: String
    let productReference: String
    let status: String
    let fields: [ProductField]
    let sourceDescription: String

    static func pending(for code: String, message: String) -> ProductProfile {
        ProductProfile(
            id: code,
            serialNumber: code,
            productReference: "等待平台返回",
            status: "待校验",
            fields: [],
            sourceDescription: message
        )
    }

    static func platform(code: String, productReference: String, status: String, fields: [String: String]) -> ProductProfile {
        ProductProfile(
            id: code,
            serialNumber: code,
            productReference: productReference.isEmpty ? "未命名产品" : productReference,
            status: status.isEmpty ? "有效" : status,
            fields: fields.sorted { $0.key < $1.key }.map { ProductField(name: $0.key, value: $0.value) },
            sourceDescription: "已从 EdgeFlow 拉取"
        )
    }
}

enum CaptureMode: String, Identifiable {
    case photo
    case video

    var id: String { rawValue }
    var title: String { self == .photo ? "拍照" : "录像" }
    var icon: String { self == .photo ? "camera" : "video" }
}

enum ExecutionItemState: String, Codable, CaseIterable {
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
    case captured = "CAPTURED"
    case synced = "SYNCED"
    case exception = "EXCEPTION"
    case skipped = "SKIPPED"
    case cancelled = "CANCELLED"

    var title: String {
        switch self {
        case .pending: "待处理"
        case .inProgress: "处理中"
        case .captured: "已采集"
        case .synced: "已同步"
        case .exception: "异常"
        case .skipped: "已跳过"
        case .cancelled: "已取消"
        }
    }

    var tint: Color {
        switch self {
        case .synced: .green
        case .captured: .blue
        case .inProgress: .orange
        case .exception: .red
        case .skipped, .cancelled: .secondary
        case .pending: .primary
        }
    }

    var isOutstanding: Bool { self == .pending || self == .inProgress }
}

enum TaskPriority: String, Codable, CaseIterable {
    case urgent = "URGENT"
    case high = "HIGH"
    case normal = "NORMAL"
    case low = "LOW"

    var title: String {
        switch self {
        case .urgent: "紧急"
        case .high: "高优"
        case .normal: "普通"
        case .low: "低优"
        }
    }

    var tint: Color {
        switch self {
        case .urgent: .red
        case .high: .orange
        case .normal: .blue
        case .low: .secondary
        }
    }

    var sortOrder: Int {
        switch self {
        case .urgent: 0
        case .high: 1
        case .normal: 2
        case .low: 3
        }
    }
}

struct EvidenceRequirement: Codable, Hashable {
    let label: String
    let minimum: Int
}

enum MediaLocationStatus: String, Codable {
    case available
    case unavailable
    case denied
    case lowAccuracy
    case timeout
}

struct MediaLocationSnapshot: Equatable {
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
    let capturedAt: Date?
    let status: MediaLocationStatus

    static let unavailable = MediaLocationSnapshot(
        latitude: nil,
        longitude: nil,
        horizontalAccuracy: nil,
        capturedAt: nil,
        status: .unavailable
    )
}

enum WallClock {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? .gmt

    static func time(_ date: Date) -> String {
        string(from: date, format: "HH:mm")
    }

    static func dateTime(_ date: Date) -> String {
        string(from: date, format: "yyyy-MM-dd HH:mm")
    }

    private static func string(from date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = shanghai
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

struct PlatformEndpoint {
    static let defaultHost = "192.168.31.5"
    static let defaultPort = 8000

    var host: String
    var port: Int
    var usesHTTPS: Bool

    init(host: String, port: Int, usesHTTPS: Bool = false) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.usesHTTPS = usesHTTPS
    }

    init(url: URL) {
        usesHTTPS = url.scheme?.lowercased() == "https"
        host = url.host ?? Self.defaultHost
        port = url.port ?? (usesHTTPS ? 443 : 80)
        if port == 80 && !usesHTTPS && url.port == nil {
            port = Self.defaultPort
        }
    }

    static func current() -> PlatformEndpoint {
        if let url = EdgeFlowClient.baseURL {
            return PlatformEndpoint(url: url)
        }
        return PlatformEndpoint(host: defaultHost, port: defaultPort)
    }

    var urlString: String {
        let scheme = usesHTTPS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    var url: URL? { URL(string: urlString) }

    static func validate(host: String, portText: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty { return "请输入服务器地址。" }
        if trimmedHost.contains("://") { return "只需填写 IP 或域名，不要包含 http://。" }
        if trimmedHost.contains("/") { return "服务器地址格式不正确。" }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0, port <= 65535 else {
            return "端口应为 1–65535 之间的数字。"
        }
        return nil
    }

    func save() throws {
        guard let url else { throw EdgeFlowServiceError.invalidBaseURL }
        UserDefaults.standard.set(url.absoluteString, forKey: EdgeFlowClient.baseURLKey)
    }

    static func save(host: String, portText: String, usesHTTPS: Bool) throws -> PlatformEndpoint {
        if let failure = validate(host: host, portText: portText) {
            throw EdgeFlowServiceError.rejected(status: 400, message: failure)
        }
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultPort
        let endpoint = PlatformEndpoint(host: host, port: port, usesHTTPS: usesHTTPS)
        try endpoint.save()
        return endpoint
    }
}

struct AppSchema {
    static let models: [any PersistentModel.Type] = [
        UserSessionRecord.self,
        TaskCache.self,
        TaskDraft.self,
        ExecutionList.self,
        ExecutionItem.self,
        CaptureSession.self,
        CaptureNote.self,
        RelatedScan.self,
        LocalEvent.self,
        LocalMedia.self,
        OutboxItem.self,
        SyncSession.self,
        DeviceRegistration.self,
        CustomerPendingAction.self,
    ]
}
