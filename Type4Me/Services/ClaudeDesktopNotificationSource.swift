import Darwin
import Foundation

/// Reads only live native Claude registrations and bounded visible transcript tails.
final class ClaudeDesktopNotificationSource: @unchecked Sendable {
    struct Registration: Decodable, Sendable {
        let pid: Int32
        let sessionId: String
        let hostSessionId: String?
        let entrypoint: String?
        let peerProtocol: Int?
        let procStart: String?
        let messagingSocketPath: String?
        let cwd: String?
        let status: String?
        let statusUpdatedAt: Double?
        let waitingFor: String?
        let peerFeatures: [String]?

        /// Checks immutable identity against a previously verified desktop process.
        ///
        /// Args:
        ///   session: Native and engine conversation identity.
        ///   inbox: Kernel-verified process generation and socket.
        ///
        /// Returns:
        ///   Whether this registration still belongs to that exact desktop runtime.
        func matches(session: AgentSessionDescriptor, inbox: AgentHandoffDeliveryService.ClaudeInbox) -> Bool {
            pid == inbox.processID && sessionId.lowercased() == session.engineSessionID?.lowercased()
                && hostSessionId == session.sessionID && entrypoint == "claude-desktop"
                && peerProtocol == 1 && messagingSocketPath.map { URL(fileURLWithPath: $0).standardizedFileURL == inbox.socketURL.standardizedFileURL } == true
                && AgentHandoffDeliveryService.processStartMatches(procStart, kernelStartSeconds: inbox.processStartSeconds)
        }
    }

    struct VisibleTail: Sendable {
        var finalID: String?
        var finalDate: Date?
        var finalText = ""
        var questionID: String?
        var questionText = ""
    }

    struct IdleNotice: Decodable, Sendable {
        let type: String
        let action: String
        let orig_msg_id: String
        let state: String
        let finished_at: Double?
        let from: String
        let msgV: Int
    }

    /// Keeps completion evidence separate from a runtime's otherwise ambiguous idle state.
    struct Cycle: Sendable {
        var busySince: Date?
        var subscriptionID: String?
        var subscriptionAttempts = 0
        var notice: IdleNotice?
        var completedID: String?
        var previousStatus: String?

        /// Starts a cycle only after observing an actual busy registration.
        ///
        /// Args:
        ///   registration: Current validated native state.
        mutating func observe(_ registration: Registration) {
            let finishedBeforeCurrentBusy = notice?.state == "idle"
                && notice?.finished_at.map { $0 < (registration.statusUpdatedAt ?? 0) } == true
            if registration.status == "busy", busySince == nil || previousStatus == "idle" || finishedBeforeCurrentBusy,
               let timestamp = registration.statusUpdatedAt, timestamp.isFinite, timestamp > 0 {
                busySince = Date(timeIntervalSince1970: timestamp / 1_000)
                subscriptionID = nil
                subscriptionAttempts = 0
                notice = nil
                completedID = nil
            }
            previousStatus = registration.status
        }

        /// Accepts one push only for its active subscription and process socket.
        ///
        /// Args:
        ///   incoming: Decoded push from an independently verified peer.
        ///   inbox: Verified sending runtime.
        ///
        /// Returns:
        ///   Whether the push is correlated to the currently observed cycle.
        mutating func receive(_ incoming: IdleNotice, inbox: AgentHandoffDeliveryService.ClaudeInbox) -> Bool {
            guard busySince != nil, incoming.type == "control", incoming.action == "peer_idle_notice",
                  incoming.msgV == 1, incoming.orig_msg_id == subscriptionID,
                  incoming.from == "uds:" + inbox.socketURL.path,
                  ["idle", "exited", "unavailable"].contains(incoming.state) else { return false }
            if incoming.state == "idle" {
                guard let finished = incoming.finished_at, finished.isFinite,
                      finished / 1_000 >= busySince!.timeIntervalSince1970 else { return false }
            }
            notice = incoming
            return true
        }

