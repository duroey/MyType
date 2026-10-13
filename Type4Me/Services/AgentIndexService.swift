import AppKit
import Darwin
import Foundation
import Observation

/// Supervises the packaged index helper while leaving ingestion and embedding to AgentsView.
@MainActor
@Observable
final class AgentIndexService {
    struct Configuration: Codable, Equatable, Sendable {
        var endpoint = "http://127.0.0.1:18742"
        var expectedAPIVersion = 10
        var expectedDataVersion = 128
        var expectedIndexScope = "dialogue-date-v1|days=30|from=|to=|tz=UTC"
        var pollIntervalSeconds: Double = 30
        var coverageIntervalSeconds: Double = 300
        var startupTimeoutSeconds: Double = 30
        var startupProbeIntervalSeconds: Double = 1
        var requestTimeoutSeconds: Double = 5
        var resourceTimeoutSeconds: Double = 10
        var syncTimeoutSeconds: Double = 600
        var minimumSyncIntervalSeconds: Double = 60
        var restartDelaysSeconds: [Double] = [2, 8, 30]
        var maximumResponseBytes = 262_144
        var maximumRuntimeRecordBytes = 65_536

        /// Reads the packaged non-secret limits without inferring a development data directory.
        ///
        /// Args:
        ///   bundle: Bundle containing the managed helper's configuration.
        ///
        /// Returns:
        ///   Validated local-service settings.
        ///
        /// Raises:
        ///   AgentIndexError: The resource is missing or invalid.
        nonisolated static func bundled(in bundle: Bundle = .main) throws -> Self {
            guard let url = bundle.url(forResource: "AgentIndexConfig", withExtension: "json") else {
                throw AgentIndexError.configurationMissing
            }
            do {
                let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                _ = try value.validatedEndpoint()
                return value
            } catch { throw AgentIndexError.invalidConfiguration }
        }

