import Combine
import Darwin
import Foundation

/// A small persistent inbox; it never schedules or executes an agent task.
@MainActor
final class AgentInboxStore: ObservableObject {
    static let shared: AgentInboxStore = {
        do {
            return AgentInboxStore(fileURL: AppIdentity.appSupportDirectory()
                .appendingPathComponent("agent-inbox", isDirectory: true).appendingPathComponent("state-v1.json"),
                configuration: try .bundled())
        } catch {
            NSLog("[AgentInbox] Notification configuration is invalid; persistent inbox is disabled.")
            let store = AgentInboxStore()
            store.storageError = true
            return store
        }
    }()

    @Published private(set) var items: [AgentInboxItem] = []
    @Published private(set) var storageError = false
    var onCompletion: ((AgentInboxItem) -> Void)?
    var onRequest: ((AgentInboxItem) -> Void)?

    private let configuration: AgentNotificationConfiguration
    private let persistence: AgentInboxPersistence?
    private var receipts: [String] = []
    private var dismissed: [String: AgentInboxItem] = [:]
    private var lastObserved: [String: Date] = [:]
    private var writeTask: Task<Void, Never>?
    private var persistenceBlocked = false
    private var completionAlerts: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Creates an isolated inbox or uses the supplied private persistent file.
    ///
    /// Args:
    ///   fileURL: nil selects memory-only storage, useful for tests and previews.
    ///   configuration: Bounds for retained visible messages and completion receipts.
    init(fileURL: URL? = nil, configuration: AgentNotificationConfiguration = .init()) {
        self.configuration = configuration
        persistence = fileURL.map { AgentInboxPersistence(url: $0, maximumBytes: configuration.maximumStoreBytes) }
    }

    /// Restores messages quietly; persisted runtime states are unknown until revalidated.
    ///
    /// Existing unrecognized/corrupt files are preserved rather than overwritten.
    func load() async {
        guard let persistence else { return }
        do {
            guard let snapshot = try await persistence.read() else { return }
            guard snapshot.version == AgentInboxSnapshot.currentVersion,
                  snapshot.items.count <= configuration.maximumInboxItems,
                  Set(snapshot.items.map(\.id)).count == snapshot.items.count,
                  snapshot.dismissed.count <= configuration.maximumInboxItems,
                  snapshot.receipts.count <= configuration.maximumCompletionReceipts else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            items = snapshot.items.map { item in
                var copy = bounded(item)
                copy.status = .unknown
                return copy
            }
            // A hidden row stays hidden across a restart until new work is observed.
            dismissed = Dictionary(snapshot.dismissed.map { ($0.id, bounded($0)) }, uniquingKeysWith: { _, last in last })
            receipts = snapshot.receipts
            storageError = false
        } catch {
            persistenceBlocked = true
            storageError = true
        }
    }

