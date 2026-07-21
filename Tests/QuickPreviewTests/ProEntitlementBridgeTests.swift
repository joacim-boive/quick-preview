import XCTest
@testable import QuickPreview

final class ProEntitlementBridgeTests: XCTestCase {
    func testAllowsProFeaturesForActiveAndGraceStatuses() {
        XCTAssertTrue(
            ProEntitlementSnapshot(status: .active, email: nil, expiresAt: nil, refreshAfter: nil)
                .allowsProFeatures
        )
        XCTAssertTrue(
            ProEntitlementSnapshot(status: .gracePeriod, email: nil, expiresAt: nil, refreshAfter: nil)
                .allowsProFeatures
        )
        XCTAssertFalse(
            ProEntitlementSnapshot(status: .expired, email: nil, expiresAt: nil, refreshAfter: nil)
                .allowsProFeatures
        )
        XCTAssertFalse(
            ProEntitlementSnapshot(status: .unlinked, email: nil, expiresAt: nil, refreshAfter: nil)
                .allowsProFeatures
        )
        XCTAssertFalse(
            ProEntitlementSnapshot(status: .revoked, email: nil, expiresAt: nil, refreshAfter: nil)
                .allowsProFeatures
        )
    }

    func testAcceptsTicketedBridgeDownloadURL() throws {
        let url = URL(string: "https://quick-preview-alpha.vercel.app/api/bridge/pro-download?t=abc123")!
        try BridgeDownloadURLValidator.validate(
            url,
            bridgeHost: "quick-preview-alpha.vercel.app"
        )
    }

    func testRejectsMarketingPortalDownloadURL() {
        let url = URL(string: "https://boive.se/quick-preview/pro/download/?token=legacy")!
        XCTAssertThrowsError(
            try BridgeDownloadURLValidator.validate(
                url,
                bridgeHost: "quick-preview-alpha.vercel.app"
            )
        ) { error in
            guard case .missingSecureDownloadLink = error as? ProEntitlementBridgeError else {
                XCTFail("Expected missingSecureDownloadLink, got \(error)")
                return
            }
        }
    }

    func testRejectsBridgeURLMissingTicketParam() {
        let url = URL(string: "https://quick-preview-alpha.vercel.app/api/bridge/pro-download")!
        XCTAssertThrowsError(
            try BridgeDownloadURLValidator.validate(
                url,
                bridgeHost: "quick-preview-alpha.vercel.app"
            )
        )
    }

    func testRejectsLegacyTokenQueryParam() {
        let url = URL(
            string: "https://quick-preview-alpha.vercel.app/api/bridge/pro-download?t=ok&token=legacy"
        )!
        XCTAssertThrowsError(
            try BridgeDownloadURLValidator.validate(
                url,
                bridgeHost: "quick-preview-alpha.vercel.app"
            )
        )
    }

    func testRejectsHostMismatch() {
        let url = URL(string: "https://evil.example/api/bridge/pro-download?t=abc")!
        XCTAssertThrowsError(
            try BridgeDownloadURLValidator.validate(
                url,
                bridgeHost: "quick-preview-alpha.vercel.app"
            )
        )
    }
}