        /// Rejects external endpoints, changed date policies, and unbounded work limits.
        ///
        /// Returns:
        ///   The exact numeric loopback endpoint shared with the search client.
        ///
        /// Raises:
        ///   AgentIndexError: A configured endpoint or bound is unsupported.
        nonisolated func validatedEndpoint() throws -> URL {
            let positive = [pollIntervalSeconds, coverageIntervalSeconds, startupTimeoutSeconds,
                            startupProbeIntervalSeconds, requestTimeoutSeconds, resourceTimeoutSeconds,
                            syncTimeoutSeconds, minimumSyncIntervalSeconds]
            guard endpoint == "http://127.0.0.1:18742", let url = URL(string: endpoint),
                  expectedAPIVersion == 10, expectedDataVersion == 128,
                  expectedIndexScope == "dialogue-date-v1|days=30|from=|to=|tz=UTC",
                  positive.allSatisfy({ $0.isFinite && $0 > 0 }),
                  pollIntervalSeconds >= 5, pollIntervalSeconds <= 300,
                  coverageIntervalSeconds >= pollIntervalSeconds, coverageIntervalSeconds <= 3600,
                  startupTimeoutSeconds <= 60, startupProbeIntervalSeconds <= startupTimeoutSeconds,
                  requestTimeoutSeconds <= resourceTimeoutSeconds, resourceTimeoutSeconds <= 30,
                  syncTimeoutSeconds >= resourceTimeoutSeconds, syncTimeoutSeconds <= 1800,
                  minimumSyncIntervalSeconds >= pollIntervalSeconds,
                  restartDelaysSeconds.count <= 3,
                  restartDelaysSeconds.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 300 }),
                  (1024...1_048_576).contains(maximumResponseBytes),
                  (1024...262_144).contains(maximumRuntimeRecordBytes) else {
                throw AgentIndexError.invalidConfiguration
            }
            return url
        }
    }

    struct Paths: Sendable {
        let helper: URL
        let dataDirectory: URL
        var configuration: URL { dataDirectory.appendingPathComponent("config.toml") }

        /// Resolves installed paths without creating directories or scanning transcript locations.
        ///
        /// Args:
        ///   bundle: Application containing Contents/Helpers/agentsview.
        ///
        /// Returns:
        ///   The helper path and the existing profile's managed index directory.
        nonisolated static func installed(in bundle: Bundle = .main) -> Self {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return Self(helper: bundle.bundleURL.appendingPathComponent("Contents/Helpers/agentsview"),
                        dataDirectory: support.appendingPathComponent(AppDataLocation.profileDirectoryName)
                            .appendingPathComponent("agent-index", isDirectory: true))
        }
    }

    struct Status: Equatable, Sendable {
        enum Phase: String, Sendable {
            case disabled, notConfigured, helperMissing, notRunning, starting, syncing
            case embedding, partialFailure, checked, portOccupied, incompatible, failed
        }
        var phase: Phase = .notRunning
        var lastSyncAt: Date?
        var lastCheckedAt: Date?
        var missingDocuments: Int?
        var embeddedDocuments: Int?
        var failedSessions = 0
        var warningCount = 0
        var observedSkippedDocuments = 0
        var processedChunks = 0
        var totalChunks = 0
        var issue: AgentIndexError?

        /// Summarizes current work without equating an idle worker with complete coverage.
        ///
        /// Args:
        ///   language: The currently displayed interface language.
        ///
        /// Returns:
        ///   Localized status containing no transcript content or backend error body.
        func summary(language: AppLanguage) -> String {
            let base = phaseSummary(language: language)
            guard let date = lastSyncAt ?? lastCheckedAt else { return base }
            let timestamp = date.formatted(Date.FormatStyle().month().day().hour().minute()
                .locale(Locale(identifier: language == .zh ? "zh_CN" : "en_US")))
            let label = lastSyncAt != nil
                ? (language == .zh ? "最近同步" : "Last sync")
                : (language == .zh ? "最近检查" : "Last checked")
            return base + " · " + label + " " + timestamp
        }

        /// Resolves the current phase independently of persisted timestamps.
        ///
        /// Args:
        ///   language: The currently displayed interface language.
        ///
        /// Returns:
        ///   A localized description of work or a bounded failure.
        private func phaseSummary(language: AppLanguage) -> String {
            let zh = language == .zh
            switch phase {
            case .disabled: return zh ? "历史索引已停用" : "History indexing is off"
            case .notConfigured: return zh ? "自动索引尚未配置" : "Automatic indexing is not configured"
            case .helperMissing: return zh ? "安装包缺少索引组件" : "The installed index helper is missing"
            case .notRunning: return zh ? "索引服务未运行" : "The index service is not running"
            case .starting: return zh ? "正在启动索引服务…" : "Starting the index service…"
            case .syncing: return zh ? "正在更新会话记录…" : "Updating conversation records…"
            case .embedding:
                return totalChunks > 0
                    ? (zh ? "正在更新语义索引（\(processedChunks)/\(totalChunks)）" : "Updating semantic index (\(processedChunks)/\(totalChunks))")
                    : (zh ? "正在更新语义索引…" : "Updating the semantic index…")
            case .partialFailure:
                if observedSkippedDocuments > 0 {
                    return zh ? "部分对话曾跳过语义索引，覆盖仍待确认" : "Some passages were previously skipped; semantic coverage remains unconfirmed"
                }
                if let missingDocuments, missingDocuments > 0 {
                    return zh ? "索引尚有 \(missingDocuments) 段对话待处理" : "\(missingDocuments) conversation passages still need indexing"
                }
                if issue == nil, failedSessions == 0, warningCount == 0, missingDocuments == nil {
                    return zh ? "已检查状态，索引覆盖仍待确认" : "Status checked; index coverage is not yet confirmed"
                }
                return zh ? "部分索引更新未完成，搜索可能遗漏结果" : "Some index updates are incomplete; search may miss results"
            case .checked:
                return zh ? "已检查索引状态" : "Index status checked"
            case .portOccupied:
                return zh ? "本地索引端口被其他服务占用" : "Another service is using the local index port"
            case .incompatible:
                return zh ? "索引组件版本或日期范围不匹配" : "The index helper version or date range does not match"
            case .failed:
                return issue == .restartLimit
                    ? (zh ? "索引服务多次退出，已停止自动重试" : "The index service kept exiting; automatic retries stopped")
                    : (zh ? "索引服务暂不可用" : "The index service is unavailable")
            }
        }

        /// Reports whether an empty search should retain an index-availability explanation.
        var searchMayBeIncomplete: Bool {
            phase != .checked || lastSyncAt == nil || missingDocuments != 0 || observedSkippedDocuments > 0
        }
    }

    struct RestartBudget: Equatable, Sendable {
        private(set) var restarts = 0

        /// Consumes a finite restart allowance that is not reset by a brief healthy interval.
        ///
        /// Args:
        ///   delays: Backoff delays from the packaged configuration.
        ///
        /// Returns:
        ///   The next delay, or nil when this enable cycle has exhausted its budget.
        mutating func nextDelay(_ delays: [Double]) -> Double? {
            guard delays.indices.contains(restarts) else { return nil }
            defer { restarts += 1 }
            return delays[restarts]
        }
    }

    static let shared = AgentIndexService()
    private(set) var status = Status()
    var searchMayBeIncomplete: Bool { status.searchMayBeIncomplete }
    @ObservationIgnored private let settings: Result<Configuration, AgentIndexError>
    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private var client: AgentIndexClient?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequestID: UUID?
    @ObservationIgnored private var child: Process?
    @ObservationIgnored private var ownedIdentity: AgentIndexProcessIdentity?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var budget = RestartBudget()
    @ObservationIgnored private var exhausted = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var readinessVerified = false
    @ObservationIgnored private var lastCoverageCheck: Date?
    @ObservationIgnored private var lastSyncRequest: Date?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    // The API does not expose cumulative skips or prove their repair; preserve observations for this app process.
    @ObservationIgnored private var observedSkippedDocuments = 0

    /// Creates an idle supervisor without filesystem writes, process launches or network requests.
    ///
    /// Args:
    ///   configuration: Optional isolated settings used by fixtures.
    ///   paths: Optional helper and profile paths used by fixtures.
    init(configuration: Configuration? = nil, paths: Paths? = nil) {
        do {
            let value = try configuration ?? Configuration.bundled()
            _ = try value.validatedEndpoint()
            settings = .success(value)
        } catch {
            settings = .failure(error as? AgentIndexError ?? .invalidConfiguration)
        }
        self.paths = paths ?? .installed()
    }

    /// Starts a bounded supervisor only when history search and its existing configuration are enabled.
    ///
    /// Returns:
    ///   Nothing. Startup proceeds off the user interaction path and publishes semantic status.
    func startIfEnabled() {
        guard AgentHistorySearchPreference.isEnabled else {
            stop()
            status.phase = .disabled
            return
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            }
        }
        guard lifecycleTask == nil, !exhausted else { return }
        let configuration: Configuration
        do { configuration = try settings.get() }
        catch {
            status = Status(phase: .notConfigured, issue: error)
            return
        }
        guard FileManager.default.isReadableFile(atPath: paths.configuration.path) else {
            status = Status(phase: .notConfigured, issue: .configurationMissing)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: paths.helper.path) else {
            status = Status(phase: .helperMissing, issue: .helperMissing)
            return
        }
        if !wantsRunning { budget = RestartBudget() }
        wantsRunning = true
        generation &+= 1
        let owner = generation
        client = AgentIndexClient(configuration: configuration)
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await self.supervise(owner: owner, configuration: configuration)
            if self.generation == owner { self.lifecycleTask = nil }
        }
    }

    /// Applies the existing history-search preference without changing its stored value.
    func preferencesDidChange() { startIfEnabled() }

    /// Requests an incremental sync on wake or explicit user refresh, coalescing repeated requests.
    ///
    /// Returns:
    ///   Nothing. This method never calls resync, rebuild, or an embeddings mutation endpoint.
    func requestSync() {
        startIfEnabled()
        guard let configuration = try? settings.get(), ownedIdentity != nil else { return }
        scheduleSync(owner: generation, configuration: configuration, startupOnly: false)
    }

    /// Refreshes status without starting a second poll or changing the index scope.
    func refreshStatus() {
        guard refreshTask == nil, let configuration = try? settings.get(), ownedIdentity != nil else { return }
        let owner = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.collectStatus(owner: owner, configuration: configuration)
            if self.generation == owner { self.refreshTask = nil }
        }
    }

    /// Stops only the helper whose executable and kernel start time still match this supervisor.
    ///
    /// Returns:
    ///   Nothing. Database files and unrelated listeners are left in place.
    func stop() {
        wantsRunning = false
        generation &+= 1
        lifecycleTask?.cancel()
        refreshTask?.cancel()
        syncTask?.cancel()
        syncRequestID = nil
        lifecycleTask = nil
        refreshTask = nil
        syncTask = nil
        refreshing = false
        readinessVerified = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        terminateOwnedHelper()
        AgentEmbeddingService.shared.stop()
        client = nil
        exhausted = false
        lastSyncRequest = nil
        status.phase = .notRunning
        status.issue = nil
    }

    /// Explicitly starts a fresh finite retry cycle after the user requests recovery.
    func retry() {
        stop()
        budget = RestartBudget()
        startIfEnabled()
    }

    /// Owns process startup, readiness, low-frequency polling and capped crash recovery.
    ///
    /// Args:
    ///   owner: Generation that must remain current after each suspension.
    ///   configuration: Validated packaged limits.
    private func supervise(owner: Int, configuration: Configuration) async {
        while owns(owner) {
            status.phase = .starting
            status.issue = nil
            status.missingDocuments = nil
            status.embeddedDocuments = nil
            lastCoverageCheck = nil
            readinessVerified = false
            do {
                await AgentEmbeddingService.shared.ensureAvailable()
                try requireOwner(owner)
                try await acquireHelper(configuration: configuration)
                try requireOwner(owner)
                try await waitUntilReady(owner: owner, configuration: configuration)
                try requireOwner(owner)
                readinessVerified = true
                await collectStatus(owner: owner, configuration: configuration)
                guard owns(owner) else { return }
                scheduleSync(owner: owner, configuration: configuration, startupOnly: true)
                while owns(owner), helperIsAlive {
                    try await Task.sleep(for: .seconds(configuration.pollIntervalSeconds))
                    try requireOwner(owner)
                    await AgentEmbeddingService.shared.ensureAvailable()
                    try requireOwner(owner)
                    await collectStatus(owner: owner, configuration: configuration)
                }
            } catch is CancellationError { return }
            catch {
                guard owns(owner) else { return }
                let failure = error as? AgentIndexError ?? .unavailable
                if [.portOccupied, .incompatible, .invalidConfiguration].contains(failure) {
                    terminateOwnedHelper()
                    status.phase = failure == .portOccupied ? .portOccupied : .incompatible
                    status.issue = failure
                    return
                }
                status.issue = failure
            }
            guard owns(owner) else { return }
            syncTask?.cancel()
            syncTask = nil
            syncRequestID = nil
            terminateOwnedHelper()
            guard let delay = budget.nextDelay(configuration.restartDelaysSeconds) else {
                exhausted = true
                status.phase = .failed
                status.issue = .restartLimit
                return
            }
            status.phase = .starting
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
    }

    /// Reuses a verified orphaned packaged helper or starts a new foreground child.
    ///
    /// Args:
    ///   configuration: Limits used for loopback and runtime identity verification.
    ///
    /// Raises:
    ///   AgentIndexError: An unknown process occupies the port, or the helper cannot start.
    private func acquireHelper(configuration: Configuration) async throws {
        guard let client else { throw CancellationError() }
        do {
            let ping = try await client.get(AgentIndexPing.self, path: "/api/ping")
            try Task.checkCancellation()
            guard let identity = AgentIndexProcessIdentity.read(pid: ping.pid),
                  let runtime = try? AgentIndexRuntime.read(pid: ping.pid, directory: paths.dataDirectory,
                                                           maximumBytes: configuration.maximumRuntimeRecordBytes),
                  Self.matchesRuntime(runtime, ping: ping, identity: identity,
                                      helper: paths.helper, configuration: configuration) else {
                throw AgentIndexError.portOccupied
            }
            ownedIdentity = identity
            child = nil
            return
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentIndexError {
            guard error == .unavailable else {
                throw error == .portOccupied ? error : AgentIndexError.portOccupied
            }
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = paths.helper
        process.arguments = ["serve", "--host", "127.0.0.1", "--port", "18742", "--no-browser", "--no-update-check", "--skip-initial-sync"]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "AGENTSVIEW_DATA_DIR": paths.dataDirectory.path,
        ]
        process.currentDirectoryURL = paths.dataDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        do { try process.run() }
        catch { throw AgentIndexError.launchFailed }
        child = process
        guard let identity = AgentIndexProcessIdentity.read(pid: process.processIdentifier) else {
            if process.isRunning { process.terminate() }
            child = nil
            throw AgentIndexError.launchFailed
        }
        ownedIdentity = identity
    }

    /// Waits for the exact child to expose the expected API, data version and 30-day scope.
    ///
    /// Args:
    ///   owner: Current lifecycle generation.
    ///   configuration: Readiness deadline and compatibility requirements.
    ///
    /// Raises:
    ///   AgentIndexError: Startup failed or a compatibility boundary was crossed.
    private func waitUntilReady(owner: Int, configuration: Configuration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(configuration.startupTimeoutSeconds))
        while clock.now < deadline {
            try requireOwner(owner)
            guard helperIsAlive, let client else { throw AgentIndexError.launchFailed }
            do {
                let ping = try await client.get(AgentIndexPing.self, path: "/api/ping")
                try requireOwner(owner)
                guard ping.ok, ping.service == "agentsview", ping.pid == ownedIdentity?.pid else {
                    throw AgentIndexError.portOccupied
                }
                let version = try await client.get(AgentIndexVersion.self, path: "/api/v1/version")
                try requireOwner(owner)
                guard version.compatible(with: configuration) else { throw AgentIndexError.incompatible }
                let embeddings: AgentIndexEmbeddingStatus
                do { embeddings = try await client.get(AgentIndexEmbeddingStatus.self, path: "/api/v1/embeddings/status") }
                catch AgentIndexError.rejected(501) {
                    // Keep keyword search available while visibly reporting an unavailable vector backend.
                    return
                }
                try requireOwner(owner)
                guard embeddings.indexScopeKey == configuration.expectedIndexScope else { throw AgentIndexError.incompatible }
                return
            } catch let error as AgentIndexError {
                if error == .portOccupied || error == .incompatible { throw error }
            }
            try await Task.sleep(for: .seconds(configuration.startupProbeIntervalSeconds))
        }
        throw AgentIndexError.timedOut
    }

    /// Collects bounded status metadata without retaining warnings, paths or conversation bodies.
    ///
    /// Args:
    ///   owner: Current lifecycle generation.
    ///   configuration: Polling limits and coverage refresh interval.
    private func collectStatus(owner: Int, configuration: Configuration) async {
        guard owns(owner), !refreshing, let client, let identity = ownedIdentity else { return }
        refreshing = true
        defer { if generation == owner { refreshing = false } }
        do {
            try await verifyOwnedEndpoint(client, owner: owner)
            try requireHelper(identity, owner: owner)
            let sync = try await client.get(AgentIndexSyncStatus.self, path: "/api/v1/sync/status")
            try requireHelper(identity, owner: owner)
            var embeddings: AgentIndexEmbeddingStatus?
            var unavailable = false
            do { embeddings = try await client.get(AgentIndexEmbeddingStatus.self, path: "/api/v1/embeddings/status") }
            catch is CancellationError { throw CancellationError() }
            catch { unavailable = true }
            try requireHelper(identity, owner: owner)
            if let embeddings, embeddings.indexScopeKey != configuration.expectedIndexScope {
                readinessVerified = false
                status.phase = .incompatible
                status.issue = .incompatible
                return
            }
            observedSkippedDocuments = max(observedSkippedDocuments, embeddings?.skippedDocuments ?? 0)
            var coverage: AgentIndexGeneration?
            let now = Date()
            if lastCoverageCheck == nil || now.timeIntervalSince(lastCoverageCheck!) >= configuration.coverageIntervalSeconds {
                lastCoverageCheck = now
                do {
                    let generations = try await client.get(AgentIndexGenerations.self, path: "/api/v1/embeddings/generations")
                    try requireHelper(identity, owner: owner)
                    guard generations.generations.allSatisfy({ $0.embedded >= 0 && $0.missing >= 0 }) else {
                        throw AgentIndexError.invalidResponse
                    }
                    coverage = generations.generations.first { $0.state == "active" }
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable = true }
            } else if sync.lastSyncDate == status.lastSyncAt,
                      let missing = status.missingDocuments, let embedded = status.embeddedDocuments {
                coverage = AgentIndexGeneration(state: "active", embedded: embedded, missing: missing)
            }
            status = Self.summarize(sync: sync, embeddings: embeddings, coverage: coverage,
                                    checkedAt: now, backendUnavailable: unavailable, syncRequested: syncTask != nil,
                                    previouslyObservedSkippedDocuments: observedSkippedDocuments)
        } catch is CancellationError { }
        catch {
            guard owns(owner), ownedIdentity == identity else { return }
            status.phase = helperIsAlive ? .partialFailure : .notRunning
            status.issue = error as? AgentIndexError ?? .unavailable
        }
    }

    /// Coalesces incremental sync requests and keeps uncertain completion visible until status is reread.
    ///
    /// Args:
    ///   owner: Current lifecycle generation.
    ///   configuration: Explicit sync deadline and minimum request interval.
    ///   startupOnly: Whether the daemon should only finish deferred startup ingestion.
    private func scheduleSync(owner: Int, configuration: Configuration, startupOnly: Bool) {
        guard owns(owner), readinessVerified, syncTask == nil, status.phase != .incompatible,
              let client, let identity = ownedIdentity else { return }
        if let lastSyncRequest, Date().timeIntervalSince(lastSyncRequest) < configuration.minimumSyncIntervalSeconds { return }
        lastSyncRequest = Date()
        let requestID = UUID()
        syncRequestID = requestID
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == owner, self.syncRequestID == requestID {
                    self.syncTask = nil
                    self.syncRequestID = nil
                    self.refreshStatus()
                }
            }
            do {
                try await self.verifyOwnedEndpoint(client, owner: owner)
                try self.requireHelper(identity, owner: owner)
                guard self.syncRequestID == requestID else { throw CancellationError() }
                self.status.phase = .syncing
                let path = startupOnly ? "/api/v1/sync?startup_only=true" : "/api/v1/sync"
                _ = try await client.request(path: path, method: "POST", timeout: configuration.syncTimeoutSeconds)
                try self.requireHelper(identity, owner: owner)
            } catch is CancellationError { }
            catch {
                guard self.owns(owner), self.ownedIdentity == identity, self.syncRequestID == requestID else { return }
                self.status.phase = .partialFailure
                self.status.issue = error as? AgentIndexError ?? .unavailable
            }
        }
    }

    /// Verifies kernel identity again before using an owned helper's loopback endpoint.
    ///
    /// Args:
    ///   client: Bounded loopback transport.
    ///   owner: Current lifecycle generation.
    ///
    /// Raises:
    ///   AgentIndexError: The helper exited or the port now belongs to a different process.
    private func verifyOwnedEndpoint(_ client: AgentIndexClient, owner: Int) async throws {
        try requireOwner(owner)
        guard helperIsAlive else { throw AgentIndexError.unavailable }
        let ping = try await client.get(AgentIndexPing.self, path: "/api/ping")
        try requireOwner(owner)
        guard helperIsAlive, ping.ok, ping.service == "agentsview", ping.pid == ownedIdentity?.pid else {
            throw AgentIndexError.portOccupied
        }
    }

    private var helperIsAlive: Bool {
        guard let ownedIdentity else { return false }
        if let child, !child.isRunning { return false }
        return AgentIndexProcessIdentity.read(pid: ownedIdentity.pid) == ownedIdentity
    }

    /// Signals only a still-matching managed process, including a verified previous-run orphan.
    private func terminateOwnedHelper() {
        if let ownedIdentity, AgentIndexProcessIdentity.read(pid: ownedIdentity.pid) == ownedIdentity {
            _ = kill(ownedIdentity.pid, SIGTERM)
        }
        ownedIdentity = nil
        child = nil
    }

    /// Rejects callbacks from disabled or replaced lifecycle tasks.
    ///
    /// Args:
    ///   owner: Generation captured before asynchronous work.
    ///
    /// Returns:
    ///   Whether the caller still owns this enabled service cycle.
    private func owns(_ owner: Int) -> Bool { generation == owner && wantsRunning && !Task.isCancelled }

    /// Converts lost lifecycle ownership into structured task cancellation.
    ///
    /// Args:
    ///   owner: Generation captured before asynchronous work.
    ///
    /// Raises:
    ///   CancellationError: The lifecycle was stopped or replaced.
    private func requireOwner(_ owner: Int) throws {
        guard owns(owner) else { throw CancellationError() }
    }

    /// Rejects a response from a helper that exited and was replaced within the same enable cycle.
    ///
    /// Args:
    ///   identity: Helper identity captured before the request.
    ///   owner: Current lifecycle generation.
    ///
    /// Raises:
    ///   CancellationError: The service or its owned helper has changed.
    private func requireHelper(_ identity: AgentIndexProcessIdentity, owner: Int) throws {
        try requireOwner(owner)
        guard ownedIdentity == identity else { throw CancellationError() }
    }

    /// Resolves status from independent sync, embedding and coverage observations.
    ///
    /// Args:
    ///   sync: Latest archive sync status.
    ///   embeddings: Latest vector worker status, if available.
    ///   coverage: Most recent active-generation coverage, if known.
    ///   checkedAt: Time of this status observation.
    ///   backendUnavailable: Whether an expected status endpoint failed.
    ///   syncRequested: Whether a local incremental-sync request is still pending.
    ///   previouslyObservedSkippedDocuments: Largest observed skip count retained for this application process.
    ///
    /// Returns:
    ///   A conservative user-facing status; idle alone never means complete.
    nonisolated static func summarize(
        sync: AgentIndexSyncStatus, embeddings: AgentIndexEmbeddingStatus?, coverage: AgentIndexGeneration?,
        checkedAt: Date, backendUnavailable: Bool, syncRequested: Bool,
        previouslyObservedSkippedDocuments: Int = 0
    ) -> Status {
        let failed = sync.stats?.failed ?? 0
        let warnings = sync.stats?.warningCount ?? 0
        let skipped = max(previouslyObservedSkippedDocuments, embeddings?.skippedDocuments ?? 0)
        var value = Status(phase: .checked, lastSyncAt: sync.lastSyncDate, lastCheckedAt: checkedAt,
                           missingDocuments: coverage?.missing, embeddedDocuments: coverage?.embedded,
                           failedSessions: failed, warningCount: warnings, observedSkippedDocuments: skipped,
                           processedChunks: max(0, embeddings?.done ?? 0), totalChunks: max(0, embeddings?.total ?? 0))
        if sync.progress?.stalled == true || sync.stats?.aborted == true || failed > 0 || warnings > 0
            || embeddings?.hasError == true || backendUnavailable || skipped > 0 {
            value.phase = .partialFailure
            value.issue = .unavailable
        } else if sync.progress?.isRunning == true || syncRequested {
            value.phase = .syncing
        } else if embeddings?.running == true {
            value.phase = .embedding
        } else if sync.lastSyncDate == nil || coverage == nil || (coverage?.missing ?? 0) > 0 {
            value.phase = .partialFailure
        }
        return value
    }

    /// Checks a daemon record against the live kernel process and the installed helper path.
    ///
    /// Args:
    ///   runtime: Same-user runtime registration inside this managed data directory.
    ///   ping: Response from the configured loopback endpoint.
    ///   identity: Current kernel executable and start timestamp.
    ///   helper: Exact packaged helper path.
    ///   configuration: Expected port and protocol versions.
    ///
    /// Returns:
    ///   True only for a compatible managed helper; PID or service name alone is insufficient.
    nonisolated static func matchesRuntime(
        _ runtime: AgentIndexRuntime, ping: AgentIndexPing, identity: AgentIndexProcessIdentity,
        helper: URL, configuration: Configuration
    ) -> Bool {
        runtime.pid == ping.pid && runtime.pid == identity.pid && ping.ok && ping.service == "agentsview"
            && runtime.service == "agentsview" && runtime.network == "tcp"
            && runtime.address == "127.0.0.1:18742"
            && runtime.metadata["no_sync"] == "false" && runtime.metadata["read_only"] == "false"
            && runtime.metadata["api_version"] == String(configuration.expectedAPIVersion)
            && runtime.metadata["data_version"] == String(configuration.expectedDataVersion)
            && runtime.metadata["create_time"] == String(identity.startMilliseconds)
            && identity.executable == helper.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum AgentIndexError: Error, Equatable, Sendable {
    case configurationMissing, invalidConfiguration, helperMissing, launchFailed, portOccupied
    case incompatible, unavailable, timedOut, invalidResponse, responseTooLarge, restartLimit
    case rejected(Int)
}

struct AgentIndexPing: Decodable, Sendable {
    let ok: Bool
    let healthy: Bool
    let service: String
    let pid: Int32
}

struct AgentIndexVersion: Decodable, Sendable {
    let apiVersion: Int
    let dataVersion: Int
    let readOnly: Bool?
    private enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version", dataVersion = "data_version", readOnly = "read_only"
    }

    /// Checks the exact protocol contract used by this packaged integration.
    ///
    /// Args:
    ///   configuration: Protocol and archive version pins.
    ///
    /// Returns:
    ///   Whether a writable helper matches both version boundaries.
    func compatible(with configuration: AgentIndexService.Configuration) -> Bool {
        apiVersion == configuration.expectedAPIVersion && dataVersion == configuration.expectedDataVersion && readOnly != true
    }
}