        /// Requires both a native idle push and a new final visible answer before completing.
        ///
        /// Args:
        ///   tail: Visible evidence from this exact engine session.
        ///   status: Latest validated registry status.
        ///
        /// Returns:
        ///   A stable completion identifier once, or nil for old, missing or interrupted evidence.
        mutating func completion(tail: VisibleTail, status: String?) -> String? {
            guard status == "idle", let since = busySince, let notice, notice.state == "idle",
                  let finished = notice.finished_at, let id = tail.finalID, let date = tail.finalDate,
                  date >= since, date.timeIntervalSince1970 <= finished / 1_000,
                  !tail.finalText.isEmpty, id != completedID else { return nil }
            completedID = id
            busySince = nil
            subscriptionID = nil
            self.notice = nil
            return id
        }
    }

    private struct Tracked {
        var session: AgentSessionDescriptor
        let inbox: AgentHandoffDeliveryService.ClaudeInbox
        let registryURL: URL
        var transcriptURL: URL?
        var cycle = Cycle()
        var tail = VisibleTail()
        var tailRevision: String?
        var nextSubscriptionAttempt: TimeInterval = 0
        var identityValid = true
    }

    private let configuration: AgentNotificationConfiguration
    private let home: URL
    private let subscriptionWriter: AgentHandoffDeliveryService.InboxWriter

