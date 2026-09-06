import AppKit
import ApplicationServices

/// Resolves a safe frame budget for the focus-to-session ownership handoff.
enum FocusExternalAudioHandoffCapacityPolicy {
    /// Mirrors the longest shared-session idle wait before a queued start is rejected.
    static let sharedRecordingStartWaitSeconds: TimeInterval = 3

    /// Calculates how many monitor frames cover shared-start wait plus safety margin.
    ///
    /// Args:
    ///   preRollFrames: Existing configured frame budget reused as claim-scheduling margin.
    ///   startWaitSeconds: Maximum time the shared recording start may remain queued.
    ///   frameDurationMs: Duration of one monitor frame in milliseconds.
    ///
    /// Returns:
    ///   A frame count covering the full wait plus the configured pre-roll margin.
    static func frameCapacity(
        preRollFrames: Int,
        startWaitSeconds: TimeInterval = sharedRecordingStartWaitSeconds,
        frameDurationMs: Int = AudioCaptureEngine.frameDurationMs
    ) -> Int {
        let normalizedPreRollFrames = max(0, preRollFrames)
        guard startWaitSeconds > 0, frameDurationMs > 0 else {
            return normalizedPreRollFrames
        }
        let waitMilliseconds = startWaitSeconds * 1_000
        let waitFrames = Int(ceil(waitMilliseconds / Double(frameDurationMs)))
        return waitFrames + normalizedPreRollFrames
    }
}

/// Buffers focus-triggered audio until the shared recognition session owns input.
struct FocusExternalAudioHandoffBuffer {
    enum Phase: Equatable {
        case inactive
        case buffering
        case direct
    }

    enum RouteResult: Equatable {
        case ignored
        case buffered
        case queuedForDirectDelivery
    }

    private(set) var phase: Phase = .inactive
    private(set) var generation = 0
    private(set) var bufferedFrames: [Data] = []
    private var maxBufferedFrames = 0
    private var deliveryFrames: [Data] = []
    private var deliveryReadIndex = 0

    var hasPendingDelivery: Bool {
        deliveryReadIndex < deliveryFrames.count
    }

    /// Starts a new bounded handoff window.
    ///
    /// Args:
    ///   maxBufferedFrames: Maximum number of post-trigger frames retained before claim.
    mutating func beginBuffering(maxBufferedFrames: Int) {
        generation &+= 1
        self.maxBufferedFrames = max(0, maxBufferedFrames)
        bufferedFrames.removeAll(keepingCapacity: true)
        deliveryFrames.removeAll(keepingCapacity: true)
        deliveryReadIndex = 0
        phase = .buffering
    }

    /// Routes one monitor frame according to current handoff ownership.
    ///
    /// Args:
    ///   frame: PCM frame received from the long-lived focus monitor.
    ///
    /// Returns:
    ///   How the frame was retained or queued for ordered delivery.
    mutating func route(_ frame: Data) -> RouteResult {
        switch phase {
        case .buffering:
            guard maxBufferedFrames > 0 else { return .ignored }
            bufferedFrames.append(frame)
            if bufferedFrames.count > maxBufferedFrames {
                bufferedFrames.removeFirst(bufferedFrames.count - maxBufferedFrames)
            }
            return .buffered

        case .direct:
            deliveryFrames.append(frame)
            return .queuedForDirectDelivery

        case .inactive:
            return .ignored
        }
    }

    /// Atomically moves every retained claim frame into the ordered delivery queue.
    ///
    /// Returns:
    ///   The generation that now owns direct delivery, or `nil` without a pending claim.
    mutating func claimDirectDelivery() -> Int? {
        guard phase == .buffering else { return nil }
        deliveryFrames.append(contentsOf: bufferedFrames)
        bufferedFrames.removeAll(keepingCapacity: true)
        phase = .direct
        return generation
    }

    /// Takes one frame for a serial delivery pump owned by the same focus generation.
    ///
    /// Args:
    ///   ownerGeneration: Focus generation that created the delivery pump.
    ///
    /// Returns:
    ///   The next ordered frame, or `nil` when ownership changed or the queue drained.
    mutating func takeNextDeliveryFrame(ownerGeneration: Int) -> Data? {
        guard phase == .direct,
              generation == ownerGeneration,
              deliveryReadIndex < deliveryFrames.count else {
            return nil
        }
        let frame = deliveryFrames[deliveryReadIndex]
        deliveryReadIndex += 1
        if deliveryReadIndex == deliveryFrames.count {
            deliveryFrames.removeAll(keepingCapacity: true)
            deliveryReadIndex = 0
        }
        return frame
    }

    /// Clears all queued frames and returns to inactive monitoring state.
    mutating func reset() {
        generation &+= 1
        phase = .inactive
        bufferedFrames.removeAll(keepingCapacity: true)
        deliveryFrames.removeAll(keepingCapacity: true)
        deliveryReadIndex = 0
        maxBufferedFrames = 0
    }
}

@MainActor
final class FocusWakeupController {
    private struct FocusSignature: Equatable {
        let pid: pid_t
        let role: String
        let identity: String
    }

    private typealias FocusProbe = FocusWakeupRetentionPolicy<FocusSignature>.Probe

    private enum FocusedElementLookup {
        case found(AXUIElement)
        case unavailable
    }

    private struct Config {
        let enabled: Bool
        let minStartRMSThreshold: Float
        let startThresholdFloor: Float
        let fallbackStartThreshold: Float
        let rmsWindowFrames: Int
        let speechFrames: Int
        let preRollFrames: Int
        let rearmDelay: TimeInterval
        let pollInterval: TimeInterval
        let noFrameReopen: TimeInterval
        let falseStartCooldown: TimeInterval
        let speechProfileMinGap: Float
        let speechProfileBlend: Float
        let falseStartNoiseMargin: Float
        let falseStartSpeechCapBlend: Float
        let falseStartColdStartCapMultiplier: Float
        let focusRetentionConfig: FocusWakeupRetentionPolicy<FocusSignature>.Config

