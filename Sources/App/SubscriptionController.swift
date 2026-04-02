import AppKit
import Foundation
import StoreKit

struct SubscriptionConfiguration {
    let productID: String
    let offlineGraceWindow: TimeInterval
    let clockRollbackTolerance: TimeInterval

    static let `default` = SubscriptionConfiguration(
        productID: "com.jboive.quickpreview.subscription.monthly",
        offlineGraceWindow: 7 * 24 * 60 * 60,
        clockRollbackTolerance: 5 * 60
    )
}

enum SubscriptionPurchaseResult: Equatable {
    case success(SubscriptionAccessState)
    case pending
    case cancelled
    case failed(String)
}

enum SubscriptionRestoreResult: Equatable {
    case restored(SubscriptionAccessState)
    case noEntitlement
    case failed(String)
}

@MainActor
final class SubscriptionController {
    private struct VerifiedSubscriptionStatus {
        let state: Product.SubscriptionInfo.RenewalState
        let transaction: Transaction
    }

    private enum SubscriptionControllerError: Error {
        case failedVerification
        case missingProduct
    }

    private let configuration: SubscriptionConfiguration
    private let entitlementCache: EntitlementCache
    private let nowProvider: () -> Date
    private var updatesTask: Task<Void, Never>?

    var onAccessStateChange: ((SubscriptionAccessState) -> Void)?

    private(set) var accessState: SubscriptionAccessState = .unknown {
        didSet {
            guard accessState != oldValue else { return }
            onAccessStateChange?(accessState)
        }
    }

    private(set) var subscriptionProduct: Product?

