import AppKit
import ApplicationServices
import Foundation

/// Frozen keyboard ownership for delayed input, without storing the field's contents.
///
/// Accessibility identities cannot identify a logical chat when an application reuses
/// the same control and exposes no document identity. This guard checks only the
/// concrete input evidence available from the operating system.
struct ConcurrentRecordingTarget: @unchecked Sendable {
    let application: NSRunningApplication
    private let focus: FocusedInputResolver.Snapshot
    private let window: AXUIElement
    private let document: String?
    private let configuration: TextDeliveryConfiguration

    /// Captures a positively identified input without reading its value or activating it.
    ///
    /// Returns:
    ///   The exact control and window, or nil when ownership cannot be established.
    static func capture() -> Self? {
        guard let configuration = try? TextDeliveryConfiguration.bundled(),
              let focus = FocusedInputResolver.resolve(configuration: configuration),
              let element = focus.element,
              !focus.application.isTerminated,
              focus.application.bundleIdentifier != Bundle.main.bundleIdentifier,
              let window = window(for: focus, configuration: configuration) else { return nil }
        let role = attribute(kAXRoleAttribute, of: element, configuration: configuration) as? String ?? ""
        let subrole = attribute(kAXSubroleAttribute, of: element, configuration: configuration) as? String ?? ""
        guard ![role, subrole].contains(where: {
            $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password")
        }), attribute(kAXEnabledAttribute, of: element, configuration: configuration) as? Bool != false else {
            return nil
        }
        return Self(
            application: focus.application, focus: focus, window: window,
            document: document(for: focus, window: window, configuration: configuration),
            configuration: configuration
        )
    }

    /// Revalidates the captured owner and control without switching focus.
    ///
    /// Returns:
    ///   True only when the available process, element, window, and document evidence agree.
    func isCurrent() -> Bool {
        guard !application.isTerminated,
              FocusedInputResolver.isCurrent(focus, configuration: configuration),
              let current = FocusedInputResolver.resolve(configuration: configuration),
              let originalElement = focus.element, let currentElement = current.element,
              let currentWindow = Self.window(for: current, configuration: configuration) else { return false }
        return Self.permitsDelivery(
            ownerMatches: application.processIdentifier == current.application.processIdentifier,
            elementMatches: CFEqual(originalElement, currentElement),
            windowMatches: CFEqual(window, currentWindow),
            originalDocument: document,
            currentDocument: Self.document(for: current, window: currentWindow, configuration: configuration)
        )
    }

    /// Evaluates identity evidence independently of Accessibility for deterministic tests.
    ///
    /// Args:
    ///   ownerMatches: Whether the same process still owns keyboard input.
    ///   elementMatches: Whether the exact input controls match.
    ///   windowMatches: Whether both controls belong to the same window.
    ///   originalDocument: Optional document identity captured at recording start.
    ///   currentDocument: Optional document identity exposed now.
    /// Returns:
    ///   True when all known identities agree; missing documents alone do not reject input.
    static func permitsDelivery(
        ownerMatches: Bool, elementMatches: Bool, windowMatches: Bool,
        originalDocument: String?, currentDocument: String?
    ) -> Bool {
        ownerMatches && elementMatches && windowMatches && originalDocument == currentDocument
    }

    /// Reads one bounded metadata attribute, never AXValue or selected text.
    private static func attribute(
        _ name: String, of element: AXUIElement, configuration: TextDeliveryConfiguration
    ) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, Float(configuration.accessibilityTimeoutSeconds))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Resolves the window already associated with the focused control.
    private static func window(
        for focus: FocusedInputResolver.Snapshot, configuration: TextDeliveryConfiguration
    ) -> AXUIElement? {
        if let window = focus.floatingWindow { return window }
        guard let element = focus.element,
              let value = attribute(kAXWindowAttribute, of: element, configuration: configuration),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Reads optional document identity from the focused control or its window.
    private static func document(
        for focus: FocusedInputResolver.Snapshot, window: AXUIElement,
        configuration: TextDeliveryConfiguration
    ) -> String? {
        if let element = focus.element,
           let value = attribute(kAXDocumentAttribute, of: element, configuration: configuration) as? String {
            return value
        }
        return attribute(kAXDocumentAttribute, of: window, configuration: configuration) as? String
    }
}

