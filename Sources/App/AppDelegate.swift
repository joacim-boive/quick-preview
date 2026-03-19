import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyManager = GlobalHotkeyManager()
    private var windowController: MainPlayerWindowController?
    private var finderSelectionMonitorTimer: DispatchSourceTimer?
    private var isSelectionCheckInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = ensureWindowController()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                let controller = self.ensureWindowController()
                controller.showWindow(nil)
                controller.window?.center()
                controller.window?.makeKeyAndOrderFront(nil)
                controller.window?.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Ctrl+Space can quickly reopen/focus the player window.
        let hotkeyRegistered = hotkeyManager.registerSpaceHotkey { [weak self] in
            guard let self else { return }
            let controller = self.ensureWindowController()
            let openedFinderVideo = controller.openFinderSelectionIfVideo(showErrors: true)
            if !openedFinderVideo {
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            }
            controller.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }

        let shortcutName = hotkeyManager.activeShortcutName
        ensureWindowController().setShortcutHint("Shortcut: \(shortcutName)")

        if !hotkeyRegistered {
            showStartupAlert(
                title: "Global Shortcut Not Registered",
                message: "No global shortcut could be registered. Open videos using the app window for now."
            )
        }

        startFinderSelectionMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        finderSelectionMonitorTimer?.cancel()
        finderSelectionMonitorTimer = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let controller = ensureWindowController()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        if first.scheme == "quickpreview" {
            openFromSchemeURL(first)
            return
        }
        if first.isFileURL {
            ensureWindowController().openVideo(url: first)
        }
    }

    private func openFromSchemeURL(_ url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host,
            host == "open"
        else {
            return
        }
        let filePath = components.queryItems?.first(where: { $0.name == "file" })?.value
        guard let filePath else { return }
        ensureWindowController().openVideo(url: URL(fileURLWithPath: filePath))
    }

    private func ensureWindowController() -> MainPlayerWindowController {
        if let windowController {
            return windowController
        }
        let controller = MainPlayerWindowController()
        windowController = controller
        return controller
    }

    private func startFinderSelectionMonitor() {
        finderSelectionMonitorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.followFinderSelectionIfNeeded()
            }
        }
        finderSelectionMonitorTimer = timer
        timer.resume()
    }

    private func followFinderSelectionIfNeeded() {
        if isSelectionCheckInProgress {
            return
        }
        isSelectionCheckInProgress = true
        defer { isSelectionCheckInProgress = false }

        guard let controller = windowController else {
            return
        }
        guard controller.hasLoadedVideo() else {
            return
        }

        let passiveState = controller.finderSelectionState(activateFinder: false)
        let state: MainPlayerWindowController.FinderSelectionState
        switch passiveState {
        case .none:
            state = controller.finderSelectionState(activateFinder: true)
        default:
            state = passiveState
        }

        switch state {
        case .none:
            return
        case .nonVideo:
            return
        case let .video(selectedVideoURL):
            guard selectedVideoURL != controller.loadedVideoURL() else {
                return
            }
            controller.openVideo(url: selectedVideoURL)
            return
        }
    }

    private func showStartupAlert(title: String, message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
