import XCTest
@testable import QuickPreview

final class SubscriptionAccessStateTests: XCTestCase {
    private func snapshot(kind: EntitlementGrantKind = .subscriptionActive) -> EntitlementSnapshot {
        EntitlementSnapshot(
            productID: "quickpreview.pro.monthly",
            grantKind: kind,
            lastVerifiedAt: Date(),
            expirationDate: Date().addingTimeInterval(3600),
            transactionID: 2,
            originalTransactionID: 1
        )
    }

    func testEntitledStatesAllowPlayback() {
        let entitled: [SubscriptionAccessState] = [
            .trialActive(snapshot(kind: .trialActive)),
            .subscriptionActive(snapshot()),
            .inGracePeriod(snapshot(kind: .appStoreGracePeriod)),
            .inBillingRetry(snapshot(kind: .billingRetry)),
            .offlineGracePeriod(snapshot()),
        ]

        for state in entitled {
            XCTAssertTrue(state.isEntitled, "Expected \(state) to be entitled")
            XCTAssertFalse(state.blocksPlayback)
            XCTAssertNotNil(state.snapshot)
        }
    }

    func testNonEntitledStatesBlockPlayback() {
        let blocked: [SubscriptionAccessState] = [
            .unknown,
            .verifying,
            .expired,
            .revoked,
            .refunded,
            .notEntitled,
        ]

        for state in blocked {
            XCTAssertFalse(state.isEntitled, "Expected \(state) to be non-entitled")
            XCTAssertTrue(state.blocksPlayback)
            XCTAssertNil(state.snapshot)
        }
    }

    func testEntitlementSnapshotProductMatch() {
        let snap = snapshot()
        XCTAssertTrue(snap.matches(productID: "quickpreview.pro.monthly"))
        XCTAssertFalse(snap.matches(productID: "other.product"))
    }
}