    /// Creates a passive observer; it never starts, stops or replies to an agent.
    ///
    /// Args:
    ///   configuration: Explicit discovery, polling, timeout and resource limits.
    ///   home: User data root; injectable for isolated filesystem fixtures.
    ///   subscriptionWriter: Passive subscription transport; injectable to audit its exact packets.
    init(configuration: AgentNotificationConfiguration = .init(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
         subscriptionWriter: @escaping AgentHandoffDeliveryService.InboxWriter = AgentHandoffDeliveryService.writeInbox) {
        self.configuration = configuration
        self.home = home
        self.subscriptionWriter = subscriptionWriter
    }

    /// Observes native registrations until cancelled and releases only its own reply socket.
    ///
    /// Args:
    ///   emit: Receives visible states and evidence-backed completion events.
    func run(emit: @escaping @Sendable (AgentInboxUpdate) async -> Void) async {
        var tracked: [String: Tracked] = [:]
        var nextDiscovery: TimeInterval = 0
        var nextReconciliation: TimeInterval = 0
        var listener: ClaudeIdleNoticeListener?
        let watcher = ClaudeRegistryWatcher()
        let registryRoot = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        defer { listener?.close(); watcher.close() }
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let changes = watcher.takeChanges()
            if listener == nil { listener = try? ClaudeIdleNoticeListener(configuration: configuration) }
            if now >= nextDiscovery || changes.directory {
                let periodicValidation = now >= nextDiscovery
                let discovered = await discover(previous: tracked, forceSignatureValidation: periodicValidation)
                for key in tracked.keys.sorted() where discovered[key] == nil {
                    if let previous = tracked[key] { await emit(AgentInboxUpdate(session: previous.session, status: .unknown)) }
                }
                tracked = discovered
                if periodicValidation { nextDiscovery = now + configuration.discoveryIntervalSeconds }
                watcher.reconcile(root: registryRoot, files: tracked.values.map(\.registryURL))
            }
            let pushes = listener?.drain() ?? []
            if pushes.isEmpty, !changes.files, now < nextReconciliation {
                do { try await Task.sleep(for: .seconds(configuration.socketPollSeconds)) }
                catch { break }
                continue
            }
            nextReconciliation = now + configuration.claudeReconcileIntervalSeconds
            for key in tracked.keys.sorted() {
                guard !Task.isCancelled, var item = tracked[key] else { break }
                for push in pushes where push.pid == item.inbox.processID && push.start == item.inbox.processStartSeconds {
                    _ = item.cycle.receive(push.notice, inbox: item.inbox)
                }
                if let notice = item.cycle.notice, ["exited", "unavailable"].contains(notice.state) {
                    item.cycle = Cycle()
                    tracked[key] = item
                    await emit(AgentInboxUpdate(session: item.session, status: notice.state == "exited" ? .interrupted : .unknown))
                    continue
                }
                guard item.identityValid,
                      AgentHandoffDeliveryService.processStartSeconds(processID: item.inbox.processID) == item.inbox.processStartSeconds,
                      let registry = Self.readRegistration(item.registryURL, maximumBytes: configuration.maximumRegistryFileBytes),
                      registry.matches(session: item.session, inbox: item.inbox) else {
                    item.cycle = Cycle()
                    tracked[key] = item
                    await emit(AgentInboxUpdate(session: item.session, status: .unknown))
                    continue
                }
                let priorCycleStart = item.cycle.busySince
                item.cycle.observe(registry)
                if item.cycle.busySince != priorCycleStart { item.nextSubscriptionAttempt = 0 }
                if item.transcriptURL == nil {
                    item.transcriptURL = transcriptURL(engineID: registry.sessionId.lowercased(), cwd: registry.cwd)
                }
                if item.cycle.busySince != nil, item.cycle.subscriptionID == nil,
                   item.cycle.subscriptionAttempts < configuration.maximumSubscriptionAttempts,
                   ["busy", "waiting", "idle"].contains(registry.status ?? ""),
                   registry.peerFeatures?.contains("notify_idle") == true, now >= item.nextSubscriptionAttempt,
                   let listener {
                    let identifier = UUID().uuidString.lowercased()
                    let packet: [String: Any] = ["type": "control", "action": "notify_when_idle", "msgV": 1,
                                                "from": "uds:" + listener.url.path, "msg_id": identifier]
                    if let bytes = try? JSONSerialization.data(withJSONObject: packet) {
                        item.cycle.subscriptionAttempts += 1
                        do {
                            try await subscriptionWriter(item.inbox, bytes + Data([10]), configuration.ioTimeoutSeconds)
                            item.cycle.subscriptionID = identifier
                        } catch AgentHandoffDeliveryError.deliveryUncertain {
                            // An uncertain write may already have registered this exact one-shot notice.
                            item.cycle.subscriptionID = identifier
                        } catch {
                            item.nextSubscriptionAttempt = now + configuration.reconnectDelaySeconds
                        }
                    }
                }
                if registry.status == "waiting" || item.cycle.busySince != nil {
                    refreshTail(&item)
                }
                let update: AgentInboxUpdate
                if let completion = item.cycle.completion(tail: item.tail, status: registry.status) {
                    update = AgentInboxUpdate(session: item.session, status: .completed, pendingRequests: [],
                                              preview: item.tail.finalText, completionID: completion)
                } else if registry.status == "idle", item.cycle.busySince != nil {
                    // The runtime stopped working, but the completion channel or visible result is not yet verified.
                    update = AgentInboxUpdate(session: item.session, status: .unknown, pendingRequests: [])
                } else {
                    update = Self.stateUpdate(registry: registry, session: item.session, tail: item.tail,
                                              completionID: item.cycle.completedID)
                }
                tracked[key] = item
                await emit(update)
            }
            do { try await Task.sleep(for: .seconds(configuration.socketPollSeconds)) }
            catch { break }
        }
    }