    /// Merges a native observation and pops only a newly verified successful completion.
    ///
    /// Args:
    ///   update: Identity-checked state from one original desktop application.
    func apply(_ update: AgentInboxUpdate) {
        guard lastObserved[update.session.id].map({ update.observedAt >= $0 }) ?? true else { return }
        let previous = items.first { $0.id == update.session.id }
        let hidden = dismissed[update.session.id]
        let old = previous ?? hidden
        if hidden != nil, update.status == .unknown {
            lastObserved[update.session.id] = update.observedAt
            return
        }
        let pending = update.pendingRequests ?? old?.pendingRequests ?? []
        if update.status != .completed || !pending.isEmpty { cancelCompletionAlert(update.session.id) }
        // A quiet idle baseline after reconnecting is not new work for a consumed completion.
        if hidden?.status == .completed, update.status == .idle, pending.isEmpty {
            lastObserved[update.session.id] = update.observedAt
            return
        }
        let preview = update.preview.isEmpty ? old?.preview ?? "" : update.preview
        var next = bounded(AgentInboxItem(session: update.session, status: update.status,
                                         pendingRequests: pending, preview: preview,
                                         updatedAt: update.observedAt, isUnread: old?.isUnread ?? false))
        let receipt = update.completionID.map { update.session.id + "|" + $0 }
        // A turn ending with a question still needs the user; only finished work pops the queue.
        let newCompletion = update.status == .completed && next.pendingRequests.isEmpty
            && receipt.map { !receipts.contains($0) } == true
        if let receipt, update.status == .completed, !receipts.contains(receipt) {
            receipts.append(receipt)
            receipts = Array(receipts.suffix(configuration.maximumCompletionReceipts))
        }
        let semanticChange = old.map { !sameContent($0, next) } ?? true
        // Removing or reordering existing requests must not alert for an already seen question.
        let previousRequestIDs = Set((old?.pendingRequests ?? []).map { $0.kind.rawValue + ":" + $0.id })
        let newRequest = next.pendingRequests.contains {
            !previousRequestIDs.contains($0.kind.rawValue + ":" + $0.id)
        }
        next.isUnread = update.nativeHasUnreadTurn != false && (next.isUnread || newCompletion || newRequest)
        if !semanticChange, !newCompletion { next.updatedAt = old?.updatedAt ?? next.updatedAt }

        if hidden != nil, !semanticChange, !newCompletion {
            lastObserved[update.session.id] = update.observedAt
            return
        }
        // Quiet terminal baselines are history, not new inbox messages.
        if old == nil, !newCompletion, pending.isEmpty,
           [.idle, .completed, .interrupted, .failed, .unknown].contains(update.status) { return }
        if previous == next, !newCompletion, update.nativeHasUnreadTurn != false {
            lastObserved[next.id] = update.observedAt
            return
        }
        dismissed.removeValue(forKey: next.id)
        lastObserved[next.id] = update.observedAt
        items.removeAll { $0.id == next.id }
        items.append(next)
        items.sort { $0.updatedAt > $1.updatedAt }
        items = Array(items.prefix(configuration.maximumInboxItems))
        trimBookkeeping()
        persist()
        // Native read state consumes only this observed result, never an unanswered request.
        if update.nativeHasUnreadTurn == false, next.status == .completed, next.pendingRequests.isEmpty {
            dismiss(next.id)
            return
        }
        if newRequest { onRequest?(next) }
        if newCompletion { scheduleCompletionAlert(next) }
    }

    /// Consumes only a completed Claude result corroborated after its latest state update.
    ///
    /// Args:
    ///   observation: Fresh exact native/engine identities from the stable external observer.
    ///   now: Current receipt time, injectable for deterministic staleness tests.
    func applyViewedSession(_ observation: ClaudeSessionViewingObservation, now: Date = Date()) {
        let id = AgentDesktopApplication.claudeCode.rawValue + ":" + observation.sessionID
        let age = now.timeIntervalSince(observation.observedAt)
        guard age >= 0, age <= configuration.viewingEvidenceMaxAgeSeconds,
              let item = items.first(where: { $0.id == id }), item.status == .completed,
              item.pendingRequests.isEmpty,
              item.session.engineSessionID?.lowercased() == observation.engineSessionID.lowercased(),
              let latest = lastObserved[id], observation.observedAt >= latest else { return }
        dismiss(id)
    }

    /// Cancels pending presentation when monitoring stops, without deleting any message.
    func cancelCompletionAlerts() {
        for alert in completionAlerts.values { alert.task.cancel() }
        completionAlerts.removeAll()
    }

