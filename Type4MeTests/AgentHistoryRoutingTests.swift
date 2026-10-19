import Foundation
import XCTest
@testable import Type4Me

final class AgentHistoryRoutingTests: XCTestCase {
    private actor SearchGate {
        private var continuation: CheckedContinuation<[AgentsViewSearchHit]?, Never>?
        private var released = false
        private(set) var started = false

        /// Suspends a fixture lookup to reproduce cancellation during an asynchronous skip.
        ///
        /// Returns:
        ///   Nil after release, representing the explicitly disabled history provider.
        func search() async -> [AgentsViewSearchHit]? {
            started = true
            if released { return nil }
            return await withCheckedContinuation { continuation = $0 }
        }

        /// Releases a pending or future fixture lookup without touching network state.
        func release() {
            released = true
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var choices: [AgentActivityCandidate] = []
        private var opened: [AgentSessionDescriptor] = []
        private var queries: [AgentSearchQuery] = []

        /// Records only synthetic topic strings passed to the search boundary.
        ///
        /// Args:
        ///   query: Test-owned search text.
        func searched(_ query: AgentSearchQuery) {
            lock.lock()
            defer { lock.unlock() }
            queries.append(query)
        }

        /// Returns search topics observed by this isolated fixture.
        ///
        /// Returns:
        ///   Topics in request order.
        func searchTopics() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return queries.map(\.text)
        }

        /// Returns test-owned structured queries in their observed request order.
        func searchQueries() -> [AgentSearchQuery] {
            lock.lock()
            defer { lock.unlock() }
            return queries
        }

        /// Captures presented rows without creating a real picker or opening applications.
        ///
        /// Args:
        ///   rows: Frozen candidates produced by the router.
        func offered(_ rows: [AgentActivityCandidate]) {
            lock.lock()
            defer { lock.unlock() }
            choices = rows
        }

        /// Records inert native navigation requests for accidental-open detection.
        ///
        /// Args:
        ///   session: Native descriptor passed to the opener boundary.
        func open(_ session: AgentSessionDescriptor) {
            lock.lock()
            defer { lock.unlock() }
            opened.append(session)
        }

        /// Reads a synchronized snapshot of all externally visible router effects.
        ///
        /// Returns:
        ///   Presented candidates and accepted inert opening requests.
        func snapshot() -> ([AgentActivityCandidate], [AgentSessionDescriptor]) {
            lock.lock()
            defer { lock.unlock() }
            return (choices, opened)
        }
    }

    private var root: URL!

    /// Creates an isolated activity file so checks cannot change real user associations.
    ///
    /// Raises:
    ///   Error: The temporary directory could not be created.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Removes only this test's temporary activity data.
    ///
    /// Raises:
    ///   Error: The temporary directory could not be removed.
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// Keeps the previous topic when a second utterance only narrows the owning agent.
    ///
    /// Raises:
    ///   Error: Isolated activity persistence failed.
    func testProviderCorrectionKeepsTopicAndFiltersOtherApp() async throws {
        let codex = descriptor("target", title: "MyType 开发")
        let engineID = "22222222-2222-4222-8222-222222222222"
        let claude = AgentSessionDescriptor(
            sessionID: "local_other", application: .claudeCode, title: "讨论 Codex 接口", workspacePath: nil,
            updatedAt: 2, matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: engineID
        )
        let hits = [
            AgentsViewSearchHit(sessionID: engineID, agent: "claude", snippet: "MyType 与 Codex"),
            AgentsViewSearchHit(sessionID: "codex:target", agent: "codex", snippet: "MyType 开发"),
        ]
        let capture = Capture()
        let router = makeRouter(sessions: [codex, claude], capture: capture) { query in
            capture.searched(query)
            return hits
        }
        _ = await router.handle("My type 的开发是", launch: false)
        _ = await offeredRows(capture)
        // The command classifier cancels the old picker before routing the next utterance.
        await router.cancelPendingSelection()
        _ = await router.handle("CoDex 的那个", launch: false)
        for _ in 0..<100 {
            if capture.snapshot().0.map(\.application) == [.codex] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(capture.searchTopics(), ["My type 的开发是", "My type 的开发是"])
        XCTAssertEqual(capture.snapshot().0.map(\.application), [.codex])
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        await router.cancelPendingSelection()
    }

    /// Carries dates into a source correction, but does not leak constraints into a new topic.
    func testRefinementRetainsMessageDateAndNewTopicResetsConstraints() async throws {
        let capture = Capture()
        let router = makeRouter(sessions: [descriptor("target", title: "MyType")], capture: capture) {
            capture.searched($0)
            return []
        }
        _ = await router.handle("昨天聊的MyType", launch: false)
        await router.cancelPendingSelection()
        _ = await router.handle("Codex 的那个", launch: false)
        _ = await router.handle("另外一个研究项目", launch: false)
        let queries = capture.searchQueries()
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[1].text, "MyType")
        XCTAssertEqual(queries[1].agent, "codex")
        XCTAssertEqual(queries[1].messageInterval, queries[0].messageInterval)
        XCTAssertNotNil(queries[1].messageInterval)
        XCTAssertNil(queries[2].agent)
        XCTAssertNil(queries[2].messageInterval)
        await router.cancelPendingSelection()
    }