    /// Maps validated native state while keeping approval instructions inside the original app.
    ///
    /// Args:
    ///   registry: Native process state.
    ///   session: Exact app-qualified identity.
    ///   tail: Last bounded visible evidence.
    ///   completionID: Previously verified completed result for this cycle.
    ///
    /// Returns:
    ///   A quiet state update; idle alone never emits a completion identifier.
    static func stateUpdate(registry: Registration, session: AgentSessionDescriptor, tail: VisibleTail,
                            completionID: String?) -> AgentInboxUpdate {
        switch registry.status {
        case "busy": return AgentInboxUpdate(session: session, status: .running, pendingRequests: [])
        case "waiting":
            let id = "claude-wait:\(registry.pid):\(registry.statusUpdatedAt ?? 0)"
            if registry.waitingFor == "input needed" {
                return AgentInboxUpdate(session: session, status: .waiting,
                                        pendingRequests: [AgentInboxRequest(id: tail.questionID ?? id, kind: .input, text: tail.questionText)])
            }
            if registry.waitingFor == "permission prompt" {
                return AgentInboxUpdate(session: session, status: .waiting,
                                        pendingRequests: [AgentInboxRequest(id: id, kind: .approval, text: "")])
            }
            return AgentInboxUpdate(session: session, status: .waiting)
        case "idle": return AgentInboxUpdate(session: session, status: completionID == nil ? .idle : .completed, pendingRequests: [])
        default: return AgentInboxUpdate(session: session, status: .unknown)
        }
    }

