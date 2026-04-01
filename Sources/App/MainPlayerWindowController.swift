import Cocoa
import AVFoundation
import UniformTypeIdentifiers

private struct BookmarkTimelineMarker: Equatable, Comparable {
    let id: BookmarkID
    let timeSeconds: PlaybackSeconds

    static func < (lhs: BookmarkTimelineMarker, rhs: BookmarkTimelineMarker) -> Bool {
        if abs(lhs.timeSeconds - rhs.timeSeconds) > 0.0001 {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

final class MainPlayerWindowController: NSWindowController, NSWindowDelegate {
    private let engine = PlaybackEngine()
    private let bookmarkStore: BookmarkStore
    private let bookmarkTimelineHoverPreview: BookmarkTimelineMarkerHoverPreviewController
    private let playerView = PlayerSurfaceView(frame: .zero)
    private let inlineTimelineView = InlineSelectionTimelineView(frame: .zero)
    private let addBookmarkButton = NSButton(title: "", target: nil, action: nil)
    private let loopToggleButton = NSButton(title: "", target: nil, action: nil)
    private let autoplayToggleButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let maxVolumeGain: Double = 3.0 // 300%
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 3.0, target: nil, action: nil)
    private let volumePercentLabel = NSTextField(labelWithString: "100%")
    private let emptyStateLabel = NSTextField(labelWithString: "No video loaded.\nUse File > Open... or File > Open Finder Selection...")

    private var escMonitor: Any?
    private var bookmarkChangeObserver: NSObjectProtocol?
    private var selectionStart: PlaybackSeconds = 0
    private var selectionEnd: PlaybackSeconds = 0
    private var currentVideoURL: URL?
    private var currentClipBookmarks: [BookmarkTimelineMarker] = []
    private var selectedBookmarkID: BookmarkID?
    private var currentRotationDegrees = 0
    private var isLoopEnabled = true
    private var isAutoplayEnabled = MainPlayerWindowController.storedAutoplayPreference()
    private var hasStoredSelectionForCurrentClip = false
    private var lastKnownDuration: PlaybackSeconds = 0
    private var lastPersistedPlaybackPlayhead: PlaybackSeconds?
    private var lastPlaybackPersistenceUptime: TimeInterval = 0
    private var lastRenderedPositionWholeSeconds = -1
    private var lastRenderedDurationWholeSeconds = -1
    private var lastTimelineUpdateUptime: TimeInterval = 0
    private let timelineRefreshInterval: TimeInterval = 1.0 / 30.0
    private let playbackCheckpointInterval: TimeInterval = 1.0
    private let playbackCheckpointMinimumDelta: PlaybackSeconds = 0.75
    private var wasPlayingBeforePlayheadDrag = false
    private var wasPlayingBeforeSelectionPreview = false
    private var wasPlayingBeforeBookmarkDrag = false
    private var selectionPreviewReturnPosition: PlaybackSeconds?
    private var pendingRestoredPlayhead: PlaybackSeconds?
    private var pendingRestoredLoopEnabled: Bool?
    private var pendingRestoredIsPlaying: Bool?
    private var pendingRestoredSelectedBookmarkID: BookmarkID?
    private var pendingBookmarkNavigationTime: PlaybackSeconds?
    private var clipSelectionStoreCache: [String: ClipSelection] = [:]
    private var clipPlaybackStoreCache: [String: ClipPlaybackState] = [:]
    private var hasLoadedClipSelectionStoreCache = false
    private var hasLoadedClipPlaybackStoreCache = false
    private var persistSelectionWorkItem: DispatchWorkItem?
    private var persistPlaybackWorkItem: DispatchWorkItem?
    private let selectionPersistenceQueue = DispatchQueue(
        label: "quickpreview.clip-selection.persistence",
        qos: .utility
    )
    private let playbackPersistenceQueue = DispatchQueue(
        label: "quickpreview.clip-playback.persistence",
        qos: .utility
    )
    private let persistDebounceInterval: TimeInterval = 0.2
    private var shortcutHintText: String?
    private static let baseWindowTitle = "Quick Preview Video Loop"
    private static let autoplayDefaultsKey = "autoplayEnabled"

    /// Keeps the controls row stable when swapping autoplay symbols (they have different intrinsic widths).
    private static func autoplayToggleButtonLayoutWidth() -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        func width(for symbolName: String) -> CGFloat {
            let button = NSButton(title: "", target: nil, action: nil)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            return button.fittingSize.width
        }
        return max(width(for: "play.circle.fill"), width(for: "play.slash"))
    }
    private static let clipRotationDefaultsKey = "clipRotationDegreesByPath"
    private static let clipSelectionDefaultsKey = "clipSelectionByPath"
    private static let clipPlaybackDefaultsKey = "clipPlaybackStateByPath"
    private static let lastOpenedVideoPathDefaultsKey = "lastOpenedVideoPath"
    private let allowedRotationDegrees = [0, 90, 180, 270]

    /// Second parameter: flash row highlight in the bookmarks manager (e.g. when focusing an existing bookmark at the playhead).
    var onShowBookmarksRequested: ((Bookmark, Bool) -> Void)?
    var onCurrentVideoURLChange: ((URL?) -> Void)?
    var onBookmarkNavigationRequested: ((Int) -> Void)?

    private struct ClipSelection: Codable {
        let start: PlaybackSeconds
        let end: PlaybackSeconds
    }

    private struct ClipPlaybackState: Codable {
        let playhead: PlaybackSeconds
        let volume: Double
        let isLoopEnabled: Bool
        let isPlaying: Bool
        let selectedBookmarkID: BookmarkID?
        let windowFrame: ClipWindowFrame?
    }

    private struct ClipWindowFrame: Codable {
        let originX: CGFloat
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat

        var rect: NSRect {
            NSRect(x: originX, y: originY, width: width, height: height)
        }
    }

    enum FinderSelectionState {
        case none
        case nonVideo(URL)
        case video(URL)
    }

    init(bookmarkStore: BookmarkStore, thumbnailService: VideoThumbnailService) {
        self.bookmarkStore = bookmarkStore
        self.bookmarkTimelineHoverPreview = BookmarkTimelineMarkerHoverPreviewController(
            thumbnailService: thumbnailService
        )
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
        super.init(window: window)
        window.delegate = self
        configureUI(on: root)
        bindEngine()
        installBookmarkObserver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        if let bookmarkChangeObserver {
            NotificationCenter.default.removeObserver(bookmarkChangeObserver)
        }
    }

    func revealWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func openVideo(url: URL, shouldRevealWindow: Bool = true) {
        if shouldRevealWindow {
            revealWindow()
        } else if window?.isVisible == true {
            window?.orderFront(nil)
        }
        persistCurrentClipPlaybackStateIfNeeded(flushImmediately: true)
        bookmarkTimelineHoverPreview.hide()
        let normalizedURL = url.standardizedFileURL
        Self.storeLastOpenedVideoURL(normalizedURL)
        engine.attach(to: normalizedURL, autoplay: isAutoplayEnabled)
        currentVideoURL = normalizedURL
        synchronizeCurrentClipBookmarks()
        lastKnownDuration = 0
        lastPersistedPlaybackPlayhead = nil
        lastPlaybackPersistenceUptime = 0
        lastRenderedPositionWholeSeconds = -1
        lastRenderedDurationWholeSeconds = -1
        lastTimelineUpdateUptime = 0
        pendingRestoredPlayhead = nil
        pendingRestoredLoopEnabled = nil
        pendingRestoredIsPlaying = nil
        pendingRestoredSelectedBookmarkID = nil
        let storedRotation = storedRotationDegrees(for: normalizedURL)
        applyRotationDegrees(storedRotation)
        updateWindowTitle()
        restoreSelection(for: normalizedURL, duration: engine.currentDurationSeconds())
        restoreClipPlaybackState(for: normalizedURL, duration: engine.currentDurationSeconds())
        emptyStateLabel.isHidden = true
        updateControlState(hasVideo: true)
        onCurrentVideoURLChange?(normalizedURL)
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

    func flushPersistedStateWrites() {
        flushPendingPersistedStateWrites(blocking: true)
    }

    func closeCurrentVideoIfNeeded() {
        guard currentVideoURL != nil else {
            return
        }
        persistCurrentClipPlaybackStateIfNeeded(flushImmediately: true)
        engine.pause()
        engine.currentPlayer().replaceCurrentItem(with: nil)
        clearLoadedVideoState()
    }

    func closeCurrentProtectedVideoIfNeeded() {
        guard
            let currentProtectedVideoURL = currentVideoURL,
            bookmarkStore.hasProtectedBookmarks(for: currentProtectedVideoURL)
        else {
            return
        }
        closeCurrentVideoIfNeeded()
    }

    func loopEnabled() -> Bool {
        isLoopEnabled
    }

    func autoplayEnabled() -> Bool {
        isAutoplayEnabled
    }

    func setLoopEnabled(_ enabled: Bool) {
        isLoopEnabled = enabled
        applyLoopPreferenceForCurrentClip()
        updateLoopToggleButtonAppearance()
        persistCurrentClipPlaybackStateIfNeeded()
    }

    func setAutoplayEnabled(_ enabled: Bool, showFeedback: Bool = false) {
        guard isAutoplayEnabled != enabled else {
            syncAutoplayPreferenceUI()
            return
        }
        isAutoplayEnabled = enabled
        Self.storeAutoplayPreference(enabled)
        syncAutoplayPreferenceUI()
        if showFeedback {
            playerView.flashStatusMessage(enabled ? "Autoplay On" : "Autoplay Off")
        }
    }

    static func storedAutoplayPreference(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoplayDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: autoplayDefaultsKey)
    }

    static func storeAutoplayPreference(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: autoplayDefaultsKey)
    }