    /// Allows native read evidence to arrive before presenting a newly completed result.
    ///
    /// Args:
    ///   item: Newly completed snapshot, already deduplicated by native turn identity.
    private func scheduleCompletionAlert(_ item: AgentInboxItem) {
        cancelCompletionAlert(item.id)
        guard configuration.completionAlertDelaySeconds > 0 else { onCompletion?(item); return }
        let token = UUID()
        let delay = configuration.completionAlertDelaySeconds
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, self.completionAlerts[item.id]?.token == token else { return }
            self.completionAlerts.removeValue(forKey: item.id)
            guard let current = self.items.first(where: { $0.id == item.id }),
                  current.status == .completed, current.pendingRequests.isEmpty, current.isUnread else { return }
            self.onCompletion?(current)
        }
        completionAlerts[item.id] = (token, task)
    }

    /// Invalidates one delayed popup so old work cannot interrupt a later interaction.
    ///
    /// Args:
    ///   id: Application-qualified session identity.
    private func cancelCompletionAlert(_ id: String) {
        completionAlerts.removeValue(forKey: id)?.task.cancel()
    }

    /// Marks local attention as read without claiming the native question was answered.
    ///
    /// Args:
    ///   id: Application-qualified native session identity.
    func markRead(_ id: String) {
        cancelCompletionAlert(id)
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isUnread else { return }
        items[index].isUnread = false
        persist()
    }

    /// Hides one local row; fresh native activity can bring it back.
    ///
    /// Args:
    ///   id: Application-qualified native session identity.
    func dismiss(_ id: String) {
        cancelCompletionAlert(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        dismissed[id] = items.remove(at: index)
        trimBookkeeping()
        persist()
    }

    /// Waits for queued persistence, allowing deterministic shutdown and tests.
    func flush() async { await writeTask?.value }

    /// Bounds persisted visible data while retaining the exact navigation identity.
    ///
    /// Args:
    ///   item: Proposed inbox row.
    ///
    /// Returns:
    ///   A compact row without search text copies or transcript locations.
    private func bounded(_ item: AgentInboxItem) -> AgentInboxItem {
        var value = item
        let session = item.session
        value.session = AgentSessionDescriptor(sessionID: session.sessionID, application: session.application,
            title: String(session.title.prefix(configuration.maximumPreviewCharacters)), workspacePath: nil,
            updatedAt: session.updatedAt, matchTexts: [], openCapability: session.openCapability,
            engineSessionID: session.engineSessionID)
        value.preview = String(value.preview.prefix(configuration.maximumPreviewCharacters))
        var seen = Set<String>()
        value.pendingRequests = value.pendingRequests.filter { seen.insert($0.id).inserted }
            .prefix(configuration.maximumPendingRequests).map {
                AgentInboxRequest(id: $0.id, kind: $0.kind,
                                  text: String($0.text.prefix(configuration.maximumPreviewCharacters)))
            }
        return value
    }

    /// Compares user-visible content without turning heartbeat timestamps into new messages.
    ///
    /// Args:
    ///   lhs: Previously displayed item.
    ///   rhs: New native observation.
    ///
    /// Returns:
    ///   Whether the message and task state remain unchanged.
    private func sameContent(_ lhs: AgentInboxItem, _ rhs: AgentInboxItem) -> Bool {
        lhs.session.title == rhs.session.title && lhs.status == rhs.status
            && lhs.pendingRequests == rhs.pendingRequests && lhs.preview == rhs.preview
    }

    /// Bounds tombstones and observation clocks together with the visible queue.
    private func trimBookkeeping() {
        dismissed = Dictionary(dismissed.values.sorted { $0.updatedAt > $1.updatedAt }
            .prefix(configuration.maximumInboxItems).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let retained = Set(items.map(\.id)).union(dismissed.keys)
        lastObserved = lastObserved.filter { retained.contains($0.key) }
        let visible = Set(items.map(\.id))
        for id in Array(completionAlerts.keys) where !visible.contains(id) { cancelCompletionAlert(id) }
    }

    /// Serializes writes off the main actor and preserves unsupported existing files.
    private func persist() {
        guard let persistence, !persistenceBlocked else { return }
        let snapshot = AgentInboxSnapshot(items: items, dismissed: Array(dismissed.values), receipts: receipts)
        writeTask?.cancel()
        let delay = configuration.persistenceDebounceSeconds
        writeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                try await persistence.write(snapshot)
                self?.storageError = false
            } catch is CancellationError {
                // Superseded observations are coalesced into the newest pending snapshot.
            } catch {
                self?.storageError = true
            }
        }
    }
}

private struct AgentInboxSnapshot: Codable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var items: [AgentInboxItem]
    var dismissed: [AgentInboxItem]
    var receipts: [String]
}

/// Serial, bounded file access; snapshots contain visible excerpts, never raw tool state.
private actor AgentInboxPersistence {
    let url: URL
    let maximumBytes: Int

    /// Creates a writer without touching the filesystem.
    ///
    /// Args:
    ///   url: Private snapshot file inside the application's profile.
    ///   maximumBytes: Maximum encoded or decoded bytes.
    init(url: URL, maximumBytes: Int) { self.url = url; self.maximumBytes = maximumBytes }

    /// Reads one bounded regular file without following a substituted symlink.
    ///
    /// Returns:
    ///   Saved content, or nil if no inbox has been saved yet.
    ///
    /// Raises:
    ///   Error: Unsafe file identity, invalid JSON, or exceeded size bound.
    func read() throws -> AgentInboxSnapshot? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(AgentInboxSnapshot.self, from: data)
    }

    /// Atomically installs a private snapshot using an exclusively created 0600 file.
    ///
    /// Args:
    ///   snapshot: Bounded semantic inbox state.
    ///
    /// Raises:
    ///   Error: Encoding, permission, write, or rename failure.
    func write(_ snapshot: AgentInboxSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard AgentHandoffDeliveryService.isOwnedItem(parent, kind: S_IFDIR, privatePermissions: false) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let temporary = parent.appendingPathComponent(".inbox-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