/// Centralized limits for PCM waiting behind an earlier recording's output pipeline.
struct BufferedRecordingConfiguration: Equatable, Sendable {
    static let defaultMaximumSegments = 3
    static let defaultMaximumDuration: TimeInterval = 120
    static let defaultMaximumBytes = 12 * 1_024 * 1_024
    static let minimumReplayUploadSeconds: TimeInterval = 2
    static let maximumReplayUploadSeconds: TimeInterval = 30
    static let replayUploadSecondsPerAudioSecond: TimeInterval = 0.5
    static let hardMaximumSegments = 8
    static let hardMaximumDuration: TimeInterval = 300
    static let hardMaximumBytes = 32 * 1_024 * 1_024
    static let bytesPerSample = MemoryLayout<Int16>.size
    static let bytesPerSecond = Int(AudioCaptureEngine.sampleRate) * bytesPerSample
    static let storageChunkBytes = AudioCaptureEngine.chunkByteSize

    let maximumSegments: Int
    let maximumDuration: TimeInterval
    let maximumBytes: Int

    /// Creates validated limits; malformed values use defaults and large values are capped.
    ///
    /// Args:
    ///   maximumSegments: Total number of active and waiting segments.
    ///   maximumDuration: Maximum physical duration of one recording, in seconds.
    ///   maximumBytes: Total retained PCM bytes across this queue.
    init(
        maximumSegments: Int = Self.defaultMaximumSegments,
        maximumDuration: TimeInterval = Self.defaultMaximumDuration,
        maximumBytes: Int = Self.defaultMaximumBytes
    ) {
        self.maximumSegments = maximumSegments > 0
            ? min(maximumSegments, Self.hardMaximumSegments) : Self.defaultMaximumSegments
        self.maximumDuration = maximumDuration.isFinite && maximumDuration > 0
            ? min(maximumDuration, Self.hardMaximumDuration) : Self.defaultMaximumDuration
        let boundedBytes = maximumBytes >= Self.bytesPerSample
            ? min(maximumBytes, Self.hardMaximumBytes) : Self.defaultMaximumBytes
        self.maximumBytes = boundedBytes - boundedBytes % Self.bytesPerSample
    }

    /// Loads optional tuning without modifying preferences.
    ///
    /// Args:
    ///   defaults: Preferences containing the buffered-recording limits.
    /// Returns:
    ///   Validated, hard-capped queue limits.
    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            maximumSegments: (defaults.object(forKey: "tf_bufferedRecordingMaximumSegments") as? NSNumber)?.intValue
                ?? defaultMaximumSegments,
            maximumDuration: (defaults.object(forKey: "tf_bufferedRecordingMaximumDuration") as? NSNumber)?.doubleValue
                ?? defaultMaximumDuration,
            maximumBytes: (defaults.object(forKey: "tf_bufferedRecordingMaximumBytes") as? NSNumber)?.intValue
                ?? defaultMaximumBytes
        )
    }

    /// Allows complete buffered uploads more time than a realtime stream's trailing packet.
    ///
    /// Args:
    ///   audioDuration: Duration of PCM to upload, excluding queue waiting time.
    /// Returns:
    ///   A bounded upload budget; failure still retries the complete retained audio.
    func replayUploadTimeout(audioDuration: TimeInterval) -> Duration {
        .seconds(min(Self.maximumReplayUploadSeconds, max(Self.minimumReplayUploadSeconds,
            audioDuration * Self.replayUploadSecondsPerAudioSecond)))
    }

    /// Maximum PCM payload of one segment, independent of callback timing or wall-clock changes.
    var maximumSegmentBytes: Int {
        let bytes = Int(maximumDuration * Double(Self.bytesPerSecond))
        return min(maximumBytes, max(Self.bytesPerSample, bytes - bytes % Self.bytesPerSample))
    }
}

