import AppKit
import ApplicationServices

@MainActor
final class FocusWakeupController {
    private struct FocusSignature: Equatable {
        let pid: pid_t
        let role: String
        let identity: String
    }

    private struct Config {
        let enabled: Bool
        let startNoiseMargin: Float
        let minStartRMSThreshold: Float
        let startThresholdFloor: Float
        let fallbackStartThreshold: Float
        let rmsWindowFrames: Int
        let speechFrames: Int
        let preRollFrames: Int
        let rearmDelay: TimeInterval
        let rearmQuietFrames: Int
        let quietRMSThreshold: Float
        let pollInterval: TimeInterval
        let noFrameReopen: TimeInterval

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
                startNoiseMargin: Float(defaults.object(forKey: "tf_focusStartNoiseMargin") as? Double ?? 160),
                minStartRMSThreshold: Float(defaults.object(forKey: "tf_focusMinStartRMSThreshold") as? Double ?? 160),
                startThresholdFloor: Float(defaults.object(forKey: "tf_focusStartThresholdFloor") as? Double ?? 300),
                fallbackStartThreshold: Float(
                    defaults.object(forKey: "tf_focusStartThreshold") as? Double
                        ?? defaults.object(forKey: "tf_focusAutoStopRMSThreshold") as? Double
                        ?? 500
                ),
                rmsWindowFrames: max(1, defaults.integerOrDefault("tf_focusRMSWindowFrames", defaultValue: 10)),
                speechFrames: max(1, defaults.integerOrDefault("tf_focusSpeechFrames", defaultValue: 4)),
                preRollFrames: max(0, defaults.integerOrDefault("tf_focusPreRollFrames", defaultValue: 25)),
                rearmDelay: defaults.doubleOrDefault("tf_focusRearmDelay", defaultValue: 0.8),
                rearmQuietFrames: max(1, defaults.integerOrDefault("tf_focusRearmQuietFrames", defaultValue: 25)),
                quietRMSThreshold: Float(defaults.object(forKey: "tf_focusQuietRMSThreshold") as? Double ?? 250),
                pollInterval: defaults.doubleOrDefault("tf_focusPollInterval", defaultValue: 0.35),
                noFrameReopen: defaults.doubleOrDefault("tf_focusNoFrameReopen", defaultValue: 1.0)
            )
        }
    }

    private weak var appState: AppState?
    private let session: RecognitionSession
    private let monitorAudio = AudioCaptureEngine()
    private var timer: Timer?
    private var currentFocus: FocusSignature?
    private var isMonitoringAudio = false
    private var isFocusRecording = false
    private var isManualRecordingPaused = false
    private var rearmBlockedUntil = Date.distantPast
    private var rmsWindow: [Float] = []
    private var preRollFrames: [Data] = []
    private var consecutiveSpeechFrames = 0
    private var consecutiveQuietFrames = 0
    private var lastFrameAt: Date?
    private var config = Config.load()

    /// Creates a controller for focus-based automatic dictation.
    ///
    /// Args:
    ///   appState: Shared UI state used to start the floating bar.
    ///   session: Recognition session that performs ASR, LLM, and text injection.
    init(appState: AppState, session: RecognitionSession) {
        self.appState = appState
        self.session = session
    }

    /// Starts watching focused editable elements.
    func start() {
        config = Config.load()
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
        timer?.invalidate()
        timer = nil
        stopAudioMonitoring(hideWaiting: true)
        currentFocus = nil
        isFocusRecording = false
    }

    /// Pauses focus wakeup while a manual hotkey recording owns the microphone.
    func pauseForManualRecording() {
        isManualRecordingPaused = true
        stopAudioMonitoring()
    }

    /// Marks a recording as finished and allows focus wakeup to re-arm.
    func sessionDidFinish() {
        isFocusRecording = false
        isManualRecordingPaused = false
        rearmBlockedUntil = Date().addingTimeInterval(config.rearmDelay)
    }

    /// Checks whether the frontmost app has an editable focused element.
    ///
    /// Starts or stops the local RMS monitor according to the current focus state.
    private func checkFocusedElement() {
        guard config.enabled else { return }
        guard !isManualRecordingPaused, !isFocusRecording else { return }
        guard Date() >= rearmBlockedUntil else { return }

        guard let focus = currentEditableFocus() else {
            if currentFocus != nil {
                DebugFileLogger.log("focus wakeup: editable focus lost")
            }
            currentFocus = nil
            stopAudioMonitoring(hideWaiting: true)
            return
        }

        if focus != currentFocus {
            currentFocus = focus
            DebugFileLogger.log("focus wakeup: editable focus armed pid=\(focus.pid) role=\(focus.role)")
            startAudioMonitoring()
        } else if !isMonitoringAudio {
            startAudioMonitoring()
        } else {
            recoverStaleAudioMonitoringIfNeeded()
        }
    }

    /// Starts a low-cost local microphone monitor for RMS wakeup detection.
    private func startAudioMonitoring() {
        guard !isMonitoringAudio else { return }
        rmsWindow = []
        preRollFrames = []
        consecutiveSpeechFrames = 0
        consecutiveQuietFrames = 0
        lastFrameAt = nil
        monitorAudio.selectedDeviceUID = UserDefaults.standard.string(forKey: "tf_selectedMicrophoneUID")
        monitorAudio.onAudioFrame = { [weak self] data in
            Task { @MainActor in
                self?.handleMonitorAudio(data)
            }
        }
        do {
            try monitorAudio.start()
            isMonitoringAudio = true
            appState?.showFocusWaiting()
            DebugFileLogger.log("focus wakeup: local RMS monitor started threshold=\(Int(effectiveStartThreshold()))")
        } catch {
            DebugFileLogger.log("focus wakeup: local RMS monitor failed \(error)")
            isMonitoringAudio = false
        }
    }

    /// Stops the local microphone monitor and clears pending RMS state.
    ///
    /// Args:
    ///   hideWaiting: Whether a visible focus-waiting bar should be hidden.
    private func stopAudioMonitoring(hideWaiting: Bool = false) {
        guard isMonitoringAudio else { return }
        monitorAudio.stop()
        isMonitoringAudio = false
        rmsWindow = []
        preRollFrames = []
        consecutiveSpeechFrames = 0
        consecutiveQuietFrames = 0
        lastFrameAt = nil
        if hideWaiting, appState?.barPhase == .focusWaiting {
            appState?.cancel()
        }
        DebugFileLogger.log("focus wakeup: local RMS monitor stopped")
    }

    /// Handles one audio chunk from the local monitor.
    ///
    /// Args:
    ///   data: PCM16 little-endian audio bytes captured from the selected microphone.
    private func handleMonitorAudio(_ data: Data) {
        guard currentFocus != nil, !isFocusRecording, !isManualRecordingPaused else { return }
        lastFrameAt = Date()
        preRollFrames.append(data)
        if preRollFrames.count > config.preRollFrames {
            preRollFrames.removeFirst(preRollFrames.count - config.preRollFrames)
        }

        let rms = Self.rms16(data)
        rmsWindow.append(rms)
        if rmsWindow.count > config.rmsWindowFrames {
            rmsWindow.removeFirst(rmsWindow.count - config.rmsWindowFrames)
        }
        guard rmsWindow.count >= min(config.rmsWindowFrames, 2) else { return }

        let avg = rmsWindow.reduce(0, +) / Float(rmsWindow.count)
        if avg <= config.quietRMSThreshold {
            consecutiveQuietFrames += 1
        } else {
            consecutiveQuietFrames = 0
        }

        let threshold = effectiveStartThreshold()
        if avg >= threshold {
            consecutiveSpeechFrames += 1
        } else {
            consecutiveSpeechFrames = 0
        }

        guard consecutiveSpeechFrames >= config.speechFrames else { return }
        let initialFrames = preRollFrames
        DebugFileLogger.log("focus wakeup: RMS triggered avg=\(Int(avg)) threshold=\(Int(threshold)) preRollFrames=\(initialFrames.count)")
        startFocusRecording(initialFrames: initialFrames)
    }

    /// Starts an automatic direct dictation session for the current editable focus.
    ///
    /// Args:
    ///   initialFrames: PCM16 20ms frames captured immediately before RMS trigger.
    private func startFocusRecording(initialFrames: [Data]) {
        guard !isFocusRecording else { return }
        let initialChunks = Self.chunkAudioFrames(initialFrames)
        stopAudioMonitoring()
        isFocusRecording = true

        let mode = ProcessingMode.direct
        Task { @MainActor in
            let ready = await session.awaitIdle()
            if !ready {
                DebugFileLogger.log("focus wakeup: previous session did not reach idle before start")
                isFocusRecording = false
                sessionDidFinish()
                return
            }
            appState?.currentMode = mode
            appState?.startRecording()
            await session.startRecording(
                mode: mode,
                autoStopOnSilence: true,
                initialAudioChunks: initialChunks
            )
        }
    }

    /// Restarts the RMS monitor when AVCapture stopped delivering frames.
    private func recoverStaleAudioMonitoringIfNeeded() {
        guard isMonitoringAudio, config.noFrameReopen > 0 else { return }
        guard let lastFrameAt else { return }
        let idle = Date().timeIntervalSince(lastFrameAt)
        guard idle >= config.noFrameReopen else { return }
        DebugFileLogger.log("focus wakeup: monitor stale for \(String(format: "%.2f", idle))s, reopening")
        stopAudioMonitoring()
        startAudioMonitoring()
    }

    /// Resolves the RMS threshold used to enter a focus-triggered recording.
    ///
    /// Returns:
    ///   A bottom-noise-derived threshold when calibrated, otherwise the
    ///   configured fallback threshold.
    private func effectiveStartThreshold() -> Float {
        if let snapshot = NoiseFloorStore.snapshot() {
            return max(
                snapshot.noiseFloor + config.startNoiseMargin,
                config.minStartRMSThreshold,
                config.startThresholdFloor
            )
        }
        return max(config.fallbackStartThreshold, config.minStartRMSThreshold)
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

    /// Finds the current frontmost editable focus, excluding mytype itself.
    ///
    /// Returns:
    ///   A focus signature only when the actual AX-focused element is editable.
    private func currentEditableFocus() -> FocusSignature? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        guard frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let pid = frontmost.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let element = copyFocusedElement(from: app) else { return nil }
        return editableSignature(for: element, pid: pid)
    }

    /// Copies the focused UI element from an accessibility application object.
    ///
    /// Args:
    ///   app: Accessibility object for the frontmost application.
    ///
    /// Returns:
    ///   The focused UI element when the app exposes one.
    private func copyFocusedElement(from app: AXUIElement) -> AXUIElement? {
        copyElementAttribute(app, attribute: kAXFocusedUIElementAttribute)
    }

    /// Copies an accessibility attribute that is expected to contain a UI element.
    ///
    /// Args:
    ///   element: Accessibility element to read from.
    ///   attribute: Accessibility attribute name.
    ///
    /// Returns:
    ///   The attribute value cast as an AXUIElement, or nil when unavailable.
    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
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
        guard isEditableRole(role: role, subrole: subrole) else { return nil }
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

    /// Calculates RMS from PCM16 audio bytes.
    ///
    /// Args:
    ///   data: PCM16 little-endian audio bytes.
    ///
    /// Returns:
    ///   Root mean square amplitude in Int16 sample units.
    private static func rms16(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let value = Float(base[index])
                sum += value * value
            }
        }
        return sqrt(sum / Float(sampleCount))
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
