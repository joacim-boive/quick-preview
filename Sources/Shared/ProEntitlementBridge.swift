import AppKit
import Foundation
import os

private let bridgeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jboive.quickpreview",
    category: "ProEntitlementBridge"
)

/// Decodes `Date` fields from ISO-8601 strings (`toISOString()` from the Node bridge).
private enum BridgeAPIJSON {
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WholeSecond: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseISO8601Date(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601WholeSecond.date(from: string)
    }

    static func requestJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional.string(from: date))
        }
        return encoder
    }
}

private struct AppStoreLinkResponseDTO: Decodable {
    let status: String
    let email: String?
    let proAccessToken: String
    let expiresAt: String?
    /// Ticketed bridge page on Vercel (`/api/bridge/pro-download?...`); required — the app refuses token-in-query marketing URLs.
    let downloadURL: String?
}

private struct ProEntitlementSnapshotDTO: Decodable {
    let status: String
    let email: String?
    let expiresAt: String?
    let refreshAfter: String?
}

private func logBridgeResponseBody(_ data: Data, context: String) {
    if let text = String(data: data, encoding: .utf8) {
        QuickPreviewDebugLog.log("\(context) response body (\(data.count) bytes): \(text)")
    } else {
        QuickPreviewDebugLog.log("\(context) response body: \(data.count) bytes (not valid UTF-8)")
    }
}