    /// Ensures cancelled or expired topics are not reused by a later source-only utterance.
    func testCancellationAndExpirationClearRefinementTopic() async throws {
        let capture = Capture()
        let clock = FixtureClock()
        let router = makeRouter(sessions: [descriptor("target", title: "MyType")], capture: capture,
                                now: { clock.read() }) {
            capture.searched($0)
            return []
        }
        _ = await router.handle("MyType", launch: false)
        _ = await router.handle("取消", launch: false)
        _ = await router.handle("Codex 的那个", launch: false)
        XCTAssertEqual(capture.searchTopics(), ["MyType"])
        _ = await router.handle("另一个主题", launch: false)
        clock.advance(AgentSearchQuery.Configuration().contextLifetimeSeconds + 1)
        _ = await router.handle("Codex 的那个", launch: false)
        XCTAssertEqual(capture.searchTopics(), ["MyType", "另一个主题"])
        await router.cancelPendingSelection()
    }

    /// Rechecks message dates and does not use a confirmed alias to bypass explicit constraints.
    func testMessageDateRequiresEligibleEvidenceDespiteConfirmedAlias() async throws {
        let session = descriptor("target", title: "MyType")
        let store = AgentActivityStore(fileURL: root.appendingPathComponent("dated.json"))
        let snapshot = try await store.reconcile(sessions: [session])
        let activity = try XCTUnwrap(snapshot.activities.first)
        try await store.markOpened(activityID: activity.id, sessionKey: session.id, queryAlias: "昨天聊的MyType")
        let capture = Capture()
        let router = makeRouter(sessions: [session], capture: capture, store: store) { query in
            capture.searched(query)
            let interval = try XCTUnwrap(query.messageInterval)
            return [AgentsViewSearchHit(sessionID: "codex:target", agent: "codex", snippet: "旧消息",
                                        timestamp: interval.start.addingTimeInterval(-1))]
        }
        let result = await router.handle("昨天聊的MyType", launch: false)
        XCTAssertEqual(result.outcome, .noMatch)
        XCTAssertEqual(capture.searchTopics(), ["MyType"])
        XCTAssertTrue(capture.snapshot().0.isEmpty)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        let disabled = makeRouter(sessions: [session], capture: Capture()) { _ in nil }
        let unavailable = await disabled.handle("昨天聊的MyType", launch: false)
        XCTAssertEqual(unavailable.outcome, .historyTimeUnavailable)
        XCTAssertNotEqual(unavailable.message(language: .zh), unavailable.message(language: .en))
    }

    /// Reports a missing Codex catalog instead of presenting Claude as a complete result.
    func testUnavailableCatalogCannotSilentlyHideOneProvider() async throws {
        let engineID = "22222222-2222-4222-8222-222222222222"
        let claude = AgentSessionDescriptor(
            sessionID: "local_other", application: .claudeCode, title: "MyType", workspacePath: nil,
            updatedAt: 2, matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: engineID
        )
        let capture = Capture()
        let router = makeRouter(sessions: [claude], capture: capture, unavailable: [.codex]) {
            capture.searched($0)
            return [AgentsViewSearchHit(sessionID: engineID, agent: "claude", snippet: "MyType")]
        }
        let incomplete = await router.handle("MyType", launch: false)
        XCTAssertEqual(incomplete.outcome, .catalogUnavailable)
        XCTAssertTrue(capture.snapshot().0.isEmpty)
        let scoped = await router.handle("Claude里聊MyType", launch: false)
        XCTAssertEqual(scoped.outcome, .selectionRequired)
        let rows = await offeredRows(capture)
        XCTAssertEqual(rows.map(\.application), [.claudeCode])
        await router.cancelPendingSelection()
    }