struct AgentIndexSyncStatus: Decodable, Sendable {
    let lastSync: String
    let stats: AgentIndexSyncStats?
    let progress: AgentIndexSyncProgress?
    private enum CodingKeys: String, CodingKey { case lastSync = "last_sync", stats, progress }
    var lastSyncDate: Date? {
        guard !lastSync.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: lastSync) ?? ISO8601DateFormatter().date(from: lastSync)
    }
}

struct AgentIndexSyncStats: Decodable, Sendable {
    let failed: Int
    let aborted: Bool
    let warningCount: Int
    private enum CodingKeys: String, CodingKey { case failed, aborted, warnings }

    /// Retains warning counts without copying parser messages or source paths into application state.
    ///
    /// Args:
    ///   decoder: Bounded sync-statistics JSON.
    ///
    /// Raises:
    ///   DecodingError: A required field or count is malformed.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        failed = try values.decode(Int.self, forKey: .failed)
        aborted = try values.decodeIfPresent(Bool.self, forKey: .aborted) ?? false
        warningCount = try values.decodeIfPresent([String].self, forKey: .warnings)?.count ?? 0
        guard failed >= 0 else { throw DecodingError.dataCorruptedError(forKey: .failed, in: values, debugDescription: "Negative count") }
    }
}

struct AgentIndexSyncProgress: Decodable, Sendable {
    let phase: String
    let stalled: Bool?
    var isRunning: Bool { !["idle", "done"].contains(phase) }
}