/// Immutable audio and input intent captured before the ASR pipeline becomes available.
struct BufferedRecording: @unchecked Sendable {
    let id: Int
    let mode: ProcessingMode
    let startedAt: Date
    let endedAt: Date
    let target: ConcurrentRecordingTarget?
    let chunks: [Data]
    let speechDetected: Bool
    let byteCount: Int

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// Thread-safe, bounded FIFO. Only audio capture is concurrent; its consumer remains serial.
///
/// Queue memory is capped in PCM bytes plus at most one fixed-size tail per recording.
/// Chunks are coalesced so tiny callbacks cannot create an unbounded array of allocations.
/// A dequeued immutable recording transfers ownership to the single processing consumer.
final class BoundedRecordingQueue: @unchecked Sendable {
    enum StartFailure: Error, Equatable { case alreadyRecording, capacityReached, invalidDate, identifierExhausted }
    enum StopReason: Equatable, Sendable { case durationLimit, memoryLimit }
    enum AppendResult: Equatable, Sendable {
        case accepted
        case stopRequired(StopReason)
        case staleRecording
        case invalidPCM
    }

    struct Snapshot {
        let activeID: Int?
        let activeMode: ProcessingMode?
        let activeStartedAt: Date?
        let pendingIDs: [Int]
        let retainedBytes: Int
        let canStart: Bool

        var pendingCount: Int { pendingIDs.count }
    }

    private struct Active {
        let id: Int
        var mode: ProcessingMode
        let startedAt: Date
        let target: ConcurrentRecordingTarget?
        var chunks: [Data] = []
        var tail = Data()
        var speechDetected = false
        var byteCount = 0
        var stopReason: StopReason?
    }

    let configuration: BufferedRecordingConfiguration
    private let lock = NSLock()
    private static let identifierLock = NSLock()
    private static var nextIdentifier = -1
    private var active: Active?
    private var pending: [BufferedRecording] = []
    private var retainedBytes = 0

    /// Creates an isolated queue; it does not access microphone hardware or preferences by default.
    ///
    /// Args:
    ///   configuration: Validated limits for all active and pending recordings.
    init(configuration: BufferedRecordingConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Reserves one recording with a process-unique negative owner ID.
    ///
    /// Args:
    ///   mode: Frozen processing mode for this segment.
    ///   target: Input identity captured by the caller without reading text.
    ///   at: Actual capture start time.
    /// Returns:
    ///   The owner ID, or a reason no new recording can be accepted.
    func start(mode: ProcessingMode, target: ConcurrentRecordingTarget?, at: Date = Date()) -> Result<Int, StartFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return .failure(.alreadyRecording) }
        guard pending.count < configuration.maximumSegments,
              retainedBytes < configuration.maximumBytes else { return .failure(.capacityReached) }
        guard at.timeIntervalSinceReferenceDate.isFinite else { return .failure(.invalidDate) }
        Self.identifierLock.lock()
        guard Self.nextIdentifier > Int.min else {
            Self.identifierLock.unlock()
            return .failure(.identifierExhausted)
        }
        let id = Self.nextIdentifier
        Self.nextIdentifier -= 1
        Self.identifierLock.unlock()
        active = Active(id: id, mode: mode, startedAt: at, target: target)
        return .success(id)
    }

