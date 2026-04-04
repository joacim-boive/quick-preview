import Carbon
import Foundation

struct HotkeyRegistration: Equatable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

enum BackgroundShortcutConfiguration {
    private struct PersistedShortcutSelection: Codable {
        let shortcutID: String
    }

    static let sharedDefaultsSuiteName = AppEdition.current.sharedContainerIdentifier
    static let helperBundleIdentifier = AppEdition.current.helperBundleIdentifier
    static let helperAppName = AppEdition.current.helperAppName
    static let shortcutInvocationURLString = "\(AppEdition.current.urlScheme)://shortcut"
    static let startupPromptDefaultsKey = "backgroundShortcutStartupPromptShown"
    static let selectedShortcutDefaultsKey = "backgroundShortcutSelection"
    static let availableShortcuts = [
        HotkeyRegistration(
            id: "option-space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            displayName: "Option+Space"
        ),
        HotkeyRegistration(
            id: "cmd-shift-space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey),
            displayName: "Cmd+Shift+Space"
        ),
        HotkeyRegistration(
            id: "cmd-option-space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey),
            displayName: "Cmd+Option+Space"
        ),
        HotkeyRegistration(
            id: "control-option-space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            displayName: "Ctrl+Option+Space"
        ),
        HotkeyRegistration(
            id: "control-option-p",
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey),
            displayName: "Ctrl+Option+P"
        ),
        HotkeyRegistration(
            id: "ctrl-space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey),
            displayName: "Ctrl+Space"
        )
    ]

    private static let sharedShortcutFileName = "BackgroundShortcutSelection.json"

    static func sharedDefaults() -> UserDefaults? {
        nil
    }

    static func selectedShortcut(defaults: UserDefaults? = sharedDefaults()) -> HotkeyRegistration? {
        _ = defaults

        guard let identifier = loadPersistedShortcutIdentifier() else {
            return nil
        }

        return availableShortcuts.first(where: { $0.id == identifier })
    }

    static func storeSelectedShortcut(
        _ shortcut: HotkeyRegistration?,
        defaults: UserDefaults? = sharedDefaults()
    ) {
        _ = defaults

        if let shortcut {
            persistShortcutIdentifier(shortcut.id)
        } else {
            clearPersistedShortcutIdentifier()
        }
    }

    static var windowTitleHint: String? {
        guard let shortcut = selectedShortcut() else {
            return nil
        }

        return "Shortcut: \(shortcut.displayName)"
    }

    private static func loadPersistedShortcutIdentifier() -> String? {
        guard
            let storageURL = sharedShortcutStorageURL(),
            let data = try? Data(contentsOf: storageURL),
            let persistedSelection = try? JSONDecoder().decode(PersistedShortcutSelection.self, from: data)
        else {
            return nil
        }

        return persistedSelection.shortcutID
    }

    private static func persistShortcutIdentifier(_ identifier: String) {
        guard let storageURL = sharedShortcutStorageURL() else { return }

        let persistedSelection = PersistedShortcutSelection(shortcutID: identifier)
        guard let data = try? JSONEncoder().encode(persistedSelection) else { return }

        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }

    private static func clearPersistedShortcutIdentifier() {
        guard let storageURL = sharedShortcutStorageURL() else { return }
        try? FileManager.default.removeItem(at: storageURL)
    }

    private static func sharedShortcutStorageURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: sharedDefaultsSuiteName
        ) else {
            return nil
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(sharedShortcutFileName, isDirectory: false)
    }
}