    static func storedLastOpenedVideoURL(defaults: UserDefaults = .standard) -> URL? {
        guard
            let storedPath = defaults.string(forKey: lastOpenedVideoPathDefaultsKey),
            !storedPath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: storedPath).standardizedFileURL
    }

    static func clearStoredLastOpenedVideoURL(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastOpenedVideoPathDefaultsKey)
    }

    func rotationDegrees() -> Int {
        currentRotationDegrees
    }

    func setRotationDegrees(_ degrees: Int) {
        applyRotationDegrees(degrees)
        guard let currentVideoURL else { return }
        storeRotationDegrees(currentRotationDegrees, for: currentVideoURL)
    }

    func rotateClockwise() {
        guard let currentIndex = allowedRotationDegrees.firstIndex(of: currentRotationDegrees) else {
            setRotationDegrees(0)
            return
        }
        let nextIndex = (currentIndex + 1) % allowedRotationDegrees.count
        setRotationDegrees(allowedRotationDegrees[nextIndex])
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
        revealWindow()
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

        inlineTimelineView.translatesAutoresizingMaskIntoConstraints = false
        inlineTimelineView.onSeekBegan = { [weak self] in
            guard let self else { return }
            self.wasPlayingBeforePlayheadDrag = self.engine.currentPlayer().rate != 0
            if self.wasPlayingBeforePlayheadDrag {
                self.engine.pause()
            }
            self.engine.beginScrubbing()
        }
        inlineTimelineView.onSeekChanged = { [weak self] seconds in
            guard let self else { return }
            self.engine.scrub(to: seconds)
            let duration = max(self.engine.currentDurationSeconds(), 0)
            self.timeLabel.stringValue = "\(Self.format(seconds)) / \(Self.format(duration))"
        }
        inlineTimelineView.onSeekEnded = { [weak self] seconds in
            guard let self else { return }
            self.engine.endScrubbing(at: seconds)
            if self.wasPlayingBeforePlayheadDrag {
                self.engine.play()
            }
            self.wasPlayingBeforePlayheadDrag = false
            self.persistCurrentClipPlaybackStateIfNeeded()
        }
        inlineTimelineView.onSelectionChange = { [weak self] start, end in
            self?.handleInlineSelectionChange(start: start, end: end, shouldCommit: false)
        }
        inlineTimelineView.onSelectionCommit = { [weak self] start, end in
            self?.handleInlineSelectionChange(start: start, end: end, shouldCommit: true)
        }
        inlineTimelineView.onSelectionPreviewBegan = { [weak self] in
            guard let self else { return }
            guard self.engine.currentPlayer().currentItem != nil else { return }
            self.selectionPreviewReturnPosition = self.engine.currentTimeSeconds()
            self.wasPlayingBeforeSelectionPreview = self.engine.currentPlayer().rate != 0
            if self.wasPlayingBeforeSelectionPreview {
                self.engine.pause()
            }
            self.engine.beginScrubbing()
        }
        inlineTimelineView.onSelectionPreviewChanged = { [weak self] seconds in
            guard let self else { return }
            self.engine.scrub(to: seconds)
            let duration = max(self.engine.currentDurationSeconds(), 0)
            self.timeLabel.stringValue = "\(Self.format(seconds)) / \(Self.format(duration))"
        }
        inlineTimelineView.onSelectionPreviewEnded = { [weak self] in
            guard let self else { return }
            let returnPosition = self.selectionPreviewReturnPosition ?? self.inlineTimelineView.currentPosition
            self.engine.endScrubbing(at: returnPosition)
            if self.wasPlayingBeforeSelectionPreview {
                self.engine.play()
            }
            self.wasPlayingBeforeSelectionPreview = false
            self.selectionPreviewReturnPosition = nil
            let duration = max(self.engine.currentDurationSeconds(), 0)
            self.timeLabel.stringValue = "\(Self.format(returnPosition)) / \(Self.format(duration))"
        }
        inlineTimelineView.onBookmarkSelectionChange = { [weak self] bookmarkID in
            self?.setSelectedBookmarkID(bookmarkID, persistPlaybackState: true)
        }
        inlineTimelineView.onBookmarkDragBegan = { [weak self] bookmarkID in
            guard let self else { return }
            self.setSelectedBookmarkID(bookmarkID, persistPlaybackState: true)
            self.wasPlayingBeforeBookmarkDrag = self.engine.currentPlayer().rate != 0
            if self.wasPlayingBeforeBookmarkDrag {
                self.engine.pause()
            }
            self.engine.beginScrubbing()
        }
        inlineTimelineView.onBookmarkDragChanged = { [weak self] bookmarkID, seconds in
            self?.handleBookmarkMarkerDrag(bookmarkID: bookmarkID, seconds: seconds, shouldCommit: false)
        }
        inlineTimelineView.onBookmarkDragEnded = { [weak self] bookmarkID, seconds in
            self?.handleBookmarkMarkerDrag(bookmarkID: bookmarkID, seconds: seconds, shouldCommit: true)
        }
        inlineTimelineView.onBookmarkMarkerHoverEnter = { [weak self] bookmarkID, rectInWindow in
            self?.showTimelineBookmarkHoverPreview(bookmarkID: bookmarkID, anchorRectInWindow: rectInWindow)
        }
        inlineTimelineView.onBookmarkMarkerHoverExit = { [weak self] in
            self?.bookmarkTimelineHoverPreview.hide()
        }
        inlineTimelineView.onBookmarkMarkerHoverMove = { [weak self] _, rectInWindow in
            self?.bookmarkTimelineHoverPreview.reposition(anchorRectInWindow: rectInWindow, parentWindow: self?.window)
        }

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.alignment = .right

        addBookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        addBookmarkButton.target = self
        addBookmarkButton.action = #selector(handleAddBookmark(_:))
        let addBookmarkImage = NSImage(
            systemSymbolName: "bookmark.fill",
            accessibilityDescription: "Add Bookmark"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        addBookmarkImage?.isTemplate = true
        addBookmarkButton.image = addBookmarkImage
        addBookmarkButton.imagePosition = .imageOnly
        addBookmarkButton.toolTip = "Add Bookmark"
        addBookmarkButton.isBordered = false
        addBookmarkButton.controlSize = .regular
        addBookmarkButton.setButtonType(.momentaryPushIn)
        addBookmarkButton.setContentHuggingPriority(.required, for: .horizontal)
        addBookmarkButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        loopToggleButton.translatesAutoresizingMaskIntoConstraints = false
        loopToggleButton.target = self
        loopToggleButton.action = #selector(handleLoopToggle(_:))
        loopToggleButton.isBordered = false
        loopToggleButton.imagePosition = .imageOnly
        loopToggleButton.controlSize = .regular
        loopToggleButton.setButtonType(.momentaryPushIn)
        loopToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        loopToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateLoopToggleButtonAppearance()

        autoplayToggleButton.translatesAutoresizingMaskIntoConstraints = false
        autoplayToggleButton.target = self
        autoplayToggleButton.action = #selector(handleAutoplayToggle(_:))
        autoplayToggleButton.isBordered = false
        autoplayToggleButton.imagePosition = .imageOnly
        autoplayToggleButton.controlSize = .small
        autoplayToggleButton.setButtonType(.momentaryPushIn)
        autoplayToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        autoplayToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        syncAutoplayPreferenceUI()

        volumePercentLabel.translatesAutoresizingMaskIntoConstraints = false
        volumePercentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumePercentLabel.alignment = .right

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.target = self
        volumeSlider.action = #selector(handleVolumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.doubleValue = 1
        engine.setAudioGain(1)
        updateVolumePercentLabel(for: 1)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 20, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor

        let volumeControls = NSStackView(views: [volumeSlider, volumePercentLabel])
        volumeControls.orientation = .horizontal
        volumeControls.alignment = .centerY
        volumeControls.distribution = .fill
        volumeControls.spacing = 4
        volumeControls.translatesAutoresizingMaskIntoConstraints = false
        volumeControls.setContentHuggingPriority(.required, for: .horizontal)
        volumeControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        let timeControls = NSStackView(views: [timeLabel])
        timeControls.orientation = .horizontal
        timeControls.alignment = .centerY
        timeControls.distribution = .fill
        timeControls.spacing = 0
        timeControls.translatesAutoresizingMaskIntoConstraints = false
        timeControls.setContentHuggingPriority(.required, for: .horizontal)
        timeControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        inlineTimelineView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inlineTimelineView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlsRow = NSStackView(views: [inlineTimelineView, addBookmarkButton, loopToggleButton, autoplayToggleButton, volumeControls, timeControls])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.distribution = .fill
        controlsRow.spacing = 16
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(playerView)
        content.addSubview(emptyStateLabel)
        content.addSubview(controlsRow)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            controlsRow.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 6),
            controlsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controlsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controlsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            inlineTimelineView.heightAnchor.constraint(equalToConstant: 36),

            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),

            emptyStateLabel.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: playerView.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: playerView.trailingAnchor, constant: -16),
            volumeSlider.widthAnchor.constraint(equalToConstant: 110),
            volumePercentLabel.widthAnchor.constraint(equalToConstant: 48),
            autoplayToggleButton.widthAnchor.constraint(equalToConstant: Self.autoplayToggleButtonLayoutWidth())
        ])

        updateControlState(hasVideo: false)

        root.keyHandler = { [weak self] event in
            self?.handleKey(event: event)
        }
        root.onFileURLsDropped = { [weak self] urls in
            guard let self else { return }
            let videoURL = urls.first(where: self.isVideoURL(_:))
            guard let videoURL else { return }
            self.openVideo(url: videoURL)
        }
        installEscCloseMonitor()
    }

    private func bindEngine() {
        engine.onPositionUpdate = { [weak self] position in
            guard let self else { return }
            if abs(position.duration - self.lastKnownDuration) > 0.01 {
                self.lastKnownDuration = position.duration
                self.synchronizeSelectionState(for: position.duration)
                self.applyPendingPlaybackRestorationIfPossible(duration: position.duration)
                self.applyPendingBookmarkNavigationIfPossible(duration: position.duration)
            }
            self.updateTimelinePositionIfNeeded(position.seconds)
            self.updateTimeLabelIfNeeded(position.seconds, duration: position.duration)
            self.checkpointPlaybackStateIfNeeded(
                positionSeconds: position.seconds,
                duration: position.duration
            )
        }
        engine.onLoopModeUpdate = { [weak self] mode in
            guard let self else { return }
            switch mode {
            case .off:
                self.isLoopEnabled = false
            case .full:
                self.isLoopEnabled = true
            case .range:
                self.isLoopEnabled = true
            }
            self.updateLoopToggleButtonAppearance()
        }
    }

    private func installBookmarkObserver() {
        bookmarkChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarkStoreDidChange,
            object: bookmarkStore,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeCurrentClipBookmarks()
        }
    }

    private func handleKey(event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 12 {
            persistCurrentClipPlaybackStateIfNeeded(flushImmediately: true)
            NSApp.terminate(nil)
            return
        }

        let isShift = event.modifierFlags.contains(.shift)
        let isOption = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 53:
            closePreviewWindow()
        case 49:
            togglePlayPauseIfPossible()
        case 37:
            toggleSelectedLoop()
            playerView.flashStatusMessage(isLoopEnabled ? "Loop On" : "Loop Off")
        case 15:
            rotateClockwise()
            playerView.flashStatusMessage("Rotation \(currentRotationDegrees)°")
        case 123:
            let amount = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: -amount))
            persistCurrentClipPlaybackStateIfNeeded()
        case 124:
            let amount = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: amount))
            persistCurrentClipPlaybackStateIfNeeded()
        case 126:
            if isShift {
                engine.handle(command: .seekFrame(delta: 1))
                persistCurrentClipPlaybackStateIfNeeded()
            } else if isOption {
                jumpToAdjacentBookmark(direction: 1)
            } else {
                onBookmarkNavigationRequested?(-1)
            }
        case 125:
            if isShift {
                engine.handle(command: .seekFrame(delta: -1))
                persistCurrentClipPlaybackStateIfNeeded()
            } else if isOption {
                jumpToAdjacentBookmark(direction: -1)
            } else {
                onBookmarkNavigationRequested?(1)
            }
        default:
            break
        }
    }

    func togglePlayPauseIfPossible() {
        guard engine.currentPlayer().currentItem != nil else { return }
        let wasPlaying = engine.currentPlayer().rate != 0
        engine.handle(command: .togglePlayPause)
        persistCurrentClipPlaybackStateIfNeeded()
        let symbolName = wasPlaying ? "pause.fill" : "play.fill"
        playerView.flashPlaybackIndicator(symbolName: symbolName)
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
        persistCurrentClipPlaybackStateIfNeeded(flushImmediately: true)
        engine.pause()
        window?.orderOut(nil)
    }

    private func clearLoadedVideoState() {
        bookmarkTimelineHoverPreview.hide()
        currentVideoURL = nil
        synchronizeCurrentClipBookmarks()
        selectedBookmarkID = nil
        lastKnownDuration = 0
        lastPersistedPlaybackPlayhead = nil
        lastPlaybackPersistenceUptime = 0
        lastRenderedPositionWholeSeconds = -1
        lastRenderedDurationWholeSeconds = -1
        lastTimelineUpdateUptime = 0
        pendingRestoredPlayhead = nil
        pendingRestoredLoopEnabled = nil
        pendingRestoredIsPlaying = nil
        pendingRestoredSelectedBookmarkID = nil
        pendingBookmarkNavigationTime = nil
        hasStoredSelectionForCurrentClip = false
        selectionStart = 0
        selectionEnd = 0
        timeLabel.stringValue = "00:00 / 00:00"
        emptyStateLabel.isHidden = false
        updateWindowTitle()
        synchronizeSelectionState(for: 0)
        updateControlState(hasVideo: false)
        onCurrentVideoURLChange?(nil)
    }

    private func handleInlineSelectionChange(start: PlaybackSeconds, end: PlaybackSeconds, shouldCommit: Bool) {
        let duration = engine.currentDurationSeconds()
        selectionStart = start
        selectionEnd = end
        synchronizeSelectionState(for: duration)
        guard shouldCommit else { return }
        refreshLoopForUpdatedSelection(shouldSeekIntoRange: true)
        persistCurrentSelectionIfNeeded()
    }

    @objc
    private func handleVolumeChanged(_ sender: NSSlider) {
        engine.setAudioGain(Float(sender.doubleValue))
        updateVolumePercentLabel(for: sender.doubleValue)
        persistCurrentClipPlaybackStateIfNeeded()
    }

    @objc
    private func handleLoopToggle(_ sender: Any?) {
        _ = sender
        guard engine.currentPlayer().currentItem != nil else { return }
        toggleSelectedLoop()
        playerView.flashStatusMessage(isLoopEnabled ? "Loop On" : "Loop Off")
    }

    @objc
    private func handleAutoplayToggle(_ sender: Any?) {
        _ = sender
        setAutoplayEnabled(!isAutoplayEnabled, showFeedback: true)
    }

    @objc
    private func handleAddBookmark(_ sender: Any?) {
        _ = sender
        guard let currentVideoURL else { return }
        let timeSeconds = engine.currentTimeSeconds()
        if let existing = bookmarkStore.bookmarkNearPosition(videoURL: currentVideoURL, timeSeconds: timeSeconds) {
            setSelectedBookmarkID(existing.id, persistPlaybackState: true)
            playerView.flashStatusMessage("Bookmark already added")
            onShowBookmarksRequested?(existing, true)
            return
        }
        let bookmark = bookmarkStore.addBookmark(
            videoURL: currentVideoURL,
            timeSeconds: timeSeconds
        )
        playerView.flashStatusMessage("Bookmark Added")
        onShowBookmarksRequested?(bookmark, false)
    }

    private func handlePlayerSurfaceClick() {
        togglePlayPauseIfPossible()
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

    private static func storeLastOpenedVideoURL(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.standardizedFileURL.path, forKey: lastOpenedVideoPathDefaultsKey)
    }

    private func storedSelection(for url: URL) -> ClipSelection? {
        loadClipSelectionStoreCacheIfNeeded()
        return clipSelectionStoreCache[url.path]
    }

    private func storeSelection(_ selection: ClipSelection, for url: URL) {
        loadClipSelectionStoreCacheIfNeeded()
        clipSelectionStoreCache[url.path] = selection
        scheduleSelectionStorePersist()
    }

    private func storedClipPlaybackState(for url: URL) -> ClipPlaybackState? {
        loadClipPlaybackStoreCacheIfNeeded()
        return clipPlaybackStoreCache[url.path]
    }

    private func storeClipPlaybackState(_ state: ClipPlaybackState, for url: URL) {
        loadClipPlaybackStoreCacheIfNeeded()
        clipPlaybackStoreCache[url.path] = state
        schedulePlaybackStorePersist()
    }

    private func restoreSelection(for url: URL, duration: PlaybackSeconds) {
        let clampedDuration = max(duration, 0)
        if let stored = storedSelection(for: url) {
            hasStoredSelectionForCurrentClip = true
            selectionStart = max(stored.start, 0)
            if clampedDuration > 0 {
                selectionEnd = min(max(stored.end, selectionStart), clampedDuration)
            } else {
                selectionEnd = max(stored.end, selectionStart)
            }
        } else {
            hasStoredSelectionForCurrentClip = false
            selectionStart = 0
            selectionEnd = clampedDuration
        }

        synchronizeSelectionState(for: clampedDuration)
    }

    private func restoreClipPlaybackState(for url: URL, duration: PlaybackSeconds) {
        let restored = storedClipPlaybackState(for: url)

        if let restored {
            restoreWindowFrameIfNeeded(restored.windowFrame)
            let clampedVolume = min(max(restored.volume, 0), maxVolumeGain)
            volumeSlider.doubleValue = clampedVolume
            engine.setAudioGain(Float(clampedVolume))
            updateVolumePercentLabel(for: clampedVolume)
            pendingRestoredPlayhead = max(restored.playhead, 0)
            pendingRestoredLoopEnabled = restored.isLoopEnabled
            pendingRestoredIsPlaying = isAutoplayEnabled ? restored.isPlaying : false
            pendingRestoredSelectedBookmarkID = restored.selectedBookmarkID
        } else {
            volumeSlider.doubleValue = 1
            engine.setAudioGain(1)
            updateVolumePercentLabel(for: 1)
            pendingRestoredPlayhead = nil
            pendingRestoredLoopEnabled = true
            pendingRestoredIsPlaying = isAutoplayEnabled
            pendingRestoredSelectedBookmarkID = nil
        }

        applyPendingPlaybackRestorationIfPossible(duration: duration)
    }

    private func updateVolumePercentLabel(for gain: Double) {
        guard gain.isFinite else { return }
        let percent = gain * 100
        let percent1 = (percent * 10).rounded() / 10
        if abs(percent1 - percent1.rounded()) < 0.0001 {
            volumePercentLabel.stringValue = "\(Int(percent1.rounded()))%"
        } else {
            volumePercentLabel.stringValue = String(format: "%.1f%%", percent1)
        }
    }

    private func applyPendingPlaybackRestorationIfPossible(duration: PlaybackSeconds) {
        guard duration > 0 else { return }

        if let pendingRestoredPlayhead {
            let clamped = min(max(pendingRestoredPlayhead, 0), duration)
            self.pendingRestoredPlayhead = nil
            engine.handle(command: .seekTo(seconds: clamped))
            inlineTimelineView.currentPosition = clamped
        }

        if let pendingRestoredLoopEnabled {
            self.pendingRestoredLoopEnabled = nil
            isLoopEnabled = pendingRestoredLoopEnabled
            applyLoopPreferenceForCurrentClip()
            updateLoopToggleButtonAppearance()
        }

        if let pendingRestoredIsPlaying {
            self.pendingRestoredIsPlaying = nil
            if pendingRestoredIsPlaying {
                engine.play()
            } else {
                engine.pause()
            }
        }

        if let pendingRestoredSelectedBookmarkID {
            self.pendingRestoredSelectedBookmarkID = nil
            setSelectedBookmarkID(pendingRestoredSelectedBookmarkID)
        }
    }

    private func applyPendingBookmarkNavigationIfPossible(duration: PlaybackSeconds) {
        guard duration > 0, let pendingBookmarkNavigationTime else { return }
        self.pendingBookmarkNavigationTime = nil
        seekToBookmarkTime(pendingBookmarkNavigationTime, duration: duration)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistCurrentClipPlaybackStateIfNeeded(flushImmediately: true)
        engine.pause()
        return true
    }

    func windowDidMove(_ notification: Notification) {
        _ = notification
        persistCurrentClipPlaybackStateIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        persistCurrentClipPlaybackStateIfNeeded()
    }

    func openBookmark(_ bookmark: Bookmark) {
        let targetURL = bookmark.videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            playerView.flashStatusMessage("Bookmark File Missing")
            return
        }
        window?.orderFront(nil)
        setSelectedBookmarkID(bookmark.id, persistPlaybackState: true)

        if currentVideoURL?.path != targetURL.path {
            pendingBookmarkNavigationTime = bookmark.timeSeconds
            openVideo(url: targetURL, shouldRevealWindow: false)
            setSelectedBookmarkID(bookmark.id, persistPlaybackState: true)
            applyPendingBookmarkNavigationIfPossible(duration: engine.currentDurationSeconds())
            return
        }

        let duration = engine.currentDurationSeconds()
        seekToBookmarkTime(bookmark.timeSeconds, duration: duration, statusMessage: "Jumped to Bookmark")
    }

    private func synchronizeCurrentClipBookmarks() {
        guard let currentVideoURL else {
            currentClipBookmarks = []
            inlineTimelineView.bookmarks = []
            inlineTimelineView.selectedBookmarkID = nil
            return
        }

        let normalizedVideoPath = currentVideoURL.standardizedFileURL.path
        currentClipBookmarks = bookmarkStore.allBookmarks(visibility: .all)
            .lazy
            .filter { $0.videoPath == normalizedVideoPath }
            .map { BookmarkTimelineMarker(id: $0.id, timeSeconds: $0.timeSeconds) }
            .filter { $0.timeSeconds.isFinite && $0.timeSeconds >= 0 }
            .sorted()
        if let selectedBookmarkID,
           !currentClipBookmarks.contains(where: { $0.id == selectedBookmarkID }) {
            setSelectedBookmarkID(nil)
        }
        inlineTimelineView.bookmarks = currentClipBookmarks
        inlineTimelineView.selectedBookmarkID = selectedBookmarkID
    }

    private func showTimelineBookmarkHoverPreview(bookmarkID: BookmarkID, anchorRectInWindow: NSRect) {
        guard
            let url = currentVideoURL,
            let bookmark = bookmarkStore.bookmark(for: bookmarkID)
        else {
            bookmarkTimelineHoverPreview.hide()
            return
        }
        guard bookmark.videoPath == url.standardizedFileURL.path else {
            bookmarkTimelineHoverPreview.hide()
            return
        }
        bookmarkTimelineHoverPreview.show(
            bookmark: bookmark,
            anchorRectInWindow: anchorRectInWindow,
            parentWindow: window
        )
    }

    private func setSelectedBookmarkID(_ bookmarkID: BookmarkID?, persistPlaybackState: Bool = false) {
        guard selectedBookmarkID != bookmarkID else {
            return
        }
        selectedBookmarkID = bookmarkID
        inlineTimelineView.selectedBookmarkID = bookmarkID
        if persistPlaybackState {
            persistCurrentClipPlaybackStateIfNeeded()
        }
    }

    private func jumpToAdjacentBookmark(direction: Int) {
        let currentClipBookmarkTimes = currentClipBookmarks.map(\.timeSeconds)
        guard !currentClipBookmarkTimes.isEmpty else {
            playerView.flashStatusMessage("No Bookmarks")
            return
        }

        let currentPosition = engine.currentTimeSeconds()
        let epsilon: PlaybackSeconds = 0.05
        let targetTime: PlaybackSeconds?

        if direction < 0 {
            targetTime = currentClipBookmarkTimes.last(where: { $0 < (currentPosition - epsilon) })
        } else {
            targetTime = currentClipBookmarkTimes.first(where: { $0 > (currentPosition + epsilon) })
        }

        guard let targetTime else {
            playerView.flashStatusMessage(direction < 0 ? "No Previous Bookmark" : "No Next Bookmark")
            return
        }

        seekToBookmarkTime(
            targetTime,
            statusMessage: direction < 0 ? "Previous Bookmark" : "Next Bookmark"
        )
    }

    private func seekToBookmarkTime(
        _ timeSeconds: PlaybackSeconds,
        duration: PlaybackSeconds? = nil,
        statusMessage: String? = nil
    ) {
        let currentDuration = duration ?? engine.currentDurationSeconds()
        let clampedTime = currentDuration > 0
            ? min(max(timeSeconds, 0), currentDuration)
            : max(timeSeconds, 0)
        engine.handle(command: .seekTo(seconds: clampedTime))
        inlineTimelineView.currentPosition = clampedTime
        if isAutoplayEnabled {
            engine.play()
        } else {
            engine.pause()
        }
        persistCurrentClipPlaybackStateIfNeeded()
        if let statusMessage {
            playerView.flashStatusMessage(statusMessage)
        }
    }

    private func handleBookmarkMarkerDrag(
        bookmarkID: BookmarkID,
        seconds: PlaybackSeconds,
        shouldCommit: Bool
    ) {
        let duration = max(engine.currentDurationSeconds(), 0)
        let clampedTime = duration > 0
            ? min(max(seconds, 0), duration)
            : max(seconds, 0)
        updateBookmarkMarkerTime(bookmarkID: bookmarkID, timeSeconds: clampedTime)
        inlineTimelineView.currentPosition = clampedTime
        timeLabel.stringValue = "\(Self.format(clampedTime)) / \(Self.format(duration))"

        if shouldCommit {
            engine.endScrubbing(at: clampedTime)
            if wasPlayingBeforeBookmarkDrag {
                engine.play()
            } else {
                engine.pause()
            }
            wasPlayingBeforeBookmarkDrag = false
            bookmarkStore.updateTimeSeconds(
                for: bookmarkID,
                timeSeconds: clampedTime,
                syncThumbnailToBookmarkTime: true
            )
            persistCurrentClipPlaybackStateIfNeeded()
            playerView.flashStatusMessage("Bookmark Updated")
            return
        }

        engine.scrub(to: clampedTime)
    }

    private func updateBookmarkMarkerTime(bookmarkID: BookmarkID, timeSeconds: PlaybackSeconds) {
        guard let bookmarkIndex = currentClipBookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }
        currentClipBookmarks[bookmarkIndex] = BookmarkTimelineMarker(id: bookmarkID, timeSeconds: timeSeconds)
        currentClipBookmarks.sort()
        inlineTimelineView.bookmarks = currentClipBookmarks
        inlineTimelineView.selectedBookmarkID = selectedBookmarkID
    }

    private func updateTimelinePositionIfNeeded(_ positionSeconds: PlaybackSeconds) {
        guard
            !inlineTimelineView.isDraggingPlayhead,
            !inlineTimelineView.isDraggingSelectionHandle,
            !inlineTimelineView.isDraggingBookmarkMarker
        else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isRefreshWindowElapsed = (now - lastTimelineUpdateUptime) >= timelineRefreshInterval
        let isLargePositionJump = abs(positionSeconds - inlineTimelineView.currentPosition) > 0.2
        guard isRefreshWindowElapsed || isLargePositionJump else {
            return
        }
        inlineTimelineView.currentPosition = positionSeconds
        lastTimelineUpdateUptime = now
    }

    private func updateTimeLabelIfNeeded(_ positionSeconds: PlaybackSeconds, duration: PlaybackSeconds) {
        let positionWholeSeconds = max(Int(positionSeconds.rounded(.down)), 0)
        let durationWholeSeconds = max(Int(duration.rounded(.down)), 0)
        guard
            positionWholeSeconds != lastRenderedPositionWholeSeconds
                || durationWholeSeconds != lastRenderedDurationWholeSeconds
        else {
            return
        }
        lastRenderedPositionWholeSeconds = positionWholeSeconds
        lastRenderedDurationWholeSeconds = durationWholeSeconds
        timeLabel.stringValue = "\(Self.format(positionSeconds)) / \(Self.format(duration))"
    }

    private func checkpointPlaybackStateIfNeeded(
        positionSeconds: PlaybackSeconds,
        duration: PlaybackSeconds
    ) {
        guard currentVideoURL != nil else { return }
        guard
            !inlineTimelineView.isDraggingPlayhead,
            !inlineTimelineView.isDraggingSelectionHandle,
            !inlineTimelineView.isDraggingBookmarkMarker
        else {
            return
        }

        let clampedPosition = duration > 0
            ? min(max(positionSeconds, 0), duration)
            : max(positionSeconds, 0)
        let intervalElapsed = (ProcessInfo.processInfo.systemUptime - lastPlaybackPersistenceUptime) >= playbackCheckpointInterval
        let movedEnough = lastPersistedPlaybackPlayhead.map {
            abs(clampedPosition - $0) >= playbackCheckpointMinimumDelta
        } ?? true

        guard intervalElapsed && movedEnough else { return }
        persistCurrentClipPlaybackStateIfNeeded()
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
    private func applySelectedLoop(shouldStartPlayback: Bool) -> Bool {
        guard let range = normalizedSelectionRange() else {
            return false
        }
        engine.setLoopRange(start: range.start, end: range.end)
        if shouldStartPlayback {
            engine.handle(command: .seekTo(seconds: range.start))
            engine.play()
        }
        return true
    }

    private func normalizedSelectionRange() -> (start: PlaybackSeconds, end: PlaybackSeconds)? {
        let duration = engine.currentDurationSeconds()
        guard duration > 0 else {
            return nil
        }
        let lower = min(max(selectionStart, 0), duration)
        let upper = min(max(selectionEnd, lower), duration)
        guard upper - lower > 0.001 else {
            return nil
        }
        return (lower, upper)
    }

    private func synchronizeSelectionState(for duration: PlaybackSeconds) {
        let clampedDuration = max(duration, 0)
        if clampedDuration <= 0 {
            inlineTimelineView.duration = 1
            inlineTimelineView.currentPosition = min(max(engine.currentTimeSeconds(), 0), 1)
            inlineTimelineView.selectionStart = min(max(selectionStart, 0), 1)
            inlineTimelineView.selectionEnd = min(max(selectionEnd, 0), 1)
            return
        }

        if !hasStoredSelectionForCurrentClip && clampedDuration > 0 && selectionEnd <= 0 {
            selectionEnd = clampedDuration
        }

        selectionStart = min(max(selectionStart, 0), clampedDuration)
        selectionEnd = min(max(selectionEnd, selectionStart), clampedDuration)

        inlineTimelineView.duration = clampedDuration
        inlineTimelineView.selectionStart = selectionStart
        inlineTimelineView.selectionEnd = selectionEnd
    }

    private func persistCurrentSelectionIfNeeded() {
        guard let currentVideoURL, let range = normalizedSelectionRange() else {
            return
        }
        hasStoredSelectionForCurrentClip = true
        storeSelection(ClipSelection(start: range.start, end: range.end), for: currentVideoURL)
    }

    private func refreshLoopForUpdatedSelection(shouldSeekIntoRange: Bool) {
        guard isLoopEnabled else { return }
        guard applySelectedLoop(shouldStartPlayback: false) else {
            engine.clearLoop()
            return
        }

        let current = engine.currentTimeSeconds()
        if shouldSeekIntoRange, let range = normalizedSelectionRange(), current < range.start || current > range.end {
            engine.handle(command: .seekTo(seconds: range.start))
        }
    }

    private func toggleSelectedLoop() {
        setLoopEnabled(!isLoopEnabled)
    }

    private func persistCurrentClipPlaybackStateIfNeeded(flushImmediately: Bool = false) {
        guard let currentVideoURL else { return }
        persistCurrentSelectionIfNeeded()
        let state = ClipPlaybackState(
            playhead: max(engine.currentTimeSeconds(), 0),
            volume: min(max(volumeSlider.doubleValue, 0), maxVolumeGain),
            isLoopEnabled: isLoopEnabled,
            isPlaying: engine.currentPlayer().rate != 0,
            selectedBookmarkID: selectedBookmarkID,
            windowFrame: currentPersistableWindowFrame()
        )
        lastPersistedPlaybackPlayhead = state.playhead
        lastPlaybackPersistenceUptime = ProcessInfo.processInfo.systemUptime
        storeClipPlaybackState(state, for: currentVideoURL)
        if flushImmediately {
            flushPendingPersistedStateWrites(blocking: false)
        }
    }

    private func updateControlState(hasVideo: Bool) {
        inlineTimelineView.isControlEnabled = hasVideo
        addBookmarkButton.isEnabled = hasVideo
        loopToggleButton.isEnabled = hasVideo
        addBookmarkButton.contentTintColor = hasVideo ? .controlAccentColor : .tertiaryLabelColor
        updateLoopToggleButtonAppearance()
        syncAutoplayPreferenceUI()
    }

    private func syncAutoplayPreferenceUI() {
        let symbolName = isAutoplayEnabled ? "play.circle.fill" : "play.slash"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isAutoplayEnabled ? "Autoplay On" : "Autoplay Off"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        image?.isTemplate = true
        autoplayToggleButton.image = image
        autoplayToggleButton.contentTintColor = isAutoplayEnabled ? .controlAccentColor : .tertiaryLabelColor
        autoplayToggleButton.toolTip = isAutoplayEnabled
            ? "Autoplay On — click to turn off"
            : "Autoplay Off — click to turn on"
    }

    private func updateLoopToggleButtonAppearance() {
        let symbolName = isLoopEnabled ? "repeat.circle.fill" : "repeat.circle"
        loopToggleButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isLoopEnabled ? "Loop On" : "Loop Off"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        loopToggleButton.image?.isTemplate = true
        loopToggleButton.contentTintColor = isLoopEnabled ? .controlAccentColor : .tertiaryLabelColor
        loopToggleButton.toolTip = isLoopEnabled ? "Loop On — click to turn off" : "Loop Off — click to turn on"
    }

    private func applyLoopPreferenceForCurrentClip() {
        guard engine.currentPlayer().currentItem != nil else { return }
        if isLoopEnabled {
            if !applySelectedLoop(shouldStartPlayback: false) {
                engine.setLoopFull(enabled: true)
            }
            return
        }
        engine.clearLoop()
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func currentPersistableWindowFrame() -> ClipWindowFrame? {
        guard let window else { return nil }
        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return ClipWindowFrame(
            originX: frame.origin.x,
            originY: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    private func restoreWindowFrameIfNeeded(_ storedFrame: ClipWindowFrame?) {
        guard let window, let storedFrame else { return }
        let minimumSize = window.minSize
        var frame = storedFrame.rect
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = max(frame.height, minimumSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let maxWidth = max(visibleFrame.width, minimumSize.width)
            let maxHeight = max(visibleFrame.height, minimumSize.height)
            frame.size.width = min(frame.width, maxWidth)
            frame.size.height = min(frame.height, maxHeight)
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }

        window.setFrame(frame, display: true)
    }

    private func loadClipSelectionStoreCacheIfNeeded() {
        guard !hasLoadedClipSelectionStoreCache else { return }
        hasLoadedClipSelectionStoreCache = true
        let defaults = UserDefaults.standard
        guard
            let data = defaults.data(forKey: Self.clipSelectionDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: ClipSelection].self, from: data)
        else {
            clipSelectionStoreCache = [:]
            return
        }
        clipSelectionStoreCache = decoded
    }

    private func loadClipPlaybackStoreCacheIfNeeded() {
        guard !hasLoadedClipPlaybackStoreCache else { return }
        hasLoadedClipPlaybackStoreCache = true
        let defaults = UserDefaults.standard
        guard
            let data = defaults.data(forKey: Self.clipPlaybackDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: ClipPlaybackState].self, from: data)
        else {
            clipPlaybackStoreCache = [:]
            return
        }
        clipPlaybackStoreCache = decoded
    }

    private func scheduleSelectionStorePersist() {
        persistSelectionWorkItem?.cancel()
        let snapshot = clipSelectionStoreCache
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistSelectionWorkItem = nil
            self.selectionPersistenceQueue.async { [weak self] in
                self?.persistSelectionSnapshot(snapshot)
            }
        }
        persistSelectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func schedulePlaybackStorePersist() {
        persistPlaybackWorkItem?.cancel()
        let snapshot = clipPlaybackStoreCache
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistPlaybackWorkItem = nil
            self.playbackPersistenceQueue.async { [weak self] in
                self?.persistPlaybackSnapshot(snapshot)
            }
        }
        persistPlaybackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func flushPendingPersistedStateWrites(blocking: Bool = false) {
        if let workItem = persistSelectionWorkItem {
            workItem.cancel()
            persistSelectionWorkItem = nil
            let snapshot = clipSelectionStoreCache
            if blocking {
                selectionPersistenceQueue.sync {
                    persistSelectionSnapshot(snapshot)
                }
            } else {
                selectionPersistenceQueue.async { [weak self] in
                    self?.persistSelectionSnapshot(snapshot)
                }
            }
        }
        if let workItem = persistPlaybackWorkItem {
            workItem.cancel()
            persistPlaybackWorkItem = nil
            let snapshot = clipPlaybackStoreCache
            if blocking {
                playbackPersistenceQueue.sync {
                    persistPlaybackSnapshot(snapshot)
                }
            } else {
                playbackPersistenceQueue.async { [weak self] in
                    self?.persistPlaybackSnapshot(snapshot)
                }
            }
        }
        if blocking {
            selectionPersistenceQueue.sync {}
            playbackPersistenceQueue.sync {}
        }
    }

    private func persistSelectionSnapshot(_ snapshot: [String: ClipSelection]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.clipSelectionDefaultsKey)
        }
    }

    private func persistPlaybackSnapshot(_ snapshot: [String: ClipPlaybackState]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.clipPlaybackDefaultsKey)
        }
    }
}

