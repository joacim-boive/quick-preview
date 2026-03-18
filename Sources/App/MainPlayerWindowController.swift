import Cocoa
import AVKit
import UniformTypeIdentifiers

final class MainPlayerWindowController: NSWindowController {
    private let engine = PlaybackEngine()
    private let playerView = AVPlayerView(frame: .zero)
    private let timelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Video", target: nil, action: nil)
    private let openFinderSelectionButton = NSButton(title: "Open Finder Selection", target: nil, action: nil)
    private let emptyStateLabel = NSTextField(labelWithString: "No video loaded.\nUse Open Video or Open Finder Selection.")

    private var isDraggingSlider = false
    private var escMonitor: Any?
    private static let baseWindowTitle = "Quick Preview Video Loop"

    convenience init() {
        let root = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 920, height: 640))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.baseWindowTitle
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = root
        self.init(window: window)
        configureUI(on: root)
        bindEngine()
    }

    deinit {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
    }

    func openVideo(url: URL) {
        showWindow(nil)
        engine.attach(to: url, autoplay: true)
        emptyStateLabel.isHidden = true
    }

    func setShortcutHint(_ shortcut: String) {
        guard !shortcut.isEmpty else {
            window?.title = Self.baseWindowTitle
            return
        }
        window?.title = "\(Self.baseWindowTitle) — \(shortcut)"
    }

    @discardableResult
    func openFinderSelectionIfVideo(showErrors: Bool = false) -> Bool {
        do {
            let fileURL = try selectedFinderFileURL()
            guard isVideoURL(fileURL) else {
                if showErrors {
                    showInfoAlert(
                        title: "Selected Item Is Not a Video",
                        message: "Select a video file in Finder (MP4, MOV, M4V, etc.) and try again."
                    )
                }
                return false
            }
            openVideo(url: fileURL)
            return true
        } catch let error as FinderSelectionError {
            if showErrors {
                showInfoAlert(title: error.title, message: error.message)
            }
            return false
        } catch {
            if showErrors {
                showInfoAlert(
                    title: "Could Not Read Finder Selection",
                    message: "Grant Finder Automation permission to QuickPreview in System Settings > Privacy & Security > Automation."
                )
            }
            return false
        }
    }

    private func selectedFinderFileURL() throws -> URL {
        let script = """
        tell application "Finder"
            activate
            delay 0.2

            set selectedItems to {}

            try
                set selectedItems to (selection as alias list)
            end try

            if (count selectedItems) is 0 then
                try
                    if (count of Finder windows) > 0 then
                        set selectedItems to (selection of front Finder window) as alias list
                    end if
                end try
            end if

            if (count selectedItems) is 0 then
                try
                    set selectedItems to (every item of desktop whose selected is true) as alias list
                end try
            end if

            if (count selectedItems) is 0 then
                return ""
            end if

            return POSIX path of (item 1 of selectedItems)
        end tell
        """

        let result = runAppleScript(script)
        if let code = result.errorCode, code == -1743 || code == -1719 {
            throw FinderSelectionError.automationDenied
        }
        if let value = result.value, !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        if let code = result.errorCode {
            throw FinderSelectionError.noSelectionWithDetails("finder.selection: error \(code)")
        }
        throw FinderSelectionError.noSelectionWithDetails("finder.selection: empty")
    }

    private func runAppleScript(_ source: String) -> (value: String?, errorCode: Int?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, -1)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        let errorCode = errorInfo?[NSAppleScript.errorNumber] as? Int
        return (result.stringValue, errorCode)
    }

    func presentOpenPanelIfNeeded() {
        guard engine.currentPlayer().currentItem == nil else { return }
        handleOpenVideo(openButton)
    }

    private func configureUI(on root: KeyCaptureView) {
        guard let content = window?.contentView else { return }
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.player = engine.currentPlayer()

        timelineSlider.translatesAutoresizingMaskIntoConstraints = false
        timelineSlider.target = self
        timelineSlider.action = #selector(handleSliderChanged(_:))

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.alignment = .right

        loopButton.translatesAutoresizingMaskIntoConstraints = false
        loopButton.target = self
        loopButton.action = #selector(handleLoopToggle(_:))

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.target = self
        openButton.action = #selector(handleOpenVideo(_:))

        openFinderSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        openFinderSelectionButton.target = self
        openFinderSelectionButton.action = #selector(handleOpenFinderSelection(_:))

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 20, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [openButton, openFinderSelectionButton, loopButton, timeLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fillProportionally
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(playerView)
        content.addSubview(emptyStateLabel)
        content.addSubview(timelineSlider)
        content.addSubview(controls)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            timelineSlider.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 10),
            timelineSlider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            timelineSlider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            controls.topAnchor.constraint(equalTo: timelineSlider.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),

            emptyStateLabel.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: playerView.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: playerView.trailingAnchor, constant: -16)
        ])

        root.keyHandler = { [weak self] event in
            self?.handleKey(event: event)
        }
        installEscCloseMonitor()
    }

    private func bindEngine() {
        engine.onPositionUpdate = { [weak self] position in
            guard let self else { return }
            if !self.isDraggingSlider {
                self.timelineSlider.doubleValue = position.progress
            }
            self.timeLabel.stringValue = "\(Self.format(position.seconds)) / \(Self.format(position.duration))"
        }
        engine.onLoopModeUpdate = { [weak self] mode in
            guard let self else { return }
            self.loopButton.state = mode == .off ? .off : .on
        }
    }

    private func handleKey(event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53:
            closePreviewWindow()
        case 49:
            engine.handle(command: .togglePlayPause)
        case 37:
            engine.handle(command: .toggleLoop)
        case 123:
            let amount = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: -amount))
        case 124:
            let amount = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: amount))
        case 126:
            engine.handle(command: .seekFrame(delta: 1))
        case 125:
            engine.handle(command: .seekFrame(delta: -1))
        default:
            break
        }
    }

    private func installEscCloseMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                let self,
                event.keyCode == 53,
                let window = self.window,
                event.window === window
            else {
                return event
            }
            self.closePreviewWindow()
            return nil
        }
    }

    private func closePreviewWindow() {
        engine.pause()
        window?.orderOut(nil)
    }

    @objc
    private func handleSliderChanged(_ sender: NSSlider) {
        let duration = engine.currentDurationSeconds()
        isDraggingSlider = true
        engine.handle(command: .seekTo(seconds: sender.doubleValue * duration))
        isDraggingSlider = false
    }

    @objc
    private func handleLoopToggle(_ sender: NSButton) {
        engine.setLoopFull(enabled: sender.state == .on)
    }

    @objc
    private func handleOpenVideo(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openVideo(url: url)
        }
    }

    @objc
    private func handleOpenFinderSelection(_ sender: NSButton) {
        _ = openFinderSelectionIfVideo(showErrors: true)
    }

    private func isVideoURL(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            if values.isDirectory == true {
                return false
            }
            if let contentType = values.contentType {
                return contentType.conforms(to: .movie)
            }
        } catch {
            return false
        }
        return false
    }

    private static func format(_ seconds: PlaybackSeconds) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
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

private enum FinderSelectionError: Error {
    case noSelection
    case automationDenied
    case noSelectionWithDetails(String)

    var title: String {
        switch self {
        case .noSelection:
            return "No Finder Selection"
        case .automationDenied:
            return "Finder Access Needed"
        case .noSelectionWithDetails:
            return "No Finder Selection"
        }
    }

    var message: String {
        switch self {
        case .noSelection:
            return "Select a file in Finder first, then run the shortcut."
        case .automationDenied:
            return "Allow QuickPreview to control Finder in System Settings > Privacy & Security > Automation."
        case let .noSelectionWithDetails(details):
            return "Finder did not report a selected file. Select one file in Finder and try again.\n\nDiagnostics: \(details)"
        }
    }
}