        /// Loads focus wakeup settings from UserDefaults.
        ///
        /// Returns:
        ///   Focus wakeup configuration with Python MyType-compatible defaults.
        static func load() -> Config {
            let defaults = UserDefaults.standard
            let enabled = defaults.object(forKey: "tf_focusWakeupEnabled") == nil
                ? true
                : defaults.bool(forKey: "tf_focusWakeupEnabled")
            return Config(
                enabled: enabled,
                minStartRMSThreshold: Float(defaults.object(forKey: "tf_focusMinStartRMSThreshold") as? Double ?? 160),
                startThresholdFloor: Float(defaults.object(forKey: "tf_focusStartThresholdFloor") as? Double ?? 300),
                fallbackStartThreshold: Float(
                    defaults.object(forKey: "tf_focusStartThreshold") as? Double
                        ?? defaults.object(forKey: "tf_focusAutoStopRMSThreshold") as? Double
                        ?? 500
                ),
                rmsWindowFrames: max(1, defaults.integerOrDefault("tf_focusRMSWindowFrames", defaultValue: 10)),
                speechFrames: max(6, defaults.integerOrDefault("tf_focusSpeechFrames", defaultValue: 6)),
                preRollFrames: max(0, defaults.integerOrDefault("tf_focusPreRollFrames", defaultValue: 25)),
                rearmDelay: defaults.doubleOrDefault("tf_focusRearmDelay", defaultValue: 0.8),
                pollInterval: defaults.doubleOrDefault("tf_focusPollInterval", defaultValue: 0.35),
                noFrameReopen: defaults.doubleOrDefault("tf_focusNoFrameReopen", defaultValue: 1.0),
                falseStartCooldown: defaults.doubleOrDefault("tf_focusFalseStartCooldown", defaultValue: 2.5),
                speechProfileMinGap: Float(
                    defaults.object(forKey: "tf_focusSpeechProfileMinGap") as? Double ?? 200
                ),
                speechProfileBlend: Float(
                    defaults.object(forKey: "tf_focusSpeechProfileBlend") as? Double ?? 0.25
                ),
                falseStartNoiseMargin: Float(
                    defaults.object(forKey: "tf_focusFalseStartNoiseMargin") as? Double ?? 120
                ),
                falseStartSpeechCapBlend: Float(
                    defaults.object(forKey: "tf_focusFalseStartSpeechCapBlend") as? Double ?? 0.9
                ),
                falseStartColdStartCapMultiplier: Float(
                    defaults.object(forKey: "tf_focusFalseStartColdStartCapMultiplier") as? Double ?? 2
                ),
                focusRetentionConfig: FocusWakeupRetentionPolicy<FocusSignature>.Config(
                    maxUnknownPolls: max(0, defaults.integerOrDefault("tf_focusUnknownGracePolls", defaultValue: 4)),
                    maxUnknownDuration: max(0, defaults.doubleOrDefault("tf_focusUnknownGraceDuration", defaultValue: 1.5))
                )
            )
        }
    }

    private struct StartThresholdResolution {
        let noiseThreshold: Float
        let speechLowRMS: Float?
        let falseStartHighRMS: Float?
        let finalThreshold: Float
    }

    private weak var appState: AppState?
    private let session: RecognitionSession
    var onRecordingStartRequested: ((ProcessingMode, [Data], Float, Bool) -> Bool)?
    var onRecordingCancellationRequested: (() -> Void)?
    private let monitorAudio = FocusAudioMonitor()
    private var timer: Timer?
    private var currentFocus: FocusSignature?
    private var isMonitoringAudio: Bool { monitorAudio.state == .running }
    private var isFocusRecording = false
    private var isManualRecordingPaused = false
    private var isStartGatePausedByEscape = false
    private var rearmBlockedUntil = Date.distantPast
    private var rmsWindow: [Float] = []
    private var preRollFrames: [Data] = []
    private var consecutiveSpeechFrames = 0
    private var monitorStartedAt: Date?
    private var lastFrameAt: Date?
    private var monitorFrameCount = 0
    private var config: Config
    private var focusRetentionPolicy: FocusWakeupRetentionPolicy<FocusSignature>
    private var lastFocusTriggerRMS: Float?
    private var acousticMode = FocusAcousticMode.noisy
    private var quietGate = QuietWakeupGate()
    private var quietDeviceUID: String?
    private var lastRecordingWasQuiet = false
    private var pendingQuietDeviceChange = false

    /// Installs a successful calibration from the shared settings button.
    ///
    /// Args:
    ///   threshold: Quiet-mode threshold computed from that capture's ambient frames.
    func applyQuietCalibration(_ threshold: Float) {
        guard !isFocusRecording,
              FocusAcousticMode.resolve(UserDefaults.standard.string(forKey: FocusAcousticMode.storageKey)) == .quiet else { return }
        acousticMode = .quiet
        quietDeviceUID = AudioInputDevicePreferenceStore.activeCachedInputDevice()?.uid
        quietGate = QuietWakeupGate(calibratedThreshold: threshold)
        appState?.quietCalibrationSecondsRemaining = 0
    }

    /// Invalidates calibration and reopens the quiet monitor after a device change.
    /// Active sessions retain their frozen gate and defer reopening until completion.
    func inputDeviceDidChange() {
        guard acousticMode == .quiet else { return }
        if isFocusRecording {
            pendingQuietDeviceChange = true
        } else {
            quietGate = QuietWakeupGate()
            stopAudioMonitoring()
        }
    }
    private var externalAudioHandoff = FocusExternalAudioHandoffBuffer()
    private var externalAudioDeliveryTask: Task<Void, Never>?
    private var externalAudioDeliveryTaskGeneration: Int?
    private var externalAudioSessionGeneration: Int?

    nonisolated static let focusWakeupModeIdKey = "tf_focusWakeupModeId"

