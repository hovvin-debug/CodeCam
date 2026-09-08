//
//  CodeCamTests.swift
//  CodeCamTests
//
//  Created by lai lin on 2026/9/4.
//

import Foundation
import Testing
@testable import CodeCam

struct CodeCamTests {

    @Test func validProductCodePassesLocalValidation() {
        #expect(CodeValidator.validate("CC-2026-0001") == nil)
    }

    @Test func invalidProductCodeIsRejected() {
        #expect(CodeValidator.validate("bad code!") != nil)
    }

    @Test func fixedFormReportsRequiredFields() {
        let missing = FixedTaskFormValidator.missingFields(for: .empty)
        #expect(missing == ["现场地点", "现场说明"])
    }

    @Test func eventIdentityIsReusableAsIdempotencyKey() {
        let eventID = ClientEventIdentity.make()
        let outbox = OutboxItem(eventID: eventID, kind: "form.saved", bodyJSON: "{}")
        #expect(outbox.eventID == eventID)
        #expect(outbox.idempotencyKey == eventID)
    }

    @Test func platformQRCodeUsesOnlyConfiguredOrigin() throws {
        let platformURL = try #require(URL(string: "https://192.0.2.10:8443"))
        let route = try PlatformPortalQRCodeRouter.route(
            scannedValue: "https://192.0.2.10:8443/q/7fA9K",
            platformBaseURL: platformURL
        )
        #expect(route == .platformPortal(PlatformPortalResource(path: "/q/7fA9K")))
    }

    @Test func externalQRCodeIsRejected() throws {
        let platformURL = try #require(URL(string: "https://platform.example.com"))
        #expect(throws: PlatformPortalError.nonPlatformAddress) {
            try PlatformPortalQRCodeRouter.route(
                scannedValue: "https://untrusted.example.com/q/7fA9K",
                platformBaseURL: platformURL
            )
        }
    }

    @Test func productCodeRemainsInCaptureFlow() throws {
        let platformURL = try #require(URL(string: "https://platform.example.com"))
        let route = try PlatformPortalQRCodeRouter.route(scannedValue: "CC-2026-0001", platformBaseURL: platformURL)
        #expect(route == .productCode("CC-2026-0001"))
    }

    @Test func validAccountCredentialsPassLocalValidation() {
        #expect(AccountCredentialsValidator.validateUsername("field_ops") == nil)
        #expect(AccountCredentialsValidator.validatePassword("Passw0rd!") == nil)
        #expect(AccountCredentialsValidator.validateDisplayName("现场员") == nil)
    }

    @Test func invalidAccountCredentialsAreRejected() {
        #expect(AccountCredentialsValidator.validateUsername("ab") != nil)
        #expect(AccountCredentialsValidator.validatePassword("short") != nil)
        #expect(AccountCredentialsValidator.validateDisplayName("   ") != nil)
    }

    @Test func relatedScanAcceptsLogisticsPayload() {
        #expect(CodeValidator.validateRelated("SF123456789CN") == nil)
        #expect(CodeValidator.validateRelated("(00)123456789012345678") == nil)
        #expect(CodeValidator.normalizeRelated("SF 123 456") == "SF123456")
        #expect(CodeValidator.validate("SF 123") != nil)
    }
}