private final class BookmarkTimelineMarkerHoverPreviewController {
    private final class PreviewPanel: NSPanel {
        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }

    private let thumbnailService: VideoThumbnailService
    private let panel: PreviewPanel
    private let previewImageView = NSImageView(frame: .zero)
    private let contentView = NSView(frame: .zero)
    private var activeBookmarkID: BookmarkID?
    private var hasLoadedHighRes = false
    private var lastAnchorRectInWindow = NSRect.zero
    private weak var lastParentWindow: NSWindow?

    init(thumbnailService: VideoThumbnailService) {
        self.thumbnailService = thumbnailService
        let contentRect = NSRect(x: 0, y: 0, width: 320, height: 200)
        panel = PreviewPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.layer?.masksToBounds = true
        contentView.addSubview(previewImageView)
        panel.contentView = contentView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
    }

    func show(bookmark: Bookmark, anchorRectInWindow: NSRect, parentWindow: NSWindow?) {
        activeBookmarkID = bookmark.id
        hasLoadedHighRes = false
        lastAnchorRectInWindow = anchorRectInWindow
        lastParentWindow = parentWindow
        let captureBookmarkID = bookmark.id
        previewImageView.image = Self.placeholderImage
        applyContentSize(for: Self.placeholderImage, parentWindow: parentWindow)
        positionPanel(anchorRectInWindow: anchorRectInWindow, parentWindow: parentWindow)
        panel.orderFront(nil)

        thumbnailService.requestThumbnail(
            for: bookmark.videoURL,
            at: bookmark.effectiveThumbnailTimeSeconds,
            maximumSize: CGSize(width: 256, height: 144)
        ) { [weak self] image in
            guard let self, self.activeBookmarkID == captureBookmarkID else { return }
            let resolved = image ?? Self.placeholderImage
            self.previewImageView.image = resolved
            self.applyContentSize(for: resolved, parentWindow: self.lastParentWindow)
            self.positionPanel(
                anchorRectInWindow: self.lastAnchorRectInWindow,
                parentWindow: self.lastParentWindow
            )
            self.requestHighResolutionPreview(bookmark: bookmark, captureBookmarkID: captureBookmarkID)
        }
    }

