import CoreServices
import Foundation

final class CodexSessionIndexWatcher: @unchecked Sendable {
    static let defaultDebounceDelay: TimeInterval = 1.0
    static let eventLatency: CFTimeInterval = 0.5

    private struct State {
        var generation = 0
        var isStarted = false
    }

    private let sessionsRoot: URL
    private let debounceDelay: TimeInterval
    private let reconcile: @Sendable () -> Void
    private let scheduler: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let fileManager: FileManager
    private let eventQueue = DispatchQueue(label: "mytype.codex-session-index-watcher", qos: .utility)
    private let stateLock = NSLock()
    private var state = State()
    private var stream: FSEventStreamRef?

    /// Creates a watcher that refreshes the Codex session index after file changes.
    ///
    /// Args:
    ///   sessionsRoot: Root directory containing Codex session jsonl files.
    ///   debounceDelay: Delay used to coalesce bursts of file events.
    ///   sessionIndex: Session index store refreshed by the watcher.
    ///   fileManager: File manager used to ensure the watched directory exists.
    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        debounceDelay: TimeInterval = CodexSessionIndexWatcher.defaultDebounceDelay,
        sessionIndex: CodexSessionIndexStore = .shared,
        fileManager: FileManager = .default
    ) {
        self.sessionsRoot = sessionsRoot
        self.debounceDelay = debounceDelay
        self.fileManager = fileManager
        self.reconcile = {
            _ = sessionIndex.reconcileSessionIndex()
        }
        self.scheduler = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    /// Creates a testable watcher with injected reconcile and scheduler hooks.
    ///
    /// Args:
    ///   sessionsRoot: Root directory containing Codex session jsonl files.
    ///   debounceDelay: Delay used to coalesce bursts of file events.
    ///   reconcile: Callback invoked after a stable event burst.
    ///   scheduler: Scheduler used for debounce timing.
    init(
        sessionsRoot: URL,
        debounceDelay: TimeInterval,
        reconcile: @escaping @Sendable () -> Void,
        scheduler: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) {
        self.sessionsRoot = sessionsRoot
        self.debounceDelay = debounceDelay
        self.fileManager = .default
        self.reconcile = reconcile
        self.scheduler = scheduler
    }

    deinit {
        stop()
    }

    /// Reconciles the session index once and starts watching for future changes.
    func reconcileAndStart() {
        reconcile()
        start()
    }

    /// Starts listening for Codex session file changes.
    func start() {
        stateLock.lock()
        if state.isStarted {
            stateLock.unlock()
            return
        }
        state.isStarted = true
        stateLock.unlock()

        do {
            try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        } catch {
            DebugFileLogger.log("CodexSessionIndexWatcher create directory failed: \(error.localizedDescription)")
            markStopped()
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            [sessionsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.eventLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else {
            DebugFileLogger.log("CodexSessionIndexWatcher failed to create FSEvent stream")
            markStopped()
            return
        }
        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, eventQueue)
        if FSEventStreamStart(createdStream) {
            DebugFileLogger.log("CodexSessionIndexWatcher started root=\(sessionsRoot.path)")
        } else {
            DebugFileLogger.log("CodexSessionIndexWatcher failed to start FSEvent stream")
            stop()
        }
    }

    /// Stops listening for session file changes.
    func stop() {
        guard let stream else {
            markStopped()
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        markStopped()
        DebugFileLogger.log("CodexSessionIndexWatcher stopped")
    }

    /// Handles a session file event and schedules a debounced reconcile.
    func sessionEventsDidChange() {
        let generation: Int
        stateLock.lock()
        state.generation += 1
        generation = state.generation
        stateLock.unlock()

        scheduler(debounceDelay) { [weak self] in
            self?.reconcileIfCurrent(generation)
        }
    }

    private func reconcileIfCurrent(_ generation: Int) {
        stateLock.lock()
        let shouldRun = generation == state.generation
        stateLock.unlock()
        guard shouldRun else { return }
        DebugFileLogger.log("CodexSessionIndexWatcher reconciling after file event")
        reconcile()
    }

    private func markStopped() {
        stateLock.lock()
        state.isStarted = false
        stateLock.unlock()
    }

    private static let streamCallback: FSEventStreamCallback = {
        _, clientInfo, _, _, _, _ in
        guard let clientInfo else { return }
        let watcher = Unmanaged<CodexSessionIndexWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
        watcher.sessionEventsDidChange()
    }
}
