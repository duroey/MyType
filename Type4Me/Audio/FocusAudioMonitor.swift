import Foundation

/// Serializes blocking microphone operations away from the UI and bounds UI waits.
@MainActor
final class FocusAudioMonitor {
    enum State: Equatable {
        case idle, starting, running, stopping, failed
    }

    enum Failure: Error, Equatable {
        case startTimedOut, stopTimedOut
    }

    struct Configuration {
        var operationTimeout: TimeInterval
        var releasePollInterval: Duration = .milliseconds(20)

        /// Loads the bounded audio lifecycle deadline without changing preferences.
        ///
        /// Args:
        ///   defaults: Store containing optional diagnostic tuning.
        ///
        /// Returns:
        ///   A finite positive deadline, defaulting to five and capped at thirty seconds.
        static func load(defaults: UserDefaults = .standard) -> Configuration {
            let defaultTimeout: TimeInterval = 5
            let maximumTimeout: TimeInterval = 30
            let value = defaults.object(forKey: "tf_focusAudioOperationTimeout") as? Double ?? defaultTimeout
            return Configuration(
                operationTimeout: value.isFinite && value > 0 ? min(value, maximumTimeout) : defaultTimeout
            )
        }
    }

    typealias FrameHandler = @Sendable (Data) -> Void
    typealias StartCapture = @Sendable (String?, @escaping FrameHandler) throws -> Void

    private(set) var state: State = .idle
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.mytype.focus-audio-lifecycle", qos: .userInitiated)
    private let startCapture: StartCapture
    private let stopCapture: @Sendable () -> Void
    private var generation = 0
    private var cleanupPending = false
    private var watchdog: Task<Void, Never>?
    private var frameHandler: ((Data) -> Void)?
    private var readyHandler: (() -> Void)?
    private var failureHandler: ((Error) -> Void)?

    /// Creates a monitor whose real capture engine is accessed only on its worker queue.
    convenience init() {
        let engine = AudioCaptureEngine()
        self.init(
            configuration: .load(),
            startCapture: { deviceUID, onFrame in
                engine.selectedDeviceUID = deviceUID
                engine.onAudioFrame = onFrame
                try engine.start()
            },
            stopCapture: { engine.stop() }
        )
    }

    /// Creates a monitor with injectable, synchronous hardware operations.
    ///
    /// Args:
    ///   configuration: Lifecycle deadlines and release polling cadence.
    ///   startCapture: Blocking startup implementation, executed off the main thread.
    ///   stopCapture: Blocking cleanup implementation, serialized after startup.
    init(
        configuration: Configuration,
        startCapture: @escaping StartCapture,
        stopCapture: @escaping @Sendable () -> Void
    ) {
        self.configuration = configuration
        self.startCapture = startCapture
        self.stopCapture = stopCapture
    }

    /// Starts at most one capture and delivers callbacks only for its active generation.
    ///
    /// Args:
    ///   deviceUID: Frozen microphone selection for this attempt.
    ///   onFrame: Main-actor consumer of frames from a ready, uncancelled capture.
    ///   onReady: Notification after synchronous hardware startup actually returns.
    ///   onFailure: Notification of startup errors or lifecycle timeouts.
    ///
    /// Returns:
    ///   True when accepted; false while busy or suspended after a failure.
    @discardableResult
    func start(
        deviceUID: String?,
        onFrame: @escaping (Data) -> Void,
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> Bool {
        guard state == .idle else { return false }
        generation &+= 1
        let owner = generation
        state = .starting
        frameHandler = onFrame
        readyHandler = onReady
        failureHandler = onFailure
        startWatchdog(owner: owner)
        DebugFileLogger.log("focus audio: start queued generation=\(owner)")
        queue.async { [startCapture] in
            let result = Result {
                try startCapture(deviceUID) { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == owner, self.state == .running else { return }
                        self.frameHandler?(frame)
                    }
                }
            }
            Task { @MainActor in self.finishStart(result, owner: owner) }
        }
        return true
    }

    /// Invalidates callbacks immediately and queues teardown without blocking the UI.
    func stop() {
        guard state == .starting || state == .running else { return }
        enqueueStop(preserveFailure: false)
    }

    /// Explicitly re-arms a failed monitor, but only after hardware cleanup has returned.
    ///
    /// Returns:
    ///   True when idle and safe to retry; false while hardware is still owned.
    @discardableResult
    func resetFailure() -> Bool {
        if state == .failed, !cleanupPending { state = .idle }
        return state == .idle
    }

    /// Waits cooperatively for actual hardware release before manual recording takes over.
    ///
    /// Returns:
    ///   False on cancellation or deadline; a failed-but-cleaned-up monitor is released.
    func waitUntilStopped() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(configuration.operationTimeout)
        while cleanupPending || state == .starting || state == .running {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: configuration.releasePollInterval) }
            catch { return false }
        }
        return !Task.isCancelled
    }

    /// Accepts hardware startup only if its request still owns this monitor.
    ///
    /// Args:
    ///   result: Outcome from the blocking hardware operation.
    ///   owner: Generation captured before startup was queued.
    private func finishStart(_ result: Result<Void, Error>, owner: Int) {
        guard generation == owner, state == .starting else { return }
        watchdog?.cancel()
        watchdog = nil
        switch result {
        case .success:
            state = .running
            let ready = readyHandler
            readyHandler = nil
            ready?()
        case .failure(let error):
            state = .failed
            enqueueStop(preserveFailure: true)
            failureHandler?(error)
        }
    }

    /// Queues exactly one cleanup behind startup, including startup that is still blocked.
    ///
    /// Args:
    ///   preserveFailure: Whether cleanup must leave automatic retries suspended.
    private func enqueueStop(preserveFailure: Bool) {
        generation &+= 1
        let owner = generation
        watchdog?.cancel()
        watchdog = nil
        frameHandler = nil
        readyHandler = nil
        cleanupPending = true
        if !preserveFailure { state = .stopping }
        queue.async { [stopCapture] in
            stopCapture()
            Task { @MainActor in
                guard self.generation == owner else { return }
                self.cleanupPending = false
                self.watchdog?.cancel()
                self.watchdog = nil
                self.failureHandler = nil
                if self.state == .stopping { self.state = .idle }
                DebugFileLogger.log("focus audio: hardware released generation=\(owner) state=\(self.state)")
            }
        }
        if !preserveFailure { startWatchdog(owner: owner) }
    }

    /// Bounds the UI-facing operation; never races another stop against a blocked driver.
    ///
    /// Args:
    ///   owner: Generation whose pending start or stop is being timed.
    private func startWatchdog(owner: Int) {
        watchdog?.cancel()
        let timeout = configuration.operationTimeout
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            guard let self, self.generation == owner else { return }
            let failure: Failure
            switch self.state {
            case .starting:
                failure = .startTimedOut
                self.state = .failed
                self.enqueueStop(preserveFailure: true)
            case .stopping:
                failure = .stopTimedOut
                self.state = .failed
            default:
                return
            }
            DebugFileLogger.log("focus audio: \(failure) after \(timeout)s; automatic retries suspended, cleanup still pending")
            self.failureHandler?(failure)
        }
    }
}
