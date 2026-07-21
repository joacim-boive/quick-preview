import XCTest
@testable import QuickPreview

final class AppEditionTests: XCTestCase {
    func testAppStoreEditionIdentity() {
        let edition = AppEdition.appStore
        XCTAssertEqual(edition.displayName, "QuickPreview")
        XCTAssertEqual(edition.urlScheme, "quickpreview")
        XCTAssertEqual(edition.helperBundleIdentifier, "com.jboive.quickpreview.launcher")
        XCTAssertFalse(edition.supportsFinderIntegration)
        XCTAssertTrue(edition.showsProMessaging)
    }

    func testProEditionIdentity() {
        let edition = AppEdition.pro
        XCTAssertEqual(edition.displayName, "QuickPreview PRO")
        XCTAssertEqual(edition.urlScheme, "quickpreview-pro")
        XCTAssertEqual(edition.helperBundleIdentifier, "com.jboive.quickpreview.pro.launcher")
        XCTAssertTrue(edition.supportsFinderIntegration)
        XCTAssertFalse(edition.showsProMessaging)
    }

    func testPortalURLsPointAtBoiveQuickPreviewPath() {
        XCTAssertEqual(
            AppEdition.appStore.accountPortalURL?.absoluteString,
            "https://boive.se/quick-preview/pro/"
        )
        XCTAssertEqual(
            AppEdition.pro.accountPortalURL?.absoluteString,
            "https://boive.se/quick-preview/pro/download/"
        )
        XCTAssertEqual(
            AppEdition.appStore.supportURL?.absoluteString,
            "https://boive.se/quick-preview/support/"
        )
        XCTAssertEqual(
            AppEdition.appStore.privacyPolicyURL?.absoluteString,
            "https://boive.se/quick-preview/privacy/"
        )
    }

    func testBridgeAPIBaseURLStaysOnVercelHost() {
        XCTAssertEqual(
            AppEdition.appStore.bridgeAPIBaseURL?.absoluteString,
            "https://quick-preview-alpha.vercel.app/api/bridge/"
        )
        XCTAssertEqual(
            AppEdition.pro.bridgeAPIBaseURL?.host,
            "quick-preview-alpha.vercel.app"
        )
    }

    func testSharedContainerIdentifiers() {
        XCTAssertEqual(
            AppEdition.appStore.sharedContainerIdentifier,
            "group.com.jboive.quickpreview.shared"
        )
        XCTAssertEqual(
            AppEdition.pro.sharedContainerIdentifier,
            "group.com.jboive.quickpreview.pro.shared"
        )
        XCTAssertEqual(
            AppEdition.proBootstrapContainerIdentifier,
            "group.com.jboive.quickpreview.pro.bootstrap"
        )
    }
}
