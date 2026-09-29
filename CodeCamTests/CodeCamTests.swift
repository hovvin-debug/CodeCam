import XCTest
import UIKit
@testable import CodeCam

@MainActor final class CodeCamTests: XCTestCase {
    func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    func testDraftAndPhotosSurviveRestartAndCompletionIsImmutable() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(root: root)
        let id = try store.create(serial: "  SN-001  ")
        try store.updateNote(id, note: "检查合格")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try store.addPhoto(id, jpeg: XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
        let restored = RecordStore(root: root)
        XCTAssertNil(restored.loadError)
        let record = try XCTUnwrap(restored.record(id))
        XCTAssertEqual(record.serial, "SN-001"); XCTAssertEqual(record.note, "检查合格")
        XCTAssertEqual(record.spaceID, store.archive.spaceID)
        XCTAssertEqual(record.photos.count, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: restored.photoURL(record.photos[0]).path))
        try restored.complete(id)
        XCTAssertThrowsError(try restored.updateNote(id, note: "覆盖"))
        XCTAssertNotNil(RecordStore(root: root).record(id)?.submittedAt)
    }
    func testSameSerialKeepsIndependentCapturesAndCase() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(root: root)
        let first = try store.create(serial: "Sn-01")
        let second = try store.create(serial: "Sn-01")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.first?.serial, "Sn-01")
        XCTAssertThrowsError(try store.create(serial: "   "))
        XCTAssertThrowsError(try store.complete(first))
    }
    func testCloudBindingMigratesSpaceAndRejectsDifferentAccount() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(root: root)
        let id = try store.create(serial: "SN-BIND")
        let binding = CloudBinding(server: "https://example.com", userID: UUID(), spaceID: UUID(), username: "first")
        try store.bindCloud(binding)
        XCTAssertEqual(store.archive.spaceID, binding.spaceID)
        XCTAssertEqual(store.record(id)?.spaceID, binding.spaceID)
        XCTAssertEqual(RecordStore(root: root).archive.cloudBinding, binding)
        XCTAssertThrowsError(try store.bindCloud(CloudBinding(server: binding.server, userID: UUID(), spaceID: UUID(), username: "second")))
        XCTAssertEqual(store.record(id)?.spaceID, binding.spaceID)
    }
    func testCorruptArchiveIsPreservedAndCannotBeOverwritten() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "records.json")
        let data = Data("corrupted".utf8); try data.write(to: file)
        let store = RecordStore(root: root)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.create(serial: "SN"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testFailedDiskSaveDoesNotReportSuccessfulRecord() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(root: root)
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        XCTAssertThrowsError(try store.create(serial: "SN"))
        XCTAssertTrue(store.records.isEmpty)
    }
}