/// Rejects legacy marketing-site URLs with `?token=` and ensures ticket links match the app’s configured bridge host.
private func validateSecureBridgeDownloadURL(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https" else {
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
    guard url.path == "/api/bridge/pro-download" else {
        QuickPreviewDebugLog.log("downloadURL rejected: path is \(url.path), expected /api/bridge/pro-download")
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
    guard let bridgeHost = AppEdition.current.bridgeAPIBaseURL?.host else {
        throw ProEntitlementBridgeError.bridgeUnavailable
    }
    guard url.host == bridgeHost else {
        QuickPreviewDebugLog.log("downloadURL host mismatch: got \(url.host ?? "?") expected \(bridgeHost) — set QUICKPREVIEW_BRIDGE_PUBLIC_URL on Vercel to this host")
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard items.contains(where: { $0.name == "t" && !($0.value ?? "").isEmpty }) else {
        QuickPreviewDebugLog.log("downloadURL rejected: missing ticket query param t")
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
    if items.contains(where: { $0.name == "token" }) {
        QuickPreviewDebugLog.log("downloadURL rejected: legacy token query param")
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
}

/// Host shown in debug logs: prefers the URLSession-effective URL so redirects are visible; compares to the request URL.
private func bridgeLogHost(endpointURL: URL, response: URLResponse) -> String {
    let requested = endpointURL.host ?? "?"
    guard let http = response as? HTTPURLResponse, let effectiveHost = http.url?.host else {
        return requested
    }
    if effectiveHost != requested {
        return "\(effectiveHost) (requested \(requested))"
    }
    return effectiveHost
}

private func decodeAppStoreLinkResponse(from data: Data) throws -> AppStoreLinkResponse {
    let dto = try JSONDecoder().decode(AppStoreLinkResponseDTO.self, from: data)
    let expires: Date?
    if let string = dto.expiresAt, !string.isEmpty {
        expires = BridgeAPIJSON.parseISO8601Date(string)
    } else {
        expires = nil
    }
    let downloadURL = dto.downloadURL.flatMap { raw in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }
    guard let downloadURL else {
        throw ProEntitlementBridgeError.missingSecureDownloadLink
    }
    try validateSecureBridgeDownloadURL(downloadURL)
    return AppStoreLinkResponse(
        status: dto.status,
        email: dto.email,
        proAccessToken: dto.proAccessToken,
        expiresAt: expires,
        downloadURL: downloadURL
    )
}

private func decodeProEntitlementSnapshot(from data: Data) throws -> ProEntitlementSnapshot {
    let dto = try JSONDecoder().decode(ProEntitlementSnapshotDTO.self, from: data)
    guard let statusEnum = ProEntitlementStatus(rawValue: dto.status) else {
        QuickPreviewDebugLog.log("validate-pro unknown status raw value: \(dto.status)")
        throw ProEntitlementBridgeError.invalidResponse
    }
    let expires = dto.expiresAt.flatMap { BridgeAPIJSON.parseISO8601Date($0) }
    let refresh = dto.refreshAfter.flatMap { BridgeAPIJSON.parseISO8601Date($0) }
    return ProEntitlementSnapshot(
        status: statusEnum,
        email: dto.email,
        expiresAt: expires,
        refreshAfter: refresh
    )
}

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
    case missingSecureDownloadLink
    case serverError(String)
    case bridgeRequestFailed(url: URL, underlying: Error)

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
        case .missingSecureDownloadLink:
            return """
            The bridge did not return a valid secure download link (expected https://YOUR_BRIDGE_HOST/api/bridge/pro-download?t=… matching the app).

            On Vercel Production: deploy the latest repo, set environment variable QUICKPREVIEW_BRIDGE_PUBLIC_URL to the same host as bridgeAPIBaseURL in the app (e.g. https://quick-preview-alpha.vercel.app), then redeploy.
            """
        case let .serverError(message):
            return message
        case let .bridgeRequestFailed(url, underlying):
            let host = url.host ?? "(no host)"
            let detail = (underlying as? URLError)?.localizedDescription ?? underlying.localizedDescription
            return """
            Could not reach the account bridge.

            Host: \(host)
            URL: \(url.absoluteString)

            \(detail)
            """
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
    let downloadURL: URL
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
            let base = AppEdition.current.bridgeAPIBaseURL?.absoluteString ?? "(nil)"
            bridgeLogger.error("link-app-store missing endpoint; bridgeAPIBaseURL=\(base, privacy: .public)")
            print("[QuickPreview] Bridge link-app-store aborted: bridgeAPIBaseURL=\(base)")
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
        request.httpBody = try BridgeAPIJSON.requestJSONEncoder().encode(requestBody)
        if let bodyData = request.httpBody, let bodyText = String(data: bodyData, encoding: .utf8) {
            QuickPreviewDebugLog.log(
                "link-app-store request expirationDate=\(String(describing: snapshot.expirationDate)) body=\(bodyText)"
            )
        } else {
            QuickPreviewDebugLog.log(
                "link-app-store request expirationDate=\(String(describing: snapshot.expirationDate)) body=(unavailable)"
            )
        }

        bridgeLogger.info("POST link-app-store host=\(endpointURL.host ?? "?", privacy: .public) url=\(endpointURL.absoluteString, privacy: .public)")
        print("[QuickPreview] Bridge link-app-store → \(endpointURL.absoluteString)")
        QuickPreviewDebugLog.log("link-app-store bridgeAPIBaseURL \(AppEdition.current.bridgeAPIBaseURL?.absoluteString ?? "(nil)")")

        let (data, response) = try await dataForBridgeRequest(request, endpointURL: endpointURL)
        try validateHTTPResponse(response, data: data)

        QuickPreviewDebugLog.log(
            "link-app-store \(data.count) bytes from \(bridgeLogHost(endpointURL: endpointURL, response: response))"
        )
        let decoded: AppStoreLinkResponse
        do {
            decoded = try decodeAppStoreLinkResponse(from: data)
        } catch let error as ProEntitlementBridgeError {
            if case .missingSecureDownloadLink = error {
                bridgeLogger.error("link-app-store missing or invalid downloadURL")
                logBridgeResponseBody(data, context: "link-app-store")
            }
            QuickPreviewDebugLog.log("link-app-store bridge error: \(error)")
            throw error
        } catch {
            bridgeLogger.error("link-app-store decode failed: \(String(describing: error), privacy: .public)")
            logBridgeResponseBody(data, context: "link-app-store")
            QuickPreviewDebugLog.log("link-app-store decode error: \(error)")
            throw ProEntitlementBridgeError.invalidResponse
        }
        QuickPreviewDebugLog.log("link-app-store decoded status=\(decoded.status) email=\(decoded.email ?? "nil") expiresAt=\(String(describing: decoded.expiresAt)) downloadURL=\(decoded.downloadURL.absoluteString)")

        if AppEdition.current == .appStore {
            NSWorkspace.shared.open(decoded.downloadURL)
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
        request.httpBody = try BridgeAPIJSON.requestJSONEncoder().encode(requestBody)

        bridgeLogger.info("POST validate-pro host=\(endpointURL.host ?? "?", privacy: .public) url=\(endpointURL.absoluteString, privacy: .public)")
        print("[QuickPreview] Bridge validate-pro → \(endpointURL.absoluteString)")

        let (data, response) = try await dataForBridgeRequest(request, endpointURL: endpointURL)
        try validateHTTPResponse(response, data: data)

        QuickPreviewDebugLog.log(
            "validate-pro \(data.count) bytes from \(bridgeLogHost(endpointURL: endpointURL, response: response))"
        )
        let snapshot: ProEntitlementSnapshot
        do {
            snapshot = try decodeProEntitlementSnapshot(from: data)
        } catch {
            bridgeLogger.error("validate-pro decode failed: \(String(describing: error), privacy: .public)")
            logBridgeResponseBody(data, context: "validate-pro")
            QuickPreviewDebugLog.log("validate-pro decode error: \(error)")
            throw ProEntitlementBridgeError.invalidResponse
        }
        QuickPreviewDebugLog.log("validate-pro decoded status=\(snapshot.status.rawValue)")

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

    private func dataForBridgeRequest(_ request: URLRequest, endpointURL: URL) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            bridgeLogger.error("Bridge request failed host=\(endpointURL.host ?? "?", privacy: .public) url=\(endpointURL.absoluteString, privacy: .public) error=\(String(describing: error), privacy: .public)")
            print("[QuickPreview] Bridge request FAILED url=\(endpointURL.absoluteString) error=\(error)")
            QuickPreviewDebugLog.log("Bridge request FAILED \(endpointURL.absoluteString) — \(error)")
            throw ProEntitlementBridgeError.bridgeRequestFailed(url: endpointURL, underlying: error)
        }
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
            QuickPreviewDebugLog.log("Bridge HTTP \(httpResponse.statusCode) (failure)")
            logBridgeResponseBody(data, context: "HTTP \(httpResponse.statusCode)")
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
