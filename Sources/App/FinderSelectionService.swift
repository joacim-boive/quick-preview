import AppKit
import UniformTypeIdentifiers

enum FinderSelectionResult: Equatable {
    case noSelection
    case nonVideo(URL)
    case video(URL)
    case automationDenied
    case finderUnavailable
    case scriptError(Int?)
}

struct FinderSelectionSnapshot: Equatable {
    let result: FinderSelectionResult

    var selectedVideoURL: URL? {
        guard case let .video(url) = result else {
            return nil
        }
        return url
    }

    fileprivate var signature: String {
        switch result {
        case .noSelection:
            return "none"
        case let .nonVideo(url):
            return "nonVideo:\(url.standardizedFileURL.path)"
        case let .video(url):
            return "video:\(url.standardizedFileURL.path)"
        case .automationDenied:
            return "automationDenied"
        case .finderUnavailable:
            return "finderUnavailable"
        case let .scriptError(code):
            return "scriptError:\(code.map(String.init) ?? "nil")"
        }
    }

    fileprivate var shouldBackOffPolling: Bool {
        switch result {
        case .automationDenied, .finderUnavailable, .scriptError:
            return true
        case .noSelection, .nonVideo, .video:
            return false
        }
    }
}

enum FinderSelectionUserFacingError: Error {
    case noSelection
    case automationDenied
    case finderUnavailable
    case scriptError(Int?)

    var title: String {
        switch self {
        case .noSelection:
            return "No Finder Selection"
        case .automationDenied:
            return "Finder Access Needed"
        case .finderUnavailable, .scriptError:
            return "Could Not Read Finder Selection"
        }
    }

    var message: String {
        switch self {
        case .noSelection:
            return "Select a file in Finder first, then try again."
        case .automationDenied:
            return "Allow QuickPreview to control Finder in System Settings > Privacy & Security > Automation."
        case .finderUnavailable:
            return "Finder is currently unavailable. Reopen Finder and try again."
        case let .scriptError(code):
            if let code {
                return "Finder selection could not be read right now. Try again.\n\nDiagnostics: finder.selection: error \(code)"
            }
            return "Finder selection could not be read right now. Try again."
        }
    }
}

struct FinderSelectionMonitoringState: Equatable {
    var isFollowEnabled = true
    var isEntitled = false
    var hasLoadedVideo = false
    var isAppActive = false
    var isFinderFrontmost = false

    var shouldPoll: Bool {
        isFollowEnabled && isEntitled && hasLoadedVideo
    }
}

final class FinderSelectionService {
    typealias SnapshotHandler = @MainActor (FinderSelectionSnapshot) -> Void

    private let automationClient: FinderAutomationClient
    private let pollingQueue: DispatchQueue
    private var monitorTimer: DispatchSourceTimer?
    private var monitoringState = FinderSelectionMonitoringState()
    private var consecutiveFailureCount = 0
    private var lastDeliveredSignature: String?
    private var isRunning = false

    var onSelectionSnapshot: SnapshotHandler?

    init(
        automationClient: FinderAutomationClient = FinderAutomationClient(),
        pollingQueue: DispatchQueue = DispatchQueue(
            label: "quickpreview.finder-selection-monitor",
            qos: .utility
        )
    ) {
        self.automationClient = automationClient
        self.pollingQueue = pollingQueue
    }

    deinit {
        monitorTimer?.setEventHandler {}
        monitorTimer?.cancel()
    }

    func start() {
        pollingQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.reschedulePolling(immediate: true)
        }
    }

    func stop() {
        pollingQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.invalidateTimer()
        }
    }

    func updateMonitoringState(_ state: FinderSelectionMonitoringState) {
        pollingQueue.async { [weak self] in
            guard let self else { return }
            let previousState = self.monitoringState
            self.monitoringState = state

            guard self.isRunning else { return }

            if !state.shouldPoll {
                self.invalidateTimer()
                self.consecutiveFailureCount = 0
                self.lastDeliveredSignature = nil
                return
            }

            let immediate = !previousState.shouldPoll
                || previousState.isFinderFrontmost != state.isFinderFrontmost
                || previousState.isAppActive != state.isAppActive
            self.reschedulePolling(immediate: immediate)
        }
    }

    func readCurrentSelection(activateFinder: Bool) -> FinderSelectionSnapshot {
        automationClient.readCurrentSelection(activateFinder: activateFinder)
    }

    private func handlePollingTick() {
        guard isRunning, monitoringState.shouldPoll else {
            invalidateTimer()
            return
        }

        let snapshot = automationClient.readCurrentSelection(activateFinder: false)
        if snapshot.shouldBackOffPolling {
            consecutiveFailureCount = min(consecutiveFailureCount + 1, 4)
        } else {
            consecutiveFailureCount = 0
        }

        let signature = snapshot.signature
        if signature != lastDeliveredSignature {
            lastDeliveredSignature = signature
            if let onSelectionSnapshot {
                Task { @MainActor in
                    onSelectionSnapshot(snapshot)
                }
            }
        }

        reschedulePolling(immediate: false)
    }

    private func reschedulePolling(immediate: Bool) {
        invalidateTimer()
        guard isRunning, monitoringState.shouldPoll else { return }

        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        let delay = immediate ? DispatchTimeInterval.milliseconds(0) : nextPollingInterval()
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.handlePollingTick()
        }
        monitorTimer = timer
        timer.resume()
    }

    private func nextPollingInterval() -> DispatchTimeInterval {
        let baseMilliseconds: Int
        if monitoringState.isFinderFrontmost {
            baseMilliseconds = 250
        } else if monitoringState.isAppActive {
            baseMilliseconds = 500
        } else {
            baseMilliseconds = 1250
        }

        guard consecutiveFailureCount > 0 else {
            return .milliseconds(baseMilliseconds)
        }

        let multiplier = min(1 << min(consecutiveFailureCount, 3), 8)
        return .milliseconds(baseMilliseconds * multiplier)
    }

    private func invalidateTimer() {
        monitorTimer?.setEventHandler {}
        monitorTimer?.cancel()
        monitorTimer = nil
    }
}

final class FinderAutomationClient {
    func readCurrentSelection(activateFinder: Bool) -> FinderSelectionSnapshot {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else {
            return FinderSelectionSnapshot(result: .finderUnavailable)
        }

        let lines = selectionScriptLines(activateFinder: activateFinder)
        let script = lines.joined(separator: "\n")
        let result = runAppleScript(script)

        if let code = result.errorCode {
            if code == -1743 || code == -1719 {
                return FinderSelectionSnapshot(result: .automationDenied)
            }
            if code == -600 {
                return FinderSelectionSnapshot(result: .finderUnavailable)
            }
            return FinderSelectionSnapshot(result: .scriptError(code))
        }

        guard let value = result.value, !value.isEmpty else {
            return FinderSelectionSnapshot(result: .noSelection)
        }

        let fileURL = URL(fileURLWithPath: value).standardizedFileURL
        if isVideoURL(fileURL) {
            return FinderSelectionSnapshot(result: .video(fileURL))
        }
        return FinderSelectionSnapshot(result: .nonVideo(fileURL))
    }

    private func selectionScriptLines(activateFinder: Bool) -> [String] {
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

        return lines
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

    private func isVideoURL(_ url: URL) -> Bool {
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
