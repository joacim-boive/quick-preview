import AppKit
import ServiceManagement

enum BackgroundShortcutServiceError: LocalizedError {
    case helperAppMissing
    case helperTerminationTimedOut

    var errorDescription: String? {
        switch self {
        case .helperAppMissing:
            return "QuickPreview could not find its background helper inside the app bundle."
        case .helperTerminationTimedOut:
            return "QuickPreview could not stop its background helper before reloading it."
        }
    }
}

@MainActor
final class BackgroundShortcutService {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var status: SMAppService.Status {
        service.status
    }

    var hasShownStartupPrompt: Bool {
        defaults.bool(forKey: BackgroundShortcutConfiguration.startupPromptDefaultsKey)
    }

    func markStartupPromptShown() {
        defaults.set(true, forKey: BackgroundShortcutConfiguration.startupPromptDefaultsKey)
    }

    func resetStartupPrompt() {
        defaults.removeObject(forKey: BackgroundShortcutConfiguration.startupPromptDefaultsKey)
    }

    func enable() throws -> SMAppService.Status {
        try service.register()
        return service.status
    }

    func disable() throws {
        try service.unregister()
        try terminateRunningHelper()
        resetStartupPrompt()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func launchHelperIfNeeded() throws {
        guard status == .enabled else { return }
        guard BackgroundShortcutConfiguration.selectedShortcut() != nil else {
            try terminateRunningHelper()
            return
        }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: BackgroundShortcutConfiguration.helperBundleIdentifier
        ).isEmpty else {
            return
        }

        let helperURL = try helperApplicationURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.hides = true

        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, _ in }
    }

    func reloadHelperIfNeeded() throws {
        guard status == .enabled else { return }
        try terminateRunningHelper()
        try launchHelperIfNeeded()
    }

    private func terminateRunningHelper() throws {
        let timeout: TimeInterval = 2.0
        let forceTerminateDelay: TimeInterval = 0.5
        let pollInterval: TimeInterval = 0.05
        let deadline = Date().addingTimeInterval(timeout)
        let forceTerminateAfter = Date().addingTimeInterval(forceTerminateDelay)

        var runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: BackgroundShortcutConfiguration.helperBundleIdentifier
        )

        guard !runningApplications.isEmpty else { return }

        runningApplications.forEach { runningApplication in
            _ = runningApplication.terminate()
        }

        var didForceTerminate = false
        while Date() < deadline {
            runningApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: BackgroundShortcutConfiguration.helperBundleIdentifier
            )
            if runningApplications.isEmpty {
                return
            }

            if !didForceTerminate, Date() >= forceTerminateAfter {
                didForceTerminate = true
                runningApplications.forEach { runningApplication in
                    _ = runningApplication.forceTerminate()
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }

        throw BackgroundShortcutServiceError.helperTerminationTimedOut
    }

    private var service: SMAppService {
        SMAppService.loginItem(identifier: BackgroundShortcutConfiguration.helperBundleIdentifier)
    }

    private func helperApplicationURL() throws -> URL {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("\(BackgroundShortcutConfiguration.helperAppName).app", isDirectory: true)

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw BackgroundShortcutServiceError.helperAppMissing
        }

        return helperURL
    }
}
