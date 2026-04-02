import Carbon
import Foundation

struct HotkeyRegistration: Equatable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

enum BackgroundShortcutConfiguration {
    static let sharedDefaultsSuiteName = "group.com.jboive.quickpreview.shared"
    static let helperBundleIdentifier = "com.jboive.quickpreview.launcher"
    static let helperAppName = "QuickPreviewLauncher"
    static let shortcutInvocationURLString = "quickpreview://shortcut"
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

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: sharedDefaultsSuiteName)
    }

    static func selectedShortcut(defaults: UserDefaults? = sharedDefaults()) -> HotkeyRegistration? {
        guard
            let defaults,
            let identifier = defaults.string(forKey: selectedShortcutDefaultsKey)
        else {
            return nil
        }

        return availableShortcuts.first(where: { $0.id == identifier })
    }

    static func storeSelectedShortcut(
        _ shortcut: HotkeyRegistration?,
        defaults: UserDefaults? = sharedDefaults()
    ) {
        guard let defaults else { return }
        if let shortcut {
            defaults.set(shortcut.id, forKey: selectedShortcutDefaultsKey)
        } else {
            defaults.removeObject(forKey: selectedShortcutDefaultsKey)
        }
    }

    static var windowTitleHint: String? {
        guard let shortcut = selectedShortcut() else {
            return nil
        }

        return "Shortcut: \(shortcut.displayName)"
    }
}
