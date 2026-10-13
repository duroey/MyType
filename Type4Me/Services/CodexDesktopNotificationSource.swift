import AppKit
import Darwin
import Foundation
import Security
import OSLog

/// Passively follows desktop-owned conversations; it never starts an agent or sends user input.
final class CodexDesktopNotificationSource: @unchecked Sendable {
    typealias SessionLoader = @Sendable () throws -> [AgentSessionDescriptor]
    private let configuration: AgentNotificationConfiguration
    private let loadSessions: SessionLoader

    /// Creates a bounded observer of Codex's existing, same-user desktop IPC endpoint.
    ///
    /// Args:
    ///   configuration: Discovery, socket, memory, and preview limits.
    ///   loadSessions: Optional metadata reader for isolated tests; metadata alone never proves ownership.
    init(configuration: AgentNotificationConfiguration = .init(), loadSessions: SessionLoader? = nil) {
        self.configuration = configuration
        self.loadSessions = loadSessions ?? { try CodexMetadataSessionCatalog().loadSessions() }
    }

    /// Observes until cancellation, reconnecting without replaying historical completion alerts.
    ///
    /// Args:
    ///   emit: Receives verified native states; unavailable states retain previous unanswered requests.
    func run(emit: @escaping @Sendable (AgentInboxUpdate) async -> Void) async {
        guard (try? configuration.validate()) != nil else { return }
        let worker = Task.detached(priority: .utility) { [self] in
            var reconnectAttempt = 0
            while !Task.isCancelled {
                let started = ProcessInfo.processInfo.systemUptime
                do { try await observe(emit: emit) }
                catch is CancellationError { return }
                catch {
                    let reason = (error as? CodexInboxError).map { String(describing: $0) } ?? "unexpectedError"
                    Logger(subsystem: "com.mytype.app", category: "AgentInbox").error("Codex observer reconnecting: \(reason, privacy: .public)")
                }
                reconnectAttempt = ProcessInfo.processInfo.systemUptime - started >= configuration.discoveryIntervalSeconds
                    ? 0 : min(reconnectAttempt + 1, configuration.maximumSnapshotRetries)
                let delay = min(configuration.discoveryIntervalSeconds,
                                configuration.reconnectDelaySeconds * pow(2, Double(reconnectAttempt)))
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
        await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Maintains one authenticated connection and a bounded set of explicitly discovered owners.
    ///
    /// Args:
    ///   emit: Destination for visible conversation observations.
    ///
    /// Raises:
    ///   Error: The peer disappeared, violated the protocol, or exceeded configured bounds.
    private func observe(emit: @escaping @Sendable (AgentInboxUpdate) async -> Void) async throws {
        let socket = try CodexInboxSocket(configuration: configuration)
        defer { socket.close() }
        let initializeID = UUID().uuidString
        try socket.send(["type": "request", "requestId": initializeID, "sourceClientId": "", "version": 0,
                         "method": "initialize", "params": ["clientType": "mytype-notification-observer"]])
        let initializationDeadline = ProcessInfo.processInfo.systemUptime + configuration.ioTimeoutSeconds
        var clientID: String?
        var pending: [String: (session: AgentSessionDescriptor, deadline: TimeInterval)] = [:]
        var sessions: [String: AgentSessionDescriptor] = [:]
        var owners: [String: String] = [:]
        var reducers: [String: CodexInboxStateReducer] = [:]
        var followDeadlines: [String: TimeInterval] = [:]
        var pendingReadRefreshes: Set<String> = []
        var retries: [String: Int] = [:]
        var cooldowns: [String: TimeInterval] = [:]
        var nextDiscovery: TimeInterval = 0
        do {
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if clientID == nil, now >= initializationDeadline { throw CodexInboxError.timeout }
                if let clientID, now >= nextDiscovery {
                    let candidates = try loadSessions().filter {
                        $0.application == .codex && UUID(uuidString: $0.sessionID) != nil
                    }.sorted { $0.updatedAt > $1.updatedAt }.prefix(configuration.maximumSessions)
                    // Old metadata is only a discovery candidate; no matching live owner means no inbox entry.
                    let wanted = Set(candidates.map(\.sessionID))
                    for id in Array(owners.keys) where !wanted.contains(id) {
                        try socket.follow(clientID: clientID, ownerID: owners[id]!, sessionID: id, following: false)
                        if let session = sessions[id] { await emit(.init(session: session, status: .unknown)) }
                        owners[id] = nil; reducers[id] = nil; sessions[id] = nil; followDeadlines[id] = nil
                    }
                    for id in Array(sessions.keys) where !wanted.contains(id) {
                        sessions[id] = nil; reducers[id] = nil; followDeadlines[id] = nil; retries[id] = nil; cooldowns[id] = nil
                    }
                    pending = pending.filter { wanted.contains($0.value.session.sessionID) }
                    retries = retries.filter { wanted.contains($0.key) }
                    cooldowns = cooldowns.filter { wanted.contains($0.key) }
                    pendingReadRefreshes.formIntersection(wanted)
                    for session in candidates where cooldowns[session.sessionID, default: 0] <= now
                        && !pending.values.contains(where: { $0.session.sessionID == session.sessionID }) {
                        let id = UUID().uuidString
                        pending[id] = (session, now + configuration.ioTimeoutSeconds)
                        try socket.send(["type": "request", "requestId": id, "sourceClientId": clientID,
                                         "version": 1, "method": "thread-owner-discovery",
                                         "timeoutMs": Int(configuration.ioTimeoutSeconds * 1_000),
                                         "params": ["hostId": "local", "conversationId": session.sessionID]])
                    }
                    nextDiscovery = now + configuration.discoveryIntervalSeconds
                }
                for id in Array(pending.keys) where pending[id]!.deadline < now {
                    let session = pending.removeValue(forKey: id)!.session
                    if owners[session.sessionID] != nil {
                        await emit(.init(session: session, status: .unknown))
                        if let clientID, let owner = owners.removeValue(forKey: session.sessionID) {
                            try socket.follow(clientID: clientID, ownerID: owner, sessionID: session.sessionID, following: false)
                        }
                        reducers[session.sessionID] = nil; followDeadlines[session.sessionID] = nil
                    }
                }
                for id in Array(followDeadlines.keys) where followDeadlines[id]! < now {
                    guard let owner = owners[id], let clientID else { continue }
                    if let session = sessions[id] { await emit(.init(session: session, status: .unknown)) }
                    let attempts = retries[id, default: 0] + 1
                    retries[id] = attempts
                    guard attempts <= configuration.maximumSnapshotRetries else { throw CodexInboxError.timeout }
                    try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: false)
                    try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                    followDeadlines[id] = now + configuration.ioTimeoutSeconds
                }
                guard let packet = try socket.receive() else { continue }
                if packet["type"] as? String == "client-discovery-request" {
                    // The router can ask all peers whether they implement an action. This observer implements none.
                    if let requestID = packet["requestId"] as? String {
                        try socket.send(["type": "client-discovery-response", "requestId": requestID,
                                         "response": ["canHandle": false]])
                    }
                    continue
                }
                if packet["type"] as? String == "response", let requestID = packet["requestId"] as? String {
                    if requestID == initializeID {
                        guard packet["resultType"] as? String == "success",
                              let result = packet["result"] as? [String: Any],
                              let value = result["clientId"] as? String, UUID(uuidString: value) != nil else {
                            throw CodexInboxError.protocolMismatch
                        }
                        clientID = value
                    } else if let discovery = pending.removeValue(forKey: requestID), let clientID {
                        let id = discovery.session.sessionID
                        let owner = packet["handledByClientId"] as? String
                        guard packet["resultType"] as? String == "success", let owner, UUID(uuidString: owner) != nil else {
                            if let previous = owners.removeValue(forKey: id) {
                                try socket.follow(clientID: clientID, ownerID: previous, sessionID: id, following: false)
                                await emit(.init(session: discovery.session, status: .unknown))
                            }
                            reducers[id] = nil; followDeadlines[id] = nil
                            continue
                        }
                        sessions[id] = discovery.session
                        if owners[id] != owner {
                            if let previous = owners[id] {
                                try socket.follow(clientID: clientID, ownerID: previous, sessionID: id, following: false)
                                await emit(.init(session: discovery.session, status: .unknown))
                            }
                            owners[id] = owner
                            reducers[id] = CodexInboxStateReducer(configuration: configuration)
                            retries[id] = 0
                            try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                            followDeadlines[id] = now + configuration.ioTimeoutSeconds
                        }
                    }
                    continue
                }
                if packet["method"] as? String == "ipc-connection-reset" { throw CodexInboxError.disconnected }
                if let id = CodexInboxStateReducer.readStateRefreshSessionID(packet: packet),
                   let owner = owners[id], reducers[id] != nil, let clientID {
                    // Broadcasts are hints only. Re-following returns a fresh, owner-validated snapshot
                    // without detaching or resetting turn history, even at the same revision.
                    if followDeadlines[id] != nil {
                        pendingReadRefreshes.insert(id)
                    } else {
                        try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                        followDeadlines[id] = now + configuration.ioTimeoutSeconds
                    }
                }
                if packet["method"] as? String == "client-status-changed",
                   let params = packet["params"] as? [String: Any], params["status"] as? String == "disconnected",
                   let disconnected = params["clientId"] as? String {
                    for id in Array(owners.keys) where owners[id] == disconnected {
                        if let session = sessions[id] { await emit(.init(session: session, status: .unknown)) }
                        owners[id] = nil; reducers[id] = nil; followDeadlines[id] = nil
                    }
                    nextDiscovery = min(nextDiscovery, now + configuration.reconnectDelaySeconds)
                }
                if packet["method"] as? String == "thread-stream-following-status-requested",
                   packet["version"] as? Int == 1, let params = packet["params"] as? [String: Any],
                   params["hostId"] as? String == "local", let id = params["conversationId"] as? String,
                   let owner = owners[id], packet["sourceClientId"] as? String == owner, let clientID {
                    reducers[id]?.invalidateRevision()
                    try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                    followDeadlines[id] = now + configuration.ioTimeoutSeconds
                }
                guard packet["method"] as? String == "thread-stream-state-changed",
                      let parameters = packet["params"] as? [String: Any],
                      let id = parameters["conversationId"] as? String,
                      let owner = owners[id], let session = sessions[id], var reducer = reducers[id], let clientID else { continue }
                do {
                    let update = try reducer.accept(packet: packet, ownerID: owner, session: session)
                    reducers[id] = reducer
                    if reducers.values.reduce(0, { $0 + $1.estimatedBytes }) > configuration.maximumCodexStateBytes {
                        for key in Array(reducers.keys) { try reducers[key]?.recountBytes() }
                        guard reducers.values.reduce(0, { $0 + $1.estimatedBytes }) <= configuration.maximumCodexStateBytes else {
                            throw CodexInboxError.capacityExceeded
                        }
                    }
                    let receivedSnapshot = (parameters["change"] as? [String: Any])?["type"] as? String == "snapshot"
                    // A patch can arrive while the owner is preparing the requested snapshot. It
                    // does not acknowledge that refresh, including a same-revision read refresh.
                    if receivedSnapshot {
                        followDeadlines[id] = nil
                        retries[id] = 0
                    }
                    await emit(update)
                    if receivedSnapshot, pendingReadRefreshes.remove(id) != nil {
                        try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                        followDeadlines[id] = now + configuration.ioTimeoutSeconds
                    }
                } catch {
                    await emit(.init(session: session, status: .unknown))
                    if error as? CodexInboxError == .capacityExceeded {
                        // A large conversation must not disconnect healthy streams or trigger an immediate retry loop.
                        try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: false)
                        owners[id] = nil; reducers[id] = nil; followDeadlines[id] = nil; retries[id] = nil
                        cooldowns[id] = now + configuration.discoveryIntervalSeconds
                        continue
                    }
                    reducers[id]?.invalidateRevision()
                    let attempts = retries[id, default: 0] + 1
                    retries[id] = attempts
                    guard attempts <= configuration.maximumSnapshotRetries else { throw error }
                    try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: false)
                    try socket.follow(clientID: clientID, ownerID: owner, sessionID: id, following: true)
                    followDeadlines[id] = now + configuration.ioTimeoutSeconds
                }
            }
        } catch {
            for (id, session) in sessions where owners[id] != nil { await emit(.init(session: session, status: .unknown)) }
            throw error
        }
        // Socket close is the router's authoritative follower cleanup, including cancellation during a partial frame.
    }
}