    /// Discovers a bounded live registry and validates each new runtime through the existing sender.
    ///
    /// Args:
    ///   previous: Previously verified bindings, retained to report disconnects.
    ///   forceSignatureValidation: Whether this is a periodic full identity check instead of a file invalidation.
    ///
    /// Returns:
    ///   Bounded app-qualified bindings; no historical runtimes are started.
    private func discover(previous: [String: Tracked], forceSignatureValidation: Bool) async -> [String: Tracked] {
        var result = previous.mapValues { item in
            var item = item
            item.identityValid = false
            return item
        }
        let registryRoot = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard AgentHandoffDeliveryService.isOwnedItem(registryRoot, kind: S_IFDIR, privatePermissions: true),
              let application = AgentDesktopLauncherService.shared.detectInstallation(for: .claudeCode).applicationURL,
              let entries = FileManager.default.enumerator(at: registryRoot, includingPropertiesForKeys: nil,
                                                           options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return result }
        var catalogConfiguration = ClaudeCodeSessionCatalog.Configuration()
        catalogConfiguration.maximumSessions = configuration.maximumSessions
        let catalog = (try? ClaudeCodeSessionCatalog(metadataDirectory: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
                                                     configuration: catalogConfiguration, openingAvailability: { true }).loadSessions()) ?? []
        let descriptors = Dictionary(catalog.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var deliveryConfiguration = AgentHandoffConfiguration()
        deliveryConfiguration.maximumClaudeRegistryEntries = configuration.maximumRegistryEntries
        deliveryConfiguration.maximumClaudeRegistryFileBytes = configuration.maximumRegistryFileBytes
        deliveryConfiguration.processTimeoutSeconds = configuration.ioTimeoutSeconds
        var entriesSeen = 0
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + configuration.discoveryIntervalSeconds
        while let url = entries.nextObject() as? URL {
            entriesSeen += 1
            guard !Task.isCancelled, entriesSeen <= configuration.maximumRegistryEntries,
                  ProcessInfo.processInfo.systemUptime < discoveryDeadline else { break }
            guard url.pathExtension == "json", let pid = Int32(url.deletingPathExtension().lastPathComponent),
                  let registration = Self.readRegistration(url, maximumBytes: configuration.maximumRegistryFileBytes),
                  registration.pid == pid, registration.entrypoint == "claude-desktop", registration.peerProtocol == 1,
                  let hostID = registration.hostSessionId, AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(hostID),
                  UUID(uuidString: registration.sessionId) != nil else { continue }
            let session = descriptors[hostID].flatMap { $0.engineSessionID?.lowercased() == registration.sessionId.lowercased() ? $0 : nil }
                ?? AgentSessionDescriptor(sessionID: hostID, application: .claudeCode, title: "", workspacePath: registration.cwd,
                                          updatedAt: (registration.statusUpdatedAt ?? 0) / 1_000, matchTexts: [],
                                          openCapability: .claudeNativeDeepLink, engineSessionID: registration.sessionId.lowercased())
            if !forceSignatureValidation, let existing = previous[session.id], existing.identityValid,
               registration.matches(session: session, inbox: existing.inbox),
               AgentHandoffDeliveryService.processStartSeconds(processID: pid) == existing.inbox.processStartSeconds {
                result[session.id]?.session = session
                result[session.id]?.identityValid = true
                continue
            }
            guard result.count < configuration.maximumSessions || result[session.id] != nil,
                  let inbox = try? await AgentHandoffDeliveryService.findClaudeInbox(target: session, applicationURL: application,
                                                                                   configuration: deliveryConfiguration) else { continue }
            if let existing = result[session.id], existing.inbox == inbox,
               registration.matches(session: session, inbox: inbox) {
                result[session.id]?.session = session
                result[session.id]?.identityValid = true
                if existing.transcriptURL == nil {
                    result[session.id]?.transcriptURL = transcriptURL(engineID: registration.sessionId.lowercased(), cwd: registration.cwd)
                }
                continue
            }
            result[session.id] = Tracked(session: session, inbox: inbox, registryURL: url,
                                        transcriptURL: transcriptURL(engineID: registration.sessionId.lowercased(), cwd: registration.cwd))
        }
        // Expired bindings do not occupy discovery capacity forever.
        if result.count >= configuration.maximumSessions {
            result = result.filter { _, item in AgentHandoffDeliveryService.processStartSeconds(processID: item.inbox.processID) == item.inbox.processStartSeconds }
        }
        return result
    }

    /// Reads one bounded registry file without following a symlink or trusting a partial write.
    ///
    /// Args:
    ///   url: Exact PID registration path.
    ///   maximumBytes: Maximum permitted registry size.
    ///
    /// Returns:
    ///   A complete decoded record, or nil; nil never represents idle.
    static func readRegistration(_ url: URL, maximumBytes: Int) -> Registration? {
        guard AgentHandoffDeliveryService.isOwnedItem(url, kind: S_IFREG, privatePermissions: false) else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(Registration.self, from: data)
    }

    /// Resolves one exact engine file in the current project, without scanning transcript contents.
    ///
    /// Args:
    ///   engineID: Validated native engine UUID.
    ///   cwd: Native registry workspace.
    ///
    /// Returns:
    ///   A same-user regular transcript, or nil when its location cannot be proven.
    private func transcriptURL(engineID: String, cwd: String?) -> URL? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        let encoded = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let directory = home.appendingPathComponent(".claude/projects", isDirectory: true).appendingPathComponent(encoded, isDirectory: true)
        let candidate = directory.appendingPathComponent(engineID + ".jsonl")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath(),
              AgentHandoffDeliveryService.isOwnedItem(directory, kind: S_IFDIR, privatePermissions: false),
              AgentHandoffDeliveryService.isOwnedItem(candidate, kind: S_IFREG, privatePermissions: false) else { return nil }
        return candidate
    }

    /// Refreshes a changed transcript tail only while active evidence is needed.
    ///
    /// Args:
    ///   item: Verified session binding and cached visible evidence.
    private func refreshTail(_ item: inout Tracked) {
        guard let url = item.transcriptURL, let engine = item.session.engineSessionID else { return }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { item.tail = VisibleTail(); return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return }
        let revision = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        guard revision != item.tailRevision else { return }
        let offset = max(0, info.st_size - off_t(configuration.maximumTranscriptTailBytes))
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              var data = try? handle.read(upToCount: configuration.maximumTranscriptTailBytes) else { return }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { item.tail = VisibleTail(); return }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        item.tail = Self.visibleTail(data: data, engineID: engine, maximumCharacters: configuration.maximumPreviewCharacters)
        item.tailRevision = revision
    }

