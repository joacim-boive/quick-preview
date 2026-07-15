import AppKit

@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyManager = GlobalHotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let didRegister = hotkeyManager.registerSelectedHotkey { [weak self] in
            self?.launchQuickPreview()
        }
        if !didRegister {
            NSApp.terminate(nil)
        }
    }

    private func launchQuickPreview() {
        guard let url = URL(string: BackgroundShortcutConfiguration.shortcutInvocationURLString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
