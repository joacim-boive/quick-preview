import Cocoa
import CryptoKit
import LocalAuthentication

extension Notification.Name {
    static let protectedBookmarksSessionDidChange = Notification.Name("ProtectedBookmarksSessionDidChange")
}

enum ProtectedBookmarksAuthenticationResult: Equatable {
    case success
    case cancelled
    case unavailable
    case failed
}

final class ProtectedBookmarksSessionController {
    private struct ParanoidModeConfiguration: Codable {
        let saltBase64: String
        let passwordHashBase64: String
    }

    private static let paranoidModeConfigurationDefaultsKey = "protectedBookmarksParanoidModeConfiguration"
    private static let passwordHashIterations = 25_000

    private let workspaceNotificationCenter: NotificationCenter
    private let defaults: UserDefaults
    private var workspaceObservers: [NSObjectProtocol] = []
    private var paranoidModeConfiguration: ParanoidModeConfiguration? {
        didSet {
            persistParanoidModeConfiguration()
        }
    }
    private(set) var isAwaitingParanoidPassword = false

    private(set) var isUnlocked = false {
        didSet {
            guard isUnlocked != oldValue else { return }
            postDidChangeNotification()
        }
    }

    var isParanoidModeEnabled: Bool {
        paranoidModeConfiguration != nil
    }

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        defaults: UserDefaults = .standard
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.defaults = defaults
        self.paranoidModeConfiguration = Self.loadParanoidModeConfiguration(from: defaults)
        installWorkspaceObservers()
    }

    deinit {
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver(_:))
    }

    func authenticateWithDeviceOwner(reason: String, completion: @escaping (ProtectedBookmarksAuthenticationResult) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            completion(.unavailable)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success)
                    return
                }

                if let laError = error as? LAError {
                    switch laError.code {
                    case .userCancel, .appCancel, .systemCancel:
                        completion(.cancelled)
                    default:
                        completion(.failed)
                    }
                    return
                }

                completion(.failed)
            }
        }
    }

    func unlock() {
        isAwaitingParanoidPassword = false
        isUnlocked = true
    }

    func lock() {
        isAwaitingParanoidPassword = false
        isUnlocked = false
    }

    func unlockWithParanoidPassword(_ password: String) -> Bool {
        guard verifyParanoidPassword(password) else {
            return false
        }
        isAwaitingParanoidPassword = false
        isUnlocked = true
        return true
    }

    func beginParanoidPasswordStep() {
        guard isParanoidModeEnabled else { return }
        isAwaitingParanoidPassword = true
    }

    func enableParanoidMode(password: String) {
        let salt = Self.makeRandomSalt()
        let hash = Self.derivePasswordHash(for: password, salt: salt)
        paranoidModeConfiguration = ParanoidModeConfiguration(
            saltBase64: salt.base64EncodedString(),
            passwordHashBase64: hash.base64EncodedString()
        )
        postDidChangeNotification()
    }

    @discardableResult
    func disableParanoidMode(password: String) -> Bool {
        guard verifyParanoidPassword(password) else {
            return false
        }
        isAwaitingParanoidPassword = false
        paranoidModeConfiguration = nil
        postDidChangeNotification()
        return true
    }

    func verifyParanoidPassword(_ password: String) -> Bool {
        guard
            let paranoidModeConfiguration,
            let salt = Data(base64Encoded: paranoidModeConfiguration.saltBase64),
            let expectedHash = Data(base64Encoded: paranoidModeConfiguration.passwordHashBase64)
        else {
            return false
        }

        let derivedHash = Self.derivePasswordHash(for: password, salt: salt)
        return derivedHash == expectedHash
    }

    private func installWorkspaceObservers() {
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]

        workspaceObservers = names.map { name in
            workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.lock()
            }
        }
    }

    private func persistParanoidModeConfiguration() {
        if let paranoidModeConfiguration,
           let data = try? JSONEncoder().encode(paranoidModeConfiguration) {
            defaults.set(data, forKey: Self.paranoidModeConfigurationDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.paranoidModeConfigurationDefaultsKey)
        }
    }

    private func postDidChangeNotification() {
        NotificationCenter.default.post(name: .protectedBookmarksSessionDidChange, object: self)
    }

    private static func loadParanoidModeConfiguration(from defaults: UserDefaults) -> ParanoidModeConfiguration? {
        guard
            let data = defaults.data(forKey: paranoidModeConfigurationDefaultsKey),
            let configuration = try? JSONDecoder().decode(ParanoidModeConfiguration.self, from: data)
        else {
            return nil
        }
        return configuration
    }

    private static func makeRandomSalt() -> Data {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    private static func derivePasswordHash(for password: String, salt: Data) -> Data {
        var derived = Data(password.utf8)
        derived.append(salt)
        derived = Data(SHA256.hash(data: derived))

        for _ in 1..<passwordHashIterations {
            var next = derived
            next.append(salt)
            derived = Data(SHA256.hash(data: next))
        }

        return derived
    }
}