    /// Projects final assistant text and visible questions, excluding tools, results and thinking.
    ///
    /// Args:
    ///   data: Bounded complete JSONL records from one native transcript tail.
    ///   engineID: Required native engine identity on every accepted row.
    ///   maximumCharacters: User-facing preview bound.
    ///
    /// Returns:
    ///   Latest visible evidence; malformed or foreign rows cannot produce completion.
    static func visibleTail(data: Data, engineID: String, maximumCharacters: Int) -> VisibleTail {
        var result = VisibleTail()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (row["sessionId"] as? String)?.lowercased() == engineID.lowercased(),
                  row["isSidechain"] as? Bool != true,
                  let type = row["type"] as? String, ["assistant", "user"].contains(type),
                  let timestamp = row["timestamp"] as? String,
                  let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { continue }
            if type == "user" { result = VisibleTail(); continue }
            guard row["entrypoint"] as? String == "claude-desktop",
                  let message = row["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let blocks = message["content"] as? [[String: Any]], let id = row["uuid"] as? String else { continue }
            result = VisibleTail()
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if message["stop_reason"] as? String == "end_turn", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.finalID = id
                result.finalDate = date
                result.finalText = String(text.prefix(maximumCharacters))
            }
            for block in blocks where block["type"] as? String == "tool_use" && block["name"] as? String == "AskUserQuestion" {
                guard let input = block["input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]] else { continue }
                result.questionID = block["id"] as? String
                result.questionText = String(questions.compactMap { $0["question"] as? String }.joined(separator: "\n").prefix(maximumCharacters))
            }
        }
        return result
    }
}

/// Coalesces native directory and per-file changes without reading on a dispatch callback.
private final class ClaudeRegistryWatcher: @unchecked Sendable {
    private struct Watch {
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }
    private let lock = NSLock()
    private var directoryChanged = false
    private var filesChanged = false
    private var watches: [String: Watch] = [:]

    /// Refreshes a bounded watch set and reopens files replaced by native atomic writes.
    ///
    /// Args:
    ///   root: Native registry directory, used only for discovery invalidation.
    ///   files: Exact verified PID files to watch for short state transitions.
    func reconcile(root: URL, files: [URL]) {
        let paths = Set([root.path] + files.map(\.path))
        for path in Array(watches.keys) where !paths.contains(path) {
            watches.removeValue(forKey: path)?.source.cancel()
        }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT != S_IFLNK else { continue }
            if watches[path]?.inode == info.st_ino { continue }
            watches.removeValue(forKey: path)?.source.cancel()
            let fd = Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global(qos: .utility))
            let isRoot = path == root.path
            source.setEventHandler { [weak self, weak source] in
                guard let self else { return }
                self.lock.lock()
                if isRoot || source?.data.contains(.delete) == true || source?.data.contains(.rename) == true {
                    self.directoryChanged = true
                }
                self.filesChanged = true
                self.lock.unlock()
            }
            source.setCancelHandler { Darwin.close(fd) }
            watches[path] = Watch(inode: info.st_ino, source: source)
            source.resume()
        }
    }

    /// Consumes coalesced invalidations on the observer's serial reconciliation loop.
    ///
    /// Returns:
    ///   Whether discovery or current-state reconciliation needs an early refresh.
    func takeChanges() -> (directory: Bool, files: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let result = (directoryChanged, filesChanged)
        directoryChanged = false
        filesChanged = false
        return result
    }

    /// Stops only this observer's event sources and closes their own watch descriptors.
    func close() {
        for watch in watches.values { watch.source.cancel() }
        watches.removeAll()
    }

    deinit { close() }
}