enum CodexInboxError: Error, Equatable {
    case socketUnavailable, untrustedPeer, timeout, disconnected, protocolMismatch, revisionGap, invalidPatch, capacityExceeded
}

/// Atomic replay of the desktop's versioned Immer state without interpreting tool output as dialogue.
struct CodexInboxStateReducer {
    private let configuration: AgentNotificationConfiguration
    private(set) var state: [String: Any]?
    private(set) var revision: Int?
    private(set) var estimatedBytes = 0
    private var turnStatuses: [String: String] = [:]
    private var outstanding: [String: (request: AgentInboxRequest, position: Position)] = [:]

    private struct Position: Comparable {
        let time: Double
        let turnID: String
        let itemIndex: Int
        static func < (left: Self, right: Self) -> Bool {
            if left.time != right.time { return left.time < right.time }
            if left.turnID != right.turnID { return left.turnID < right.turnID }
            return left.itemIndex < right.itemIndex
        }
    }

    /// Creates an isolated stream reducer with explicit payload bounds.
    ///
    /// Args:
    ///   configuration: Preview, request, and state limits.
    init(configuration: AgentNotificationConfiguration = .init()) { self.configuration = configuration }

    /// Extracts a native read-state hint without accepting it as proof of reading.
    ///
    /// Args:
    ///   packet: Broadcast received through the verified desktop router.
    ///
    /// Returns:
    ///   Local session identity to refresh from its known owner, or nil for other packets.
    static func readStateRefreshSessionID(packet: [String: Any]) -> String? {
        guard packet["type"] as? String == "broadcast",
              packet["method"] as? String == "thread-read-state-changed",
              packet["version"] as? Int == 3,
              let params = packet["params"] as? [String: Any], params["hostId"] as? String == "local",
              let unread = params["hasUnreadTurn"] as? NSNumber, CFGetTypeID(unread) == CFBooleanGetTypeID(),
              !unread.boolValue,
              let id = params["conversationId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    /// Invalidates stale patch state while retaining unresolved asynchronous questions.
    mutating func invalidateRevision() { state = nil; revision = nil; estimatedBytes = 0; turnStatuses = [:] }

    /// Recomputes actual state size only when conservative incremental accounting reaches its budget.
    ///
    /// Raises:
    ///   Error: State contains a non-JSON value.
    mutating func recountBytes() throws {
        estimatedBytes = try state.map { try JSONSerialization.data(withJSONObject: $0).count } ?? 0
    }

    /// Validates sender, identity, schema, and revision before committing an entire native state change.
    ///
    /// Args:
    ///   packet: One decoded desktop broadcast.
    ///   ownerID: Owner established by this connection's targeted discovery reply.
    ///   session: Exact native conversation metadata.
    ///
    /// Returns:
    ///   Current visible state; snapshots never generate completion alerts.
    ///
    /// Raises:
    ///   CodexInboxError: State cannot safely be attributed or replayed.
    mutating func accept(packet: [String: Any], ownerID: String, session: AgentSessionDescriptor) throws -> AgentInboxUpdate {
        guard packet["type"] as? String == "broadcast", packet["method"] as? String == "thread-stream-state-changed",
              packet["version"] as? Int == 11,
              packet["sourceClientId"] as? String == ownerID,
              let parameters = packet["params"] as? [String: Any], parameters["hostId"] as? String == "local",
              parameters["conversationId"] as? String == session.sessionID,
              let change = parameters["change"] as? [String: Any], let nextRevision = change["revision"] as? Int,
              nextRevision >= 0 else { throw CodexInboxError.protocolMismatch }
        let isSnapshot = change["type"] as? String == "snapshot"
        var hasFreshReadState = isSnapshot
        let next: [String: Any]
        var nextBytes = estimatedBytes
        if isSnapshot {
            guard let snapshot = change["conversationState"] as? [String: Any], revision == nil || nextRevision >= revision! else { throw CodexInboxError.protocolMismatch }
            next = snapshot
            nextBytes = try JSONSerialization.data(withJSONObject: snapshot).count
        } else {
            guard change["type"] as? String == "patches", let revision, let state,
                  change["baseRevision"] as? Int == revision, nextRevision > revision,
                  let patches = change["patches"] as? [[String: Any]] else { throw CodexInboxError.revisionGap }
            var root: Any = state
            for patch in patches {
                guard let path = patch["path"] as? [Any], let operation = patch["op"] as? String else { throw CodexInboxError.invalidPatch }
                root = try Self.patch(root, path: ArraySlice(path), operation: operation, value: patch["value"])
                if path as? [String] == ["hasUnreadTurn"] { hasFreshReadState = true }
                if let value = patch["value"] {
                    nextBytes += try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]).count
                }
            }
            guard let result = root as? [String: Any] else { throw CodexInboxError.invalidPatch }
            next = result
        }
        guard next["id"] as? String == session.sessionID, next["hostId"] as? String == "local",
              next["requests"] is [Any], next["threadRuntimeStatus"] is [String: Any] else { throw CodexInboxError.protocolMismatch }
        // A full-state recount limits long-running text replacement streams without serializing history every token.
        if nextBytes > configuration.maximumCodexStateBytes {
            nextBytes = try JSONSerialization.data(withJSONObject: next).count
            guard nextBytes <= configuration.maximumCodexStateBytes else { throw CodexInboxError.capacityExceeded }
        }
        state = next; revision = nextRevision; estimatedBytes = nextBytes
        let unread = next["hasUnreadTurn"] as? NSNumber
        let nativeHasUnreadTurn = hasFreshReadState && unread.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
            ? unread?.boolValue : nil
        return project(next, session: session, snapshot: isSnapshot, nativeHasUnreadTurn: nativeHasUnreadTurn)
    }

