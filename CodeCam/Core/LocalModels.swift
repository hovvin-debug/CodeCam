import Foundation
import SwiftData

@Model
final class UserSessionRecord {
    @Attribute(.unique) var userID: String
    var terminalID: String
    var installationID: String
    var username: String = ""
    var displayName: String = ""
    var platformOperator: Bool = false
    var isAuthenticated: Bool = false
    var expiresAt: Date?
    var updatedAt: Date

    init(
        userID: String,
        terminalID: String,
        installationID: String,
        username: String = "",
        displayName: String = "",
        platformOperator: Bool = false,
        isAuthenticated: Bool = false,
        expiresAt: Date? = nil
    ) {
        self.userID = userID
        self.terminalID = terminalID
        self.installationID = installationID
        self.username = username
        self.displayName = displayName
        self.platformOperator = platformOperator
        self.isAuthenticated = isAuthenticated
        self.expiresAt = expiresAt
        self.updatedAt = .now
    }
}

@Model
final class DeviceRegistration {
    @Attribute(.unique) var terminalID: String
    var serialNumber: String
    var stateRaw: String
    var pairingID: String?
    var verificationCode: String?
    var pairingExpiresAt: Date?
    var factoryName: String?
    var heartbeatSequence: Int
    var lastHeartbeatAt: Date?
    var lastError: String?
    var storageConfigJSON: String = "{}"
    var updatedAt: Date

    init(terminalID: String, serialNumber: String) {
        self.terminalID = terminalID
        self.serialNumber = serialNumber
        self.stateRaw = DeviceConnectionState.unpaired.rawValue
        self.heartbeatSequence = 0
        self.updatedAt = .now
    }

    var state: DeviceConnectionState {
        get { DeviceConnectionState(rawValue: stateRaw) ?? .unpaired }
        set { stateRaw = newValue.rawValue }
    }
}

@Model
final class TaskCache {
    @Attribute(.unique) var taskID: String
    var templateID: String
    var templateVersion: String
    var payloadJSON: String
    var cachedAt: Date

    init(taskID: String, templateID: String, templateVersion: String, payloadJSON: String = "{}") {
        self.taskID = taskID
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.payloadJSON = payloadJSON
        self.cachedAt = .now
    }
}

@Model
final class TaskDraft {
    @Attribute(.unique) var id: String
    var taskID: String
    var title: String
    var taskType: String
    var templateID: String
    var templateVersion: String
    var codeValue: String?
    var codeValidationRaw: String
    var formJSON: String
    var mediaCount: Int
    var syncStateRaw: String
    var updatedAt: Date

    init(id: String = UUID().uuidString.lowercased(), taskID: String, title: String, taskType: String, templateID: String, templateVersion: String) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.taskType = taskType
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.codeValidationRaw = CodeValidationState.notChecked.rawValue
        self.formJSON = "{}"
        self.mediaCount = 0
        self.syncStateRaw = SyncState.localOnly.rawValue
        self.updatedAt = .now
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .localOnly }
        set { syncStateRaw = newValue.rawValue }
    }

    var codeValidation: CodeValidationState {
        get { CodeValidationState(rawValue: codeValidationRaw) ?? .notChecked }
        set { codeValidationRaw = newValue.rawValue }
    }

    var form: FixedTaskForm {
        get { (try? JSONDecoder().decode(FixedTaskForm.self, from: Data(formJSON.utf8))) ?? .empty }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8)
            formJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

@Model
final class ExecutionList {
    @Attribute(.unique) var id: String
    var workDateKey: String
    var factoryTimeZoneID: String
    var title: String
    var sourceVersion: String
    var assignmentDescription: String
    var updatedAt: Date
    var lastRefreshError: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        workDateKey: String,
        factoryTimeZoneID: String = TimeZone.current.identifier,
        title: String,
        sourceVersion: String = "local-1",
        assignmentDescription: String = "当前设备"
    ) {
        self.id = id
        self.workDateKey = workDateKey
        self.factoryTimeZoneID = factoryTimeZoneID
        self.title = title
        self.sourceVersion = sourceVersion
        self.assignmentDescription = assignmentDescription
        self.updatedAt = .now
    }
}