    func reposition(anchorRectInWindow: NSRect, parentWindow: NSWindow?) {
        lastAnchorRectInWindow = anchorRectInWindow
        lastParentWindow = parentWindow ?? lastParentWindow
        guard activeBookmarkID != nil, panel.isVisible else { return }
        positionPanel(anchorRectInWindow: anchorRectInWindow, parentWindow: parentWindow)
    }

    func hide() {
        panel.orderOut(nil)
        activeBookmarkID = nil
        hasLoadedHighRes = false
    }

    private func requestHighResolutionPreview(bookmark: Bookmark, captureBookmarkID: BookmarkID) {
        guard !hasLoadedHighRes else { return }
        hasLoadedHighRes = true
        thumbnailService.requestThumbnail(
            for: bookmark.videoURL,
            at: bookmark.effectiveThumbnailTimeSeconds,
            maximumSize: nil
        ) { [weak self] image in
            guard let self, self.activeBookmarkID == captureBookmarkID, let image else { return }
            self.previewImageView.image = image
            self.applyContentSize(for: image, parentWindow: self.lastParentWindow)
            self.positionPanel(
                anchorRectInWindow: self.lastAnchorRectInWindow,
                parentWindow: self.lastParentWindow
            )
        }
    }

    private func applyContentSize(for image: NSImage, parentWindow: NSWindow?) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            setPanelContentSize(NSSize(width: 294, height: 174))
            return
        }
        let screenFrame = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxContentWidth = max(240, floor((screenFrame?.width ?? 1080) * 0.22))
        let maxContentHeight = max(135, floor((screenFrame?.height ?? 720) * 0.22))
        let widthScale = maxContentWidth / imageSize.width
        let heightScale = maxContentHeight / imageSize.height
        let scale = min(widthScale, heightScale, 1)
        let contentWidth = max(240, floor(imageSize.width * scale))
        let contentHeight = max(135, floor(imageSize.height * scale))
        setPanelContentSize(NSSize(width: contentWidth + 24, height: contentHeight + 24))
    }

    private func setPanelContentSize(_ size: NSSize) {
        contentView.setFrameSize(size)
        previewImageView.frame = contentView.bounds.insetBy(dx: 12, dy: 12)
        panel.setContentSize(size)
    }

    private func positionPanel(anchorRectInWindow: NSRect, parentWindow: NSWindow?) {
        let size = contentView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let screenFrame = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let anchorScreen = parentWindow?.convertToScreen(anchorRectInWindow) ?? anchorRectInWindow
        let gap: CGFloat = 8
        var x = anchorScreen.midX - (size.width / 2)
        var y = anchorScreen.maxY + gap
        x = min(max(screenFrame.minX, x), screenFrame.maxX - size.width)
        y = min(max(screenFrame.minY, y), screenFrame.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private static let placeholderImage: NSImage = {
        let size = NSSize(width: 128, height: 72)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let symbolRect = NSRect(x: 44, y: 20, width: 40, height: 32)
        if let symbol = NSImage(
            systemSymbolName: "bookmark.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) {
            symbol.draw(in: symbolRect)
        }
        image.unlockFocus()
        return image
    }()
}

private final class InlineSelectionTimelineView: NSView {
    enum DragTarget: Equatable {
        case playhead
        case startHandle
        case endHandle
        case bookmark(BookmarkID)
    }

    private struct PendingPrecisionActivation {
        let initialPoint: CGPoint
        var currentPoint: CGPoint
    }

    private struct PrecisionZoomState {
        let anchorValue: PlaybackSeconds
        let anchorPointX: CGFloat
    }

    var duration: PlaybackSeconds = 1 {
        didSet { updateLayerFrames() }
    }

    var currentPosition: PlaybackSeconds = 0 {
        didSet { updateLayerFrames() }
    }

    var selectionStart: PlaybackSeconds = 0 {
        didSet { updateLayerFrames() }
    }

    var selectionEnd: PlaybackSeconds = 1 {
        didSet { updateLayerFrames() }
    }

    var bookmarks: [BookmarkTimelineMarker] = [] {
        didSet {
            syncBookmarkMarkerLayers()
            updateLayerFrames()
        }
    }

    var selectedBookmarkID: BookmarkID? {
        didSet {
            updateAppearance()
            updateLayerFrames()
        }
    }

    var onSeekChanged: ((PlaybackSeconds) -> Void)?
    var onSeekEnded: ((PlaybackSeconds) -> Void)?
    var onSeekBegan: (() -> Void)?
    var onSelectionChange: ((PlaybackSeconds, PlaybackSeconds) -> Void)?
    var onSelectionCommit: ((PlaybackSeconds, PlaybackSeconds) -> Void)?
    var onSelectionPreviewBegan: (() -> Void)?
    var onSelectionPreviewChanged: ((PlaybackSeconds) -> Void)?
    var onSelectionPreviewEnded: (() -> Void)?
    var onBookmarkSelectionChange: ((BookmarkID?) -> Void)?
    var onBookmarkDragBegan: ((BookmarkID) -> Void)?
    var onBookmarkDragChanged: ((BookmarkID, PlaybackSeconds) -> Void)?
    var onBookmarkDragEnded: ((BookmarkID, PlaybackSeconds) -> Void)?
    var onBookmarkMarkerHoverEnter: ((BookmarkID, NSRect) -> Void)?
    var onBookmarkMarkerHoverExit: (() -> Void)?
    var onBookmarkMarkerHoverMove: ((BookmarkID, NSRect) -> Void)?

    var isDraggingPlayhead: Bool {
        dragTarget == .playhead
    }

    var isDraggingSelectionHandle: Bool {
        dragTarget == .startHandle || dragTarget == .endHandle
    }

    var isDraggingBookmarkMarker: Bool {
        if case .bookmark = dragTarget {
            return true
        }
        return false
    }

    override var isFlipped: Bool {
        true
    }

    var isControlEnabled: Bool = true {
        didSet {
            updateAppearance()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var dragTarget: DragTarget?
    private var pendingPrecisionActivation: PendingPrecisionActivation?
    private var precisionZoomState: PrecisionZoomState?
    private var precisionActivationWorkItem: DispatchWorkItem?
    private var hoveredBookmarkID: BookmarkID?
    private var hoverTrackingArea: NSTrackingArea?
    private let trackLayer = CALayer()
    private let selectionLayer = CALayer()
    private let playheadLayer = CALayer()
    private let startHandleLayer = CALayer()
    private let endHandleLayer = CALayer()
    private var bookmarkMarkerLayers: [CALayer] = []
    private let precisionActivationDelay: TimeInterval = 1.0
    private let precisionActivationMovementTolerance: CGFloat = 6
    private let precisionZoomFactor: PlaybackSeconds = 10
    private let minimumPrecisionVisibleDuration: PlaybackSeconds = 1
    private let maximumPrecisionVisibleDuration: PlaybackSeconds = 20
    private let precisionReferencePadding: PlaybackSeconds = 0.25

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard dragTarget == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateBookmarkHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        clearBookmarkHoverState()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isControlEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateBookmarkHover(at: point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        guard isControlEnabled else { return }

        for bookmark in bookmarks {
            addCursorRect(bookmarkHitRect(for: bookmark), cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else { return }
        clearBookmarkHoverState()
        let point = convert(event.locationInWindow, from: nil)
        clearPrecisionInteractionState()
        let resolvedTarget = resolvedDragTarget(for: point)

        if case let .bookmark(bookmarkID) = resolvedTarget, selectedBookmarkID != bookmarkID {
            selectedBookmarkID = bookmarkID
            onBookmarkSelectionChange?(bookmarkID)
            dragTarget = nil
            return
        }

        if !isBookmarkTarget(resolvedTarget), selectedBookmarkID != nil {
            selectedBookmarkID = nil
            onBookmarkSelectionChange?(nil)
        }

        dragTarget = resolvedTarget
        switch resolvedTarget {
        case .playhead:
            onSeekBegan?()
        case .startHandle, .endHandle:
            onSelectionPreviewBegan?()
        case let .bookmark(bookmarkID):
            selectedBookmarkID = bookmarkID
            onBookmarkSelectionChange?(bookmarkID)
            onBookmarkDragBegan?(bookmarkID)
        }
        beginPendingPrecisionActivation(at: point)
        updateDrag(with: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragTarget != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        cancelPendingPrecisionActivationIfNeeded(for: point)
        updateDrag(with: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragTarget != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateDrag(with: point, isFinal: true)
        if dragTarget == .startHandle || dragTarget == .endHandle {
            clearPrecisionInteractionState()
            onSelectionPreviewEnded?()
        } else {
            clearPrecisionInteractionState()
        }
        dragTarget = nil
        let hoverPoint = convert(event.locationInWindow, from: nil)
        updateBookmarkHover(at: hoverPoint)
    }

    private func configureLayers() {
        guard let rootLayer = layer else { return }

        trackLayer.cornerRadius = 4
        selectionLayer.cornerRadius = 4
        playheadLayer.cornerRadius = 2
        startHandleLayer.cornerRadius = 8
        endHandleLayer.cornerRadius = 8

        [trackLayer, selectionLayer, playheadLayer, startHandleLayer, endHandleLayer].forEach {
            $0.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
                "cornerRadius": NSNull()
            ]
            rootLayer.addSublayer($0)
        }
        updateAppearance()
    }

    private func updateAppearance() {
        let isPrecisionActive = precisionZoomState != nil
        trackLayer.backgroundColor = NSColor(
            calibratedRed: 0.18,
            green: 0.45,
            blue: 0.91,
            alpha: isControlEnabled ? (isPrecisionActive ? 0.68 : 0.45) : 0.2
        ).cgColor
        selectionLayer.backgroundColor = NSColor(
            calibratedRed: 0.27,
            green: 0.58,
            blue: 0.98,
            alpha: isControlEnabled ? (isPrecisionActive ? 1.0 : 0.95) : 0.35
        ).cgColor
        playheadLayer.backgroundColor = NSColor.white.withAlphaComponent(isControlEnabled ? 0.95 : 0.5).cgColor
        startHandleLayer.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: isControlEnabled ? 1 : 0.45).cgColor
        endHandleLayer.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: isControlEnabled ? 1 : 0.45).cgColor
        startHandleLayer.borderColor = NSColor(calibratedWhite: 0.2, alpha: isControlEnabled ? (isPrecisionActive ? 0.35 : 0.2) : 0.1).cgColor
        endHandleLayer.borderColor = NSColor(calibratedWhite: 0.2, alpha: isControlEnabled ? (isPrecisionActive ? 0.35 : 0.2) : 0.1).cgColor
        startHandleLayer.borderWidth = isPrecisionActive ? 1.5 : 1
        endHandleLayer.borderWidth = isPrecisionActive ? 1.5 : 1
        for (index, markerLayer) in bookmarkMarkerLayers.enumerated() {
            let bookmark = bookmarks[index]
            let isSelected = bookmark.id == selectedBookmarkID
            let markerColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(isControlEnabled ? 0.95 : 0.4).cgColor
                : NSColor.white.withAlphaComponent(isControlEnabled ? 0.78 : 0.35).cgColor
            markerLayer.backgroundColor = markerColor
            markerLayer.cornerRadius = isSelected ? 1.5 : 1
        }
    }

    private func updateLayerFrames() {
        syncBookmarkMarkerLayers()
        let trackRect = self.trackRect
        let visibleRange = timelineVisibleRange()
        trackLayer.frame = CGRect(x: trackRect.minX, y: trackRect.minY, width: max(trackRect.width, 0), height: trackRect.height)
        let clippedSelectionStart = max(selectionStart, visibleRange.lowerBound)
        let clippedSelectionEnd = min(selectionEnd, visibleRange.upperBound)
        if clippedSelectionEnd > clippedSelectionStart {
            selectionLayer.frame = CGRect(
                x: xPosition(for: clippedSelectionStart),
                y: trackRect.minY,
                width: abs(xPosition(for: clippedSelectionEnd) - xPosition(for: clippedSelectionStart)),
                height: trackRect.height
            )
            selectionLayer.isHidden = false
        } else {
            selectionLayer.frame = .zero
            selectionLayer.isHidden = precisionZoomState != nil
        }

        let playheadWidth: CGFloat = precisionZoomState != nil ? 5 : 4
        playheadLayer.frame = CGRect(
            x: xPosition(for: currentPosition) - (playheadWidth / 2),
            y: trackRect.midY - 9,
            width: playheadWidth,
            height: 18
        )
        startHandleLayer.frame = handleRect(at: startX)
        endHandleLayer.frame = handleRect(at: endX)
        playheadLayer.isHidden = !isMarkerVisible(currentPosition, in: visibleRange, marker: .playhead)
        startHandleLayer.isHidden = !isMarkerVisible(selectionStart, in: visibleRange, marker: .startHandle)
        endHandleLayer.isHidden = !isMarkerVisible(selectionEnd, in: visibleRange, marker: .endHandle)
        let epsilon: PlaybackSeconds = 0.0001
        for (index, markerLayer) in bookmarkMarkerLayers.enumerated() {
            let bookmark = bookmarks[index]
            let isVisible = bookmark.timeSeconds >= (visibleRange.lowerBound - epsilon)
                && bookmark.timeSeconds <= (visibleRange.upperBound + epsilon)
            markerLayer.isHidden = !isVisible
            guard isVisible else {
                markerLayer.frame = .zero
                continue
            }
            markerLayer.frame = bookmarkRect(for: bookmark)
        }
        updateLayerOrdering()
        window?.invalidateCursorRects(for: self)
        if let hoveredBookmarkID, let bookmark = bookmarks.first(where: { $0.id == hoveredBookmarkID }) {
            let rectInWindow = convert(bookmarkRect(for: bookmark), to: nil)
            onBookmarkMarkerHoverMove?(hoveredBookmarkID, rectInWindow)
        }
    }

    private var trackRect: CGRect {
        let height: CGFloat = precisionZoomState != nil ? 10 : 8
        return CGRect(
            x: 18,
            y: (bounds.height - height) / 2,
            width: max(bounds.width - 36, 0),
            height: height
        )
    }

    private var startX: CGFloat {
        xPosition(for: selectionStart)
    }

    private var endX: CGFloat {
        xPosition(for: selectionEnd)
    }

    private func xPosition(for value: PlaybackSeconds) -> CGFloat {
        let visibleRange = timelineVisibleRange()
        let visibleDuration = max(visibleRange.upperBound - visibleRange.lowerBound, 0.0001)
        let progress = min(max((value - visibleRange.lowerBound) / visibleDuration, 0), 1)
        return trackRect.minX + (trackRect.width * progress)
    }

    private func seconds(for point: CGPoint) -> PlaybackSeconds {
        let visibleRange = timelineVisibleRange()
        let visibleDuration = max(visibleRange.upperBound - visibleRange.lowerBound, 0)
        let clampedX = min(max(point.x, trackRect.minX), trackRect.maxX)
        let progress = (clampedX - trackRect.minX) / max(trackRect.width, 1)
        return visibleRange.lowerBound + (PlaybackSeconds(progress) * visibleDuration)
    }

    private func handleRect(at x: CGFloat) -> CGRect {
        CGRect(x: x - 8, y: trackRect.midY - 14, width: 16, height: 28)
    }

    private func bookmarkRect(for bookmark: BookmarkTimelineMarker) -> CGRect {
        let isSelected = bookmark.id == selectedBookmarkID
        let width: CGFloat = isSelected ? 5 : 4
        let height: CGFloat = isSelected ? 11 : 9
        return CGRect(
            x: xPosition(for: bookmark.timeSeconds) - (width / 2),
            y: max(trackRect.minY - height - 1, 1),
            width: width,
            height: height
        )
    }

    private func bookmarkHitRect(for bookmark: BookmarkTimelineMarker) -> CGRect {
        bookmarkRect(for: bookmark).insetBy(dx: -8, dy: -7)
    }

    private func playheadRect(at x: CGFloat) -> CGRect {
        CGRect(x: x - 4, y: trackRect.midY - 10, width: 8, height: 20)
    }

    private func currentValue(for target: DragTarget) -> PlaybackSeconds {
        switch target {
        case .playhead:
            return currentPosition
        case .startHandle:
            return selectionStart
        case .endHandle:
            return selectionEnd
        case let .bookmark(bookmarkID):
            return bookmarks.first(where: { $0.id == bookmarkID })?.timeSeconds ?? currentPosition
        }
    }

    private func beginPendingPrecisionActivation(at point: CGPoint) {
        pendingPrecisionActivation = PendingPrecisionActivation(initialPoint: point, currentPoint: point)
        let workItem = DispatchWorkItem { [weak self] in
            self?.activatePrecisionMode()
        }
        precisionActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + precisionActivationDelay, execute: workItem)
    }

    private func cancelPendingPrecisionActivationIfNeeded(for point: CGPoint) {
        guard let pendingPrecisionActivation, precisionZoomState == nil else { return }
        let deltaX = point.x - pendingPrecisionActivation.initialPoint.x
        let deltaY = point.y - pendingPrecisionActivation.initialPoint.y
        let distance = hypot(deltaX, deltaY)
        guard distance > precisionActivationMovementTolerance else {
            self.pendingPrecisionActivation?.currentPoint = point
            return
        }
        cancelPendingPrecisionActivation()
    }

    private func cancelPendingPrecisionActivation() {
        precisionActivationWorkItem?.cancel()
        precisionActivationWorkItem = nil
        pendingPrecisionActivation = nil
    }

    private func activatePrecisionMode() {
        guard let dragTarget, let pendingPrecisionActivation else { return }
        precisionActivationWorkItem = nil
        precisionZoomState = PrecisionZoomState(
            anchorValue: currentValue(for: dragTarget),
            anchorPointX: min(max(pendingPrecisionActivation.currentPoint.x, trackRect.minX), trackRect.maxX)
        )
        self.pendingPrecisionActivation = nil
        updateAppearance()
        updateLayerFrames()
    }

    private func clearPrecisionInteractionState() {
        cancelPendingPrecisionActivation()
        precisionZoomState = nil
        updateAppearance()
        updateLayerFrames()
    }

    private func timelineVisibleRange() -> ClosedRange<PlaybackSeconds> {
        guard duration > 0 else { return 0...1 }
        guard let precisionZoomState, let dragTarget else { return 0...duration }

        let baseVisibleDuration = min(
            max(duration / precisionZoomFactor, minimumPrecisionVisibleDuration),
            min(duration, maximumPrecisionVisibleDuration)
        )
        let trackWidth = max(trackRect.width, 1)
        let anchorProgress = min(max((precisionZoomState.anchorPointX - trackRect.minX) / trackWidth, 0), 1)
        let visibleDuration = precisionVisibleDuration(
            for: precisionZoomState.anchorValue,
            anchorProgress: anchorProgress,
            dragTarget: dragTarget,
            baseVisibleDuration: baseVisibleDuration
        )
        guard visibleDuration < duration else { return 0...duration }

        let proposedStart = precisionZoomState.anchorValue - (visibleDuration * PlaybackSeconds(anchorProgress))

        let maximumStart = max(duration - visibleDuration, 0)
        let clampedStart = min(max(proposedStart, 0), maximumStart)
        let clampedEnd = min(clampedStart + visibleDuration, duration)
        return clampedStart...clampedEnd
    }

    private func precisionVisibleDuration(
        for anchorValue: PlaybackSeconds,
        anchorProgress: CGFloat,
        dragTarget: DragTarget,
        baseVisibleDuration: PlaybackSeconds
    ) -> PlaybackSeconds {
        guard let nearestReferenceValue = nearestReferenceMarker(for: dragTarget, anchorValue: anchorValue)?.value else {
            return baseVisibleDuration
        }

        let delta = abs(nearestReferenceValue - anchorValue)
        let targetPadding = min(precisionReferencePadding, baseVisibleDuration * 0.15)
        let desiredDuration = max(delta + (targetPadding * 2), minimumPrecisionVisibleDuration)

        let referenceIsOnRight = nearestReferenceValue >= anchorValue
        let availableProgress = referenceIsOnRight
            ? PlaybackSeconds(max(1 - anchorProgress, 0.0001))
            : PlaybackSeconds(max(anchorProgress, 0.0001))
        let minimumDurationToKeepReferenceVisible = (delta + targetPadding) / availableProgress
        let preferredDuration = min(baseVisibleDuration, desiredDuration)
        return min(
            max(preferredDuration, minimumDurationToKeepReferenceVisible, minimumPrecisionVisibleDuration),
            min(duration, maximumPrecisionVisibleDuration)
        )
    }

    private func nearestReferenceMarker(
        for dragTarget: DragTarget,
        anchorValue: PlaybackSeconds
    ) -> (target: DragTarget, value: PlaybackSeconds)? {
        let referenceMarkers: [(target: DragTarget, value: PlaybackSeconds)]
        switch dragTarget {
        case .playhead:
            referenceMarkers = [(.startHandle, selectionStart), (.endHandle, selectionEnd)] + bookmarks.map {
                (.bookmark($0.id), $0.timeSeconds)
            }
        case .startHandle:
            referenceMarkers = [(.playhead, currentPosition), (.endHandle, selectionEnd)] + bookmarks.map {
                (.bookmark($0.id), $0.timeSeconds)
            }
        case .endHandle:
            referenceMarkers = [(.playhead, currentPosition), (.startHandle, selectionStart)] + bookmarks.map {
                (.bookmark($0.id), $0.timeSeconds)
            }
        case let .bookmark(bookmarkID):
            referenceMarkers = [(.playhead, currentPosition), (.startHandle, selectionStart), (.endHandle, selectionEnd)]
                + bookmarks.compactMap { bookmark in
                    guard bookmark.id != bookmarkID else { return nil }
                    return (.bookmark(bookmark.id), bookmark.timeSeconds)
                }
        }

        return referenceMarkers.min { lhs, rhs in
            abs(lhs.value - anchorValue) < abs(rhs.value - anchorValue)
        }
    }

    private func updateLayerOrdering() {
        trackLayer.zPosition = 0
        selectionLayer.zPosition = 1
        for (index, markerLayer) in bookmarkMarkerLayers.enumerated() {
            let bookmark = bookmarks[index]
            markerLayer.zPosition = bookmark.id == selectedBookmarkID ? 4 : 2
        }
        playheadLayer.zPosition = 3
        startHandleLayer.zPosition = dragTarget == .startHandle ? 4 : 2
        endHandleLayer.zPosition = dragTarget == .endHandle ? 4 : 2
    }

    private func syncBookmarkMarkerLayers() {
        guard let rootLayer = layer else { return }

        while bookmarkMarkerLayers.count < bookmarks.count {
            let markerLayer = CALayer()
            markerLayer.cornerRadius = 1
            markerLayer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
                "cornerRadius": NSNull(),
                "hidden": NSNull()
            ]
            rootLayer.addSublayer(markerLayer)
            bookmarkMarkerLayers.append(markerLayer)
        }

        while bookmarkMarkerLayers.count > bookmarks.count {
            let markerLayer = bookmarkMarkerLayers.removeLast()
            markerLayer.removeFromSuperlayer()
        }

        updateAppearance()
    }

    private func isMarkerVisible(
        _ value: PlaybackSeconds,
        in visibleRange: ClosedRange<PlaybackSeconds>,
        marker: DragTarget
    ) -> Bool {
        if dragTarget == marker {
            return true
        }
        guard precisionZoomState != nil else {
            return true
        }
        if nearestReferenceMarker(for: dragTarget ?? marker, anchorValue: currentValue(for: dragTarget ?? marker))?.target != marker {
            return false
        }
        let epsilon: PlaybackSeconds = 0.0001
        return value >= (visibleRange.lowerBound - epsilon) && value <= (visibleRange.upperBound + epsilon)
    }

    private func resolvedDragTarget(for point: CGPoint) -> DragTarget {
        if let selectedBookmarkID,
           let selectedBookmark = bookmarks.first(where: { $0.id == selectedBookmarkID }),
           bookmarkHitRect(for: selectedBookmark).contains(point) {
            return .bookmark(selectedBookmarkID)
        }

        if handleRect(at: startX).insetBy(dx: -6, dy: -4).contains(point) {
            return .startHandle
        }

        if handleRect(at: endX).insetBy(dx: -6, dy: -4).contains(point) {
            return .endHandle
        }

        if playheadRect(at: xPosition(for: currentPosition)).insetBy(dx: -5, dy: -4).contains(point) {
            return .playhead
        }

        if let bookmark = bookmarks.first(where: { bookmarkHitRect(for: $0).contains(point) }) {
            return .bookmark(bookmark.id)
        }

        return .playhead
    }

    private func updateDrag(with point: CGPoint, isFinal: Bool = false) {
        let proposedSeconds = seconds(for: point)

        switch dragTarget {
        case .playhead:
            currentPosition = proposedSeconds
            updateLayerFrames()
            if isFinal {
                onSeekEnded?(proposedSeconds)
            } else {
                onSeekChanged?(proposedSeconds)
            }
        case .startHandle:
            let updatedStart = min(proposedSeconds, selectionEnd)
            selectionStart = updatedStart
            updateLayerFrames()
            onSelectionPreviewChanged?(updatedStart)
            if isFinal {
                onSelectionCommit?(selectionStart, selectionEnd)
            } else {
                onSelectionChange?(selectionStart, selectionEnd)
            }
        case .endHandle:
            let updatedEnd = max(proposedSeconds, selectionStart)
            selectionEnd = updatedEnd
            updateLayerFrames()
            onSelectionPreviewChanged?(updatedEnd)
            if isFinal {
                onSelectionCommit?(selectionStart, selectionEnd)
            } else {
                onSelectionChange?(selectionStart, selectionEnd)
            }
        case let .bookmark(bookmarkID):
            updateLayerFrames()
            if isFinal {
                onBookmarkDragEnded?(bookmarkID, proposedSeconds)
            } else {
                onBookmarkDragChanged?(bookmarkID, proposedSeconds)
            }
        case .none:
            break
        }
    }

    private func isBookmarkTarget(_ target: DragTarget) -> Bool {
        if case .bookmark = target {
            return true
        }
        return false
    }

    private func bookmarkID(at point: CGPoint) -> BookmarkID? {
        if let selectedBookmarkID,
           let selected = bookmarks.first(where: { $0.id == selectedBookmarkID }),
           bookmarkHitRect(for: selected).contains(point) {
            return selectedBookmarkID
        }
        return bookmarks.first(where: { bookmarkHitRect(for: $0).contains(point) })?.id
    }

    private func clearBookmarkHoverState() {
        guard hoveredBookmarkID != nil else { return }
        hoveredBookmarkID = nil
        onBookmarkMarkerHoverExit?()
    }

    private func updateBookmarkHover(at point: CGPoint) {
        guard dragTarget == nil, isControlEnabled else {
            clearBookmarkHoverState()
            return
        }
        let newID = bookmarkID(at: point)
        if newID == hoveredBookmarkID {
            if let newID, let bookmark = bookmarks.first(where: { $0.id == newID }) {
                let rectInWindow = convert(bookmarkRect(for: bookmark), to: nil)
                onBookmarkMarkerHoverMove?(newID, rectInWindow)
            }
            return
        }
        if hoveredBookmarkID != nil {
            onBookmarkMarkerHoverExit?()
        }
        hoveredBookmarkID = newID
        if let newID, let bookmark = bookmarks.first(where: { $0.id == newID }) {
            let rectInWindow = convert(bookmarkRect(for: bookmark), to: nil)
            onBookmarkMarkerHoverEnter?(newID, rectInWindow)
        }
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
    private let statusMessageContainer = NSVisualEffectView()
    private let statusMessageLabel = NSTextField(labelWithString: "")
    private var hideStatusMessageWorkItem: DispatchWorkItem?
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
        rootLayer.masksToBounds = true
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

        statusMessageContainer.translatesAutoresizingMaskIntoConstraints = false
        statusMessageContainer.material = .hudWindow
        statusMessageContainer.blendingMode = .withinWindow
        statusMessageContainer.state = .active
        statusMessageContainer.wantsLayer = true
        statusMessageContainer.layer?.cornerRadius = 10
        statusMessageContainer.layer?.masksToBounds = true
        statusMessageContainer.alphaValue = 0
        statusMessageContainer.isHidden = true

        statusMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        statusMessageLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusMessageLabel.textColor = .white
        statusMessageLabel.alignment = .center
        statusMessageContainer.addSubview(statusMessageLabel)
        addSubview(statusMessageContainer)

        NSLayoutConstraint.activate([
            playbackIndicatorContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            playbackIndicatorContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            playbackIndicatorContainer.widthAnchor.constraint(equalToConstant: 68),
            playbackIndicatorContainer.heightAnchor.constraint(equalToConstant: 68),

            playbackIndicatorImageView.centerXAnchor.constraint(equalTo: playbackIndicatorContainer.centerXAnchor),
            playbackIndicatorImageView.centerYAnchor.constraint(equalTo: playbackIndicatorContainer.centerYAnchor),
            playbackIndicatorImageView.widthAnchor.constraint(equalToConstant: 34),
            playbackIndicatorImageView.heightAnchor.constraint(equalToConstant: 34),

            statusMessageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusMessageContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),

            statusMessageLabel.topAnchor.constraint(equalTo: statusMessageContainer.topAnchor, constant: 8),
            statusMessageLabel.bottomAnchor.constraint(equalTo: statusMessageContainer.bottomAnchor, constant: -8),
            statusMessageLabel.leadingAnchor.constraint(equalTo: statusMessageContainer.leadingAnchor, constant: 14),
            statusMessageLabel.trailingAnchor.constraint(equalTo: statusMessageContainer.trailingAnchor, constant: -14)
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

    func flashStatusMessage(_ message: String) {
        guard !message.isEmpty else { return }

        hideStatusMessageWorkItem?.cancel()
        statusMessageLabel.stringValue = message
        statusMessageContainer.isHidden = false
        statusMessageContainer.alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            statusMessageContainer.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.statusMessageContainer.animator().alphaValue = 0
            } completionHandler: {
                self.statusMessageContainer.isHidden = true
            }
        }
        hideStatusMessageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
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