struct AgentIndexEmbeddingStatus: Decodable, Sendable {
    let running: Bool
    let indexScopeKey: String?
    let done: Int
    let total: Int
    let hasError: Bool
    let skippedDocuments: Int
    private enum CodingKeys: String, CodingKey {
        case running, indexScopeKey = "index_scope_key", done, total, lastError = "last_error", lastResult = "last_result"
    }
    private struct BuildResult: Decodable {
        let fill: FillStatistics?
        private enum CodingKeys: String, CodingKey { case fill = "Fill" }
    }
    private struct FillStatistics: Decodable {
        let skipped: Int?
        private enum CodingKeys: String, CodingKey { case skipped = "Skipped" }
    }

    /// Reads progress, skipped counts and the presence of a backend error without retaining source content.
    ///
    /// Args:
    ///   decoder: Bounded vector-status JSON.
    ///
    /// Raises:
    ///   DecodingError: A status field is malformed.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        running = try values.decode(Bool.self, forKey: .running)
        indexScopeKey = try values.decodeIfPresent(String.self, forKey: .indexScopeKey)
        done = try values.decode(Int.self, forKey: .done)
        total = try values.decode(Int.self, forKey: .total)
        hasError = !(try values.decodeIfPresent(String.self, forKey: .lastError) ?? "").isEmpty
        skippedDocuments = try values.decodeIfPresent(BuildResult.self, forKey: .lastResult)?.fill?.skipped ?? 0
        guard done >= 0, total >= 0 else { throw DecodingError.dataCorruptedError(forKey: .done, in: values, debugDescription: "Negative count") }
        guard skippedDocuments >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .lastResult, in: values, debugDescription: "Negative skipped count")
        }
    }
}

