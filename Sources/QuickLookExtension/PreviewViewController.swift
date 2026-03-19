import Cocoa
import AVKit
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let engine = PlaybackEngine()
    private let playerView = AVPlayerView(frame: .zero)
    private let timelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let loopButton = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let setSelectionStartButton = NSButton(title: "Set Start", target: nil, action: nil)
    private let setSelectionEndButton = NSButton(title: "Set End", target: nil, action: nil)
    private let replaySelectionButton = NSButton(checkboxWithTitle: "Replay Selection", target: nil, action: nil)
    private let clearSelectionButton = NSButton(title: "Clear Selection", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "Selection: none")
    private let openInAppButton = NSButton(title: "Open In App", target: nil, action: nil)

    private var currentFileURL: URL?
    private var isDraggingSlider = false
    private var eventMonitor: Any?
    private var selectionStart: PlaybackSeconds?
    private var selectionEnd: PlaybackSeconds?

    override func loadView() {
        view = KeyCaptureView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindEngineCallbacks()
        installKeyMonitor()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        currentFileURL = url
        engine.attach(to: url, autoplay: true)
        selectionStart = nil
        selectionEnd = nil
        replaySelectionButton.state = .off
        selectionLabel.stringValue = "Selection: none"
        handler(nil)
    }

    private func setupUI() {
        guard let container = view as? KeyCaptureView else { return }
        container.keyHandler = { [weak self] event in
            self?.handleKey(event: event)
        }

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .none
        playerView.player = engine.currentPlayer()

        timelineSlider.translatesAutoresizingMaskIntoConstraints = false
        timelineSlider.target = self
        timelineSlider.action = #selector(handleSliderChanged(_:))
        timelineSlider.isContinuous = true

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

        openInAppButton.translatesAutoresizingMaskIntoConstraints = false
        openInAppButton.target = self
        openInAppButton.action = #selector(handleOpenInApp(_:))

        let controls = NSStackView(
            views: [
                loopButton,
                setSelectionStartButton,
                setSelectionEndButton,
                replaySelectionButton,
                clearSelectionButton,
                openInAppButton,
                selectionLabel,
                timeLabel
            ]
        )
        controls.orientation = .horizontal
        controls.distribution = .fillProportionally
        controls.alignment = .centerY
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(playerView)
        view.addSubview(timelineSlider)
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            timelineSlider.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 10),
            timelineSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            timelineSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            controls.topAnchor.constraint(equalTo: timelineSlider.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func bindEngineCallbacks() {
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

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event: event) ? nil : event
        }
    }

    @discardableResult
    private func handleKey(event: NSEvent) -> Bool {
        let isShift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // Space
            engine.handle(command: .togglePlayPause)
            return true
        case 37: // L
            engine.handle(command: .toggleLoop)
            return true
        case 123: // Left
            let step = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: -step))
            return true
        case 124: // Right
            let step = isShift ? engine.coarseStepAmount() : engine.fineStepAmount()
            engine.handle(command: .seekBy(seconds: step))
            return true
        case 126: // Up
            engine.handle(command: .seekFrame(delta: 1))
            return true
        case 125: // Down
            engine.handle(command: .seekFrame(delta: -1))
            return true
        default:
            return false
        }
    }

    @objc
    private func handleSliderChanged(_ sender: NSSlider) {
        guard sender.maxValue > sender.minValue else { return }
        let duration = engine.currentDurationSeconds()
        let target = sender.doubleValue * duration
        isDraggingSlider = true
        engine.handle(command: .seekTo(seconds: target))
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
            _ = applySelectionReplay()
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
            _ = applySelectionReplay()
        }
        _ = sender
    }

    @objc
    private func handleReplaySelectionToggle(_ sender: NSButton) {
        if sender.state == .on {
            guard applySelectionReplay() else {
                sender.state = .off
                NSSound.beep()
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
    private func handleOpenInApp(_ sender: NSButton) {
        guard let fileURL = currentFileURL else { return }
        var components = URLComponents()
        components.scheme = "quickpreview"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "file", value: fileURL.path)]

        if
            let appURL = components.url,
            NSWorkspace.shared.open(appURL)
        {
            return
        }

        NSWorkspace.shared.open(fileURL)
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
}

final class KeyCaptureView: NSView {
    var keyHandler: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        keyHandler?(event)
    }
}