    /// Applies one bounded Immer path with strict array bounds and no partial state mutation.
    ///
    /// Args:
    ///   node: Current JSON subtree.
    ///   path: Remaining string/integer path components.
    ///   operation: Native add, replace, or remove operation.
    ///   value: Required for add and replace, including explicit JSON null.
    ///
    /// Returns:
    ///   A new subtree sharing unchanged values with its predecessor.
    ///
    /// Raises:
    ///   CodexInboxError: Unsupported operation, missing parent, or invalid index.
    static func patch(_ node: Any, path: ArraySlice<Any>, operation: String, value: Any?) throws -> Any {
        guard ["add", "replace", "remove"].contains(operation), path.count <= 128 else { throw CodexInboxError.invalidPatch }
        guard let key = path.first else {
            guard operation != "remove", let value else { throw CodexInboxError.invalidPatch }
            return value
        }
        if var object = node as? [String: Any], let key = key as? String {
            if path.count == 1 {
                if operation == "remove" {
                    guard object.removeValue(forKey: key) != nil else { throw CodexInboxError.invalidPatch }
                } else {
                    guard let value, operation == "add" || object[key] != nil else { throw CodexInboxError.invalidPatch }
                    object[key] = value
                }
            } else {
                guard let child = object[key] else { throw CodexInboxError.invalidPatch }
                object[key] = try patch(child, path: path.dropFirst(), operation: operation, value: value)
            }
            return object
        }
        if var array = node as? [Any], let index = key as? Int, let number = key as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), index >= 0 {
            if path.count == 1, operation == "add" {
                guard index <= array.count, let value else { throw CodexInboxError.invalidPatch }
                array.insert(value, at: index)
            } else {
                guard array.indices.contains(index) else { throw CodexInboxError.invalidPatch }
                if path.count > 1 { array[index] = try patch(array[index], path: path.dropFirst(), operation: operation, value: value) }
                else if operation == "remove" { array.remove(at: index) }
                else { guard let value else { throw CodexInboxError.invalidPatch }; array[index] = value }
            }
            return array
        }
        throw CodexInboxError.invalidPatch
    }

    /// Separates explicit turn completion from runtime idle and persistent asynchronous questions.
    ///
    /// Args:
    ///   state: Validated, completely replayed native state.
    ///   session: Exact conversation descriptor.
    ///   snapshot: Whether this is baseline/recovery state that must stay quiet.
    ///   nativeHasUnreadTurn: Read state explicitly refreshed by this packet, never inherited from old patches.
    ///
    /// Returns:
    ///   A bounded UI projection with no tool execution output.
    private mutating func project(_ state: [String: Any], session: AgentSessionDescriptor, snapshot: Bool,
                                  nativeHasUnreadTurn: Bool?) -> AgentInboxUpdate {
        let history = ((state["turnHistory"] as? [String: Any])?["history"] as? [String: Any])?["entitiesByKey"] as? [String: Any] ?? [:]
        var turnsByID: [String: [String: Any]] = [:]
        for turn in (state["turns"] as? [[String: Any]] ?? []) + history.values.compactMap({ $0 as? [String: Any] }) {
            if let id = turn["turnId"] as? String { turnsByID[id] = turn }
        }
        let turns = turnsByID.values.sorted {
            let left = $0["turnStartedAtMs"] as? Double ?? 0, right = $1["turnStartedAtMs"] as? Double ?? 0
            return left == right ? ($0["turnId"] as? String ?? "") < ($1["turnId"] as? String ?? "") : left < right
        }
        var lastUser: Position?
        var preview = ""
        var completion: String?
        var newStatuses: [String: String] = [:]
        for turn in turns {
            guard let turnID = turn["turnId"] as? String else { continue }
            let status = turn["status"] as? String ?? ""
            newStatuses[turnID] = status
            if !snapshot, status == "completed", turnStatuses[turnID] == "inProgress" {
                completion = turnID
            }
            for (index, item) in (turn["items"] as? [[String: Any]] ?? []).enumerated() {
                let position = Position(time: turn["turnStartedAtMs"] as? Double ?? 0, turnID: turnID, itemIndex: index)
                if item["type"] as? String == "userMessage" { lastUser = position }
                guard item["type"] as? String == "agentMessage" else { continue }
                if let text = item["text"] as? String, !text.isEmpty { preview = String(text.prefix(configuration.maximumPreviewCharacters)) }
                if item["delivery"] as? String == "async", let questions = item["questions"] as? [[String: Any]],
                   !questions.isEmpty, let id = item["id"] as? String {
                    let text = (item["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? questions.compactMap { $0["title"] as? String }.joined(separator: "\n")
                    outstanding[id] = (.init(id: "async:" + id, kind: .input,
                                            text: String(text.prefix(configuration.maximumPreviewCharacters))), position)
                }
            }
        }
        if let lastUser { outstanding = outstanding.filter { !($0.value.position < lastUser) } }
        // Bound retained question state even if the native history contains repeated unanswered prompts.
        outstanding = Dictionary(uniqueKeysWithValues: outstanding.sorted { $0.value.position > $1.value.position }
            .prefix(configuration.maximumPendingRequests).map { ($0.key, $0.value) })
        var requests = (state["requests"] as? [[String: Any]] ?? []).compactMap { request -> AgentInboxRequest? in
            guard let method = request["method"] as? String, let id = request["id"],
                  let parameters = request["params"] as? [String: Any],
                  parameters["threadId"] == nil || parameters["threadId"] as? String == session.sessionID else { return nil }
            let requestID: String
            if let value = id as? String, value.count <= AgentSessionMetadataValidation.maximumIdentifierCharacters { requestID = value }
            else if let value = id as? NSNumber { requestID = value.stringValue }
            else { return nil }
            let approvalMethods = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"]
            let inputMethods = ["item/tool/requestUserInput", "mcpServer/elicitation/request"]
            guard approvalMethods.contains(method) || inputMethods.contains(method) else { return nil }
            let questions = parameters["questions"] as? [[String: Any]] ?? []
            let text = parameters["reason"] as? String ?? parameters["message"] as? String
                ?? questions.compactMap { $0["question"] as? String ?? $0["header"] as? String }.joined(separator: "\n")
            return .init(id: "request:\(requestID)", kind: approvalMethods.contains(method) ? .approval : .input,
                         text: String(text.prefix(configuration.maximumPreviewCharacters)))
        }
        let hasBlockingRequest = !requests.isEmpty
        requests += outstanding.values.sorted { $0.position < $1.position }.map(\.request)
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        let latest = turns.last?["status"] as? String
        let flags = runtime["activeFlags"] as? [String] ?? []
        let waiting = hasBlockingRequest || flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
        if completion != turns.last?["turnId"] as? String { completion = nil }
        let status: AgentInboxStatus
        if completion != nil { status = .completed }
        else if runtime["type"] as? String == "active" { status = waiting ? .waiting : .running }
        else if latest == "interrupted" { status = .interrupted }
        else if latest == "failed" { status = .failed }
        else if latest == "completed" { status = .completed }
        else if !requests.isEmpty { status = .waiting }
        else if runtime["type"] as? String == "idle" { status = .idle }
        else { status = .unknown }
        turnStatuses = newStatuses
        return .init(session: session, status: status,
                     pendingRequests: Array(requests.prefix(configuration.maximumPendingRequests)), preview: preview,
                     completionID: completion, nativeHasUnreadTurn: nativeHasUnreadTurn)
    }
}

/// Nonblocking framed socket whose peer is the signed original Codex desktop process.
final class CodexInboxSocket {
    private let configuration: AgentNotificationConfiguration
    private var descriptor: Int32 = -1
    private var buffer = Data()
    private var peerPID: Int32 = 0
    private var peerStart: UInt64 = 0
    private var partialFrameStarted: TimeInterval?

    /// Connects without starting an app and verifies the socket, live process, and signing identity.
    ///
    /// Args:
    ///   configuration: I/O and framing limits.
    ///
    /// Raises:
    ///   CodexInboxError: Endpoint ownership, transport, or process identity cannot be verified.
    init(configuration: AgentNotificationConfiguration) throws {
        self.configuration = configuration
        let endpoint = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")
        guard Self.owned(endpoint, type: S_IFSOCK), Self.owned(endpoint.deletingLastPathComponent(), type: S_IFDIR) else {
            throw CodexInboxError.socketUnavailable
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexInboxError.socketUnavailable }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw CodexInboxError.socketUnavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(endpoint.path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexInboxError.socketUnavailable }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw CodexInboxError.socketUnavailable }
                try wait(events: Int16(POLLOUT), timeout: configuration.ioTimeoutSeconds)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CodexInboxError.socketUnavailable }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0,
                  let start = Self.processStart(peerPID), Self.trustedDesktop(peerPID, signingTeam: configuration.codexSigningTeamIdentifier) else { throw CodexInboxError.untrustedPeer }
            peerStart = start
        } catch { close(); throw error }
    }

    /// Closes this observer's connection only; closing never terminates the desktop owner.
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }; buffer.removeAll() }
    deinit { close() }

    /// Writes one complete length-prefixed JSON frame against a shared monotonic deadline.
    ///
    /// Args:
    ///   packet: Control-plane subscription packet, never user content or approval decisions.
    ///
    /// Raises:
    ///   CodexInboxError: Write failed, was cancelled, or exceeded its deadline.
    func send(_ packet: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: packet)
        guard body.count <= configuration.maximumFrameBytes else { throw CodexInboxError.capacityExceeded }
        var size = UInt32(body.count).littleEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(body)
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.ioTimeoutSeconds
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexInboxError.timeout }
                let result = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if result > 0 { offset += result }
                else if result < 0, errno == EINTR { continue }
                else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(events: Int16(POLLOUT), timeout: deadline - ProcessInfo.processInfo.systemUptime)
                } else { throw CodexInboxError.disconnected }
            }
        }
    }

    /// Returns a complete frame or nil after a short poll, preserving incomplete frames within bounds.
    ///
    /// Returns:
    ///   One native JSON object; no historical transcript is logged.
    ///
    /// Raises:
    ///   CodexInboxError: Peer disappeared, frame is oversized, or JSON is incompatible.
    func receive() throws -> [String: Any]? {
        try Task.checkCancellation()
        guard Self.processStart(peerPID) == peerStart else { throw CodexInboxError.untrustedPeer }
        if let started = partialFrameStarted, ProcessInfo.processInfo.systemUptime - started > configuration.ioTimeoutSeconds {
            throw CodexInboxError.timeout
        }
        if let packet = try takeFrame() { return packet }
        do { try wait(events: Int16(POLLIN), timeout: configuration.socketPollSeconds) }
        catch CodexInboxError.timeout { return nil }
        var bytes = [UInt8](repeating: 0, count: min(configuration.maximumFrameBytes + 4 - buffer.count, 65_536))
        guard !bytes.isEmpty else { throw CodexInboxError.capacityExceeded }
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count > 0 {
            if buffer.isEmpty { partialFrameStarted = ProcessInfo.processInfo.systemUptime }
            buffer.append(contentsOf: bytes.prefix(count)); return try takeFrame()
        }
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
        throw CodexInboxError.disconnected
    }

    /// Builds the exact non-mutating native follower subscription frame.
    ///
    /// Args:
    ///   clientID: Initialized observer identity.
    ///   ownerID: Discovered owner identity.
    ///   sessionID: Exact native conversation UUID.
    ///   following: Whether to attach or detach this observer.
    ///
    /// Raises:
    ///   Error: The frame could not be fully sent.
    func follow(clientID: String, ownerID: String, sessionID: String, following: Bool) throws {
        try send(["type": "broadcast", "sourceClientId": clientID, "targetClientIds": [ownerID], "version": 1,
                  "method": "thread-stream-following-changed",
                  "params": ["hostId": "local", "conversationId": sessionID, "following": following]])
    }

    /// Removes only one complete little-endian frame, retaining any following frame bytes.
    ///
    /// Returns:
    ///   Decoded JSON or nil while the first frame is incomplete.
    ///
    /// Raises:
    ///   CodexInboxError: Invalid length or root JSON shape.
    private func takeFrame() throws -> [String: Any]? {
        let result = try Self.decodeFrame(from: &buffer, maximumBytes: configuration.maximumFrameBytes)
        if result != nil { partialFrameStarted = buffer.isEmpty ? nil : ProcessInfo.processInfo.systemUptime }
        return result
    }

    /// Decodes a bounded frame without assuming any alignment or network packet boundary.
    ///
    /// Args:
    ///   buffer: Incomplete/coalesced bytes; only a successfully decoded frame is consumed.
    ///   maximumBytes: Largest accepted JSON payload.
    ///
    /// Returns:
    ///   The first complete JSON object, or nil until its bytes arrive.
    ///
    /// Raises:
    ///   CodexInboxError: Frame length or JSON root is unsupported.
    static func decodeFrame(from buffer: inout Data, maximumBytes: Int) throws -> [String: Any]? {
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size > 0, size <= maximumBytes else { throw CodexInboxError.capacityExceeded }
        guard buffer.count >= size + 4 else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(size))
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw CodexInboxError.protocolMismatch }
        buffer.removeFirst(size + 4)
        return object
    }

    /// Polls in cancellation-sized slices while preserving one operation deadline.
    ///
    /// Args:
    ///   events: Required read/write readiness bits.
    ///   timeout: Maximum total wait duration in seconds.
    ///
    /// Raises:
    ///   CodexInboxError: Poll failure, hangup without readable data, or timeout.
    private func wait(events: Int16, timeout: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let count = Darwin.poll(&pollDescriptor, 1, Int32(ceil(min(configuration.socketPollSeconds, remaining) * 1_000)))
            if count > 0 {
                if pollDescriptor.revents & events != 0 { return }
                throw CodexInboxError.disconnected
            }
            if count < 0, errno != EINTR { throw CodexInboxError.disconnected }
        }
        throw CodexInboxError.timeout
    }

    /// Checks private socket-directory ownership without following symlinks.
    ///
    /// Args:
    ///   url: Native endpoint or its private containing directory.
    ///   type: Required POSIX object type.
    ///
    /// Returns:
    ///   Whether this user exclusively owns the expected object type.
    private static func owned(_ url: URL, type: mode_t) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && information.st_uid == getuid()
            && information.st_mode & S_IFMT == type && information.st_mode & 0o077 == 0
    }

    /// Returns the exact kernel process generation used to reject PID reuse.
    ///
    /// Args:
    ///   pid: Actual socket peer PID.
    ///
    /// Returns:
    ///   Kernel start microseconds, or nil after process exit or inaccessible identity.
    private static func processStart(_ pid: Int32) -> UInt64? {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size else { return nil }
        return information.pbi_start_tvsec * 1_000_000 + information.pbi_start_tvusec
    }

    /// Verifies the live signed executable against the installed desktop bundle's designated requirement.
    ///
    /// Args:
    ///   pid: PID obtained from the connected Unix socket rather than supplied metadata.
    ///   signingTeam: Packaged OpenAI developer identity pinned to the validated desktop publisher.
    ///
    /// Returns:
    ///   Whether this is the registered original desktop's valid running executable.
    private static func trustedDesktop(_ pid: Int32, signingTeam: String) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard AgentDesktopLauncherService.isValidApplication(at: bundle, bundleIdentifier: AgentDesktopApplication.codex.bundleIdentifier),
              let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentDesktopApplication.codex.bundleIdentifier),
              registered.resolvingSymlinksInPath() == bundle else { return false }
        guard !signingTeam.isEmpty, signingTeam.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return false }
        var publisher: SecRequirement?
        let expression = "anchor apple generic and identifier \"com.openai.codex\" and certificate leaf[subject.OU] = \"\(signingTeam)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &publisher) == errSecSuccess, let publisher else { return false }
        var installed: SecStaticCode?
        var requirement: SecRequirement?
        var dynamic: SecCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &installed) == errSecSuccess, let installed,
              SecStaticCodeCheckValidity(installed, [], publisher) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(installed, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &dynamic) == errSecSuccess,
              let dynamic, SecCodeCheckValidity(dynamic, [], requirement) == errSecSuccess,
              SecCodeCheckValidity(dynamic, [], publisher) == errSecSuccess else { return false }
        return true
    }
}