struct AgentIndexGeneration: Decodable, Sendable {
    let state: String
    let embedded: Int
    let missing: Int
}

struct AgentIndexGenerations: Decodable, Sendable { let generations: [AgentIndexGeneration] }

struct AgentIndexProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startMilliseconds: UInt64
    let executable: String

    /// Reads same-user process identity directly from the kernel, avoiding command or environment dumps.
    ///
    /// Args:
    ///   pid: Candidate managed-helper PID.
    ///
    /// Returns:
    ///   Executable and millisecond creation time, or nil for an unverifiable process.
    static func read(pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL.path
        return Self(pid: pid, startMilliseconds: info.pbi_start_tvsec * 1000 + info.pbi_start_tvusec / 1000, executable: path)
    }
}

struct AgentIndexRuntime: Decodable, Sendable {
    let pid: Int32
    let network: String
    let address: String
    let service: String
    let metadata: [String: String]

    /// Reads the one existing AgentsView runtime record named by the endpoint's verified PID.
    ///
    /// Args:
    ///   pid: PID reported by the local health endpoint.
    ///   directory: This installation's managed data directory.
    ///   maximumBytes: Upper bound for the small runtime record.
    ///
    /// Returns:
    ///   A same-user, non-symlink daemon registration.
    ///
    /// Raises:
    ///   AgentIndexError: Ownership, permissions, file type, size or JSON is invalid.
    static func read(pid: Int32, directory: URL, maximumBytes: Int) throws -> Self {
        guard pid > 0 else { throw AgentIndexError.invalidResponse }
        let url = directory.appendingPathComponent("daemon.\(pid).json")
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= maximumBytes else {
            throw AgentIndexError.invalidResponse
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentIndexError.invalidResponse }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_uid == getuid(), opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & 0o022 == 0, opened.st_size > 0, opened.st_size <= maximumBytes,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw AgentIndexError.invalidResponse
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AgentIndexError.responseTooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Serializes bounded local requests without sharing cookies, proxy configuration or redirected traffic.
private actor AgentIndexClient {
    private let configuration: AgentIndexService.Configuration
    private let session: URLSession
    private let syncSession: URLSession

    /// Creates a local-only transport; request cancellation does not invalidate other status requests.
    ///
    /// Args:
    ///   configuration: Validated endpoint and resource bounds.
    init(configuration: AgentIndexService.Configuration) {
        self.configuration = configuration
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        options.urlCache = nil
        options.httpCookieStorage = nil
        options.httpShouldSetCookies = false
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        options.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        options.timeoutIntervalForResource = configuration.resourceTimeoutSeconds
        options.waitsForConnectivity = false
        session = URLSession(configuration: options, delegate: AgentIndexNoRedirectDelegate(), delegateQueue: nil)
        options.timeoutIntervalForResource = configuration.syncTimeoutSeconds
        syncSession = URLSession(configuration: options, delegate: AgentIndexNoRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        syncSession.invalidateAndCancel()
    }

    /// Decodes only the requested metadata shape from an allow-listed local route.
    ///
    /// Args:
    ///   type: Expected response schema.
    ///   path: One supported read-only endpoint.
    ///
    /// Returns:
    ///   Validated metadata without retaining the source response body.
    ///
    /// Raises:
    ///   AgentIndexError: Transport, bounds or response schema failed.
    func get<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await request(path: path, method: "GET")
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AgentIndexError.invalidResponse }
    }

    /// Performs a bounded metadata read or incremental-sync request with no external redirects.
    ///
    /// Args:
    ///   path: An allow-listed API path.
    ///   method: GET for metadata, POST only for incremental sync.
    ///   timeout: Optional complete sync deadline.
    ///
    /// Returns:
    ///   A bounded response body, never logged.
    ///
    /// Raises:
    ///   AgentIndexError: The endpoint is unsupported or the request failed.
    func request(path: String, method: String, timeout: Double? = nil) async throws -> Data {
        try Task.checkCancellation()
        let reads = ["/api/ping", "/api/v1/version", "/api/v1/sync/status", "/api/v1/embeddings/status", "/api/v1/embeddings/generations"]
        let writes = ["/api/v1/sync", "/api/v1/sync?startup_only=true"]
        guard (method == "GET" && reads.contains(path)) || (method == "POST" && writes.contains(path)),
              let url = URL(string: configuration.endpoint + path) else { throw AgentIndexError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout ?? configuration.requestTimeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let transport = method == "POST" ? syncSession : session
            let (bytes, response) = try await transport.bytes(for: request)
            defer { bytes.task.cancel() }
            return try await withTaskCancellationHandler {
                guard let response = response as? HTTPURLResponse else { throw AgentIndexError.invalidResponse }
                guard response.statusCode == 200 else { throw AgentIndexError.rejected(response.statusCode) }
                guard response.expectedContentLength <= configuration.maximumResponseBytes else { throw AgentIndexError.responseTooLarge }
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < configuration.maximumResponseBytes else { throw AgentIndexError.responseTooLarge }
                    body.append(byte)
                }
                try Task.checkCancellation()
                return body
            } onCancel: { bytes.task.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentIndexError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AgentIndexError.timedOut }
            if [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                throw AgentIndexError.unavailable
            }
            throw AgentIndexError.invalidResponse
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentIndexError.invalidResponse
        }
    }
}

private final class AgentIndexNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Refuses redirection even to another loopback path so control requests cannot change destination.
    ///
    /// Args:
    ///   session: Local metadata transport.
    ///   task: Request receiving the redirect.
    ///   response: Redirect metadata.
    ///   request: Proposed redirected request.
    ///   completionHandler: Receives nil to reject the redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
