import AppKit
import ServiceManagement

enum BackgroundShortcutServiceError: LocalizedError {
    case helperAppMissing

    var errorDescription: String? {
        switch self {
        case .helperAppMissing:
            return "QuickPreview could not find its background helper inside the app bundle."
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
        terminateRunningHelper()
        resetStartupPrompt()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func launchHelperIfNeeded() throws {
        guard status == .enabled else { return }
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

    private func terminateRunningHelper() {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: BackgroundShortcutConfiguration.helperBundleIdentifier
        ).forEach { runningApplication in
            runningApplication.terminate()
        }
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