    /// Creates a controller for focus-based automatic dictation.
    ///
    /// Args:
    ///   appState: Shared UI state used to start the floating bar.
    ///   session: Recognition session that performs ASR, LLM, and text injection.
    init(appState: AppState, session: RecognitionSession) {
        let config = Config.load()
        self.config = config
        self.focusRetentionPolicy = FocusWakeupRetentionPolicy(config: config.focusRetentionConfig)
        self.appState = appState
        self.session = session
    }

    /// Returns whether a mode can be used by focus-triggered dictation.
    ///
    /// Args:
    ///   mode: Processing mode loaded from storage.
    ///
    /// Returns:
    ///   True for text-producing modes. Agent Router is excluded because it
    ///   launches or switches agents instead of typing into the focused field.
    nonisolated static func isTextProducingFocusMode(_ mode: ProcessingMode) -> Bool {
        mode.id != ProcessingMode.agentRouterModeId
    }

    /// Resolves the processing mode used by focus-triggered dictation.
    ///
    /// Args:
    ///   modes: Available modes loaded from `ModeStorage`.
    ///   storedModeId: UserDefaults value for the focus wakeup mode preference.
    ///   provider: Currently selected ASR provider.
    ///
    /// Returns:
    ///   The selected provider-compatible text mode, defaulting to Voice Polish
    ///   when available and falling back to direct dictation otherwise.
    nonisolated static func resolvedFocusWakeupMode(
        modes: [ProcessingMode],
        storedModeId: String?,
        provider: ASRProvider
    ) -> ProcessingMode {
        let textModes = modes.filter(isTextProducingFocusMode)
        let preferredMode = storedModeId.flatMap(UUID.init(uuidString:)).flatMap { id in
            textModes.first { $0.id == id }
        }
        let defaultMode = textModes.first { $0.id == ProcessingMode.formalWritingId }
            ?? textModes.first { $0.id == ProcessingMode.directId }
            ?? ProcessingMode.direct
        let selectedMode = preferredMode ?? defaultMode
        let resolvedMode = ASRProviderRegistry.resolvedMode(for: selectedMode, provider: provider)
        return textModes.first { $0.id == resolvedMode.id } ?? resolvedMode
    }

