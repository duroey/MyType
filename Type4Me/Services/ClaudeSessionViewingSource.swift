import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog
import Security

/// Ephemeral observation, never persisted or interpreted as an approval or reply.
struct ClaudeSessionViewingObservation: Sendable {
    let sessionID: String
    let engineSessionID: String
    let observedAt: Date
}

/// Requires continuous foreground evidence and restarts after uncertainty or a sampling gap.
struct ClaudeSessionViewingGate {
    let stableSeconds: TimeInterval
    let maximumGapSeconds: TimeInterval
    private var candidate: String?
    private var since: TimeInterval?
    private var previousSample: TimeInterval?

    /// Creates a reducer with configurable dwell and continuity bounds.
    ///
    /// Args:
    ///   stableSeconds: Required continuous viewing duration.
    ///   maximumGapSeconds: Largest acceptable gap between observations.
    init(stableSeconds: TimeInterval, maximumGapSeconds: TimeInterval) {
        self.stableSeconds = stableSeconds
        self.maximumGapSeconds = maximumGapSeconds
    }

    /// Reduces identity and visibility without treating a navigation request as evidence.
    ///
    /// Args:
    ///   selection: Exact ID from a fresh, continuous native log stream.
    ///   eligible: Whether OS state and native metadata corroborate that selection.
    ///   now: Monotonic sampling time.
    ///
    /// Returns:
    ///   Stable viewed session, or nil when insufficiently observed.
    mutating func observe(selection: String?, eligible: Bool, now: TimeInterval) -> String? {
        if let previousSample, now < previousSample || now - previousSample > maximumGapSeconds {
            candidate = nil; since = nil
        }
        previousSample = now
        let next = eligible ? selection : nil
        if next != candidate { candidate = next; since = next == nil ? nil : now }
        guard let candidate, let since, now - since >= stableSeconds else { return nil }
        return candidate
    }
}

/// Reads only newly appended complete lines, resetting at EOF after any discontinuity.
struct ClaudeFocusLogCursor {
    struct Batch { let continuous: Bool; let selections: [String] }
    let maximumBytes: Int
    private var identity: String?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var skipPartialLine = false

    /// Creates an unprimed cursor that skips historical contents on its first read.
    ///
    /// Args:
    ///   maximumBytes: Maximum incremental read and unfinished-line memory.
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    /// Reads bounded new log events from an owned, regular file without following symlinks.
    ///
    /// Args:
    ///   url: The native Claude main log, or an isolated fixture.
    ///
    /// Returns:
    ///   Fresh validated IDs/nulls, with false continuity on startup or rotation.
    ///
    /// Raises:
    ///   Error: File ownership, type, opening, seeking or reading cannot be validated.
    mutating func read(_ url: URL) throws -> Batch {
        let (handle, info) = try Self.openOwnedFile(url)
        defer { try? handle.close() }
        let current = "\(info.st_dev):\(info.st_ino)"
        let size = UInt64(info.st_size)
        guard identity == current, size >= offset, size - offset <= UInt64(maximumBytes) else {
            identity = current; offset = size; pending.removeAll()
            if size > 0 {
                try handle.seek(toOffset: size - 1)
                skipPartialLine = try handle.read(upToCount: 1)?.first != 10
            } else { skipPartialLine = false }
            return Batch(continuous: false, selections: [])
        }
        try handle.seek(toOffset: offset)
        let fresh = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard fresh.count <= maximumBytes, pending.count + fresh.count <= maximumBytes else {
            identity = nil; pending.removeAll()
            return Batch(continuous: false, selections: [])
        }
        offset += UInt64(fresh.count)
        pending.append(fresh)
        var selections: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending = Data(pending.suffix(from: pending.index(after: newline)))
            if skipPartialLine { skipPartialLine = false; continue }
            let marker = " [info] [CCD] LocalSessions.setFocusedSession: sessionId="
            guard let range = line.range(of: marker) else { continue }
            // The source emits an exact timestamp-prefixed line. Extra fields mean schema drift.
            let prefix = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let timestampShape = prefix.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
            selections.append(timestampShape && AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(value) ? value : "null")
        }
        // Detect replacement between open and read; the next sample starts at the new EOF.
        var currentInfo = stat()
        guard lstat(url.path, &currentInfo) == 0,
              currentInfo.st_dev == info.st_dev, currentInfo.st_ino == info.st_ino,
              currentInfo.st_size >= off_t(offset) else {
            identity = nil; pending.removeAll()
            return Batch(continuous: false, selections: [])
        }
        return Batch(continuous: true, selections: selections)
    }

    /// Opens bounded-observer input using kernel type/owner checks and no symlink traversal.
    ///
    /// Args:
    ///   url: Exact local native data file.
    ///
    /// Returns:
    ///   Open handle and descriptor metadata, owned by the caller.
    ///
    /// Raises:
    ///   CocoaError: The path or descriptor cannot be trusted or read.
    static func openOwnedFile(_ url: URL) throws -> (FileHandle, stat) {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw CocoaError(.fileReadNoPermission) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_mode & 0o022 == 0 else {
            try? handle.close()
            throw CocoaError(.fileReadNoPermission)
        }
        return (handle, info)
    }
}

