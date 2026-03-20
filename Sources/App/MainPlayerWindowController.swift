import Cocoa
import AVFoundation
import UniformTypeIdentifiers

final class MainPlayerWindowController: NSWindowController, NSWindowDelegate {
    private let engine = PlaybackEngine()
    private let playerView = PlayerSurfaceView(frame: .zero)
    private let timelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let setSelectionStartButton = NSButton(title: "Set Start", target: nil, action: nil)
    private let setSelectionEndButton = NSButton(title: "Set End", target: nil, action: nil)
    private let replaySelectionButton = NSButton(checkboxWithTitle: "Replay Selection", target: nil, action: nil)
    private let clearSelectionButton = NSButton(title: "Clear Selection", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "Selection: none")
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let rotationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fullscreenButton = NSButton(title: "Fullscreen", target: nil, action: nil)
    private let openFinderSelectionButton = NSButton(title: "Open Finder Selection", target: nil, action: nil)
    private let emptyStateLabel = NSTextField(labelWithString: "No video loaded.\nUse File > Open... or Open Finder Selection.")

    private var isDraggingSlider = false
    private var escMonitor: Any?
    private var selectionStart: PlaybackSeconds?
    private var selectionEnd: PlaybackSeconds?
    private var currentVideoURL: URL?
    private var currentRotationDegrees = 0
    private var shortcutHintText: String?
    private static let baseWindowTitle = "Quick Preview Video Loop"
    private static let clipRotationDefaultsKey = "clipRotationDegreesByPath"
    private let allowedRotationDegrees = [0, 90, 180, 270]

