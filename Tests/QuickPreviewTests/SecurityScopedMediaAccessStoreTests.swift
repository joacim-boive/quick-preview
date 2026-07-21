import XCTest
@testable import QuickPreview

final class SecurityScopedMediaAccessStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SecurityScopedMediaAccessStore!
    private var temporaryDirectoryURL: URL!
    private var temporaryVideoURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suite = TestUserDefaults.makeSuite(named: "SecurityScopedMediaAccessStoreTests")
        suiteName = suite.suiteName
        defaults = suite.defaults
        store = SecurityScopedMediaAccessStore(defaults: defaults)

        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPreviewMediaAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        temporaryVideoURL = temporaryDirectoryURL.appendingPathComponent("clip.mp4")
        try Data("fake-video".utf8).write(to: temporaryVideoURL)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        store = nil
        TestUserDefaults.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        temporaryDirectoryURL = nil
        temporaryVideoURL = nil
        try super.tearDownWithError()
    }

    func testBeginAccessFallsBackToReadableFileURL() {
        let accessibleURL = store.beginAccess(for: temporaryVideoURL)
        XCTAssertEqual(accessibleURL?.standardizedFileURL.path, temporaryVideoURL.standardizedFileURL.path)
        if let accessibleURL {
            store.endAccess(for: accessibleURL)
        }
    }

    func testAccessIsReferenceCounted() {
        let first = store.beginAccess(for: temporaryVideoURL)
        let second = store.beginAccess(for: temporaryVideoURL)
        XCTAssertEqual(
            first?.resolvingSymlinksInPath().path,
            second?.resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(first)

        if let first {
            store.endAccess(for: first)
        }
        // Still held by second retain.
        XCTAssertEqual(
            store.beginAccess(for: temporaryVideoURL)?.resolvingSymlinksInPath().path,
            temporaryVideoURL.resolvingSymlinksInPath().path
        )
        if let second {
            store.endAccess(for: second)
            store.endAccess(for: second)
        }
    }

    func testPersistedBookmarkLookupSurvivesReloadWhenRegisterSucceeds() {
        let didRegister = store.register(temporaryVideoURL)
        // In a non-sandboxed test host, creating a security-scoped bookmark may fail.
        // The store must still remain usable via readable-path fallback after reload.
        let reloaded = SecurityScopedMediaAccessStore(defaults: defaults)
        let accessibleURL = reloaded.beginAccess(for: temporaryVideoURL)
        XCTAssertNotNil(accessibleURL)
        if didRegister {
            XCTAssertTrue(reloaded.hasPersistedAccess(for: temporaryVideoURL))
        }
        if let accessibleURL {
            reloaded.endAccess(for: accessibleURL)
        }
    }

    func testNormalizedPathIgnoresVarSymlinkAlias() {
        let varAlias = URL(fileURLWithPath: temporaryVideoURL.path.replacingOccurrences(
            of: "/private/var/",
            with: "/var/"
        ))
        let first = store.beginAccess(for: temporaryVideoURL)
        let second = store.beginAccess(for: varAlias)
        XCTAssertEqual(
            first?.resolvingSymlinksInPath().path,
            second?.resolvingSymlinksInPath().path
        )
        if let first {
            store.endAccess(for: first)
        }
        if let second {
            store.endAccess(for: second)
        }
    }
}