/// Owns a private reply socket and accepts only kernel-identified same-user peers.
private final class ClaudeIdleNoticeListener {
    struct Push {
        let pid: Int32
        let start: UInt64
        let notice: ClaudeDesktopNotificationSource.IdleNotice
    }
    private struct Client {
        let pid: Int32
        let start: UInt64
        let deadline: TimeInterval
        var data = Data()
    }
    let url: URL
    private let configuration: AgentNotificationConfiguration
    private var descriptor: Int32 = -1
    private var inode: ino_t = 0
    private var clients: [Int32: Client] = [:]

    /// Binds the observer's own PID socket without replacing an existing endpoint.
    ///
    /// Args:
    ///   configuration: Frame, connection and deadline bounds.
    ///
    /// Raises:
    ///   AgentHandoffDeliveryError: The private native socket directory or endpoint is unavailable.
    init(configuration: AgentNotificationConfiguration) throws {
        self.configuration = configuration
        let directories = ["/tmp/cc-socks", "/tmp/cc-socks-\(getuid())"]
        guard let root = directories.map({ URL(fileURLWithPath: $0, isDirectory: true) }).first(where: {
            AgentHandoffDeliveryService.isOwnedItem($0, kind: S_IFDIR, privatePermissions: true)
        }) else { throw AgentHandoffDeliveryError.socketUnavailable }
        url = root.appendingPathComponent("\(getpid()).sock")
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentHandoffDeliveryError.socketUnavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(url.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(); throw AgentHandoffDeliveryError.socketUnavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(); throw AgentHandoffDeliveryError.socketUnavailable }
        var info = stat()
        if lstat(url.path, &info) == 0 { inode = info.st_ino }
        guard chmod(url.path, 0o600) == 0, Darwin.listen(descriptor, Int32(configuration.maximumSessions)) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { close(); throw AgentHandoffDeliveryError.socketUnavailable }
    }

    /// Reads bounded complete notices without blocking the registry reconciliation loop.
    ///
    /// Returns:
    ///   Native notices with kernel PID and generation evidence; callers correlate subscriptions.
    func drain() -> [Push] {
        guard descriptor >= 0 else { return [] }
        var accepted = 0
        while clients.count < configuration.maximumSessions, accepted < configuration.maximumSessions {
            let fd = Darwin.accept(descriptor, nil, nil)
            guard fd >= 0 else { break }
            accepted += 1
            var pid: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
                  let start = AgentHandoffDeliveryService.processStartSeconds(processID: pid),
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(fd); continue }
            clients[fd] = Client(pid: pid, start: start, deadline: ProcessInfo.processInfo.systemUptime + configuration.ioTimeoutSeconds)
        }
        var pushes: [Push] = []
        for fd in clients.keys.sorted() {
            guard var client = clients[fd] else { continue }
            var buffer = [UInt8](repeating: 0, count: min(configuration.maximumRegistryFileBytes, configuration.maximumFrameBytes))
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 { client.data.append(contentsOf: buffer.prefix(count)) }
            let oversized = client.data.count > configuration.maximumRegistryFileBytes
            if !oversized, let newline = client.data.firstIndex(of: 10),
               AgentHandoffDeliveryService.processStartSeconds(processID: client.pid) == client.start,
               let notice = try? JSONDecoder().decode(ClaudeDesktopNotificationSource.IdleNotice.self, from: Data(client.data[..<newline])) {
                pushes.append(Push(pid: client.pid, start: client.start, notice: notice))
                Darwin.close(fd); clients.removeValue(forKey: fd)
            } else if oversized || count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                        || ProcessInfo.processInfo.systemUptime > client.deadline {
                Darwin.close(fd); clients.removeValue(forKey: fd)
            } else { clients[fd] = client }
        }
        return pushes
    }

    /// Closes this observer's sockets and unlinks only the inode it created.
    func close() {
        for fd in clients.keys { Darwin.close(fd) }
        clients.removeAll()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        var info = stat()
        if inode != 0, lstat(url.path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK {
            _ = Darwin.unlink(url.path)
        }
        inode = 0
    }

    deinit { close() }
}
