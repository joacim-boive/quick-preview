import Carbon
import Foundation

struct HotkeyRegistration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

enum BackgroundShortcutConfiguration {
    static let helperBundleIdentifier = "com.jboive.quickpreview.launcher"
    static let helperAppName = "QuickPreviewLauncher"
    static let shortcutInvocationURLString = "quickpreview://shortcut"
    static let windowTitleHint = "Shortcut: Ctrl+Space"
    static let startupPromptDefaultsKey = "backgroundShortcutStartupPromptShown"
    static let candidates = [
        HotkeyRegistration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey),
            displayName: "Ctrl+Space"
        ),
        HotkeyRegistration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            displayName: "Option+Space"
        ),
        HotkeyRegistration(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey),
            displayName: "Cmd+Shift+Space"
        )
    ]

    static var fallbackDescription: String {
        candidates.dropFirst().map(\.displayName).joined(separator: " or ")
    }
}
