import XCTest
@testable import QuickPreview

@MainActor
final class ProEntitlementSessionTests: XCTestCase {
    private var defaultsSuite: String!
    private var bootstrapSuite: String!
    private var defaults: UserDefaults!
    private var bootstrapDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let primary = TestUserDefaults.makeSuite(named: "QuickPreview.session")
        let bootstrap = TestUserDefaults.makeSuite(named: "QuickPreview.bootstrap")
        defaultsSuite = primary.suiteName
        bootstrapSuite = bootstrap.suiteName
        defaults = primary.defaults
        bootstrapDefaults = bootstrap.defaults
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        TestUserDefaults.tearDown(defaultsSuite)
        TestUserDefaults.tearDown(bootstrapSuite)
        defaults = nil
        bootstrapDefaults = nil
        defaultsSuite = nil
        bootstrapSuite = nil
        super.tearDown()
    }

    func testLoadsPersistedSessionAndSnapshot() throws {
        let linkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ProSession(accessToken: "token-1", email: "user@example.com", linkedAt: linkedAt)
        let snapshot = ProEntitlementSnapshot(
            status: .active,
            email: "user@example.com",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshAfter: Date(timeIntervalSince1970: 1_700_100_000)
        )

        defaults.set(try JSONEncoder().encode(session), forKey: "proEntitlementSession")
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "proEntitlementSnapshot")

        let bridge = ProEntitlementBridge(
            defaults: defaults,
            session: MockURLSessionFactory.make(),
            bootstrapDefaults: bootstrapDefaults
        )

        XCTAssertEqual(bridge.currentSession, session)
        XCTAssertEqual(bridge.currentSnapshot, snapshot)
        XCTAssertEqual(
            bridge.allowsFinderIntegration,
            AppEdition.current.supportsFinderIntegration
        )
    }

    func testClearProSessionRemovesLocalAndBootstrapState() throws {
        let session = ProSession(accessToken: "token-1", email: "user@example.com", linkedAt: Date())
        let snapshot = ProEntitlementSnapshot(status: .gracePeriod, email: "user@example.com", expiresAt: nil, refreshAfter: nil)
        defaults.set(try JSONEncoder().encode(session), forKey: "proEntitlementSession")
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "proEntitlementSnapshot")
        bootstrapDefaults.set(try JSONEncoder().encode(session), forKey: "proEntitlementBootstrapSession")

        let bridge = ProEntitlementBridge(
            defaults: defaults,
            session: MockURLSessionFactory.make(),
            bootstrapDefaults: bootstrapDefaults
        )
        bridge.clearProSession()

        XCTAssertNil(bridge.currentSession)
        XCTAssertNil(bridge.currentSnapshot)
        XCTAssertNil(defaults.data(forKey: "proEntitlementSession"))
        XCTAssertNil(defaults.data(forKey: "proEntitlementSnapshot"))
        XCTAssertNil(bootstrapDefaults.data(forKey: "proEntitlementBootstrapSession"))
        XCTAssertFalse(bridge.allowsFinderIntegration)
    }

    func testHandleProSessionCallbackPersistsSessionAndRefreshesSnapshot() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "validate-pro")
            let body = """
            {"status":"active","email":"user@example.com","expiresAt":"2030-01-01T00:00:00.000Z","refreshAfter":"2030-01-01T00:00:00.000Z"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let bridge = ProEntitlementBridge(
            defaults: defaults,
            session: MockURLSessionFactory.make(),
            bootstrapDefaults: bootstrapDefaults
        )

        let snapshot = try await bridge.handleProSessionCallback(
            accessToken: "fresh-token",
            email: "user@example.com"
        )

        XCTAssertEqual(bridge.currentSession?.accessToken, "fresh-token")
        XCTAssertEqual(bridge.currentSession?.email, "user@example.com")
        XCTAssertNotNil(defaults.data(forKey: "proEntitlementSession"))
        XCTAssertNotNil(bootstrapDefaults.data(forKey: "proEntitlementBootstrapSession"))

        if AppEdition.current.supportsFinderIntegration {
            XCTAssertEqual(snapshot.status, .active)
            XCTAssertEqual(bridge.currentSnapshot?.status, .active)
            XCTAssertTrue(bridge.allowsFinderIntegration)
        } else {
            XCTAssertEqual(snapshot.status, .unlinked)
            XCTAssertEqual(bridge.currentSnapshot?.status, .unlinked)
            XCTAssertFalse(bridge.allowsFinderIntegration)
        }
    }

    func testRefreshImportsNewerBootstrapSessionBeforeValidating() async throws {
        guard AppEdition.current.supportsFinderIntegration else {
            throw XCTSkip("Bootstrap import path is exercised in PRO edition builds")
        }

        let older = ProSession(
            accessToken: "older-token",
            email: "old@example.com",
            linkedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = ProSession(
            accessToken: "newer-token",
            email: "new@example.com",
            linkedAt: Date(timeIntervalSince1970: 2_000)
        )
        defaults.set(try JSONEncoder().encode(older), forKey: "proEntitlementSession")
        bootstrapDefaults.set(try JSONEncoder().encode(newer), forKey: "proEntitlementBootstrapSession")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "validate-pro")
            let payload = """
            {"status":"gracePeriod","email":"new@example.com","expiresAt":"2030-01-01T00:00:00Z","refreshAfter":"2030-01-01T00:00:00Z"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        let bridge = ProEntitlementBridge(
            defaults: defaults,
            session: MockURLSessionFactory.make(),
            bootstrapDefaults: bootstrapDefaults
        )
        let snapshot = try await bridge.refreshEntitlement(bundleIdentifier: "com.jboive.quickpreview.pro")

        XCTAssertEqual(bridge.currentSession?.accessToken, "newer-token")
        XCTAssertEqual(bridge.currentSession?.email, "new@example.com")
        XCTAssertEqual(snapshot.status, .gracePeriod)
        XCTAssertTrue(bridge.allowsFinderIntegration)
    }

    func testAccountPortalURLMatchesEdition() {
        let bridge = ProEntitlementBridge(
            defaults: defaults,
            session: MockURLSessionFactory.make(),
            bootstrapDefaults: bootstrapDefaults
        )
        XCTAssertEqual(bridge.accountPortalURL(), AppEdition.current.accountPortalURL)
    }
}
