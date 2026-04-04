import AppKit
import Foundation

enum ProEntitlementStatus: String, Codable, Equatable {
    case unlinked
    case active
    case gracePeriod
    case expired
    case revoked
}

struct ProSession: Codable, Equatable {
    let accessToken: String
    let email: String?
    let linkedAt: Date
}

struct ProEntitlementSnapshot: Codable, Equatable {
    let status: ProEntitlementStatus
    let email: String?
    let expiresAt: Date?
    let refreshAfter: Date?

    var allowsProFeatures: Bool {
        status == .active || status == .gracePeriod
    }
}

enum ProEntitlementBridgeError: LocalizedError {
    case bridgeUnavailable
    case accountLinkRequiresSubscription
    case invalidCallback
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .bridgeUnavailable:
            return "QuickPreview could not reach the account bridge right now."
        case .accountLinkRequiresSubscription:
            return "An active App Store subscription is required before linking QuickPreview PRO access."
        case .invalidCallback:
            return "QuickPreview received an incomplete account callback."
        case .invalidResponse:
            return "QuickPreview received an unexpected response from the account bridge."
        case let .serverError(message):
            return message
        }
    }
}

struct AppStoreLinkRequest: Codable, Equatable {
    let linkCode: String
    let appEdition: String
    let bundleIdentifier: String
    let productID: String
    let entitlementState: String
    let expirationDate: Date?
    let originalTransactionID: UInt64?
    let transactionID: UInt64?
}

struct AppStoreLinkResponse: Codable, Equatable {
    let status: String
    let email: String?
    let proAccessToken: String
    let expiresAt: Date?
}

struct ProEntitlementValidationRequest: Codable, Equatable {
    let accessToken: String
    let appEdition: String
    let bundleIdentifier: String
}

@MainActor
final class ProEntitlementBridge {
    private static let sessionDefaultsKey = "proEntitlementSession"
    private static let snapshotDefaultsKey = "proEntitlementSnapshot"

    private let defaults: UserDefaults
    private let session: URLSession

    private(set) var currentSession: ProSession?
    private(set) var currentSnapshot: ProEntitlementSnapshot?

    var allowsFinderIntegration: Bool {
        guard AppEdition.current.supportsFinderIntegration else {
            return false
        }
        return currentSnapshot?.allowsProFeatures == true
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session

        if
            let data = defaults.data(forKey: Self.sessionDefaultsKey),
            let session = try? JSONDecoder().decode(ProSession.self, from: data)
        {
            currentSession = session
        }

        if
            let data = defaults.data(forKey: Self.snapshotDefaultsKey),
            let snapshot = try? JSONDecoder().decode(ProEntitlementSnapshot.self, from: data)
        {
            currentSnapshot = snapshot
        }
    }

    func accountPortalURL() -> URL? {
        AppEdition.current.accountPortalURL
    }

    func beginAccountPortal() {
        guard let url = accountPortalURL() else { return }
        NSWorkspace.shared.open(url)
    }

    func linkAppStoreSubscription(
        linkCode: String,
        subscriptionState: SubscriptionAccessState,
        bundleIdentifier: String
    ) async throws -> AppStoreLinkResponse {
        guard let snapshot = subscriptionState.snapshot else {
            throw ProEntitlementBridgeError.accountLinkRequiresSubscription
        }
        guard let endpointURL = bridgeEndpointURL(path: "link-app-store") else {
            throw ProEntitlementBridgeError.bridgeUnavailable
        }

        let requestBody = AppStoreLinkRequest(
            linkCode: linkCode,
            appEdition: AppEdition.current.rawValue,
            bundleIdentifier: bundleIdentifier,
            productID: snapshot.productID,
            entitlementState: entitlementStateName(for: subscriptionState),
            expirationDate: snapshot.expirationDate,
            originalTransactionID: snapshot.originalTransactionID,
            transactionID: snapshot.transactionID
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let decoded = try? JSONDecoder().decode(AppStoreLinkResponse.self, from: data) else {
            throw ProEntitlementBridgeError.invalidResponse
        }

        if AppEdition.current == .appStore, let proDownloadURL = makeProDownloadURL(from: decoded) {
            NSWorkspace.shared.open(proDownloadURL)
        }

        return decoded
    }

    func handleProSessionCallback(
        accessToken: String,
        email: String?
    ) async throws -> ProEntitlementSnapshot {
        let proSession = ProSession(accessToken: accessToken, email: email, linkedAt: Date())
        storeSession(proSession)
        return try await refreshEntitlement(bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    }

    func refreshEntitlement(bundleIdentifier: String) async throws -> ProEntitlementSnapshot {
        guard AppEdition.current.supportsFinderIntegration else {
            let snapshot = ProEntitlementSnapshot(status: .unlinked, email: nil, expiresAt: nil, refreshAfter: nil)
            storeSnapshot(snapshot)
            return snapshot
        }

        guard
            let currentSession,
            let endpointURL = bridgeEndpointURL(path: "validate-pro")
        else {
            let snapshot = ProEntitlementSnapshot(status: .unlinked, email: nil, expiresAt: nil, refreshAfter: nil)
            storeSnapshot(snapshot)
            return snapshot
        }

        let requestBody = ProEntitlementValidationRequest(
            accessToken: currentSession.accessToken,
            appEdition: AppEdition.current.rawValue,
            bundleIdentifier: bundleIdentifier
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let snapshot = try? JSONDecoder().decode(ProEntitlementSnapshot.self, from: data) else {
            throw ProEntitlementBridgeError.invalidResponse
        }

        storeSnapshot(snapshot)
        return snapshot
    }

    func clearProSession() {
        currentSession = nil
        currentSnapshot = nil
        defaults.removeObject(forKey: Self.sessionDefaultsKey)
        defaults.removeObject(forKey: Self.snapshotDefaultsKey)
    }

    private func bridgeEndpointURL(path: String) -> URL? {
        AppEdition.current.bridgeAPIBaseURL?.appendingPathComponent(path)
    }

    private func makeProDownloadURL(from response: AppStoreLinkResponse) -> URL? {
        guard var components = URLComponents(url: AppEdition.current.proDownloadURL ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "token", value: response.proAccessToken),
            URLQueryItem(name: "email", value: response.email)
        ]
        return components.url
    }

    private func entitlementStateName(for state: SubscriptionAccessState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .verifying:
            return "verifying"
        case .trialActive:
            return "trialActive"
        case .subscriptionActive:
            return "subscriptionActive"
        case .inGracePeriod:
            return "gracePeriod"
        case .inBillingRetry:
            return "billingRetry"
        case .offlineGracePeriod:
            return "offlineGracePeriod"
        case .expired:
            return "expired"
        case .revoked:
            return "revoked"
        case .refunded:
            return "refunded"
        case .notEntitled:
            return "notEntitled"
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProEntitlementBridgeError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if
                let decoded = try? JSONDecoder().decode(ServerErrorPayload.self, from: data),
                !decoded.error.isEmpty
            {
                throw ProEntitlementBridgeError.serverError(decoded.error)
            }
            throw ProEntitlementBridgeError.invalidResponse
        }
    }

    private func storeSession(_ proSession: ProSession) {
        currentSession = proSession
        defaults.set(try? JSONEncoder().encode(proSession), forKey: Self.sessionDefaultsKey)
    }

    private func storeSnapshot(_ snapshot: ProEntitlementSnapshot) {
        currentSnapshot = snapshot
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Self.snapshotDefaultsKey)
    }
}

private struct ServerErrorPayload: Codable {
    let error: String
}