    enum FinderSelectionState {
        case none
        case nonVideo(URL)
        case video(URL)
    }

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
        window.delegate = self
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
        let normalizedURL = url.standardizedFileURL
        engine.attach(to: normalizedURL, autoplay: true)
        currentVideoURL = normalizedURL
        let storedRotation = storedRotationDegrees(for: normalizedURL)
        applyRotationDegrees(storedRotation)
        rotationPopup.isEnabled = true
        updateWindowTitle()
        selectionStart = nil
        selectionEnd = nil
        replaySelectionButton.state = .off
        selectionLabel.stringValue = "Selection: none"
        emptyStateLabel.isHidden = true
    }

    func setShortcutHint(_ shortcut: String) {
        shortcutHintText = shortcut.isEmpty ? nil : shortcut
        updateWindowTitle()
    }

    @discardableResult
    func openFinderSelectionIfVideo(showErrors: Bool = false) -> Bool {
        do {
            let fileURL = try selectedFinderFileURL(activateFinder: true)
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

    func selectedFinderVideoURL(activateFinder: Bool) -> URL? {
        guard let fileURL = try? selectedFinderFileURL(activateFinder: activateFinder) else {
            return nil
        }
        guard isVideoURL(fileURL) else {
            return nil
        }
        return fileURL.standardizedFileURL
    }

    func finderSelectionState(activateFinder: Bool) -> FinderSelectionState {
        guard let fileURL = try? selectedFinderFileURL(activateFinder: activateFinder) else {
            return .none
        }
        if isVideoURL(fileURL) {
            return .video(fileURL.standardizedFileURL)
        }
        return .nonVideo(fileURL.standardizedFileURL)
    }

    func loadedVideoURL() -> URL? {
        currentVideoURL
    }

    func hasLoadedVideo() -> Bool {
        currentVideoURL != nil
    }

    private func selectedFinderFileURL(activateFinder: Bool) throws -> URL {
        var lines: [String] = [
            "tell application \"Finder\""
        ]
        if activateFinder {
            lines.append("    activate")
            lines.append("    delay 0.2")
        }
        lines.append(contentsOf: [
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
        ])
        let script = lines.joined(separator: "\n")

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
        let processResult = runAppleScriptUsingProcess(source)
        if processResult.errorCode == nil {
            return processResult
        }

        guard let script = NSAppleScript(source: source) else {
            return (nil, -1)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        let errorCode = errorInfo?[NSAppleScript.errorNumber] as? Int
        return (result.stringValue, errorCode)
    }

    private func runAppleScriptUsingProcess(_ source: String) -> (value: String?, errorCode: Int?) {
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
            return (nil, -1)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return (output?.isEmpty == false ? output : nil, nil)
        }

        let parsedCode = parseAppleScriptErrorCode(from: errorText) ?? Int(process.terminationStatus)
        return (nil, parsedCode)
    }

    private func parseAppleScriptErrorCode(from errorText: String) -> Int? {
        guard let match = errorText.range(of: #"\(-?\d+\)"#, options: .regularExpression) else {
            return nil
        }
        let raw = errorText[match]
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return Int(raw)
    }

    func presentOpenPanelIfNeeded() {
        guard engine.currentPlayer().currentItem == nil else { return }
        presentOpenVideoPanel()
    }

    func presentOpenVideoPanel() {
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

    private func configureUI(on root: KeyCaptureView) {
        guard let content = window?.contentView else { return }
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.player = engine.currentPlayer()
        playerView.clickHandler = { [weak self] in
            self?.handlePlayerSurfaceClick()
        }

        timelineSlider.translatesAutoresizingMaskIntoConstraints = false
        timelineSlider.target = self
        timelineSlider.action = #selector(handleSliderChanged(_:))

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.alignment = .right

        loopButton.translatesAutoresizingMaskIntoConstraints = false
        loopButton.target = self
        loopButton.action = #selector(handleLoopToggle(_:))

        setSelectionStartButton.translatesAutoresizingMaskIntoConstraints = false
        setSelectionStartButton.target = self
        setSelectionStartButton.action = #selector(handleSetSelectionStart(_:))

        setSelectionEndButton.translatesAutoresizingMaskIntoConstraints = false
        setSelectionEndButton.target = self
        setSelectionEndButton.action = #selector(handleSetSelectionEnd(_:))

        replaySelectionButton.translatesAutoresizingMaskIntoConstraints = false
        replaySelectionButton.target = self
        replaySelectionButton.action = #selector(handleReplaySelectionToggle(_:))

        clearSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        clearSelectionButton.target = self
        clearSelectionButton.action = #selector(handleClearSelection(_:))

        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.lineBreakMode = .byTruncatingTail

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = Double(engine.currentPlayer().volume)

        rotationPopup.translatesAutoresizingMaskIntoConstraints = false
        rotationPopup.target = self
        rotationPopup.action = #selector(handleRotationChanged(_:))
        rotationPopup.removeAllItems()
        rotationPopup.addItems(withTitles: allowedRotationDegrees.map { "\($0)°" })
        rotationPopup.selectItem(at: 0)
        rotationPopup.isEnabled = false

        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        fullscreenButton.target = self
        fullscreenButton.action = #selector(handleToggleFullscreen(_:))
        updateFullscreenButtonTitle()

        openFinderSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        openFinderSelectionButton.target = self
        openFinderSelectionButton.action = #selector(handleOpenFinderSelection(_:))

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 20, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor

        let topControls = NSStackView(
            views: [
                openFinderSelectionButton,
                loopButton,
                setSelectionStartButton,
                setSelectionEndButton,
                replaySelectionButton,
                clearSelectionButton,
                rotationPopup,
                fullscreenButton
            ]
        )
        topControls.orientation = .horizontal
        topControls.alignment = .centerY
        topControls.distribution = .fill
        topControls.spacing = 10
        topControls.translatesAutoresizingMaskIntoConstraints = false

        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomControls = NSStackView(
            views: [
                selectionLabel,
                volumeSlider,
                timeLabel
            ]
        )
        bottomControls.orientation = .horizontal
        bottomControls.alignment = .centerY
        bottomControls.distribution = .fill
        bottomControls.spacing = 10
        bottomControls.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [topControls, bottomControls])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.distribution = .fillEqually
        controls.spacing = 8
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
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: playerView.trailingAnchor, constant: -16),

            volumeSlider.widthAnchor.constraint(equalToConstant: 160)
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
            switch mode {
            case .off:
                self.loopButton.state = .off
                self.replaySelectionButton.state = .off
            case .full:
                self.loopButton.state = .on
                self.replaySelectionButton.state = .off
            case .range:
                self.loopButton.state = .off
                self.replaySelectionButton.state = .on
            }
        }
    }

    private func handleKey(event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 12 {
            NSApp.terminate(nil)
            return
        }

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
        if window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
            return
        }
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
    private func handleSetSelectionStart(_ sender: NSButton) {
        let current = engine.currentTimeSeconds()
        selectionStart = current
        if let end = selectionEnd, end < current {
            selectionEnd = current
        }
        updateSelectionLabel()
        if replaySelectionButton.state == .on {
            applySelectionReplay()
        }
        _ = sender
    }

    @objc
    private func handleSetSelectionEnd(_ sender: NSButton) {
        let current = engine.currentTimeSeconds()
        selectionEnd = current
        if let start = selectionStart, start > current {
            selectionStart = current
        }
        updateSelectionLabel()
        if replaySelectionButton.state == .on {
            applySelectionReplay()
        }
        _ = sender
    }

    @objc
    private func handleReplaySelectionToggle(_ sender: NSButton) {
        if sender.state == .on {
            guard applySelectionReplay() else {
                sender.state = .off
                showInfoAlert(
                    title: "Selection Not Ready",
                    message: "Set both selection start and end to replay only that part of the video."
                )
                return
            }
            return
        }
        engine.clearLoop()
    }

    @objc
    private func handleClearSelection(_ sender: NSButton) {
        selectionStart = nil
        selectionEnd = nil
        replaySelectionButton.state = .off
        engine.clearLoop()
        updateSelectionLabel()
        _ = sender
    }

    @objc
    private func handleOpenFinderSelection(_ sender: NSButton) {
        _ = openFinderSelectionIfVideo(showErrors: true)
    }

    @objc
    private func handleVolumeChanged(_ sender: NSSlider) {
        engine.currentPlayer().volume = Float(sender.doubleValue)
    }

    @objc
    private func handleToggleFullscreen(_ sender: NSButton) {
        window?.toggleFullScreen(sender)
    }

    @objc
    private func handleRotationChanged(_ sender: NSPopUpButton) {
        let selectedIndex = max(sender.indexOfSelectedItem, 0)
        guard selectedIndex < allowedRotationDegrees.count else { return }
        let degrees = allowedRotationDegrees[selectedIndex]
        applyRotationDegrees(degrees)
        guard let currentVideoURL else { return }
        storeRotationDegrees(degrees, for: currentVideoURL)
    }

    private func handlePlayerSurfaceClick() {
        guard engine.currentPlayer().currentItem != nil else { return }
        let wasPlaying = engine.currentPlayer().rate != 0
        engine.handle(command: .togglePlayPause)
        let symbolName = wasPlaying ? "pause.fill" : "play.fill"
        playerView.flashPlaybackIndicator(symbolName: symbolName)
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

    private func updateWindowTitle() {
        if let currentVideoURL {
            window?.title = currentVideoURL.lastPathComponent
            return
        }
        if let shortcutHintText {
            window?.title = shortcutHintText
            return
        }
        window?.title = Self.baseWindowTitle
    }

    private func applyRotationDegrees(_ degrees: Int) {
        guard allowedRotationDegrees.contains(degrees) else { return }
        currentRotationDegrees = degrees
        playerView.setRotationDegrees(degrees)
        if let selectedIndex = allowedRotationDegrees.firstIndex(of: degrees) {
            rotationPopup.selectItem(at: selectedIndex)
        }
    }

    private func storedRotationDegrees(for url: URL) -> Int {
        let defaults = UserDefaults.standard
        guard
            let raw = defaults.dictionary(forKey: Self.clipRotationDefaultsKey) as? [String: Int],
            let degrees = raw[url.path],
            allowedRotationDegrees.contains(degrees)
        else {
            return 0
        }
        return degrees
    }

    private func storeRotationDegrees(_ degrees: Int, for url: URL) {
        guard allowedRotationDegrees.contains(degrees) else { return }
        let defaults = UserDefaults.standard
        var raw = defaults.dictionary(forKey: Self.clipRotationDefaultsKey) as? [String: Int] ?? [:]
        raw[url.path] = degrees
        defaults.set(raw, forKey: Self.clipRotationDefaultsKey)
    }

    private func updateFullscreenButtonTitle() {
        if window?.styleMask.contains(.fullScreen) == true {
            fullscreenButton.title = "Exit Fullscreen"
            return
        }
        fullscreenButton.title = "Fullscreen"
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateFullscreenButtonTitle()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateFullscreenButtonTitle()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        engine.pause()
        return true
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

    @discardableResult
    private func applySelectionReplay() -> Bool {
        guard let range = normalizedSelectionRange() else {
            return false
        }
        engine.setLoopRange(start: range.start, end: range.end)
        engine.handle(command: .seekTo(seconds: range.start))
        engine.play()
        return true
    }

    private func normalizedSelectionRange() -> (start: PlaybackSeconds, end: PlaybackSeconds)? {
        guard let start = selectionStart, let end = selectionEnd else {
            return nil
        }
        let lower = min(start, end)
        let upper = max(start, end)
        guard upper - lower > 0.001 else {
            return nil
        }
        return (lower, upper)
    }

    private func updateSelectionLabel() {
        guard let start = selectionStart, let end = selectionEnd else {
            selectionLabel.stringValue = "Selection: none"
            return
        }
        let lower = min(start, end)
        let upper = max(start, end)
        selectionLabel.stringValue = "Selection: \(Self.format(lower))-\(Self.format(upper))"
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

private final class PlayerSurfaceView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let playbackIndicatorContainer = NSVisualEffectView()
    private let playbackIndicatorImageView = NSImageView()
    private var hideIndicatorWorkItem: DispatchWorkItem?
    private var rotationDegrees = 0

    var clickHandler: (() -> Void)?

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        layer = rootLayer
        playerLayer.videoGravity = .resizeAspect
        rootLayer.addSublayer(playerLayer)

        playbackIndicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        playbackIndicatorContainer.material = .hudWindow
        playbackIndicatorContainer.blendingMode = .withinWindow
        playbackIndicatorContainer.state = .active
        playbackIndicatorContainer.wantsLayer = true
        playbackIndicatorContainer.layer?.cornerRadius = 34
        playbackIndicatorContainer.layer?.masksToBounds = true
        playbackIndicatorContainer.alphaValue = 0
        playbackIndicatorContainer.isHidden = true

        playbackIndicatorImageView.translatesAutoresizingMaskIntoConstraints = false
        playbackIndicatorImageView.imageScaling = .scaleProportionallyUpOrDown
        playbackIndicatorImageView.contentTintColor = .white
        playbackIndicatorContainer.addSubview(playbackIndicatorImageView)
        addSubview(playbackIndicatorContainer)

        NSLayoutConstraint.activate([
            playbackIndicatorContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            playbackIndicatorContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            playbackIndicatorContainer.widthAnchor.constraint(equalToConstant: 68),
            playbackIndicatorContainer.heightAnchor.constraint(equalToConstant: 68),

            playbackIndicatorImageView.centerXAnchor.constraint(equalTo: playbackIndicatorContainer.centerXAnchor),
            playbackIndicatorImageView.centerYAnchor.constraint(equalTo: playbackIndicatorContainer.centerYAnchor),
            playbackIndicatorImageView.widthAnchor.constraint(equalToConstant: 34),
            playbackIndicatorImageView.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let isQuarterTurn = rotationDegrees == 90 || rotationDegrees == 270
        if isQuarterTurn {
            let frame = CGRect(
                x: (bounds.width - bounds.height) / 2,
                y: (bounds.height - bounds.width) / 2,
                width: bounds.height,
                height: bounds.width
            )
            playerLayer.frame = frame
        } else {
            playerLayer.frame = bounds
        }
    }

    override func mouseUp(with event: NSEvent) {
        clickHandler?()
        super.mouseUp(with: event)
    }

    func flashPlaybackIndicator(symbolName: String) {
        guard
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 34, weight: .medium))
        else {
            return
        }

        hideIndicatorWorkItem?.cancel()
        playbackIndicatorImageView.image = image
        playbackIndicatorContainer.isHidden = false
        playbackIndicatorContainer.alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            playbackIndicatorContainer.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.playbackIndicatorContainer.animator().alphaValue = 0
            } completionHandler: {
                self.playbackIndicatorContainer.isHidden = true
            }
        }
        hideIndicatorWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    func setRotationDegrees(_ degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        rotationDegrees = normalized
        let radians = CGFloat(normalized) * .pi / 180

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        CATransaction.commit()

        needsLayout = true
    }
}