    /// Allows an unused provider while rejecting missing native identities in returned Codex hits.
    func testAbsentProviderDoesNotBlockHealthySearchButMissingCodexMappingIsExplicit() async throws {
        let capture = Capture()
        let session = descriptor("target", title: "MyType")
        let router = makeRouter(sessions: [session], capture: capture,
                                unavailable: [.claudeCode], absent: [.claudeCode]) { _ in
            [AgentsViewSearchHit(sessionID: "codex:target", agent: "codex", snippet: "MyType")]
        }
        let result = await router.handle("MyType", launch: false)
        XCTAssertEqual(result.outcome, .selectionRequired)
        await router.cancelPendingSelection()
        let missing = makeRouter(sessions: [session], capture: Capture()) { _ in
            [AgentsViewSearchHit(sessionID: "codex:missing", agent: "codex", snippet: "MyType")]
        }
        let unmapped = await missing.handle("MyType", launch: false)
        XCTAssertEqual(unmapped.outcome, .historyMappingUnavailable)
        XCTAssertEqual(unmapped.application, .codex)
    }

    /// Verifies an unnamed native session survives history matching and reaches the chooser.
    ///
    /// Raises:
    ///   Error: The isolated activity fixture could not be written or read.
    func testUnnamedHistoryMatchReachesCandidateSelection() async throws {
        let session = AgentSessionDescriptor(
            sessionID: "unnamed", application: .codex, title: "", workspacePath: nil,
            updatedAt: 1, matchTexts: [], openCapability: .codexDeepLink
        )
        let hit = AgentsViewSearchHit(sessionID: "codex:unnamed", agent: "codex", snippet: "继续试试别的方法")
        let capture = Capture()
        let router = makeRouter(sessions: [session], capture: capture) { _ in [hit] }
        let result = await router.handle("尝试各种方法的", launch: false)
        XCTAssertEqual(result.outcome, .selectionRequired)
        let rows = await offeredRows(capture)
        XCTAssertEqual(rows.map(\.sessionID), ["unnamed"])
        XCTAssertEqual(rows.first?.evidence?.snippet, hit.snippet)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        await router.cancelPendingSelection()
    }