/// Adapts the independent probe without UI automation, runtime injection or app-store writes.
final class ClaudeSessionViewingSource: @unchecked Sendable {
    private struct AppState: Sendable {
        let processID: Int32
        let generation: String
        let eligible: Bool
    }
    private struct Metadata: Decodable {
        let sessionId: String
        let cliSessionId: String
        let lastFocusedAt: Double
        let isArchived: Bool
    }
    private let configuration: AgentNotificationConfiguration
    private let home: URL

    /// Creates the observer without touching native files or starting any agent.
    ///
    /// Args:
    ///   configuration: Polling, stability, signature and file bounds.
    ///   home: Local profile root; injectable for a separate observer process.
    init(configuration: AgentNotificationConfiguration, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.configuration = configuration
        self.home = home
    }

    /// Samples exact native focus evidence; uncertain states emit no read acknowledgement.
    ///
    /// Args:
    ///   emit: Receives only corroborated, stable viewing observations.
    func run(emit: @escaping @Sendable (ClaudeSessionViewingObservation) async -> Void) async {
        let worker = Task.detached(priority: .utility) { [self] in
            let log = home.appendingPathComponent("Library/Logs/Claude/main.log")
            let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            var cursor = ClaudeFocusLogCursor(maximumBytes: configuration.maximumClaudeFocusLogBytes)
            var gate = makeGate()
            var generation: String?
            var selected: String?
            var startedAt = Date()
            var metadataURL: URL?
            var metadataRevision: String?
            var metadata: Metadata?
            var reportedUnavailable = false
            while !Task.isCancelled {
                do {
                    let observedAt = Date()
                    guard let app = await Self.appState() else { throw CocoaError(.featureUnsupported) }
                    if generation != app.generation {
                        guard Self.trustedDesktop(app.processID, team: configuration.claudeSigningTeamIdentifier) else {
                            throw CocoaError(.fileReadNoPermission)
                        }
                        generation = app.generation
                        cursor = ClaudeFocusLogCursor(maximumBytes: configuration.maximumClaudeFocusLogBytes)
                        selected = nil; metadataURL = nil; metadata = nil; metadataRevision = nil
                        startedAt = Date(); gate = makeGate()
                    }
                    let batch = try cursor.read(log)
                    if !batch.continuous {
                        selected = nil; metadataURL = nil; metadata = nil; metadataRevision = nil
                        startedAt = Date(); gate = makeGate()
                    }
                    if let event = batch.selections.last {
                        selected = event == "null" ? nil : event
                        metadataURL = nil; metadata = nil; metadataRevision = nil; gate = makeGate()
                    }
                    if let selected {
                        if metadataURL == nil { metadataURL = try findMetadata(selected, root: root) }
                        guard let metadataURL else { throw CocoaError(.fileReadNoSuchFile) }
                        let (handle, info) = try ClaudeFocusLogCursor.openOwnedFile(metadataURL)
                        defer { try? handle.close() }
                        let revision = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
                        if revision != metadataRevision {
                            guard info.st_size <= configuration.maximumClaudeFocusMetadataBytes,
                                  let data = try handle.read(upToCount: configuration.maximumClaudeFocusMetadataBytes + 1),
                                  data.count <= configuration.maximumClaudeFocusMetadataBytes else { throw CocoaError(.fileReadTooLarge) }
                            metadata = try JSONDecoder().decode(Metadata.self, from: data)
                            metadataRevision = revision
                        }
                    }
                    let corroborated = metadata.map {
                        !$0.isArchived && $0.sessionId == selected && UUID(uuidString: $0.cliSessionId) != nil
                            && $0.lastFocusedAt.isFinite && $0.lastFocusedAt / 1_000 >= startedAt.timeIntervalSince1970
                    } ?? false
                    // Metadata I/O may overlap an in-app navigation. Recheck the stream before
                    // acknowledging, and keep the original sample time rather than minting a newer one.
                    let verification = try cursor.read(log)
                    if !verification.continuous || !verification.selections.isEmpty {
                        selected = verification.continuous ? verification.selections.last : nil
                        if selected == "null" { selected = nil }
                        metadataURL = nil; metadata = nil; metadataRevision = nil; gate = makeGate()
                        if !verification.continuous { startedAt = Date() }
                    }
                    // Re-read OS state after I/O so a background transition cannot acknowledge a result.
                    let currentApp = await Self.appState()
                    let eligible = app.eligible && currentApp?.eligible == true && currentApp?.generation == generation
                        && verification.continuous && verification.selections.isEmpty
                    if let sessionID = gate.observe(selection: selected, eligible: eligible && corroborated,
                                                    now: ProcessInfo.processInfo.systemUptime), let metadata {
                        await emit(.init(sessionID: sessionID, engineSessionID: metadata.cliSessionId.lowercased(), observedAt: observedAt))
                    }
                    reportedUnavailable = false
                } catch {
                    selected = nil; metadataURL = nil; metadata = nil; metadataRevision = nil
                    generation = nil; gate = makeGate()
                    if !reportedUnavailable {
                        Logger(subsystem: "com.mytype.app", category: "AgentInbox").info("Claude viewing evidence unavailable; completed messages retained.")
                        reportedUnavailable = true
                    }
                }
                do { try await Task.sleep(for: .seconds(configuration.viewingPollSeconds)) }
                catch { return }
            }
        }
        await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Creates a fresh reducer after stream/process continuity is lost.
    private func makeGate() -> ClaudeSessionViewingGate {
        .init(stableSeconds: configuration.viewingStableSeconds, maximumGapSeconds: configuration.viewingEvidenceMaxAgeSeconds)
    }

    /// Resolves one exact native session among bounded account/organization metadata entries.
    ///
    /// Args:
    ///   sessionID: Validated native local session ID.
    ///   root: Claude's metadata directory, never a project/transcript tree.
    ///
    /// Returns:
    ///   The unique matching file, or nil on absence/ambiguity/traversal exhaustion.
    private func findMetadata(_ sessionID: String, root: URL) throws -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        var matches: [URL] = []
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= configuration.maximumClaudeFocusMetadataEntries else { return nil }
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants(); continue
            }
            if enumerator.level >= 3 { enumerator.skipDescendants() }
            if enumerator.level == 3, url.lastPathComponent == sessionID + ".json" { matches.append(url) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Reads OS identities only; window content, titles and accessibility are never inspected.
    ///
    /// Returns:
    ///   One unambiguous native process plus foreground/console visibility eligibility.
    @MainActor private static func appState() -> AppState? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: AgentDesktopApplication.claudeCode.bundleIdentifier)
        guard apps.count == 1, let app = apps.first,
              let start = AgentHandoffDeliveryService.processStartSeconds(processID: app.processIdentifier) else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let console = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let eligible = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            && console["kCGSSessionOnConsoleKey"] as? Bool == true
            && console["CGSSessionScreenIsLocked"] as? Bool != true && visible.count == 1
        return AppState(processID: app.processIdentifier, generation: "\(app.processIdentifier):\(start)", eligible: eligible)
    }

    /// Verifies the running publisher once per process generation, without attaching a debugger.
    ///
    /// Args:
    ///   pid: Native Claude main process from AppKit.
    ///   team: Explicitly trusted application signing team.
    ///
    /// Returns:
    ///   Whether the live code meets the native bundle and Apple signing requirement.
    private static func trustedDesktop(_ pid: Int32, team: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                            [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"com.anthropic.claudefordesktop\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
