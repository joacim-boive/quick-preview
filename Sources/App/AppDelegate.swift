import Cocoa
import ApplicationServices
import ServiceManagement
import StoreKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let backgroundShortcutService = BackgroundShortcutService()
    private let bookmarkStore = BookmarkStore()
    private let thumbnailService = VideoThumbnailService()
    private let protectedBookmarksSessionController = ProtectedBookmarksSessionController()
    private let subscriptionController = SubscriptionController()
    private var windowController: MainPlayerWindowController?
    private var helpWindowController: HelpWindowController?
    private var bookmarksWindowController: BookmarksWindowController?
    private var paywallWindowController: PaywallWindowController?
    private var finderSelectionMonitorTimer: DispatchSourceTimer?
    private var accessRefreshTask: Task<Void, Never>?
    private var suppressSubscriptionLoadingWindow = false
    private var latestSuppressingRefreshID = 0
    private var pendingPostEntitlementAction: (() -> Void)?
    private var shortcutHintText: String?
    private var didCenterMainWindowOnFirstPresentation = false
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var protectedBookmarksSessionObserver: NSObjectProtocol?
    private let finderSelectionMonitorQueue = DispatchQueue(
        label: "quickpreview.finder-selection-monitor",
        qos: .utility
    )
    private var isSelectionCheckInProgress = false
    private var lastObservedFinderSelectedVideoURL: URL?
    private var ignoredFinderSelectedVideoURL: URL?
    private let loopMenuItemTag = 4101
    private let autoplayMenuItemTag = 4102
    private let rotationMenuItemBaseTag = 4200
    private let protectedMediaMenuItemTag = 4300
    private let paranoidModeMenuItemTag = 4301
    private let backgroundShortcutMenuItemTag = 4302
    private let allowedRotationDegrees = [0, 90, 180, 270]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        configureSubscriptionController()
        configureProtectedBookmarksSessionObserver()
        subscriptionController.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.recoverVisibleWindowIfNeeded()
        }

        shortcutHintText = BackgroundShortcutConfiguration.windowTitleHint
        startFinderSelectionMonitor()
        requestSubscriptionAccess(showLoadingWindow: true) { [weak self] in
            self?.restoreLastOpenedVideoIfPossible()
            self?.revealPlayerWindow(centerIfNeeded: true)
            self?.restoreBookmarksWindowIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.syncBackgroundShortcutServiceAfterLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessRefreshTask?.cancel()
        bookmarksWindowController?.prepareForApplicationTermination()
        windowController?.closeCurrentVideoIfNeeded()
        windowController?.flushPersistedStateWrites()
        bookmarkStore.flushPendingWrites()
        finderSelectionMonitorTimer?.cancel()
        finderSelectionMonitorTimer = nil
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }
        NotificationCenter.default.removeObserver(
            self,
            name: .protectedBookmarksSessionDidChange,
            object: protectedBookmarksSessionController
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let paywallWindowController, paywallWindowController.window?.isVisible == true {
                paywallWindowController.showWindow(nil)
                paywallWindowController.window?.makeKeyAndOrderFront(nil)
            } else {
                requestSubscriptionAccess(showLoadingWindow: false) { [weak self] in
                    self?.revealPlayerWindow(centerIfNeeded: false)
                }
            }
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
            requestSubscriptionAccess(showLoadingWindow: true) { [weak self] in
                self?.ensureWindowController().openVideo(url: first)
            }
        }
    }

    @objc
    private func handleOpenFromMenu(_ sender: Any?) {
        requestSubscriptionAccess(showLoadingWindow: false) { [weak self] in
            self?.ensureWindowController().presentOpenVideoPanel()
        }
        _ = sender
    }

    @objc
    private func handleOpenFinderSelectionFromMenu(_ sender: Any?) {
        requestSubscriptionAccess(showLoadingWindow: false) { [weak self] in
            guard let self else { return }
            let controller = self.ensureWindowController()
            _ = controller.openFinderSelectionIfVideo(showErrors: true)
        }
        _ = sender
    }

    @objc
    private func handleLoopFromMenu(_ sender: Any?) {
        let controller = ensureWindowController()
        controller.setLoopEnabled(!controller.loopEnabled())
        _ = sender
    }

    @objc
    private func handleAutoplayFromMenu(_ sender: Any?) {
        let controller = ensureWindowController()
        controller.setAutoplayEnabled(!controller.autoplayEnabled(), showFeedback: true)
        _ = sender
    }

    @objc
    private func handleSetRotationFromMenu(_ sender: NSMenuItem) {
        let rotationDegrees = sender.tag - rotationMenuItemBaseTag
        ensureWindowController().setRotationDegrees(rotationDegrees)
    }

    @objc
    private func handleShowBookmarks(_ sender: Any?) {
        requestSubscriptionAccess(showLoadingWindow: false) { [weak self] in
            self?.showBookmarksWindow(selecting: nil)
        }
        _ = sender
    }

    @objc
    private func handleProtectedMediaSession(_ sender: Any?) {
        _ = sender
        if protectedBookmarksSessionController.isUnlocked {
            protectedBookmarksSessionController.lock()
            return
        }

        unlockProtectedMediaSession()
    }

    @objc
    private func handleParanoidMode(_ sender: Any?) {
        _ = sender

        guard protectedBookmarksSessionController.isUnlocked else {
            showInfoAlert(
                title: "Protected Media Locked",
                message: "Unlock protected media first to change paranoid mode."
            )
            return
        }

        if protectedBookmarksSessionController.isParanoidModeEnabled {
            disableParanoidMode()
        } else {
            enableParanoidMode()
        }
    }

    private func unlockProtectedMediaSession() {
        let controller = ensureBookmarksWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if protectedBookmarksSessionController.isParanoidModeEnabled,
           protectedBookmarksSessionController.isAwaitingParanoidPassword {
            guard let password = promptForParanoidPassword(
                title: "Enter Paranoid Mode Password",
                message: "Enter your paranoid mode password to reveal protected bookmarks.",
                actionTitle: "Unlock"
            ) else {
                return
            }

            guard protectedBookmarksSessionController.unlockWithParanoidPassword(password) else {
                return
            }

            showBookmarksWindow(selecting: nil)
            return
        }

        protectedBookmarksSessionController.authenticateWithDeviceOwner(
            reason: "Unlock protected bookmarks in QuickPreview."
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.protectedBookmarksSessionController.isParanoidModeEnabled {
                    self.protectedBookmarksSessionController.beginParanoidPasswordStep()
                } else {
                    self.protectedBookmarksSessionController.unlock()
                    self.showBookmarksWindow(selecting: nil)
                }
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

    private func enableParanoidMode() {
        guard let password = promptForNewParanoidModePassword() else {
            return
        }

        protectedBookmarksSessionController.enableParanoidMode(password: password)
        showInfoAlert(
            title: "Paranoid Mode Enabled",
            message: "Protected media now requires macOS authentication and your paranoid mode password to unlock. If you forget this password, it cannot be recovered."
        )
    }

    private func disableParanoidMode() {
        guard let password = promptForParanoidPassword(
            title: "Disable Paranoid Mode",
            message: "Enter the paranoid mode password to disable this setting.",
            actionTitle: "Disable"
        ) else {
            return
        }

        guard protectedBookmarksSessionController.disableParanoidMode(password: password) else {
            showInfoAlert(
                title: "Incorrect Password",
                message: "The paranoid mode password you entered was incorrect."
            )
            return
        }

        showInfoAlert(
            title: "Paranoid Mode Disabled",
            message: "Protected media will now unlock with macOS authentication only."
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isEntitled = subscriptionController.accessState.isEntitled
        let controller = windowController
        switch menuItem.tag {
        case loopMenuItemTag:
            menuItem.state = controller?.loopEnabled() == true ? .on : .off
            return isEntitled && controller?.hasLoadedVideo() == true
        case autoplayMenuItemTag:
            let autoplayEnabled = controller?.autoplayEnabled() ?? MainPlayerWindowController.storedAutoplayPreference()
            menuItem.state = autoplayEnabled ? .on : .off
            return isEntitled
        case protectedMediaMenuItemTag:
            let isUnlocked = protectedBookmarksSessionController.isUnlocked
            menuItem.title = isUnlocked ? "Lock Protected Media" : "Unlock Protected Media..."
            return isEntitled
        case paranoidModeMenuItemTag:
            menuItem.title = protectedBookmarksSessionController.isParanoidModeEnabled
                ? "Disable Paranoid Mode..."
                : "Enable Paranoid Mode..."
            return isEntitled && protectedBookmarksSessionController.isUnlocked
        case backgroundShortcutMenuItemTag:
            if let selectedShortcut = BackgroundShortcutConfiguration.selectedShortcut() {
                switch backgroundShortcutService.status {
                case .enabled:
                    menuItem.title = "Background Shortcut (\(selectedShortcut.displayName))..."
                case .requiresApproval:
                    menuItem.title = "Finish Enabling Background Shortcut..."
                case .notRegistered, .notFound:
                    menuItem.title = "Set Background Shortcut..."
                @unknown default:
                    menuItem.title = "Background Shortcut..."
                }
            } else {
                menuItem.title = "Set Background Shortcut..."
            }
            return true
        default:
            let rotationTagRangeUpperBound = rotationMenuItemBaseTag + 360
            if (rotationMenuItemBaseTag...rotationTagRangeUpperBound).contains(menuItem.tag) {
                let rotationDegrees = menuItem.tag - rotationMenuItemBaseTag
                menuItem.state = rotationDegrees == controller?.rotationDegrees() ? .on : .off
                return isEntitled && controller?.hasLoadedVideo() == true
            }
            return true
        }
    }

    private func openFromSchemeURL(_ url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host
        else {
            return
        }

        switch host {
        case "open":
            let filePath = components.queryItems?.first(where: { $0.name == "file" })?.value
            guard let filePath else { return }
            requestSubscriptionAccess(showLoadingWindow: true) { [weak self] in
                self?.ensureWindowController().openVideo(url: URL(fileURLWithPath: filePath))
            }
        case "shortcut":
            performGlobalShortcutAction()
        default:
            return
        }
    }

    private func ensureWindowController() -> MainPlayerWindowController {
        if let windowController {
            return windowController
        }
        let controller = MainPlayerWindowController(
            bookmarkStore: bookmarkStore,
            thumbnailService: thumbnailService
        )
        if let shortcutHintText {
            controller.setShortcutHint(shortcutHintText)
        }
        controller.onShowBookmarksRequested = { [weak self] bookmark, highlightSelection in
            self?.showBookmarksWindow(selecting: bookmark, highlightSelection: highlightSelection)
        }
        controller.onCurrentVideoURLChange = { [weak self] videoURL in
            self?.bookmarksWindowController?.setCurrentVideoURL(videoURL)
        }
        controller.onBookmarkNavigationRequested = { [weak self] delta in
            self?.bookmarksWindowController?.navigateSelection(delta: delta)
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
        controller.onEscapeKey = { [weak self] in
            self?.windowController?.closeCurrentVideoIfNeeded()
        }
        controller.onPlayPauseRequested = { [weak self] in
            self?.windowController?.togglePlayPauseIfPossible()
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

    @objc
    private func handleBackgroundShortcutMenuItem(_ sender: Any?) {
        _ = sender
        presentBackgroundShortcutConfiguration()
    }

    private func showBookmarksWindow(selecting bookmark: Bookmark?, highlightSelection: Bool = false) {
        let controller = ensureBookmarksWindowController()
        controller.setCurrentVideoURL(windowController?.loadedVideoURL())
        controller.showAndTrackWindow()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let bookmark {
            controller.revealBookmark(bookmark, highlight: highlightSelection)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let backgroundShortcutItem = NSMenuItem(
            title: "Enable Background Shortcut...",
            action: #selector(handleBackgroundShortcutMenuItem(_:)),
            keyEquivalent: ""
        )
        backgroundShortcutItem.target = self
        backgroundShortcutItem.tag = backgroundShortcutMenuItemTag
        appMenu.addItem(backgroundShortcutItem)
        appMenu.addItem(.separator())
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

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu

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

        let autoplayItem = NSMenuItem(
            title: "Autoplay",
            action: #selector(handleAutoplayFromMenu(_:)),
            keyEquivalent: "p"
        )
        autoplayItem.target = self
        autoplayItem.tag = autoplayMenuItemTag
        autoplayItem.keyEquivalentModifierMask = [.command, .shift]
        playbackMenu.addItem(autoplayItem)

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

        let paranoidModeItem = NSMenuItem(
            title: "Enable Paranoid Mode...",
            action: #selector(handleParanoidMode(_:)),
            keyEquivalent: ""
        )
        paranoidModeItem.target = self
        paranoidModeItem.tag = paranoidModeMenuItemTag
        playbackMenu.addItem(paranoidModeItem)
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

    private func syncBackgroundShortcutServiceAfterLaunch() {
        do {
            try backgroundShortcutService.launchHelperIfNeeded()
        } catch {
            showStartupAlert(
                title: "Background Helper Missing",
                message: error.localizedDescription
            )
        }

        guard BackgroundShortcutConfiguration.selectedShortcut() != nil else {
            return
        }

        guard !backgroundShortcutService.hasShownStartupPrompt else {
            return
        }

        switch backgroundShortcutService.status {
        case .enabled, .notRegistered, .notFound:
            return
        case .requiresApproval:
            backgroundShortcutService.markStartupPromptShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                switch self.backgroundShortcutService.status {
                case .requiresApproval:
                    self.presentBackgroundShortcutApprovalPrompt(isStartupPrompt: true)
                default:
                    break
                }
            }
        @unknown default:
            return
        }
    }

    private func performGlobalShortcutAction() {
        requestSubscriptionAccess(showLoadingWindow: false) { [weak self] in
            guard let self else { return }
            let controller = self.ensureWindowController()
            let openedFinderVideo = controller.openFinderSelectionIfVideo(showErrors: true)
            if !openedFinderVideo {
                self.revealPlayerWindow(centerIfNeeded: false)
            }
        }
    }

    private func presentBackgroundShortcutConfiguration() {
        let currentShortcut = BackgroundShortcutConfiguration.selectedShortcut()
        let alert = NSAlert()
        alert.messageText = "Background Shortcut"
        alert.informativeText = """
        QuickPreview will not reserve any global shortcut until you choose one here.

        Pick a shortcut that does not conflict with your editor or macOS, and QuickPreview will use it to reopen from the background after the main app is closed.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        if currentShortcut != nil || backgroundShortcutService.status == .enabled || backgroundShortcutService.status == .requiresApproval {
            alert.addButton(withTitle: "Turn Off")
        }
        alert.addButton(withTitle: "Cancel")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        let label = NSTextField(labelWithString: "Shortcut")
        label.frame = NSRect(x: 0, y: 30, width: 320, height: 16)

        let popupButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        popupButton.addItem(withTitle: "Choose a shortcut...")
        BackgroundShortcutConfiguration.availableShortcuts.forEach { shortcut in
            popupButton.addItem(withTitle: shortcut.displayName)
            popupButton.lastItem?.representedObject = shortcut.id as NSString
        }
        if let currentShortcut,
           let index = BackgroundShortcutConfiguration.availableShortcuts.firstIndex(of: currentShortcut) {
            popupButton.selectItem(at: index + 1)
        } else {
            popupButton.selectItem(at: 0)
        }

        accessoryView.addSubview(label)
        accessoryView.addSubview(popupButton)
        alert.accessoryView = accessoryView

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            guard
                let selectedItem = popupButton.selectedItem,
                let identifier = selectedItem.representedObject as? NSString,
                let selectedShortcut = BackgroundShortcutConfiguration.availableShortcuts.first(where: { $0.id == String(identifier) })
            else {
                showInfoAlert(
                    title: "Choose a Shortcut",
                    message: "Pick a shortcut before enabling the background helper."
                )
                return
            }
            setBackgroundShortcut(selectedShortcut)
            return
        }

        if response == .alertSecondButtonReturn,
           currentShortcut != nil || backgroundShortcutService.status == .enabled || backgroundShortcutService.status == .requiresApproval {
            disableBackgroundShortcut(clearSelection: true)
        }
    }

    private func presentBackgroundShortcutApprovalPrompt(isStartupPrompt: Bool) {
        let alert = NSAlert()
        alert.messageText = "Approve Background Shortcut"
        alert.informativeText = """
        macOS still needs approval for QuickPreview's background helper.

        Open System Settings > General > Login Items and allow QuickPreview to run in the background so the global shortcut keeps working after you close the app.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: isStartupPrompt ? "Later" : "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            backgroundShortcutService.openSystemSettings()
        }
    }

    private func setBackgroundShortcut(_ shortcut: HotkeyRegistration) {
        guard GlobalHotkeyManager.canRegister(shortcut) else {
            showInfoAlert(
                title: "Shortcut Unavailable",
                message: """
                \(shortcut.displayName) is already reserved by macOS or another app.

                Choose a different shortcut for QuickPreview.
                """
            )
            return
        }

        BackgroundShortcutConfiguration.storeSelectedShortcut(shortcut)
        updateShortcutHint()
        backgroundShortcutService.resetStartupPrompt()

        do {
            let status: SMAppService.Status
            switch backgroundShortcutService.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .requiresApproval
            case .notRegistered, .notFound:
                status = try backgroundShortcutService.enable()
            @unknown default:
                status = backgroundShortcutService.status
            }

            switch status {
            case .enabled:
                try backgroundShortcutService.reloadHelperIfNeeded()
                showInfoAlert(
                    title: "Background Shortcut Set",
                    message: """
                    QuickPreview can now reopen from the background using \(shortcut.displayName).
                    """
                )
            case .requiresApproval:
                presentBackgroundShortcutApprovalPrompt(isStartupPrompt: false)
            case .notRegistered, .notFound:
                showInfoAlert(
                    title: "Background Shortcut Pending",
                    message: "QuickPreview saved your shortcut, but the background helper is not active yet."
                )
            @unknown default:
                showInfoAlert(
                    title: "Background Shortcut Unavailable",
                    message: "QuickPreview could not verify that the background helper was enabled."
                )
            }
        } catch {
            showInfoAlert(
                title: "Could Not Enable Background Shortcut",
                message: error.localizedDescription
            )
        }
    }

    private func disableBackgroundShortcut(clearSelection: Bool) {
        if clearSelection {
            BackgroundShortcutConfiguration.storeSelectedShortcut(nil)
            updateShortcutHint()
        }

        do {
            switch backgroundShortcutService.status {
            case .enabled, .requiresApproval:
                try backgroundShortcutService.disable()
            case .notRegistered, .notFound:
                backgroundShortcutService.resetStartupPrompt()
            @unknown default:
                break
            }
            showInfoAlert(
                title: "Background Shortcut Disabled",
                message: "QuickPreview will no longer reserve a background shortcut after you close the app."
            )
        } catch {
            showInfoAlert(
                title: "Could Not Disable Background Shortcut",
                message: error.localizedDescription
            )
        }
    }

    private func updateShortcutHint() {
        shortcutHintText = BackgroundShortcutConfiguration.windowTitleHint
        windowController?.setShortcutHint(shortcutHintText ?? "")
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
                controller.hasLoadedVideo(),
                let loadedVideoURL = controller.loadedVideoURL()
            else {
                return nil
            }
            return loadedVideoURL
        }

        guard let loadedVideoURL else {
            return
        }

        let selectedVideoURL = FinderSelectionProbe.selectedFinderVideoURL()
        let selectionChanged = selectedVideoURL != lastObservedFinderSelectedVideoURL
        lastObservedFinderSelectedVideoURL = selectedVideoURL

        let isEntitled = subscriptionController.accessState.isEntitled
        if !isEntitled {
            return
        } else if selectedVideoURL == nil {
            ignoredFinderSelectedVideoURL = nil
        } else if ignoredFinderSelectedVideoURL == selectedVideoURL {
            return
        } else if !selectionChanged {
            ignoredFinderSelectedVideoURL = nil
        } else if selectedVideoURL == loadedVideoURL {
            ignoredFinderSelectedVideoURL = nil
        } else {
            ignoredFinderSelectedVideoURL = nil
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.subscriptionController.accessState.isEntitled,
                    let controller = self.windowController,
                    controller.hasLoadedVideo(),
                    selectedVideoURL != controller.loadedVideoURL(),
                    let selectedVideoURL
                else {
                    return
                }
                controller.openVideo(url: selectedVideoURL)
            }
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

    private func promptForNewParanoidModePassword() -> String? {
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"
        confirmField.placeholderString = "Confirm password"

        let warningLabel = NSTextField(wrappingLabelWithString: "Warning: if you forget this password, QuickPreview cannot recover it.")
        warningLabel.textColor = .systemRed
        warningLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Set a paranoid mode password."),
            passwordField,
            confirmField,
            warningLabel
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 132))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "Enable Paranoid Mode"
        alert.informativeText = "Paranoid mode adds a password after macOS authentication every time you unlock protected media."
        alert.alertStyle = .warning
        alert.accessoryView = container
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")

        while true {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                return nil
            }

            let password = passwordField.stringValue
            let confirmedPassword = confirmField.stringValue

            guard !password.isEmpty else {
                showInfoAlert(title: "Password Required", message: "Enter a password to enable paranoid mode.")
                continue
            }

            guard password == confirmedPassword else {
                showInfoAlert(title: "Passwords Do Not Match", message: "Enter the same password in both fields.")
                continue
            }

            return password
        }
    }

    private func promptForParanoidPassword(
        title: String,
        message: String,
        actionTitle: String
    ) -> String? {
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.accessoryView = passwordField
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let password = passwordField.stringValue
        guard !password.isEmpty else {
            showInfoAlert(title: "Password Required", message: "Enter the paranoid mode password to continue.")
            return nil
        }

        return password
    }

    private func configureSubscriptionController() {
        subscriptionController.onAccessStateChange = { [weak self] state in
            self?.handleSubscriptionAccessStateChange(state)
        }

        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessStateInBackground()
            }
        }
    }

    private func configureProtectedBookmarksSessionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProtectedBookmarksSessionDidChange(_:)),
            name: .protectedBookmarksSessionDidChange,
            object: protectedBookmarksSessionController
        )
        protectedBookmarksSessionObserver = nil
    }

    @MainActor
    @objc
    private func handleProtectedBookmarksSessionDidChange(_ notification: Notification) {
        _ = notification
        guard !protectedBookmarksSessionController.isUnlocked else {
            return
        }

        windowController?.closeCurrentProtectedVideoIfNeeded()
    }

    private func refreshAccessStateInBackground() {
        accessRefreshTask?.cancel()
        latestSuppressingRefreshID += 1
        let myRefreshID = latestSuppressingRefreshID
        suppressSubscriptionLoadingWindow = true
        accessRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if myRefreshID == self.latestSuppressingRefreshID {
                    self.suppressSubscriptionLoadingWindow = false
                }
            }
            guard !Task.isCancelled else { return }
            _ = await self.subscriptionController.refreshEntitlements()
            guard !Task.isCancelled else { return }
        }
    }

    private func requestSubscriptionAccess(
        showLoadingWindow: Bool,
        action: @escaping () -> Void
    ) {
        pendingPostEntitlementAction = action

        if subscriptionController.accessState.isEntitled {
            let pendingAction = pendingPostEntitlementAction
            pendingPostEntitlementAction = nil
            pendingAction?()
            refreshAccessStateInBackground()
            return
        }

        if showLoadingWindow || subscriptionController.accessState == .unknown || subscriptionController.accessState == .verifying {
            presentLoadingWindow()
        }

        refreshAccessStateInBackground()
    }

    private func handleSubscriptionAccessStateChange(_ state: SubscriptionAccessState) {
        switch state {
        case .unknown, .verifying:
            if !suppressSubscriptionLoadingWindow {
                presentLoadingWindow()
            }
        case .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            dismissPaywallWindowIfNeeded()
            let pendingAction = pendingPostEntitlementAction
            pendingPostEntitlementAction = nil
            if let pendingAction {
                pendingAction()
            } else if !isMainWindowVisible {
                revealPlayerWindow(centerIfNeeded: false)
            }
        case .expired, .revoked, .refunded, .notEntitled:
            hideEntitledWindows()
            presentBlockedPaywall(for: state)
        }
    }

    private func presentLoadingWindow() {
        let controller = ensurePaywallWindowController()
        controller.apply(mode: .loading, isBusy: false)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentBlockedPaywall(for state: SubscriptionAccessState) {
        let controller = ensurePaywallWindowController()
        controller.apply(
            mode: .blocked(state, makePaywallProductDetails()),
            isBusy: false
        )
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensurePaywallWindowController() -> PaywallWindowController {
        if let paywallWindowController {
            return paywallWindowController
        }

        let controller = PaywallWindowController()
        controller.onSubscribe = { [weak self] in
            self?.startPurchaseFlow()
        }
        controller.onRestorePurchases = { [weak self] in
            self?.startRestoreFlow()
        }
        controller.onManageSubscription = { [weak self] in
            self?.subscriptionController.openManageSubscriptions()
        }
        controller.onShowHelp = { [weak self] in
            self?.handleShowGuide(nil)
        }
        controller.onQuit = {
            NSApp.terminate(nil)
        }
        paywallWindowController = controller
        return controller
    }

    private func makePaywallProductDetails() -> PaywallProductDetails? {
        guard let product = subscriptionController.subscriptionProduct else {
            return nil
        }

        return PaywallProductDetails(
            displayName: product.displayName,
            displayPrice: product.displayPrice
        )
    }

    private func startPurchaseFlow() {
        let controller = ensurePaywallWindowController()
        controller.apply(
            mode: .blocked(subscriptionController.accessState, makePaywallProductDetails()),
            isBusy: true
        )

        Task { [weak self] in
            guard let self else { return }
            let result = await self.subscriptionController.purchaseSubscription()
            switch result {
            case .success:
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
            case .pending:
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
                self.showInfoAlert(
                    title: "Purchase Pending",
                    message: "The App Store purchase is pending approval."
                )
            case .cancelled:
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
            case .failed(let message):
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
                self.showInfoAlert(title: "Purchase Failed", message: message)
            }
        }
    }

    private func startRestoreFlow() {
        let controller = ensurePaywallWindowController()
        controller.apply(
            mode: .blocked(subscriptionController.accessState, makePaywallProductDetails()),
            isBusy: true
        )

        Task { [weak self] in
            guard let self else { return }
            let result = await self.subscriptionController.restorePurchases()
            switch result {
            case .restored:
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
            case .noEntitlement:
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
                self.showInfoAlert(
                    title: "Nothing to Restore",
                    message: "QuickPreview could not find an active subscription to restore for this Apple account."
                )
            case .failed(let message):
                controller.apply(
                    mode: .blocked(self.subscriptionController.accessState, self.makePaywallProductDetails()),
                    isBusy: false
                )
                self.showInfoAlert(title: "Restore Failed", message: message)
            }
        }
    }

    private func dismissPaywallWindowIfNeeded() {
        paywallWindowController?.close()
    }

    private func revealPlayerWindow(centerIfNeeded: Bool) {
        let controller = ensureWindowController()
        controller.showWindow(nil)
        if centerIfNeeded && !didCenterMainWindowOnFirstPresentation {
            controller.window?.center()
            didCenterMainWindowOnFirstPresentation = true
        }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreBookmarksWindowIfNeeded() {
        guard BookmarksWindowController.shouldReopenOnLaunch() else {
            return
        }
        showBookmarksWindow(selecting: nil)
    }

    @discardableResult
    private func restoreLastOpenedVideoIfPossible() -> Bool {
        let controller = ensureWindowController()
        guard controller.loadedVideoURL() == nil else {
            return false
        }
        guard let lastOpenedVideoURL = MainPlayerWindowController.storedLastOpenedVideoURL() else {
            return false
        }
        guard FileManager.default.fileExists(atPath: lastOpenedVideoURL.path) else {
            MainPlayerWindowController.clearStoredLastOpenedVideoURL()
            return false
        }
        guard
            protectedBookmarksSessionController.isUnlocked
                || !bookmarkStore.hasProtectedBookmarks(for: lastOpenedVideoURL)
        else {
            return false
        }

        ignoreCurrentFinderSelection()
        controller.openVideo(url: lastOpenedVideoURL, shouldRevealWindow: false)
        return true
    }

    private var isMainWindowVisible: Bool {
        windowController?.window?.isVisible == true
    }

    private func hideEntitledWindows() {
        windowController?.window?.orderOut(nil)
        bookmarksWindowController?.close()
        protectedBookmarksSessionController.lock()
    }

    private func recoverVisibleWindowIfNeeded() {
        if NSApp.windows.contains(where: { $0.isVisible }) {
            return
        }

        switch subscriptionController.accessState {
        case .trialActive,
             .subscriptionActive,
             .inGracePeriod,
             .inBillingRetry,
             .offlineGracePeriod:
            revealPlayerWindow(centerIfNeeded: false)
        case .expired, .revoked, .refunded, .notEntitled:
            presentBlockedPaywall(for: subscriptionController.accessState)
        case .unknown, .verifying:
            presentLoadingWindow()
            refreshAccessStateInBackground()
        }
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
        let result = runAppleScriptUsingProcess(script)
        guard let output = result.output, !output.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: output)
    }

    private static func runAppleScriptUsingProcess(_ source: String) -> (output: String?, errorOutput: String?, terminationStatus: Int32) {
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
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (
                output: nil,
                errorOutput: error.localizedDescription,
                terminationStatus: -1
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            output: output?.isEmpty == false ? output : nil,
            errorOutput: errorOutput?.isEmpty == false ? errorOutput : nil,
            terminationStatus: process.terminationStatus
        )
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
