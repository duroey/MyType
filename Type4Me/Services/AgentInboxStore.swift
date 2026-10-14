import Combine
import Foundation

/// A process-local inbox; it never restores history, schedules, or executes agent tasks.
@MainActor
final class AgentInboxStore: ObservableObject {
    private enum OrderingGroup: Int { case attention, active, history }

    static let shared: AgentInboxStore = {
        do {
            return AgentInboxStore(configuration: try .bundled())
        } catch {
            NSLog("[AgentInbox] Notification configuration is invalid; monitoring is unavailable.")
            let store = AgentInboxStore()
            store.configurationError = true
            return store
        }
    }()

    @Published private(set) var items: [AgentInboxItem] = []
    @Published private(set) var configurationError = false
    var onCompletion: ((AgentInboxItem) -> Void)?
    var onRequest: ((AgentInboxItem) -> Void)?

    private let configuration: AgentNotificationConfiguration
    private var receipts: [String] = []
    private var dismissed: [String: AgentInboxItem] = [:]
    private var lastObserved: [String: Date] = [:]
    private var completionAlerts: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Creates an empty, memory-only inbox for this application lifetime.
    ///
    /// Args:
    ///   configuration: Bounds for visible messages and in-memory completion receipts.
    init(configuration: AgentNotificationConfiguration = .init()) {
        self.configuration = configuration
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
        if update.status == .idle, pending.isEmpty {
            // A completion is a notification, not the agent's availability. Keep it unread
            // until viewed, but never retain an idle worker as a queue entry.
            if previous?.status == .completed, previous?.isUnread == true,
               previous?.pendingRequests.isEmpty == true,
               update.nativeHasUnreadTurn != false {
                lastObserved[update.session.id] = update.observedAt
                return
            }
            cancelCompletionAlert(update.session.id)
            if let previous {
                var idle = previous
                idle.status = .idle
                idle.pendingRequests = []
                idle.isUnread = false
                dismissed[idle.id] = idle
                items.removeAll { $0.id == idle.id }
            }
            lastObserved[update.session.id] = update.observedAt
            trimBookkeeping()
            return
        }
        // Losing the connection cannot turn a known unread result into a roster status.
        if update.status == .unknown, previous?.status == .completed,
           previous?.isUnread == true, previous?.pendingRequests.isEmpty == true, pending.isEmpty {
            lastObserved[update.session.id] = update.observedAt
            return
        }
        let status: AgentInboxStatus = update.status == .idle ? .waiting : update.status
        if status != .completed || !pending.isEmpty { cancelCompletionAlert(update.session.id) }
        let preview = update.preview.isEmpty ? old?.preview ?? "" : update.preview
        var next = bounded(AgentInboxItem(session: update.session, status: status,
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
        // Streaming text and reconnects must not promote an already outstanding question.
        if let old, !newCompletion, !newRequest,
           !hasMeaningfulStateChange(from: old, to: next) { next.updatedAt = old.updatedAt }

        if hidden != nil, !semanticChange, !newCompletion {
            lastObserved[update.session.id] = update.observedAt
            return
        }
        // Quiet terminal baselines are history, not new inbox messages.
        if previous == nil, !newCompletion, pending.isEmpty,
           [.idle, .completed, .interrupted, .failed, .unknown].contains(update.status) { return }
        if previous == next, !newCompletion, update.nativeHasUnreadTurn != false {
            lastObserved[next.id] = update.observedAt
            return
        }
        dismissed.removeValue(forKey: next.id)
        lastObserved[next.id] = update.observedAt
        items.removeAll { $0.id == next.id }
        items.append(next)
        sortItems()
        items = Array(items.prefix(configuration.maximumInboxItems))
        trimBookkeeping()
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
        sortItems()
    }

    /// Consumes the opened notification without clearing newer work or unresolved requests.
    ///
    /// Args:
    ///   selected: Exact row snapshot whose native conversation was successfully opened.
    func acknowledgeOpened(_ selected: AgentInboxItem) {
        guard items.first(where: { $0.id == selected.id }) == selected else { return }
        if selected.pendingRequests.isEmpty, selected.status == .completed || selected.status == .idle {
            dismiss(selected.id)
        } else {
            markRead(selected.id)
        }
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
    }

    /// Bounds retained visible data while keeping the exact navigation identity.
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

    /// Recognizes state changes without treating streamed content as a fresh request.
    ///
    /// Args:
    ///   previous: Previously retained state.
    ///   current: New observation whose new request and completion IDs were already checked.
    ///
    /// Returns:
    ///   Whether the existing row should receive a new ordering timestamp.
    private func hasMeaningfulStateChange(from previous: AgentInboxItem, to current: AgentInboxItem) -> Bool {
        // An unanswered request retains its original place even if the owner keeps working,
        // disconnects, changes its preview, or removes another request from the same row.
        if !previous.pendingRequests.isEmpty, !current.pendingRequests.isEmpty { return false }
        if previous.pendingRequests.isEmpty != current.pendingRequests.isEmpty { return true }
        if previous.needsAttention, current.needsAttention {
            // Idle/disconnected observations do not announce new work. Revalidating an
            // existing completion after either baseline retains that completion's time.
            if current.status == .unknown || current.status == .idle { return false }
            if current.status == .completed,
               previous.status == .unknown || previous.status == .idle { return false }
        }
        return previous.status != current.status
    }

    /// Places actionable updates above active work while keeping equal timestamps stable.
    private func sortItems() {
        items.sort { lhs, rhs in
            let leftGroup = orderingGroup(for: lhs)
            let rightGroup = orderingGroup(for: rhs)
            if leftGroup != rightGroup { return leftGroup.rawValue < rightGroup.rawValue }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// Classifies attention, background work, and already-seen history for presentation.
    ///
    /// Args:
    ///   item: Current row with independent request and unread state.
    ///
    /// Returns:
    ///   Attention first, then active work, then other retained history.
    private func orderingGroup(for item: AgentInboxItem) -> OrderingGroup {
        if item.needsAttention { return .attention }
        return item.status == .running || item.status == .waiting ? .active : .history
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

}