    /// Adds complete PCM16 samples without allowing a stale callback or oversized payload to grow memory.
    ///
    /// Args:
    ///   data: Mono, 16 kHz, little-endian PCM16 samples.
    ///   to: Owner ID returned by start.
    ///   speechDetected: Whether speech has already been observed in this callback.
    ///   at: Time at which the capture callback arrived.
    /// Returns:
    ///   Whether capture may continue. Stop-required results retain only the bounded prefix.
    func append(_ data: Data, to id: Int, speechDetected: Bool = false, at: Date = Date()) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard var current = active, current.id == id else { return .staleRecording }
        guard data.count.isMultiple(of: BufferedRecordingConfiguration.bytesPerSample) else { return .invalidPCM }
        if let reason = current.stopReason { return .stopRequired(reason) }
        current.speechDetected = current.speechDetected || speechDetected
        guard at.timeIntervalSinceReferenceDate.isFinite,
              at.timeIntervalSince(current.startedAt) < configuration.maximumDuration else {
            current.stopReason = .durationLimit
            active = current
            return .stopRequired(.durationLimit)
        }
        let segmentRemaining = configuration.maximumSegmentBytes - current.byteCount
        let queueRemaining = configuration.maximumBytes - retainedBytes
        let accepted = min(data.count, segmentRemaining, queueRemaining)
        var offset = 0
        while offset < accepted {
            let count = min(BufferedRecordingConfiguration.storageChunkBytes - current.tail.count, accepted - offset)
            let lower = data.index(data.startIndex, offsetBy: offset)
            let upper = data.index(lower, offsetBy: count)
            current.tail.append(contentsOf: data[lower..<upper])
            offset += count
            if current.tail.count == BufferedRecordingConfiguration.storageChunkBytes {
                current.chunks.append(current.tail)
                current.tail = Data()
            }
        }
        current.byteCount += accepted
        retainedBytes += accepted
        if current.byteCount >= configuration.maximumSegmentBytes || retainedBytes >= configuration.maximumBytes {
            current.stopReason = retainedBytes >= configuration.maximumBytes ? .memoryLimit : .durationLimit
        }
        active = current
        return current.stopReason.map(AppendResult.stopRequired) ?? .accepted
    }

    /// Records speech evidence from a separate level callback without storing samples.
    ///
    /// Args:
    ///   id: Owner whose capture produced the level update.
    func markSpeech(for id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard active?.id == id else { return }
        active?.speechDetected = true
    }

    /// Applies the existing cross-hotkey finish policy to the active segment only.
    ///
    /// Args:
    ///   mode: Processing mode chosen by the finishing shortcut.
    /// Returns:
    ///   True when an active buffered recording was updated.
    @discardableResult
    func switchActiveMode(to mode: ProcessingMode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active != nil else { return false }
        active?.mode = mode
        return true
    }

    /// Freezes the final tail and enqueues the segment after capture has actually stopped.
    ///
    /// Args:
    ///   id: Owner of the stopped capture.
    ///   at: Actual capture stop time, excluding subsequent ASR and polish waits.
    /// Returns:
    ///   The immutable queued segment, or nil for a stale/invalid completion.
    @discardableResult
    func finish(id: Int, at: Date = Date()) -> BufferedRecording? {
        lock.lock()
        defer { lock.unlock() }
        guard var current = active, current.id == id,
              at.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if !current.tail.isEmpty { current.chunks.append(current.tail) }
        let recording = BufferedRecording(
            id: current.id, mode: current.mode, startedAt: current.startedAt,
            endedAt: max(current.startedAt, at), target: current.target,
            chunks: current.chunks, speechDetected: current.speechDetected, byteCount: current.byteCount
        )
        pending.append(recording)
        active = nil
        return recording
    }

    /// Removes only the named recording, keeping unrelated pending work intact.
    ///
    /// Args:
    ///   id: Active or pending recording to cancel.
    /// Returns:
    ///   True if a matching recording was removed.
    @discardableResult
    func cancel(id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let current = active, current.id == id {
            retainedBytes -= current.byteCount
            active = nil
            return true
        }
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        retainedBytes -= pending.remove(at: index).byteCount
        return true
    }

    /// Transfers the oldest finished segment to the sole downstream processing consumer.
    ///
    /// Returns:
    ///   The oldest segment, or nil when no completed capture is waiting.
    func dequeue() -> BufferedRecording? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let recording = pending.removeFirst()
        retainedBytes -= recording.byteCount
        return recording
    }

    /// Returns lightweight queue state without copying audio or exposing target metadata.
    ///
    /// Returns:
    ///   Current capture ownership, FIFO order, retained bytes, and admission availability.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            activeID: active?.id, activeMode: active?.mode, activeStartedAt: active?.startedAt,
            pendingIDs: pending.map(\.id), retainedBytes: retainedBytes,
            canStart: active == nil && pending.count < configuration.maximumSegments
                && retainedBytes < configuration.maximumBytes
        )
    }
}