    /// Starts watching focused editable elements.
    func start() {
        config = Config.load()
        monitorAudio.resetFailure()
        focusRetentionPolicy.updateConfig(config.focusRetentionConfig)
        isStartGatePausedByEscape = false
        guard config.enabled else {
            DebugFileLogger.log("focus wakeup disabled")
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkFocusedElement()
            }
        }
        checkFocusedElement()
        DebugFileLogger.log("focus wakeup started")
    }

    /// Stops focus watching and releases the local monitor microphone stream.
    func stop() {
        let shouldCancelRecording = isFocusRecording
        timer?.invalidate()
        timer = nil
        isStartGatePausedByEscape = false
        stopAudioMonitoring(hideWaiting: true)
        currentFocus = nil
        focusRetentionPolicy.reset()
        isFocusRecording = false
        lastFocusTriggerRMS = nil
        resetExternalAudioHandoff()
        if shouldCancelRecording {
            onRecordingCancellationRequested?()
        }
    }

    /// Pauses only the start RMS gate after the user presses Escape in waiting state.
    ///
    /// The end RMS gate remains part of the next recording pipeline. The start gate
    /// is resumed when the user next starts the pipeline with a hotkey.
    func pauseStartGateForEscape() {
        isStartGatePausedByEscape = true
        stopAudioMonitoring(hideWaiting: true)
        currentFocus = nil
        focusRetentionPolicy.reset()
        DebugFileLogger.log("focus wakeup: start RMS gate paused by ESC")
    }

    /// Pauses focus wakeup while a manual hotkey recording owns the microphone.
    func pauseForManualRecording() {
        isManualRecordingPaused = true
        stopAudioMonitoring()
    }

    /// Waits for the background monitor to release the device before manual capture.
    ///
    /// Returns:
    ///   True only after actual teardown; false when cancelled or the driver is stuck.
    func waitForAudioRelease() async -> Bool {
        await monitorAudio.waitUntilStopped()
    }

    /// Resumes the start RMS gate when a hotkey starts the main pipeline.
    func resumeStartGateAfterPipelineStart() {
        guard isStartGatePausedByEscape else { return }
        isStartGatePausedByEscape = false
        DebugFileLogger.log("focus wakeup: start RMS gate resumed by hotkey pipeline start")
    }

    /// Marks a recording as finished and allows focus wakeup to re-arm.
    func sessionDidFinish() {
        isFocusRecording = false
        isManualRecordingPaused = false
        lastFocusTriggerRMS = nil
        quietGate.rearm()
        if pendingQuietDeviceChange {
            pendingQuietDeviceChange = false
            quietGate = QuietWakeupGate()
            stopAudioMonitoring()
        }
        resetExternalAudioHandoff()
        rearmBlockedUntil = Date().addingTimeInterval(config.rearmDelay)
    }

    /// Marks an RMS-triggered recording as a false start and briefly delays re-arming.
    func sessionDidFalseStart() {
        isFocusRecording = false
        isManualRecordingPaused = false
        if !lastRecordingWasQuiet, let triggerRMS = lastFocusTriggerRMS {
            _ = FalseStartRMSProfileStore.record(triggerRMS, source: "focus")
        }
        lastFocusTriggerRMS = nil
        quietGate.rearm()
        resetExternalAudioHandoff()
        rearmBlockedUntil = Date().addingTimeInterval(config.falseStartCooldown)
        DebugFileLogger.log(
            "focus wakeup: false-start cooldown=\(String(format: "%.1f", config.falseStartCooldown))s stableThreshold=true"
        )
    }

    /// Checks whether the frontmost app has an editable focused element.
    ///
    /// Starts or stops the local RMS monitor according to the current focus state.
    private func checkFocusedElement() {
        guard config.enabled else { return }
        guard !isStartGatePausedByEscape else {
            stopAudioMonitoring(hideWaiting: true)
            return
        }
        guard !isManualRecordingPaused, !isFocusRecording else { return }
        guard Date() >= rearmBlockedUntil else { return }

        let decision = focusRetentionPolicy.update(currentFocusProbe(), at: Date())
        switch decision {
        case .arm(let focus):
            currentFocus = focus
            DebugFileLogger.log(
                "focus wakeup: editable focus armed pid=\(focus.pid) role=\(focus.role) wasMonitoring=\(isMonitoringAudio)"
            )
            startAudioMonitoring()

        case .keep(let focus):
            currentFocus = focus
            if !isMonitoringAudio {
                DebugFileLogger.log("focus wakeup: editable focus retained pid=\(focus.pid) role=\(focus.role)")
                startAudioMonitoring()
            } else {
                restoreFocusWaitingIfNeeded()
                recoverStaleAudioMonitoringIfNeeded()
            }

        case .clear:
            if currentFocus != nil {
                DebugFileLogger.log("focus wakeup: editable focus lost")
            }
            currentFocus = nil
            stopAudioMonitoring(hideWaiting: true)

        case .none:
            currentFocus = nil
            stopAudioMonitoring(hideWaiting: true)
        }
    }

    /// Starts a low-cost local microphone monitor for RMS wakeup detection.
    private func startAudioMonitoring() {
        guard !isMonitoringAudio else {
            restoreFocusWaitingIfNeeded()
            DebugFileLogger.log(
                "focus wakeup: local RMS monitor start skipped alreadyMonitoring=true focus=\(Self.focusLogDescription(currentFocus)) deviceUID=\(Self.selectedMicrophoneUIDDescription())"
            )
            return
        }
        // Polls may continue while hardware is starting, stopping, or failed.
        // Coalesce them instead of repeatedly opening the same audio device.
        guard monitorAudio.state == .idle else { return }
        rmsWindow = []
        preRollFrames = []
        consecutiveSpeechFrames = 0
        monitorStartedAt = nil
        lastFrameAt = nil
        monitorFrameCount = 0
        monitorAudio.start(
            deviceUID: AudioInputDevicePreferenceStore.resolvedCachedDeviceUID(),
            onFrame: { [weak self] data in self?.handleMonitorAudio(data) },
            onReady: { [weak self] in self?.audioMonitorDidStart() },
            onFailure: { [weak self] error in
                DebugFileLogger.log("focus wakeup: local RMS monitor suspended error=\(error)")
                guard let self, !self.isManualRecordingPaused else { return }
                if self.appState?.barPhase == .hidden || self.appState?.barPhase == .focusWaiting {
                    self.appState?.showError(AudioCaptureError.converterCreationFailed.localizedDescription)
                }
            }
        )
    }

    /// Publishes readiness only after the background driver has actually started.
    private func audioMonitorDidStart() {
        guard config.enabled, currentFocus != nil,
              !isManualRecordingPaused, !isStartGatePausedByEscape else {
            monitorAudio.stop()
            return
        }
        monitorStartedAt = Date()
        appState?.showFocusWaiting()
        let threshold = resolveStartThreshold()
        let speechLow = threshold.speechLowRMS.map { String(Int($0)) } ?? "nil"
        let falseStartHigh = threshold.falseStartHighRMS.map { String(Int($0)) } ?? "nil"
        DebugFileLogger.log(
            "focus wakeup: local RMS monitor started threshold=\(Int(threshold.finalThreshold)) noise=\(Int(threshold.noiseThreshold)) speechLow=\(speechLow) falseStartHigh=\(falseStartHigh) deviceUID=\(Self.selectedMicrophoneUIDDescription())"
        )
    }

    /// Restores the blue focus-waiting UI when the monitor stayed alive across sessions.
    private func restoreFocusWaitingIfNeeded(now: Date = Date()) {
        guard let appState else { return }
        guard Self.shouldRestoreFocusWaitingUI(
            isMonitoringAudio: isMonitoringAudio,
            isFocusRecording: isFocusRecording,
            isManualRecordingPaused: isManualRecordingPaused,
            isStartGatePausedByEscape: isStartGatePausedByEscape,
            hasCurrentFocus: currentFocus != nil,
            rearmBlockedUntil: rearmBlockedUntil,
            now: now,
            barPhase: appState.barPhase
        ) else {
            return
        }
        appState.showFocusWaiting()
        DebugFileLogger.log("focus wakeup: focusWaiting restored while monitor remains active")
    }

    /// Determines whether focus waiting UI should be restored without reopening audio.
    ///
    /// Args:
    ///   isMonitoringAudio: Whether the local RMS monitor is already running.
    ///   isFocusRecording: Whether a focus-triggered recognition session is active.
    ///   isManualRecordingPaused: Whether manual hotkey recording owns the microphone.
    ///   isStartGatePausedByEscape: Whether Escape has paused the start RMS gate.
    ///   hasCurrentFocus: Whether an editable element is currently retained.
    ///   rearmBlockedUntil: Timestamp before which the next focus wakeup is blocked.
    ///   now: Current timestamp.
    ///   barPhase: Current floating bar phase.
    ///
    /// Returns:
    ///   True when the monitor is alive and ready, but the waiting UI is hidden.
    nonisolated static func shouldRestoreFocusWaitingUI(
        isMonitoringAudio: Bool,
        isFocusRecording: Bool,
        isManualRecordingPaused: Bool,
        isStartGatePausedByEscape: Bool,
        hasCurrentFocus: Bool,
        rearmBlockedUntil: Date,
        now: Date,
        barPhase: FloatingBarPhase
    ) -> Bool {
        guard isMonitoringAudio,
              !isFocusRecording,
              !isManualRecordingPaused,
              !isStartGatePausedByEscape,
              hasCurrentFocus,
              now >= rearmBlockedUntil else {
            return false
        }
        return barPhase == .hidden
    }

    /// Stops the local microphone monitor and clears pending RMS state.
    ///
    /// Args:
    ///   hideWaiting: Whether a visible focus-waiting bar should be hidden.
    private func stopAudioMonitoring(hideWaiting: Bool = false) {
        appState?.quietCalibrationSecondsRemaining = 0
        if quietGate.threshold == nil { quietGate = QuietWakeupGate() }
        let wasActive = monitorAudio.state == .starting || isMonitoringAudio
        monitorAudio.stop()
        rmsWindow = []
        preRollFrames = []
        consecutiveSpeechFrames = 0
        monitorStartedAt = nil
        lastFrameAt = nil
        monitorFrameCount = 0
        if hideWaiting, appState?.barPhase == .focusWaiting {
            appState?.cancel()
        }
        if wasActive {
            DebugFileLogger.log("focus wakeup: local RMS monitor stop queued; callbacks detached")
        }
    }

    /// Handles one audio chunk from the local monitor.
    ///
    /// Args:
    ///   data: PCM16 little-endian audio bytes captured from the selected microphone.
    private func handleMonitorAudio(_ data: Data) {
        lastFrameAt = Date()
        monitorFrameCount += 1
        if isFocusRecording {
            if externalAudioHandoff.route(data) == .queuedForDirectDelivery {
                startExternalAudioDeliveryIfNeeded()
            }
            return
        }
        guard currentFocus != nil, !isManualRecordingPaused else { return }
        guard Date() >= rearmBlockedUntil else { return }

        let requestedMode = FocusAcousticMode.resolve(UserDefaults.standard.string(forKey: FocusAcousticMode.storageKey))
        let deviceUID = AudioInputDevicePreferenceStore.activeCachedInputDevice()?.uid
        if requestedMode != acousticMode || deviceUID != quietDeviceUID {
            acousticMode = requestedMode
            quietDeviceUID = deviceUID
            quietGate = QuietWakeupGate()
            rmsWindow = []
            consecutiveSpeechFrames = 0
            preRollFrames = []
        }

        preRollFrames.append(data)
        if preRollFrames.count > config.preRollFrames {
            preRollFrames.removeFirst(preRollFrames.count - config.preRollFrames)
        }

        let stats = AudioCaptureEngine.pcm16FrameStats(from: data)
        let rms = stats.rms
        if acousticMode == .quiet {
            let wasCalibrating = quietGate.threshold == nil
            let triggered = quietGate.consume(rms)
            let remaining = quietGate.threshold == nil
                ? Int(ceil(Double(quietGate.calibrationRemaining) / 50)) : 0
            if appState?.quietCalibrationSecondsRemaining != remaining {
                appState?.quietCalibrationSecondsRemaining = remaining
            }
            if wasCalibrating, let threshold = quietGate.threshold {
                DebugFileLogger.log("quiet wakeup: calibrated threshold=\(threshold)")
            }
            if triggered, let threshold = quietGate.threshold {
                DebugFileLogger.log("quiet wakeup: triggered rms=\(rms) threshold=\(threshold)")
                lastFocusTriggerRMS = rms
                startFocusRecording(initialFrames: preRollFrames, triggerThreshold: threshold)
            }
            return
        }
        appState?.quietCalibrationSecondsRemaining = 0
        rmsWindow.append(rms)
        if rmsWindow.count > config.rmsWindowFrames {
            rmsWindow.removeFirst(rmsWindow.count - config.rmsWindowFrames)
        }
        if monitorFrameCount.isMultiple(of: 300) {
            DebugFileLogger.log(
                "focus wakeup: monitor audio health frame=\(monitorFrameCount) rms=\(Int(stats.rms)) min=\(stats.minSample) max=\(stats.maxSample) zeroRatio=\(String(format: "%.3f", stats.zeroRatio)) threshold=\(Int(effectiveStartThreshold())) focus=\(Self.focusLogDescription(currentFocus)) deviceUID=\(Self.selectedMicrophoneUIDDescription())"
            )
        }
        guard rmsWindow.count >= min(config.rmsWindowFrames, 2) else { return }

        let avg = rmsWindow.reduce(0, +) / Float(rmsWindow.count)
        let threshold = effectiveStartThreshold()
        if avg >= threshold {
            consecutiveSpeechFrames += 1
        } else {
            consecutiveSpeechFrames = 0
        }

        guard consecutiveSpeechFrames >= config.speechFrames else { return }
        let initialFrames = preRollFrames
        lastFocusTriggerRMS = avg
        DebugFileLogger.log(
            "focus wakeup: RMS triggered avg=\(Int(avg)) threshold=\(Int(threshold)) preRollFrames=\(initialFrames.count)"
        )
        startFocusRecording(initialFrames: initialFrames, triggerThreshold: threshold)
    }

    /// Starts an automatic direct dictation session for the current editable focus.
    ///
    /// Args:
    ///   initialFrames: PCM16 20ms frames captured immediately before RMS trigger.
    ///   triggerThreshold: RMS threshold that caused this focus recording to start.
    private func startFocusRecording(initialFrames: [Data], triggerThreshold: Float) {
        guard !isFocusRecording else { return }
        let initialChunks = Self.chunkAudioFrames(initialFrames)
        rmsWindow = []
        preRollFrames = []
        consecutiveSpeechFrames = 0
        isFocusRecording = true
        lastRecordingWasQuiet = acousticMode == .quiet
        resetExternalAudioHandoff()
        let handoffCapacity = FocusExternalAudioHandoffCapacityPolicy.frameCapacity(
            preRollFrames: config.preRollFrames
        )
        externalAudioHandoff.beginBuffering(maxBufferedFrames: handoffCapacity)

        let mode = Self.resolvedFocusWakeupMode(
            modes: ModeStorage().load(),
            storedModeId: UserDefaults.standard.string(forKey: Self.focusWakeupModeIdKey),
            provider: KeychainService.selectedASRProvider
        )
        guard onRecordingStartRequested?(mode, initialChunks, triggerThreshold, lastRecordingWasQuiet) == true else {
            DebugFileLogger.log("focus wakeup: shared recording start gate rejected request")
            isFocusRecording = false
            sessionDidFinish()
            return
        }
        DebugFileLogger.log(
            "focus wakeup: external audio awaiting claim capacity=\(handoffCapacity) frames"
        )
    }

    /// Claims post-trigger audio and starts one generation-owned serial delivery pump.
    ///
    /// This method performs the buffer-to-direct transition without suspending on the
    /// main actor. Frames arriving afterward append behind the retained claim frames,
    /// so one pump delivers the complete sequence without duplication or reordering.
    ///
    /// Args:
    ///   sessionGeneration: Recognition session generation that owns delivered frames.
    func sessionDidClaimExternalAudioInput(sessionGeneration: Int) {
        guard isFocusRecording else {
            resetExternalAudioHandoff()
            return
        }
        guard externalAudioHandoff.claimDirectDelivery() != nil else { return }
        externalAudioSessionGeneration = sessionGeneration
        startExternalAudioDeliveryIfNeeded()
    }

    /// Starts the serial external-audio pump when direct frames are waiting.
    private func startExternalAudioDeliveryIfNeeded() {
        guard externalAudioDeliveryTask == nil,
              isFocusRecording,
              externalAudioHandoff.phase == .direct,
              externalAudioHandoff.hasPendingDelivery else {
            return
        }
        let ownerGeneration = externalAudioHandoff.generation
        externalAudioDeliveryTaskGeneration = ownerGeneration
        externalAudioDeliveryTask = Task { @MainActor [weak self] in
            await self?.deliverExternalAudioFrames(ownerGeneration: ownerGeneration)
        }
    }

    /// Delivers claimed and live monitor frames in FIFO order for one generation.
    ///
    /// Args:
    ///   ownerGeneration: Focus generation that owns this delivery pump.
    private func deliverExternalAudioFrames(ownerGeneration: Int) async {
        guard let sessionGeneration = externalAudioSessionGeneration else { return }
        while !Task.isCancelled,
              isFocusRecording,
              externalAudioHandoff.generation == ownerGeneration,
              let frame = externalAudioHandoff.takeNextDeliveryFrame(
                  ownerGeneration: ownerGeneration
              ) {
            await session.acceptExternalAudioFrame(
                frame,
                expectedGeneration: sessionGeneration
            )
        }

        guard externalAudioDeliveryTaskGeneration == ownerGeneration else { return }
        externalAudioDeliveryTask = nil
        externalAudioDeliveryTaskGeneration = nil
        if isFocusRecording,
           externalAudioHandoff.generation == ownerGeneration,
           externalAudioHandoff.hasPendingDelivery {
            startExternalAudioDeliveryIfNeeded()
        }
    }

    /// Invalidates the current focus generation and cancels queued delivery work.
    private func resetExternalAudioHandoff() {
        externalAudioDeliveryTask?.cancel()
        externalAudioDeliveryTask = nil
        externalAudioDeliveryTaskGeneration = nil
        externalAudioSessionGeneration = nil
        externalAudioHandoff.reset()
    }

    /// Restarts the RMS monitor when AVCapture stopped delivering frames.
    private func recoverStaleAudioMonitoringIfNeeded() {
        let now = Date()
        guard Self.shouldReopenAudioMonitor(
            isMonitoringAudio: isMonitoringAudio,
            noFrameReopen: config.noFrameReopen,
            lastFrameAt: lastFrameAt,
            monitorStartedAt: monitorStartedAt,
            now: now
        ) else {
            return
        }
        let reference = lastFrameAt ?? monitorStartedAt ?? now
        let idle = now.timeIntervalSince(reference)
        let reason = lastFrameAt == nil ? "no first frame" : "stale frames"
        DebugFileLogger.log("focus wakeup: monitor \(reason) for \(String(format: "%.2f", idle))s, reopening")
        stopAudioMonitoring()
        startAudioMonitoring()
    }

    /// Determines whether the RMS monitor should be reopened.
    ///
    /// Args:
    ///   isMonitoringAudio: Whether the monitor is believed to be running.
    ///   noFrameReopen: Timeout in seconds before a silent monitor is considered stale.
    ///   lastFrameAt: Time when the most recent frame arrived.
    ///   monitorStartedAt: Time when the monitor was started.
    ///   now: Current timestamp.
    ///
    /// Returns:
    ///   `true` when the monitor has produced no frames or stale frames past the timeout.
    nonisolated static func shouldReopenAudioMonitor(
        isMonitoringAudio: Bool,
        noFrameReopen: TimeInterval,
        lastFrameAt: Date?,
        monitorStartedAt: Date?,
        now: Date
    ) -> Bool {
        guard isMonitoringAudio, noFrameReopen > 0 else { return false }
        guard let reference = lastFrameAt ?? monitorStartedAt else { return false }
        return now.timeIntervalSince(reference) >= noFrameReopen
    }

    /// Resolves the RMS threshold used to enter a focus-triggered recording.
    ///
    /// Returns:
    ///   A bottom-noise-derived threshold when calibrated, otherwise the
    ///   configured fallback threshold.
    private func effectiveStartThreshold() -> Float {
        resolveStartThreshold().finalThreshold
    }

    /// Resolves the start threshold and the profile values that shaped it.
    ///
    /// Returns:
    ///   Threshold components used by the local RMS wakeup monitor.
    private func resolveStartThreshold() -> StartThresholdResolution {
        let noiseThreshold: Float
        if let snapshot = NoiseFloorStore.snapshot() {
            noiseThreshold = max(snapshot.threshold, config.minStartRMSThreshold, config.startThresholdFloor)
        } else {
            noiseThreshold = max(config.fallbackStartThreshold, config.minStartRMSThreshold)
        }
        let speechLowRMS = SpeechRMSProfileStore.snapshot()?.lowSpeechRMS
        let falseStartHighRMS = FalseStartRMSProfileStore.snapshot()?.highFalseStartRMS
        let finalThreshold = Self.learnedStartThreshold(
            noiseThreshold: noiseThreshold,
            speechLowRMS: speechLowRMS,
            falseStartHighRMS: falseStartHighRMS,
            minGap: config.speechProfileMinGap,
            blend: config.speechProfileBlend,
            falseStartMargin: config.falseStartNoiseMargin,
            falseStartCapBlend: config.falseStartSpeechCapBlend,
            coldStartCapMultiplier: config.falseStartColdStartCapMultiplier
        )
        return StartThresholdResolution(
            noiseThreshold: noiseThreshold,
            speechLowRMS: speechLowRMS,
            falseStartHighRMS: falseStartHighRMS,
            finalThreshold: finalThreshold
        )
    }

    /// Places the start threshold between stable ambient noise and learned speech RMS.
    ///
    /// Args:
    ///   noiseThreshold: Threshold derived from bottom-noise calibration.
    ///   speechLowRMS: Lower percentile of ASR-confirmed user speech RMS.
    ///   minGap: Minimum separation needed before speech profile can affect wakeup.
    ///   blend: Fraction of the noise-to-speech gap used for the lift.
    ///
    /// Returns:
    ///   Noise threshold, or a stable in-between threshold when speech is well separated.
    nonisolated static func speechProfileStartThreshold(
        noiseThreshold: Float,
        speechLowRMS: Float?,
        minGap: Float,
        blend: Float
    ) -> Float {
        learnedStartThreshold(
            noiseThreshold: noiseThreshold,
            speechLowRMS: speechLowRMS,
            falseStartHighRMS: nil,
            minGap: minGap,
            blend: blend,
            falseStartMargin: 0,
            falseStartCapBlend: 0,
            coldStartCapMultiplier: 1
        )
    }

    /// Places the start threshold between noise, false-start noise, and learned speech RMS.
    ///
    /// Args:
    ///   noiseThreshold: Threshold derived from bottom-noise calibration.
    ///   speechLowRMS: Lower percentile of ASR-confirmed user speech RMS.
    ///   falseStartHighRMS: High percentile of recent ASR-empty false-start triggers.
    ///   minGap: Minimum separation needed before speech profile can affect wakeup.
    ///   blend: Fraction of the noise-to-speech gap used for the base threshold.
    ///   falseStartMargin: RMS margin added above learned false-start noise.
    ///   falseStartCapBlend: Maximum fraction of the noise-to-speech gap allowed for false-start learning.
    ///   coldStartCapMultiplier: Maximum multiplier over noise threshold before speech RMS is known.
    ///
    /// Returns:
    ///   Stable threshold that can move above learned false-start noise without crossing the speech-side cap.
    nonisolated static func learnedStartThreshold(
        noiseThreshold: Float,
        speechLowRMS: Float?,
        falseStartHighRMS: Float?,
        minGap: Float,
        blend: Float,
        falseStartMargin: Float,
        falseStartCapBlend: Float,
        coldStartCapMultiplier: Float
    ) -> Float {
        guard let speechLowRMS, speechLowRMS > noiseThreshold + max(minGap, 0) else {
            let baseThreshold = noiseThreshold
            guard let falseStartHighRMS, falseStartHighRMS.isFinite, falseStartHighRMS > baseThreshold else {
                return baseThreshold
            }
            let learnedThreshold = max(baseThreshold, falseStartHighRMS + max(falseStartMargin, 0))
            let coldStartCap = max(baseThreshold, noiseThreshold * max(coldStartCapMultiplier, 1))
            return min(learnedThreshold, coldStartCap)
        }
        let clampedBlend = min(max(blend, 0), 1)
        let baseThreshold = noiseThreshold + (speechLowRMS - noiseThreshold) * clampedBlend
        guard let falseStartHighRMS, falseStartHighRMS.isFinite, falseStartHighRMS > baseThreshold else {
            return baseThreshold
        }
        let learnedThreshold = max(baseThreshold, falseStartHighRMS + max(falseStartMargin, 0))
        let clampedCapBlend = min(max(falseStartCapBlend, 0), 1)
        let speechSideCap = max(
            baseThreshold,
            noiseThreshold + (speechLowRMS - noiseThreshold) * clampedCapBlend
        )
        return min(learnedThreshold, speechSideCap)
    }

    /// Coalesces 20ms pre-roll frames into ASR-sized chunks.
    ///
    /// Args:
    ///   frames: PCM16 20ms frames from the local RMS monitor.
    ///
    /// Returns:
    ///   PCM chunks no larger than the standard 200ms ASR chunk, with a final
    ///   partial chunk kept when the pre-roll length is not exactly divisible.
    private static func chunkAudioFrames(_ frames: [Data]) -> [Data] {
        var pending = Data()
        var chunks: [Data] = []
        for frame in frames {
            pending.append(frame)
            while pending.count >= AudioCaptureEngine.chunkByteSize {
                chunks.append(Data(pending.prefix(AudioCaptureEngine.chunkByteSize)))
                pending.removeFirst(AudioCaptureEngine.chunkByteSize)
            }
        }
        if !pending.isEmpty {
            chunks.append(pending)
        }
        return chunks
    }

    /// Probes the current frontmost editable focus, excluding mytype itself.
    ///
    /// Returns:
    ///   Editable, unknown, or confirmed non-editable state for retention policy.
    private func currentFocusProbe() -> FocusProbe {
        guard AXIsProcessTrusted() else { return .confirmedNoEditableFocus }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return .confirmedNoEditableFocus
        }
        guard frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return .confirmedNoEditableFocus
        }

        let pid = frontmost.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        switch copyFocusedElement(from: app) {
        case .found(let element):
            if let focus = editableSignature(for: element, pid: pid) {
                return .editable(focus, pid: pid)
            }
            if Self.shouldUseEditableWindowFallback(focusedElementWasUnavailable: false),
               let fallback = findEditableElementInApp(frontmost),
               let focus = editableSignature(for: fallback, pid: pid) {
                return .editable(focus, pid: pid)
            }
            return .confirmedNoEditableFocus

        case .unavailable:
            enableEnhancedAX(for: frontmost)
            usleep(30_000)
            if case .found(let element) = copyFocusedElement(from: app),
               let focus = editableSignature(for: element, pid: pid) {
                return .editable(focus, pid: pid)
            }
            if Self.shouldUseEditableWindowFallback(focusedElementWasUnavailable: true),
               let fallback = findEditableElementInApp(frontmost),
               let focus = editableSignature(for: fallback, pid: pid) {
                return .editable(focus, pid: pid)
            }
            return .unknown(pid: pid)
        }
    }

    /// Returns whether window traversal can be used as a focus fallback.
    ///
    /// Args:
    ///   focusedElementWasUnavailable: Whether AX failed to provide a focused element.
    ///
    /// Returns:
    ///   True only when focused-element lookup failed; known non-editable focus
    ///   must not search the whole window for unrelated inputs.
    nonisolated static func shouldUseEditableWindowFallback(focusedElementWasUnavailable: Bool) -> Bool {
        focusedElementWasUnavailable
    }

    /// Copies the focused UI element from an accessibility application object.
    ///
    /// Args:
    ///   app: Accessibility object for the frontmost application.
    ///
    /// Returns:
    ///   Focused element when available, otherwise an unknown accessibility state.
    private func copyFocusedElement(from app: AXUIElement) -> FocusedElementLookup {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else {
            return .unavailable
        }
        return .found(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// Enables enhanced accessibility on the frontmost window.
    ///
    /// Args:
    ///   app: Frontmost application that may expose a lazy Chromium AX tree.
    private func enableEnhancedAX(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        AXUIElementSetAttributeValue(
            window,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    /// Traverses the frontmost app's focused window to find an editable child.
    ///
    /// Args:
    ///   app: Frontmost app to inspect.
    ///
    /// Returns:
    ///   First editable accessibility element found in the focused window.
    private func findEditableElementInApp(_ app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        return findEditableChild(in: window, maxDepth: 8)
    }

    /// Searches an accessibility subtree for an editable element.
    ///
    /// Args:
    ///   element: Root element to inspect.
    ///   depth: Current recursion depth.
    ///   maxDepth: Maximum recursion depth.
    ///
    /// Returns:
    ///   Editable element when one is found.
    private func findEditableChild(in element: AXUIElement, depth: Int = 0, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        if isEditableRole(role: role, subrole: subrole) || isEditableAttributeSettable(element) {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findEditableChild(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Builds a stable signature for an editable accessibility element.
    ///
    /// Args:
    ///   element: Candidate accessibility element.
    ///   pid: Owning process identifier for the frontmost app.
    ///
    /// Returns:
    ///   A focus signature when the candidate is editable.
    private func editableSignature(for element: AXUIElement, pid: pid_t) -> FocusSignature? {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        guard isEditableRole(role: role, subrole: subrole) || isEditableAttributeSettable(element) else { return nil }
        let identity = stringAttribute(element, "AXIdentifier")
            ?? stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? ""
        return FocusSignature(pid: pid, role: subrole.isEmpty ? role : "\(role):\(subrole)", identity: identity)
    }

    /// Reads a string accessibility attribute.
    ///
    /// Args:
    ///   element: Accessibility element to read from.
    ///   attribute: Accessibility attribute name.
    ///
    /// Returns:
    ///   The string value when present.
    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Returns whether an accessibility role should be treated as editable text input.
    ///
    /// Args:
    ///   role: AX role string.
    ///   subrole: AX subrole string.
    ///
    /// Returns:
    ///   True when the element is likely to accept typed dictation text.
    private func isEditableRole(role: String, subrole: String) -> Bool {
        let editableRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            "AXSearchField",
        ]
        if editableRoles.contains(role) { return true }
        if role == "AXWebArea" && subrole.contains("Text") { return true }
        if role == kAXGroupRole && subrole.contains("Text") { return true }
        return false
    }

    /// Returns whether an accessibility element exposes editable text attributes.
    ///
    /// Args:
    ///   element: Accessibility element to inspect.
    ///
    /// Returns:
    ///   True when the element allows setting text selection or value.
    private func isEditableAttributeSettable(_ element: AXUIElement) -> Bool {
        isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
    }

    /// Returns whether an accessibility attribute is settable on an element.
    ///
    /// Args:
    ///   attribute: Accessibility attribute name.
    ///   element: Accessibility element to inspect.
    ///
    /// Returns:
    ///   True when the attribute is settable.
    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    /// Formats focus state for bounded diagnostic logs.
    ///
    /// Args:
    ///   focus: Focus signature currently tracked by focus wakeup.
    ///
    /// Returns:
    ///   Stable, non-content focus description.
    private static func focusLogDescription(_ focus: FocusSignature?) -> String {
        guard let focus else { return "nil" }
        return "pid=\(focus.pid) role=\(focus.role)"
    }

    /// Reads the selected microphone UID for diagnostic logs.
    ///
    /// Returns:
    ///   Selected microphone UID, or "default" when the system default is used.
    private static func selectedMicrophoneUIDDescription() -> String {
        guard let uid = AudioInputDevicePreferenceStore.resolvedCachedDeviceUID() else {
            return "default"
        }
        return uid
    }
}

private extension UserDefaults {
    /// Reads an integer default while preserving an explicit zero value.
    ///
    /// Args:
    ///   key: UserDefaults key.
    ///   defaultValue: Fallback used when the key does not exist.
    ///
    /// Returns:
    ///   Stored integer or fallback value.
    func integerOrDefault(_ key: String, defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }

    /// Reads a floating-point default while preserving an explicit zero value.
    ///
    /// Args:
    ///   key: UserDefaults key.
    ///   defaultValue: Fallback used when the key does not exist.
    ///
    /// Returns:
    ///   Stored double or fallback value.
    func doubleOrDefault(_ key: String, defaultValue: Double) -> Double {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }
}
