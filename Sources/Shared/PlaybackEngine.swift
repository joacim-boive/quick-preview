import Foundation
import AVFoundation

typealias PositionUpdateHandler = (PlaybackPosition) -> Void
typealias LoopModeUpdateHandler = (LoopMode) -> Void

final class PlaybackEngine {
    private let player: AVPlayer
    private let loopController: LoopController
    private let seekController: PreciseSeekController
    private var timeObserverToken: Any?
    private var isScrubbing = false
    private var scrubSeekInFlight = false
    private var pendingScrubSeekSeconds: PlaybackSeconds?
    private var scrubTimer: DispatchSourceTimer?
    private var audioGain: Float = 1.0

    var onPositionUpdate: PositionUpdateHandler?
    var onLoopModeUpdate: LoopModeUpdateHandler?

    init(
        player: AVPlayer = AVPlayer(),
        loopController: LoopController = LoopController(),
        seekController: PreciseSeekController = PreciseSeekController()
    ) {
        self.player = player
        self.loopController = loopController
        self.seekController = seekController
    }

    deinit {
        stopScrubTimer()
        detachTimeObserver()
        NotificationCenter.default.removeObserver(self)
    }

    func attach(to url: URL, autoplay: Bool = true) {
        loopController.clearLoop()
        onLoopModeUpdate?(loopController.mode)

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        applyAudioGainToCurrentItem()

        detachTimeObserver()
        attachTimeObserver()
        observePlaybackEnd(for: item)

        if autoplay {
            play()
        }
    }

    func setAudioGain(_ gain: Float) {
        audioGain = max(gain, 0)
        applyAudioGainToCurrentItem()
    }

    func currentPlayer() -> AVPlayer {
        player
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlayPause() {
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    func setLoopFull(enabled: Bool) {
        loopController.setFullLoop(enabled: enabled)
        onLoopModeUpdate?(loopController.mode)
    }

    func setLoopRange(start: PlaybackSeconds, end: PlaybackSeconds) {
        loopController.setRangeLoop(start: start, end: end)
        onLoopModeUpdate?(loopController.mode)
    }

    func clearLoop() {
        loopController.clearLoop()
        onLoopModeUpdate?(loopController.mode)
    }

    func loopMode() -> LoopMode {
        loopController.mode
    }

    func handle(command: PlaybackCommand, isCoarseStep: Bool = false) {
        switch command {
        case .togglePlayPause:
            togglePlayPause()
        case let .seekBy(seconds):
            seekBy(seconds: seconds)
        case let .seekTo(seconds):
            seekTo(seconds: seconds)
        case let .seekFrame(delta):
            seekFrame(delta: delta)
        case .toggleLoop:
            switch loopController.mode {
            case .off:
                setLoopFull(enabled: true)
            default:
                setLoopFull(enabled: false)
            }
        }
        _ = isCoarseStep
    }

    func seekBy(seconds: PlaybackSeconds) {
        let duration = currentDurationSeconds()
        let current = currentTimeSeconds()
        let target = seekController.clampedSeekTarget(
            current: current,
            delta: seconds,
            duration: duration
        )
        seekTo(seconds: target)
    }

    func seekTo(seconds: PlaybackSeconds) {
        let duration = currentDurationSeconds()
        let clamped = min(max(seconds, 0), max(duration, 0))
        let time = CMTime.seconds(clamped)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func applyAudioGainToCurrentItem() {
        guard let item = player.currentItem else { return }

        // AVPlayer.volume is documented as 0.0...1.0; use AVAudioMix to exceed 100%.
        player.volume = 1.0

        let inputParameters: [AVMutableAudioMixInputParameters] = item.tracks.compactMap { itemTrack in
            guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .audio else { return nil }
            let params = AVMutableAudioMixInputParameters(track: assetTrack)
            params.setVolume(audioGain, at: .zero)
            return params
        }

        guard !inputParameters.isEmpty else { return }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        item.audioMix = audioMix
    }

    func beginScrubbing() {
        isScrubbing = true
        scrubSeekInFlight = false
        pendingScrubSeekSeconds = nil
        startScrubTimer()
    }

    func scrub(to seconds: PlaybackSeconds) {
        let duration = currentDurationSeconds()
        let clamped = min(max(seconds, 0), max(duration, 0))
        pendingScrubSeekSeconds = clamped
    }

    func endScrubbing(at seconds: PlaybackSeconds) {
        isScrubbing = false
        pendingScrubSeekSeconds = nil
        scrubSeekInFlight = false
        stopScrubTimer()
        seekTo(seconds: seconds)
    }

    func seekFrame(delta: Int) {
        guard delta != 0 else { return }
        let current = currentTimeSeconds()
        let step = seekController.frameStepSeconds(for: player.currentItem) ?? seekController.fineStepSeconds
        seekBy(seconds: step * PlaybackSeconds(delta))
        onPositionUpdate?(PlaybackPosition(seconds: current, duration: currentDurationSeconds()))
    }

    func fineStepAmount() -> PlaybackSeconds {
        seekController.fineStepSeconds
    }

    func coarseStepAmount() -> PlaybackSeconds {
        seekController.coarseStepSeconds
    }

    func currentTimeSeconds() -> PlaybackSeconds {
        player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
    }

    func currentDurationSeconds() -> PlaybackSeconds {
        guard
            let duration = player.currentItem?.duration.seconds,
            duration.isFinite
        else {
            return 0
        }
        return max(duration, 0)
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onPositionUpdate?(
                PlaybackPosition(
                    seconds: self.currentTimeSeconds(),
                    duration: self.currentDurationSeconds()
                )
            )
            self.applyRangeLoopIfNeeded()
        }
    }

    private func detachTimeObserver() {
        guard let token = timeObserverToken else { return }
        player.removeTimeObserver(token)
        timeObserverToken = nil
    }

    private func applyRangeLoopIfNeeded() {
        guard !isScrubbing else {
            return
        }
        let current = currentTimeSeconds()
        let duration = currentDurationSeconds()
        guard let restart = loopController.loopRestartTime(currentSeconds: current, duration: duration) else {
            return
        }
        player.seek(to: .seconds(restart), toleranceBefore: .zero, toleranceAfter: .zero)
        if player.rate == 0 {
            player.play()
        }
    }

    @objc
    private func handlePlaybackEnd(_ notification: Notification) {
        guard !isScrubbing else {
            return
        }
        let duration = currentDurationSeconds()
        guard let restart = loopController.loopRestartTime(currentSeconds: duration, duration: duration) else {
            return
        }
        player.seek(to: .seconds(restart), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func startScrubTimer() {
        guard scrubTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.dispatchPendingScrubSeekIfNeeded()
        }
        scrubTimer = timer
        timer.resume()
    }

    private func stopScrubTimer() {
        scrubTimer?.cancel()
        scrubTimer = nil
    }

    private func dispatchPendingScrubSeekIfNeeded() {
        guard isScrubbing, !scrubSeekInFlight, let target = pendingScrubSeekSeconds else {
            return
        }

        pendingScrubSeekSeconds = nil
        scrubSeekInFlight = true

        let tolerance = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
        player.seek(
            to: .seconds(target),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            guard let self else { return }
            self.scrubSeekInFlight = false
            self.dispatchPendingScrubSeekIfNeeded()
        }
    }
}
