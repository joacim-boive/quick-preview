import AppKit

@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyManager = GlobalHotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = hotkeyManager.registerSpaceHotkey { [weak self] in
            self?.launchQuickPreview()
        }
    }

    private func launchQuickPreview() {
        guard let url = URL(string: BackgroundShortcutConfiguration.shortcutInvocationURLString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