    // Local development bypass:
    // - Default: enabled for DEBUG builds so you can run without an App Store subscription.
    // - Optional env var override:
    //   - QUICKPREVIEW_DEV_ENTITLED=1 enables (even for Release)
    //   - QUICKPREVIEW_DEV_ENTITLED=0 disables (even for Debug)
    private static func isDevEntitledBypassEnabled() -> Bool {
        if let raw = ProcessInfo.processInfo.environment["QUICKPREVIEW_DEV_ENTITLED"] {
            switch raw.lowercased() {
            case "0", "false", "no":
                return false
            case "1", "true", "yes":
                return true
            default:
                return true
            }
        }

        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func makeDevEntitlementSnapshot(now: Date) -> EntitlementSnapshot {
        let expirationDate = now.addingTimeInterval(365 * 24 * 60 * 60)
        return EntitlementSnapshot(
            productID: configuration.productID,
            grantKind: .subscriptionActive,
            lastVerifiedAt: now,
            expirationDate: expirationDate,
            transactionID: nil,
            originalTransactionID: nil
        )
    }

    init(
        configuration: SubscriptionConfiguration = .default,
        entitlementCache: EntitlementCache = EntitlementCache(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.entitlementCache = entitlementCache
        self.nowProvider = nowProvider
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() {
        guard updatesTask == nil else { return }

        updatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
    }

    func refreshEntitlements() async -> SubscriptionAccessState {
        accessState = .verifying
        let cachedSnapshot = entitlementCache.load()
        let verifiedAt = nowProvider()

        if Self.isDevEntitledBypassEnabled() {
            let snapshot = makeDevEntitlementSnapshot(now: verifiedAt)
            let devState: SubscriptionAccessState = .subscriptionActive(snapshot)
            accessState = devState
            return devState
        }

        do {
            let product = try await loadProduct()
            if let resolvedState = try await currentVerifiedAccessState(product: product, verifiedAt: verifiedAt) {
                persistVerifiedAccessStateIfNeeded(resolvedState)
                accessState = resolvedState
                return resolvedState
            }
        } catch {
            if let fallbackState = offlineFallbackState(from: cachedSnapshot, now: verifiedAt) {
                accessState = fallbackState
                return fallbackState
            }

            accessState = .notEntitled
            return .notEntitled
        }

        if let fallbackState = offlineFallbackState(from: cachedSnapshot, now: verifiedAt) {
            accessState = fallbackState
            return fallbackState
        }

        entitlementCache.clear()
        accessState = .notEntitled
        return .notEntitled
    }

    func purchaseSubscription() async -> SubscriptionPurchaseResult {
        do {
            let product = try await loadProduct()
            let purchaseResult = try await product.purchase()

            switch purchaseResult {
            case .success(let verificationResult):
                let transaction = try Self.requireVerified(verificationResult)
                await transaction.finish()
                let refreshedState = await refreshEntitlements()
                if refreshedState.isEntitled {
                    return .success(refreshedState)
                }
                return .failed("The purchase completed, but QuickPreview could not verify access yet.")
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("QuickPreview received an unknown App Store purchase response.")
            }
        } catch {
            return .failed(Self.userFacingMessage(for: error))
        }
    }

    func restorePurchases() async -> SubscriptionRestoreResult {
        do {
            try await AppStore.sync()
            let refreshedState = await refreshEntitlements()
            return refreshedState.isEntitled ? .restored(refreshedState) : .noEntitlement
        } catch {
            return .failed(Self.userFacingMessage(for: error))
        }
    }

    func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func loadProduct() async throws -> Product {
        if let subscriptionProduct {
            return subscriptionProduct
        }

        let products = try await Product.products(for: [configuration.productID])
        guard let product = products.first else {
            throw SubscriptionControllerError.missingProduct
        }

        subscriptionProduct = product
        return product
    }

    private func currentVerifiedAccessState(
        product: Product,
        verifiedAt: Date
    ) async throws -> SubscriptionAccessState? {
        if let subscription = product.subscription {
            let statuses = try await subscription.status
            let matchingStatuses = try statuses
                .map(Self.makeVerifiedSubscriptionStatus(_:))
                .filter { $0.transaction.productID == configuration.productID }

            if let resolvedState = resolveAccessState(from: matchingStatuses, verifiedAt: verifiedAt) {
                return resolvedState
            }
        }

        for await entitlement in Transaction.currentEntitlements {
            let transaction = try Self.requireVerified(entitlement)
            guard transaction.productID == configuration.productID else {
                continue
            }

            return makeAccessState(from: transaction, subscriptionState: nil, verifiedAt: verifiedAt)
        }

        return nil
    }

    private func resolveAccessState(
        from statuses: [VerifiedSubscriptionStatus],
        verifiedAt: Date
    ) -> SubscriptionAccessState? {
        if let subscribedStatus = statuses.first(where: { $0.state == .subscribed }) {
            return makeAccessState(
                from: subscribedStatus.transaction,
                subscriptionState: subscribedStatus.state,
                verifiedAt: verifiedAt
            )
        }

        if let graceStatus = statuses.first(where: { $0.state == .inGracePeriod }) {
            return makeAccessState(
                from: graceStatus.transaction,
                subscriptionState: graceStatus.state,
                verifiedAt: verifiedAt
            )
        }

        if let billingRetryStatus = statuses.first(where: { $0.state == .inBillingRetryPeriod }) {
            return makeAccessState(
                from: billingRetryStatus.transaction,
                subscriptionState: billingRetryStatus.state,
                verifiedAt: verifiedAt
            )
        }

        if let revokedStatus = statuses.first(where: { $0.state == .revoked }) {
            return makeAccessState(
                from: revokedStatus.transaction,
                subscriptionState: revokedStatus.state,
                verifiedAt: verifiedAt
            )
        }

        if statuses.contains(where: { $0.state == .expired }) {
            return .expired
        }

        return nil
    }

    private func makeAccessState(
        from transaction: Transaction,
        subscriptionState: Product.SubscriptionInfo.RenewalState?,
        verifiedAt: Date
    ) -> SubscriptionAccessState {
        if let revocationReason = transaction.revocationReason {
            return revocationReason == .developerIssue ? .refunded : .revoked
        }

        let snapshot = EntitlementSnapshot(
            productID: transaction.productID,
            grantKind: grantKind(for: transaction, subscriptionState: subscriptionState),
            lastVerifiedAt: verifiedAt,
            expirationDate: transaction.expirationDate,
            transactionID: transaction.id,
            originalTransactionID: transaction.originalID
        )

        switch subscriptionState {
        case .inGracePeriod:
            return .inGracePeriod(snapshot)
        case .inBillingRetryPeriod:
            return .inBillingRetry(snapshot)
        case .revoked:
            return .revoked
        case .expired:
            return .expired
        case .subscribed, .none:
            return transaction.offerType == .introductory
                ? .trialActive(snapshot)
                : .subscriptionActive(snapshot)
        default:
            return .subscriptionActive(snapshot)
        }
    }

    private func grantKind(
        for transaction: Transaction,
        subscriptionState: Product.SubscriptionInfo.RenewalState?
    ) -> EntitlementGrantKind {
        switch subscriptionState {
        case .inGracePeriod:
            return .appStoreGracePeriod
        case .inBillingRetryPeriod:
            return .billingRetry
        case .subscribed, .expired, .revoked, .none:
            return transaction.offerType == .introductory ? .trialActive : .subscriptionActive
        default:
            return .subscriptionActive
        }
    }

    private func persistVerifiedAccessStateIfNeeded(_ state: SubscriptionAccessState) {
        switch state {
        case .trialActive(let snapshot),
             .subscriptionActive(let snapshot),
             .inGracePeriod(let snapshot),
             .inBillingRetry(let snapshot):
            _ = entitlementCache.save(snapshot)
        case .offlineGracePeriod:
            break
        case .unknown,
             .verifying,
             .expired,
             .revoked,
             .refunded,
             .notEntitled:
            entitlementCache.clear()
        }
    }

    private func offlineFallbackState(
        from snapshot: EntitlementSnapshot?,
        now: Date
    ) -> SubscriptionAccessState? {
        guard let snapshot else {
            return nil
        }

        let rollbackThreshold = now.addingTimeInterval(configuration.clockRollbackTolerance)
        guard rollbackThreshold >= snapshot.lastVerifiedAt else {
            return nil
        }

        let graceDeadline = snapshot.lastVerifiedAt.addingTimeInterval(configuration.offlineGraceWindow)
        guard now <= graceDeadline else {
            return nil
        }

        return .offlineGracePeriod(snapshot)
    }

    private func observeTransactionUpdates() async {
        for await update in Transaction.updates {
            guard !Task.isCancelled else { return }

            if let transaction = try? Self.requireVerified(update) {
                await transaction.finish()
            }

            _ = await refreshEntitlements()
        }
    }

    private static func makeVerifiedSubscriptionStatus(
        _ status: Product.SubscriptionInfo.Status
    ) throws -> VerifiedSubscriptionStatus {
        let transaction = try requireVerified(status.transaction)
        return VerifiedSubscriptionStatus(state: status.state, transaction: transaction)
    }

    private static func requireVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let verifiedValue):
            return verifiedValue
        case .unverified:
            throw SubscriptionControllerError.failedVerification
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case SubscriptionControllerError.missingProduct:
            return "QuickPreview could not load the subscription product. Check the App Store product identifier setup."
        case SubscriptionControllerError.failedVerification:
            return "QuickPreview could not verify the App Store transaction."
        default:
            return error.localizedDescription
        }
    }
}