@Model
final class ExecutionItem {
    @Attribute(.unique) var id: String
    var listID: String
    var draftID: String
    var codeID: String?
    var codeValue: String
    var productName: String?
    var productModel: String?
    var orderSummary: String?
    var stateRaw: String
    var captureID: String?
    var completedAt: Date?
    var exceptionReason: String?
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        listID: String,
        draftID: String,
        codeID: String? = nil,
        codeValue: String,
        productName: String? = nil,
        productModel: String? = nil,
        orderSummary: String? = nil,
        state: ExecutionItemState = .pending
    ) {
        self.id = id
        self.listID = listID
        self.draftID = draftID
        self.codeID = codeID
        self.codeValue = codeValue
        self.productName = productName
        self.productModel = productModel
        self.orderSummary = orderSummary
        self.stateRaw = state.rawValue
        self.updatedAt = .now
    }

    var state: ExecutionItemState {
        get { ExecutionItemState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

@Model
final class CaptureSession {
    var productName: String?
    var productModel: String?
    @Attribute(.unique) var id: String
    var draftID: String
    var codeValue: String
    var executionListID: String?
    var executionItemID: String?
    var codeValidationRaw: String
    var scannedAt: Date
    var completedAt: Date?
    var updatedAt: Date

    init(id: String = UUID().uuidString.lowercased(), draftID: String, codeValue: String) {
        self.id = id
        self.draftID = draftID
        self.codeValue = codeValue
        self.codeValidationRaw = CodeValidationState.locallyValid.rawValue
        self.scannedAt = .now
        self.updatedAt = .now
    }

    var codeValidation: CodeValidationState {
        get { CodeValidationState(rawValue: codeValidationRaw) ?? .notChecked }
        set { codeValidationRaw = newValue.rawValue }
    }

    var isCompleted: Bool { completedAt != nil }
}

@Model
final class CaptureNote {
    @Attribute(.unique) var id: String
    var captureID: String
    var text: String
    var createdAt: Date

    init(id: String = UUID().uuidString.lowercased(), captureID: String, text: String) {
        self.id = id
        self.captureID = captureID
        self.text = text
        self.createdAt = .now
    }
}

@Model
final class RelatedScan {
    @Attribute(.unique) var id: String
    var parentCaptureID: String
    var draftID: String
    var codeValue: String
    var kindRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString.lowercased(), parentCaptureID: String, draftID: String, codeValue: String, kind: RelatedScanKind) {
        self.id = id
        self.parentCaptureID = parentCaptureID
        self.draftID = draftID
        self.codeValue = codeValue
        self.kindRaw = kind.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }

    var kind: RelatedScanKind {
        get { RelatedScanKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

@Model
final class LocalEvent {
    @Attribute(.unique) var eventID: String
    var draftID: String
    var captureID: String?
    var kind: String
    var codeValue: String?
    var occurredAt: Date
    var syncStateRaw: String
    var payloadJSON: String

    init(eventID: String, draftID: String, captureID: String? = nil, kind: String, codeValue: String?, payloadJSON: String) {
        self.eventID = eventID
        self.draftID = draftID
        self.captureID = captureID
        self.kind = kind
        self.codeValue = codeValue
        self.occurredAt = .now
        self.syncStateRaw = SyncState.localOnly.rawValue
        self.payloadJSON = payloadJSON
    }
}

@Model
final class LocalMedia {
    @Attribute(.unique) var mediaID: String
    var draftID: String
    var captureID: String?
    var category: String
    var mediaType: String
    var originalPath: String
    var thumbnailPath: String
    var checksum: String
    var pixelWidth: Int
    var pixelHeight: Int
    var capturedAt: Date
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var locationCapturedAt: Date?
    var locationStatusRaw: String = MediaLocationStatus.unavailable.rawValue
    var syncStateRaw: String
    var relatedScanID: String?

    init(mediaID: String, draftID: String, captureID: String? = nil, relatedScanID: String? = nil, category: String, mediaType: String = "image", originalPath: String, thumbnailPath: String, checksum: String, pixelWidth: Int, pixelHeight: Int, location: MediaLocationSnapshot = .unavailable) {
        self.mediaID = mediaID
        self.draftID = draftID
        self.captureID = captureID
        self.relatedScanID = relatedScanID
        self.category = category
        self.mediaType = mediaType
        self.originalPath = originalPath
        self.thumbnailPath = thumbnailPath
        self.checksum = checksum
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAt = .now
        self.latitude = location.latitude
        self.longitude = location.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.locationCapturedAt = location.capturedAt
        self.locationStatusRaw = location.status.rawValue
        self.syncStateRaw = SyncState.localOnly.rawValue
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .localOnly }
        set { syncStateRaw = newValue.rawValue }
    }

    var locationStatus: MediaLocationStatus {
        get { MediaLocationStatus(rawValue: locationStatusRaw) ?? .unavailable }
        set { locationStatusRaw = newValue.rawValue }
    }

    var isRelatedMedia: Bool { !(relatedScanID ?? "").isEmpty }
}

@Model
final class OutboxItem {
    @Attribute(.unique) var idempotencyKey: String
    var eventID: String
    var kind: String
    var bodyJSON: String
    var stateRaw: String
    var retryCount: Int
    var nextRetryAt: Date?
    var lastError: String?
    var createdAt: Date

    init(eventID: String, kind: String, bodyJSON: String) {
        self.idempotencyKey = eventID
        self.eventID = eventID
        self.kind = kind
        self.bodyJSON = bodyJSON
        self.stateRaw = SyncState.queued.rawValue
        self.retryCount = 0
        self.createdAt = .now
    }

    var state: SyncState {
        get { SyncState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }
}

@Model
final class SyncSession {
    @Attribute(.unique) var scope: String
    var cursor: String?
    var failedSummary: String?
    var updatedAt: Date

    init(scope: String = "default", cursor: String? = nil, failedSummary: String? = nil) {
        self.scope = scope
        self.cursor = cursor
        self.failedSummary = failedSummary
        self.updatedAt = .now
    }
}
