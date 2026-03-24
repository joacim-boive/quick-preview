import Cocoa
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
    private let workspaceNotificationCenter: NotificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []

    private(set) var isUnlocked = false {
        didSet {
            guard isUnlocked != oldValue else { return }
            NotificationCenter.default.post(name: .protectedBookmarksSessionDidChange, object: self)
        }
    }

    init(workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        installWorkspaceObservers()
    }

    deinit {
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver(_:))
    }

    func authenticate(reason: String, completion: @escaping (ProtectedBookmarksAuthenticationResult) -> Void) {
        guard !isUnlocked else {
            completion(.success)
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            completion(.unavailable)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.isUnlocked = true
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

    func lock() {
        isUnlocked = false
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
}