    /// Checks an explicitly supplied live query through production search, mapping and routing.
    ///
    /// Real metadata is read only; associations stay in this test's temporary directory and
    /// the chooser/opener are inert. Environment inputs opt in without embedding user data.
    ///
    /// Raises:
    ///   XCTSkip: Live query, native target ID and Codex metadata directory are not supplied.
    ///   Error: Live metadata, local search or the isolated association fixture failed.
    func testOptInLiveQueryReachesRequestedNativeSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let query = environment["MYTYPE_LIVE_SEARCH_QUERY"],
              let target = environment["MYTYPE_LIVE_SEARCH_TARGET"],
              let directory = environment["MYTYPE_LIVE_CODEX_HOME"] else {
            throw XCTSkip("Live session lookup requires explicit query, target and metadata path")
        }
        let metadataURL = URL(fileURLWithPath: directory, isDirectory: true)
        let catalog = AgentSessionCatalog(codexLoader: {
            try CodexMetadataSessionCatalog(metadataDirectory: metadataURL).loadSessions()
        })
        let snapshot = try catalog.loadSessions()
        XCTAssertTrue(snapshot.sessions.contains { $0.application == .codex && $0.sessionID == target })
        let capture = Capture()
        var configuration = AgentsViewSearchService.Configuration()
        if let endpoint = environment["MYTYPE_LIVE_SEARCH_ENDPOINT"] { configuration.endpoint = endpoint }
        let search = AgentsViewSearchService(configuration: configuration)
        let router = makeRouter(sessions: snapshot.sessions, capture: capture) {
            try await search.search($0)
        }
        let result = await router.handle(query, launch: false)
        XCTAssertEqual(result.outcome, .selectionRequired)
        _ = await offeredRows(capture)
        if let followUp = environment["MYTYPE_LIVE_SEARCH_FOLLOW_UP"] {
            await router.cancelPendingSelection()
            capture.offered([])
            let refined = await router.handle(followUp, launch: false)
            XCTAssertEqual(refined.outcome, .selectionRequired)
        }
        let rows = await offeredRows(capture)
        let index = try XCTUnwrap(rows.firstIndex { $0.application == .codex && $0.sessionID == target })
        XCTAssertNotNil(rows[index].evidence)
        XCTAssertTrue(rows[index].canOpen)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        print("Live history route: target present at choice \(index + 1) of \(rows.count); native opening disabled")
        await router.cancelPendingSelection()
    }

    /// Verifies content evidence reaches a choice even when it differs from the native title.
    ///
    /// Raises:
    ///   Error: Isolated router fixture creation failed.
    func testContentMatchRequiresChoiceAndPreservesEvidenceAcrossRename() async throws {
        let session = descriptor("target", title: "评估桌面 Agent 对接方案")
        let hit = AgentsViewSearchHit(sessionID: "codex:target", agent: "codex", snippet: "已交付 MyType 体验包", ordinal: 66)
        let capture = Capture()
        let router = makeRouter(sessions: [session], capture: capture) { _ in [hit] }
        let result = await router.handle("打开 MyType 体验包", launch: false)
        XCTAssertEqual(result.outcome, .selectionRequired)
        let rows = await offeredRows(capture)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.first?.sessionID, "target")
        XCTAssertEqual(rows.first?.evidence?.ordinal, 66)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        let renamed = AgentActivityPickerCopy.renamedCandidates(activityID: row.activityID, title: "体验包", candidates: rows)
        XCTAssertEqual(renamed.first?.evidence, rows.first?.evidence)
        await router.cancelPendingSelection()
    }

    /// Verifies no content result cannot be replaced with recent or title-matching sessions.
    ///
    /// Raises:
    ///   Error: Isolated router fixture creation failed.
    func testEmptyHistoryDoesNotFallBackToRecentTitle() async throws {
        let capture = Capture()
        let router = makeRouter(sessions: [descriptor("recent", title: "旅行相册")], capture: capture) { _ in [] }
        let result = await router.handle("打开旅行相册")
        XCTAssertEqual(result.outcome, .noMatch)
        XCTAssertTrue(capture.snapshot().0.isEmpty)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
    }

    /// Verifies unavailable history cannot silently fall back to a confident title opening.
    ///
    /// Raises:
    ///   Error: Isolated router fixture creation failed.
    func testUnavailableSearchDoesNotOpenExactTitle() async throws {
        let capture = Capture()
        let router = makeRouter(sessions: [descriptor("recent", title: "体验包")], capture: capture) { _ in
            throw AgentsViewSearchError.unavailable
        }
        let result = await router.handle("打开体验包")
        XCTAssertEqual(result.outcome, .historySearchUnavailable)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
    }

    /// Verifies a stale archive identifier cannot manufacture a desktop destination.
    ///
    /// Raises:
    ///   Error: Isolated router fixture creation failed.
    func testUnmappedHitDoesNotOpenOtherSession() async throws {
        let capture = Capture()
        let hit = AgentsViewSearchHit(sessionID: "codex:missing", agent: "codex", snippet: "目标事情")
        let router = makeRouter(sessions: [descriptor("recent", title: "目标事情")], capture: capture) { _ in [hit] }
        let result = await router.handle("目标事情")
        XCTAssertEqual(result.outcome, .historyMappingUnavailable)
        XCTAssertTrue(capture.snapshot().0.isEmpty)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
    }

    /// Verifies a cancelled lookup cannot reopen the title route when history is skipped.
    ///
    /// Raises:
    ///   Error: Isolated router fixture creation failed.
    func testCancelledDisabledSearchCannotOpenOldTitle() async throws {
        let capture = Capture()
        let gate = SearchGate()
        let router = makeRouter(sessions: [descriptor("old", title: "旧事情")], capture: capture) { _ in
            await gate.search()
        }
        let previous = Task { await router.handle("旧事情") }
        for _ in 0..<100 {
            if await gate.started { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await gate.started
        XCTAssertTrue(started)
        _ = await router.handle("取消")
        await gate.release()
        let result = await previous.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(capture.snapshot().0.isEmpty)
        XCTAssertTrue(capture.snapshot().1.isEmpty)
    }

    /// Verifies a previously confirmed phrase restores its native target without another search.
    ///
    /// Raises:
    ///   Error: Isolated confirmed-association persistence failed.
    func testConfirmedPhraseRestoresWithoutBackendOrTitleMatch() async throws {
        let session = descriptor("target", title: "原来的桌面对接讨论")
        let store = AgentActivityStore(fileURL: root.appendingPathComponent("confirmed.json"))
        let snapshot = try await store.reconcile(sessions: [session])
        let activity = try XCTUnwrap(snapshot.activities.first)
        try await store.markOpened(activityID: activity.id, sessionKey: session.id, queryAlias: "MyType 体验包")
        let capture = Capture()
        let router = makeRouter(sessions: [session], capture: capture, store: store) { _ in
            throw AgentsViewSearchError.unavailable
        }
        let result = await router.handle("打开 mytype体验包")
        XCTAssertEqual(result.outcome, .requestedOpen)
        XCTAssertEqual(capture.snapshot().1.map(\.sessionID), ["target"])
    }

    /// Verifies two confirmed targets with the same phrase still require an explicit choice.
    ///
    /// Raises:
    ///   Error: Isolated association persistence failed.
    func testConfirmedPhraseCollisionNeverChoosesByRecency() async throws {
        let sessions = [descriptor("first", title: "第一件事"), descriptor("second", title: "第二件事")]
        let store = AgentActivityStore(fileURL: root.appendingPathComponent("collision.json"))
        let snapshot = try await store.reconcile(sessions: sessions)
        for session in sessions {
            let activity = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys.contains(session.id) })
            try await store.markOpened(activityID: activity.id, sessionKey: session.id, queryAlias: "体验包")
        }
        let capture = Capture()
        let router = makeRouter(sessions: sessions, capture: capture, store: store) { _ in
            throw AgentsViewSearchError.unavailable
        }
        let result = await router.handle("打开体验包", launch: false)
        XCTAssertEqual(result.outcome, .selectionRequired)
        let rows = await offeredRows(capture)
        XCTAssertEqual(Set(rows.map(\.sessionID)), Set(sessions.map(\.sessionID)))
        XCTAssertTrue(capture.snapshot().1.isEmpty)
        await router.cancelPendingSelection()
    }

    /// Verifies persistent history notices and excerpts render in either product language.
    func testHistoryCopyIsBilingualAndLinksRenderAsLabels() {
        for label in [AgentActivityPickerCopy.Label.historyEvidence, .evidenceTime, .historyReview] {
            XCTAssertNotEqual(AgentActivityPickerCopy.text(label, language: .zh), AgentActivityPickerCopy.text(label, language: .en))
        }
        let evidence = AgentActivityEvidence(snippet: "已交付 [体验包](/private/work/package.zip)，**可以继续**。", timestamp: nil, ordinal: 66)
        XCTAssertEqual(AgentActivityPickerCopy.excerpt(evidence), "已交付 体验包，可以继续。")
    }

    /// Creates a deterministic router with fully inert UI, metadata and launch boundaries.
    ///
    /// Args:
    ///   sessions: Native descriptors available to the strict identity join.
    ///   capture: Recorder for choices and launch effects.
    ///   store: Optional prepopulated confirmed associations in this test's directory.
    ///   unavailable: Providers whose catalog could not be read.
    ///   absent: Providers without any local native metadata.
    ///   now: Clock used to expire refinement context deterministically.
    ///   search: Injected history provider that never accesses real transcripts.
    ///
    /// Returns:
    ///   A router backed only by this test's isolated file.
    private func makeRouter(
        sessions: [AgentSessionDescriptor], capture: Capture, store: AgentActivityStore? = nil,
        unavailable: [AgentDesktopApplication] = [], absent: [AgentDesktopApplication] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        search: @escaping AgentRouterService.ContentSearchProvider
    ) -> AgentRouterService {
        AgentRouterService(
            store: store ?? AgentActivityStore(fileURL: root.appendingPathComponent("activities.json")),
            catalogProvider: { .init(sessions: sessions, unavailableApplications: unavailable, absentApplications: absent) },
            opener: { capture.open($0) },
            chooser: { _, rows, _, _ in capture.offered(rows); return nil },
            resultSink: { _ in }, contentSearchProvider: search, now: now
        )
    }

    /// Supplies a synchronized clock so expiration checks require no real waiting.
    private final class FixtureClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_792_137_600)

        /// Returns the current test time.
        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        /// Advances the clock by the requested fixture interval.
        ///
        /// Args:
        ///   seconds: Elapsed fixture time.
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value.addTimeInterval(seconds)
        }
    }

    /// Creates an inert Codex descriptor whose identifiers need no real application.
    ///
    /// Args:
    ///   identifier: Stable fixture identifier.
    ///   title: Metadata title, deliberately independent of the historical message.
    ///
    /// Returns:
    ///   A syntactically navigable fixture descriptor.
    private func descriptor(_ identifier: String, title: String) -> AgentSessionDescriptor {
        .init(sessionID: identifier, application: .codex, title: title, workspacePath: nil,
              updatedAt: 1, matchTexts: [title], openCapability: .codexDeepLink)
    }

    /// Waits briefly for the asynchronously presented inert chooser to capture its rows.
    ///
    /// Args:
    ///   capture: Effect recorder owned by this test.
    ///
    /// Returns:
    ///   Recorded rows, or an empty list after the bounded observation period.
    private func offeredRows(_ capture: Capture) async -> [AgentActivityCandidate] {
        for _ in 0..<100 {
            let rows = capture.snapshot().0
            if !rows.isEmpty { return rows }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return []
    }
}
