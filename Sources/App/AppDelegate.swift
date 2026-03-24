import Cocoa
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let hotkeyManager = GlobalHotkeyManager()
    private let bookmarkStore = BookmarkStore()
    private let thumbnailService = VideoThumbnailService()
    private let protectedBookmarksSessionController = ProtectedBookmarksSessionController()
    private var windowController: MainPlayerWindowController?
    private var helpWindowController: HelpWindowController?
    private var bookmarksWindowController: BookmarksWindowController?
    private var finderSelectionMonitorTimer: DispatchSourceTimer?
    private let finderSelectionMonitorQueue = DispatchQueue(
        label: "quickpreview.finder-selection-monitor",
        qos: .utility
    )
    private var isSelectionCheckInProgress = false
    private var lastObservedFinderSelectedVideoURL: URL?
    private var ignoredFinderSelectedVideoURL: URL?
    private let loopMenuItemTag = 4101
    private let rotationMenuItemBaseTag = 4200
    private let protectedMediaMenuItemTag = 4300
    private let allowedRotationDegrees = [0, 90, 180, 270]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
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
        windowController?.flushPersistedStateWrites()
        bookmarkStore.flushPendingWrites()
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

    @objc
    private func handleOpenFromMenu(_ sender: Any?) {
        ensureWindowController().presentOpenVideoPanel()
        _ = sender
    }

    @objc
    private func handleOpenFinderSelectionFromMenu(_ sender: Any?) {
        let controller = ensureWindowController()
        _ = controller.openFinderSelectionIfVideo(showErrors: true)
        _ = sender
    }

    @objc
    private func handleLoopFromMenu(_ sender: Any?) {
        let controller = ensureWindowController()
        controller.setLoopEnabled(!controller.loopEnabled())
        _ = sender
    }

    @objc
    private func handleSetRotationFromMenu(_ sender: NSMenuItem) {
        let rotationDegrees = sender.tag - rotationMenuItemBaseTag
        ensureWindowController().setRotationDegrees(rotationDegrees)
    }

    @objc
    private func handleShowBookmarks(_ sender: Any?) {
        showBookmarksWindow(selecting: nil)
        _ = sender
    }

    @objc
    private func handleProtectedMediaSession(_ sender: Any?) {
        _ = sender
        if protectedBookmarksSessionController.isUnlocked {
            protectedBookmarksSessionController.lock()
            return
        }

        let controller = ensureBookmarksWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        protectedBookmarksSessionController.authenticate(
            reason: "Unlock protected bookmarks in QuickPreview."
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.showBookmarksWindow(selecting: nil)
            case .cancelled:
                break
            case .unavailable:
                self.showInfoAlert(
                    title: "Authentication Unavailable",
                    message: "QuickPreview could not use macOS authentication to unlock protected bookmarks."
                )
            case .failed:
                self.showInfoAlert(
                    title: "Authentication Failed",
                    message: "QuickPreview could not unlock protected bookmarks."
                )
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controller = ensureWindowController()
        switch menuItem.tag {
        case loopMenuItemTag:
            menuItem.state = controller.loopEnabled() ? .on : .off
            return controller.hasLoadedVideo()
        case protectedMediaMenuItemTag:
            let isUnlocked = protectedBookmarksSessionController.isUnlocked
            menuItem.title = isUnlocked ? "Lock Protected Media" : "Unlock Protected Media..."
            return true
        default:
            let rotationTagRangeUpperBound = rotationMenuItemBaseTag + 360
            if (rotationMenuItemBaseTag...rotationTagRangeUpperBound).contains(menuItem.tag) {
                let rotationDegrees = menuItem.tag - rotationMenuItemBaseTag
                menuItem.state = rotationDegrees == controller.rotationDegrees() ? .on : .off
                return controller.hasLoadedVideo()
            }
            return true
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
        let controller = MainPlayerWindowController(bookmarkStore: bookmarkStore)
        controller.onShowBookmarksRequested = { [weak self] bookmark in
            self?.showBookmarksWindow(selecting: bookmark)
        }
        controller.onCurrentVideoURLChange = { [weak self] videoURL in
            self?.bookmarksWindowController?.setCurrentVideoURL(videoURL)
        }
        windowController = controller
        return controller
    }

    private func ensureHelpWindowController() -> HelpWindowController {
        if let helpWindowController {
            return helpWindowController
        }
        let controller = HelpWindowController()
        helpWindowController = controller
        return controller
    }

    private func ensureBookmarksWindowController() -> BookmarksWindowController {
        if let bookmarksWindowController {
            return bookmarksWindowController
        }
        let controller = BookmarksWindowController(
            bookmarkStore: bookmarkStore,
            thumbnailService: thumbnailService,
            protectedBookmarksSessionController: protectedBookmarksSessionController
        )
        controller.onOpenBookmark = { [weak self] bookmark in
            self?.ignoreCurrentFinderSelection()
            self?.ensureWindowController().openBookmark(bookmark)
        }
        controller.onWindowClosed = { [weak self] in
            self?.protectedBookmarksSessionController.lock()
        }
        controller.setCurrentVideoURL(windowController?.loadedVideoURL())
        bookmarksWindowController = controller
        return controller
    }

    @objc
    private func handleShowGuide(_ sender: Any?) {
        let controller = ensureHelpWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = sender
    }

    private func showBookmarksWindow(selecting bookmark: Bookmark?) {
        let controller = ensureBookmarksWindowController()
        controller.setCurrentVideoURL(ensureWindowController().loadedVideoURL())
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let bookmark {
            controller.revealBookmark(bookmark)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(
            title: "Open...",
            action: #selector(handleOpenFromMenu(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

        let openFinderSelectionItem = NSMenuItem(
            title: "Open Finder Selection...",
            action: #selector(handleOpenFinderSelectionFromMenu(_:)),
            keyEquivalent: "o"
        )
        openFinderSelectionItem.target = self
        openFinderSelectionItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFinderSelectionItem)
        fileMenuItem.submenu = fileMenu

        let playbackMenuItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        mainMenu.addItem(playbackMenuItem)

        let playbackMenu = NSMenu(title: "Playback")
        let loopItem = NSMenuItem(
            title: "Loop",
            action: #selector(handleLoopFromMenu(_:)),
            keyEquivalent: "l"
        )
        loopItem.target = self
        loopItem.tag = loopMenuItemTag
        loopItem.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(loopItem)

        let rotationMenuItem = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
        let rotationMenu = NSMenu(title: "Rotation")
        for degrees in allowedRotationDegrees {
            let item = NSMenuItem(
                title: "\(degrees)°",
                action: #selector(handleSetRotationFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = rotationMenuItemBaseTag + degrees
            rotationMenu.addItem(item)
        }
        rotationMenuItem.submenu = rotationMenu
        playbackMenu.addItem(rotationMenuItem)

        let bookmarksItem = NSMenuItem(
            title: "Bookmarks",
            action: #selector(handleShowBookmarks(_:)),
            keyEquivalent: "b"
        )
        bookmarksItem.target = self
        bookmarksItem.keyEquivalentModifierMask = [.command]
        playbackMenu.addItem(bookmarksItem)

        let protectedMediaItem = NSMenuItem(
            title: "Unlock Protected Media...",
            action: #selector(handleProtectedMediaSession(_:)),
            keyEquivalent: ""
        )
        protectedMediaItem.target = self
        protectedMediaItem.tag = protectedMediaMenuItemTag
        playbackMenu.addItem(protectedMediaItem)
        playbackMenuItem.submenu = playbackMenu

        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)

        let helpMenu = NSMenu(title: "Help")
        let guideItem = NSMenuItem(
            title: "QuickPreview Guide",
            action: #selector(handleShowGuide(_:)),
            keyEquivalent: "/"
        )
        guideItem.target = self
        guideItem.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.addItem(guideItem)
        helpMenuItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func startFinderSelectionMonitor() {
        finderSelectionMonitorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: finderSelectionMonitorQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.followFinderSelectionIfNeeded()
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

        let loadedVideoURL: URL? = DispatchQueue.main.sync { [weak self] in
            guard
                let self,
                let controller = self.windowController,
                controller.hasLoadedVideo()
            else {
                return nil
            }
            return controller.loadedVideoURL()
        }

        guard let loadedVideoURL else {
            return
        }

        let selectedVideoURL = FinderSelectionProbe.selectedFinderVideoURL()
        let selectionChanged = selectedVideoURL != lastObservedFinderSelectedVideoURL
        lastObservedFinderSelectedVideoURL = selectedVideoURL

        guard let selectedVideoURL else {
            ignoredFinderSelectedVideoURL = nil
            return
        }

        if ignoredFinderSelectedVideoURL == selectedVideoURL {
            return
        }
        ignoredFinderSelectedVideoURL = nil

        guard selectionChanged else {
            return
        }
        guard selectedVideoURL != loadedVideoURL else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let controller = self.windowController,
                controller.hasLoadedVideo(),
                selectedVideoURL != controller.loadedVideoURL()
            else {
                return
            }
            controller.openVideo(url: selectedVideoURL)
        }
    }

    private func ignoreCurrentFinderSelection() {
        ignoredFinderSelectedVideoURL = FinderSelectionProbe.selectedFinderVideoURL()
        lastObservedFinderSelectedVideoURL = ignoredFinderSelectedVideoURL
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

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum FinderSelectionProbe {
    static func selectedFinderVideoURL() -> URL? {
        guard let selectedURL = selectedFinderFileURL() else {
            return nil
        }
        guard isVideoURL(selectedURL) else {
            return nil
        }
        return selectedURL.standardizedFileURL
    }

    private static func selectedFinderFileURL() -> URL? {
        let lines: [String] = [
            "tell application \"Finder\"",
            "    set selectedItems to {}",
            "",
            "    try",
            "        set selectedItems to selection",
            "    end try",
            "",
            "    if (count selectedItems) is 0 then",
            "        try",
            "            if (count of Finder windows) > 0 then",
            "                set selectedItems to (selection of front Finder window)",
            "            end if",
            "        end try",
            "    end if",
            "",
            "    if (count selectedItems) is 0 then",
            "        try",
            "            set selectedItems to (every item of desktop whose selected is true)",
            "        end try",
            "    end if",
            "",
            "    if (count selectedItems) is 0 then",
            "        return \"\"",
            "    end if",
            "",
            "    set firstItem to item 1 of selectedItems",
            "    return POSIX path of (firstItem as alias)",
            "end tell"
        ]
        let script = lines.joined(separator: "\n")
        guard let output = runAppleScriptUsingProcess(script), !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output)
    }

    private static func runAppleScriptUsingProcess(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        var arguments: [String] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            arguments.append("-e")
            arguments.append(String(line))
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isVideoURL(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            if values.isDirectory == true {
                return false
            }
            if let contentType = values.contentType {
                return contentType.conforms(to: .movie)
            }
            return false
        } catch {
            return false
        }
    }
}
