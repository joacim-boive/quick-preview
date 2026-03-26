import Foundation

enum EntitlementGrantKind: String, Codable, Equatable {
    case trialActive
    case subscriptionActive
    case appStoreGracePeriod
    case billingRetry
}

struct EntitlementSnapshot: Codable, Equatable {
    let productID: String
    let grantKind: EntitlementGrantKind
    let lastVerifiedAt: Date
    let expirationDate: Date?
    let transactionID: UInt64?
    let originalTransactionID: UInt64?
}

enum SubscriptionAccessState: Equatable {
    case unknown
    case verifying
    case trialActive(EntitlementSnapshot)
    case subscriptionActive(EntitlementSnapshot)
    case inGracePeriod(EntitlementSnapshot)
    case inBillingRetry(EntitlementSnapshot)
    case offlineGracePeriod(EntitlementSnapshot)
    case expired
    case revoked
    case refunded
    case notEntitled

    var isEntitled: Bool {
        switch self {
        case .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            return true
        case .unknown,
             .verifying,
             .expired,
             .revoked,
             .refunded,
             .notEntitled:
            return false
        }
    }

    var blocksPlayback: Bool {
        !isEntitled
    }

    var snapshot: EntitlementSnapshot? {
        switch self {
        case .trialActive(let snapshot),
             .subscriptionActive(let snapshot),
             .inGracePeriod(let snapshot),
             .inBillingRetry(let snapshot),
             .offlineGracePeriod(let snapshot):
            return snapshot
        case .unknown,
             .verifying,
             .expired,
             .revoked,
             .refunded,
             .notEntitled:
            return nil
        }
    }
}
