import Foundation
import XCTest
@testable import Type4Me

final class AgentRouterServiceTests: XCTestCase {
    private enum MockError: Error { case openRejected }
    private static let chooserTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let pollDelayNanoseconds: UInt64 = 10_000_000
    private static let maximumPollAttempts = 100
    private static let pausedOpeningNanoseconds: UInt64 = 300_000_000
    private static let effectObservationTimeout: TimeInterval = 0.4
    private static let expectationTimeout: TimeInterval = 1

    private actor CatalogFixture {
        var sessions: [AgentSessionDescriptor]
        private let unavailableApplications: [AgentDesktopApplication]

        /// Creates a synthetic catalog with no agent history access.
        ///
        /// Args:
        ///   sessions: Descriptors visible to the router.
        ///   unavailableApplications: Provider limitations simulated by this fixture.
        init(
            _ sessions: [AgentSessionDescriptor],
            unavailableApplications: [AgentDesktopApplication] = [.claudeCode]
        ) {
            self.sessions = sessions
            self.unavailableApplications = unavailableApplications
        }

        /// Returns the current simulated catalog.
        ///
        /// Returns:
        ///   Metadata and provider limitations configured for this fixture.
        func snapshot() -> AgentSessionCatalogSnapshot {
            .init(sessions: sessions, unavailableApplications: unavailableApplications)
        }

        /// Replaces metadata during a pending selection.
        ///
        /// Args:
        ///   sessions: Next catalog state.
        func replace(with sessions: [AgentSessionDescriptor]) { self.sessions = sessions }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var opens: [AgentSessionDescriptor] = []
        private var choices: [[AgentActivityCandidate]] = []
        private var results: [AgentRouterResult] = []

        /// Captures an inert opening request under a lock.
        ///
        /// Args:
        ///   session: Selected descriptor.
        func recordOpen(_ session: AgentSessionDescriptor) {
            lock.lock()
            defer { lock.unlock() }
            opens.append(session)
        }

        /// Captures frozen rows presented by the chooser.
        ///
        /// Args:
        ///   candidates: Candidate rows for the pending request.
        func recordChoice(_ candidates: [AgentActivityCandidate]) {
            lock.lock()
            defer { lock.unlock() }
            choices.append(candidates)
        }

        /// Captures asynchronous feedback without touching UI.
        ///
        /// Args:
        ///   result: Result delivered by the callback.
        func recordResult(_ result: AgentRouterResult) {
            lock.lock()
            defer { lock.unlock() }
            results.append(result)
        }

        /// Reads accepted requests without sharing mutable storage.
        ///
        /// Returns:
        ///   Thread-safe snapshot of opening calls.
        func openedSessions() -> [AgentSessionDescriptor] {
            lock.lock()
            defer { lock.unlock() }
            return opens
        }

        /// Reads rows for each chooser invocation.
        ///
        /// Returns:
        ///   Thread-safe snapshots of frozen chooser ordering.
        func offeredChoices() -> [[AgentActivityCandidate]] {
            lock.lock()
            defer { lock.unlock() }
            return choices
        }

        /// Reads later chooser outcomes without sharing mutable state.
        ///
        /// Returns:
        ///   Thread-safe snapshot of asynchronously published results.
        func publishedResults() -> [AgentRouterResult] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }

    private var rootURL: URL!

    /// Creates an isolated activity-store root.
    ///
    /// Raises:
    ///   Error: Fixture directory creation failed.
    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("activity-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Removes only this test's isolated association files.
    ///
    /// Raises:
    ///   Error: Fixture cleanup failed.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    /// Verifies titles open original conversations while directory names cannot.
    ///
    /// Raises:
    ///   Error: Synthetic association persistence failed.
    func testConversationTitleMatchesButWorkspaceNameDoesNot() async throws {
        let session = descriptor("thread_1", title: "算法评估", workspace: "/workspace/folder-only")
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: CatalogFixture([session]), recorder: recorder)

        let directoryResult = await router.handle("folder-only")
        XCTAssertEqual(directoryResult.outcome, .selectionRequired)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        let titleResult = await router.handle("算法评估")

        XCTAssertEqual(titleResult.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), ["thread_1"])
        let persisted = try await store.readSnapshot()
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty })
    }

    /// Verifies previous user names stay searchable without changing agent titles.
    ///
    /// Raises:
    ///   Error: Synthetic association updates failed.
    func testUserAliasMatchesWithoutRenamingAgentConversation() async throws {
        let session = descriptor("thread_1", title: "Original conversation")
        let store = makeStore()
        let snapshot = try await store.reconcile(sessions: [session])
        let activity = try XCTUnwrap(snapshot.activities.first)
        try await store.rename(activityID: activity.id, title: "训练评估")
        try await store.rename(activityID: activity.id, title: "能力评估")
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: CatalogFixture([session]), recorder: recorder)

        let result = await router.handle("训练评估")

        XCTAssertEqual(result.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().first?.title, "Original conversation")
    }

    /// Verifies same-title sessions stay distinct across apps, including unsupported Claude.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testCrossApplicationConflictIncludesUnsupportedClaude() async throws {
        let codex = descriptor("same_id", title: "算法评估")
        let claude = descriptor("same_id", title: "算法评估", application: .claudeCode)
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([codex, claude]), recorder: recorder)

        let result = await router.handle("算法评估")
        let rows = try await waitForChoice(recorder)

        XCTAssertEqual(result.outcome, .selectionRequired)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.application)), [.codex, .claudeCode])
        XCTAssertEqual(Set(rows.map(\.activityID)).count, 2)
        XCTAssertTrue(rows.contains { $0.application == .claudeCode && !$0.canOpen })
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        await router.cancelPendingSelection()
    }

    /// Verifies a supported native Claude descriptor dispatches its original local identifier.
    ///
    /// Raises:
    ///   Error: Isolated association persistence failed.
    func testClaudeNativeCapabilityOpensOriginalSessionIdentifier() async throws {
        let session = descriptor(
            "local_existing-001", title: "原生 Claude 推理会话", application: .claudeCode,
            capability: .claudeNativeDeepLink
        )
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(
            store: store, catalog: CatalogFixture([session], unavailableApplications: []), recorder: recorder
        )

        let result = await router.handle(session.title)
        let persisted = try await store.readSnapshot()

        XCTAssertTrue(AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(session.sessionID))
        XCTAssertTrue(session.canOpenExistingConversation)
        XCTAssertEqual(result.outcome, .requestedOpen)
        XCTAssertEqual(result.application, .claudeCode)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), [session.sessionID])
        XCTAssertEqual(recorder.openedSessions().map(\.openCapability), [.claudeNativeDeepLink])
        XCTAssertTrue(recorder.offeredChoices().isEmpty)
        XCTAssertEqual(persisted.lastSessionKey, session.id)
    }

    /// Verifies an explicit weak choice teaches an alias for the same native Claude conversation.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or isolated association persistence failed.
    func testWeakClaudeNativeChoiceLearnsAliasForOriginalSession() async throws {
        let target = descriptor(
            "local_alias-001", title: "alpha gamma", application: .claudeCode, updatedAt: 300,
            capability: .claudeNativeDeepLink
        )
        let catalog = CatalogFixture(
            [target, descriptor("unrelated", title: "论文写作", updatedAt: 100)],
            unavailableApplications: []
        )
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: catalog, recorder: recorder)

        let search = await router.handle("打开 alpha beta")
        let rows = try await waitForChoice(recorder)
        let beforeChoice = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(rows.first?.session.id, target.id)
        XCTAssertTrue(try XCTUnwrap(rows.first).canOpen)
        XCTAssertLessThan(try XCTUnwrap(rows.first?.score), AgentFuzzyMatcher.defaultThreshold)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(beforeChoice.activities.allSatisfy { $0.aliases.isEmpty })

        let chosen = await router.handle("第一个")
        let remembered = try await store.readSnapshot()
        let activity = try XCTUnwrap(remembered.activities.first { $0.sessionKeys.contains(target.id) })

        XCTAssertEqual(chosen.outcome, .requestedOpen)
        XCTAssertEqual(chosen.application, .claudeCode)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id])
        XCTAssertEqual(activity.aliases, ["alpha beta"])
        XCTAssertEqual(activity.preferredSessionKey, target.id)
        XCTAssertEqual(remembered.lastSessionKey, target.id)

        await catalog.replace(with: [descriptor(
            target.sessionID, title: "Renamed native Claude conversation", application: .claudeCode,
            capability: .claudeNativeDeepLink
        )])
        let repeated = await router.handle("打开 alpha beta")

        XCTAssertEqual(repeated.outcome, .requestedOpen)
        XCTAssertEqual(repeated.application, .claudeCode)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id, target.id])
        XCTAssertEqual(recorder.offeredChoices().count, 1)
        await router.cancelPendingSelection()
    }

    /// Verifies supported same-title providers still require an explicit choice without preferring Codex.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testSupportedCrossApplicationConflictRequiresChoice() async throws {
        let codex = descriptor("codex_same", title: "算法评估", updatedAt: 300)
        let claude = descriptor(
            "local_same-id", title: "算法评估", application: .claudeCode, updatedAt: 100,
            capability: .claudeNativeDeepLink
        )
        let recorder = Recorder()
        let router = makeRouter(
            catalog: CatalogFixture([claude, codex], unavailableApplications: []), recorder: recorder
        )

        let result = await router.handle("算法评估")
        let rows = try await waitForChoice(recorder)

        XCTAssertEqual(result.outcome, .selectionRequired)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.application)), [.codex, .claudeCode])
        XCTAssertEqual(Set(rows.map(\.activityID)).count, 2)
        XCTAssertTrue(rows.allSatisfy(\.canOpen))
        XCTAssertTrue(recorder.openedSessions().isEmpty)

        let claudeIndex = try XCTUnwrap(rows.firstIndex { $0.session.id == claude.id })
        let chosen = await router.handle(claudeIndex == 0 ? "第一个" : "第二个")

        XCTAssertEqual(chosen.outcome, .requestedOpen)
        XCTAssertEqual(chosen.application, .claudeCode)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [claude.id])
        await router.cancelPendingSelection()
    }

    /// Verifies linked conversations still require an explicit choice.
    ///
    /// Raises:
    ///   Error: Synthetic association updates or chooser observation failed.
    func testMultipleSessionsOfOneActivityRequireExplicitSelection() async throws {
        let sessions = [descriptor("one", title: "Run A"), descriptor("two", title: "Run B")]
        let store = makeStore()
        let snapshot = try await store.reconcile(sessions: sessions)
        let activity = try XCTUnwrap(snapshot.activities.first { $0.sessionKeys.contains(sessions[0].id) })
        try await store.link(sessionKey: sessions[1].id, to: activity.id)
        try await store.rename(activityID: activity.id, title: "算法评估")
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: CatalogFixture(sessions), recorder: recorder)

        let result = await router.handle("算法评估")
        let rows = try await waitForChoice(recorder)

        XCTAssertEqual(result.outcome, .selectionRequired)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.activityID)), [activity.id])
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        await router.cancelPendingSelection()
    }

    /// Verifies weak token overlap offers a choice instead of opening a conversation.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testWeakSimilarityDoesNotOpenConversation() async throws {
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([descriptor("one", title: "alpha gamma")]), recorder: recorder)

        let result = await router.handle("alpha beta")
        let rows = try await waitForChoice(recorder)
        await router.cancelPendingSelection()

        XCTAssertEqual(result.outcome, .selectionRequired)
        XCTAssertEqual(rows.map(\.sessionID), ["one"])
        XCTAssertGreaterThan(try XCTUnwrap(rows.first?.score), 0)
        XCTAssertLessThan(try XCTUnwrap(rows.first?.score), AgentFuzzyMatcher.defaultThreshold)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
    }

    /// Verifies blank searches cannot offer a fallback, open a target, or teach an alias.
    ///
    /// Raises:
    ///   Error: Synthetic association persistence failed.
    func testEmptySearchDoesNotOfferOrLearnAlias() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(
            store: store, catalog: CatalogFixture([descriptor("one", title: "MyType Desktop Agent Routing")]),
            recorder: recorder
        )

        let empty = await router.handle(" \n")
        let missingName = await router.handle("打开")
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(empty.outcome, .noMatch)
        XCTAssertEqual(missingName.outcome, .noMatch)
        XCTAssertTrue(recorder.offeredChoices().isEmpty)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty && $0.preferredSessionKey == nil })
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
    }

    /// Verifies weak suggestions stay bounded while preserving recent and unsupported candidates.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testWeakSuggestionsAreBoundedAndIncludeRecentCandidates() async throws {
        let configuration = AgentRouterService.Configuration()
        let positiveSessions = (0...configuration.maximumSuggestedCandidates).map {
            descriptor("weak_\($0)", title: "alpha gamma", updatedAt: TimeInterval($0 + 1))
        }
        let sessions = positiveSessions + [
            descriptor("local_weak", title: "alpha gamma", application: .claudeCode, updatedAt: 1_000),
            descriptor("unrelated", title: "unrelated topic", updatedAt: 2_000),
        ]
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture(sessions), recorder: recorder)

        let result = await router.handle("alpha beta")
        let rows = try await waitForChoice(recorder)
        await router.cancelPendingSelection()

        XCTAssertEqual(result.outcome, .selectionRequired)
        XCTAssertEqual(rows.count, configuration.maximumSuggestedCandidates)
        XCTAssertTrue(rows.allSatisfy { $0.score < AgentFuzzyMatcher.defaultThreshold })
        XCTAssertTrue(rows.contains { $0.score > 0 })
        XCTAssertTrue(rows.contains { $0.sessionID == "unrelated" && $0.score == 0 })
        XCTAssertTrue(rows.contains { $0.application == .claudeCode && !$0.canOpen })
        XCTAssertEqual(Set(rows.map(\.session.id)).count, rows.count)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
    }

    /// Verifies an explicit weak choice learns its parsed name for the same original session.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or association persistence failed.
    func testSpokenMyTypePackageChoiceLearnsAliasForOriginalSession() async throws {
        let target = descriptor("original_thread", title: "MyType Desktop Agent Routing")
        let catalog = CatalogFixture([target, descriptor("unrelated", title: "论文写作")])
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: catalog, recorder: recorder)

        let search = await router.handle("打开 MyType 体验包")
        let rows = try await waitForChoice(recorder)
        let beforeChoice = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(rows.first?.session.id, target.id)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(beforeChoice.activities.allSatisfy { $0.aliases.isEmpty })

        let chosen = await router.handle("第一个")
        let remembered = try await store.readSnapshot()
        let activity = try XCTUnwrap(remembered.activities.first { $0.sessionKeys.contains(target.id) })

        XCTAssertEqual(chosen.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id])
        XCTAssertEqual(activity.aliases, ["MyType 体验包"])
        XCTAssertNil(activity.customTitle)
        XCTAssertEqual(activity.preferredSessionKey, target.id)
        XCTAssertEqual(remembered.lastActivityID, activity.id)
        XCTAssertEqual(remembered.lastSessionKey, target.id)

        await catalog.replace(with: [descriptor(target.sessionID, title: "Renamed native conversation")])
        let repeatSearch = await router.handle("打开 MyType 体验包")
        let afterRepeat = try await store.readSnapshot()

        XCTAssertEqual(repeatSearch.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id, target.id])
        XCTAssertEqual(recorder.offeredChoices().count, 1)
        XCTAssertEqual(afterRepeat.activities.first { $0.id == activity.id }?.aliases, ["MyType 体验包"])
        await router.cancelPendingSelection()
    }

    /// Verifies a new zero-overlap spoken name can bind a recent original conversation.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or association persistence failed.
    func testZeroOverlapMyTypeQueryOffersRecentSessionAndLearnsAfterChoice() async throws {
        let target = descriptor("desktop_thread", title: "评估桌面 Agent 对接方案", updatedAt: 300)
        let catalog = CatalogFixture([target, descriptor("older_thread", title: "训练进度", updatedAt: 100)])
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: catalog, recorder: recorder)
        let query = "打开MyType体验包"

        XCTAssertEqual(AgentFuzzyMatcher().score(query: "MyType体验包", candidate: target.title), 0)
        let search = await router.handle(query)
        let rows = try await waitForChoice(recorder)
        let beforeChoice = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(rows.map(\.session.id), [target.id, "codex:older_thread"])
        XCTAssertTrue(rows.allSatisfy { $0.score == 0 })
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(beforeChoice.activities.allSatisfy { $0.aliases.isEmpty })

        let chosen = await router.handle("第一个")
        let remembered = try await store.readSnapshot()
        let activity = try XCTUnwrap(remembered.activities.first { $0.sessionKeys.contains(target.id) })

        XCTAssertEqual(chosen.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id])
        XCTAssertEqual(recorder.openedSessions().first?.title, target.title)
        XCTAssertEqual(activity.aliases, ["MyType体验包"])
        XCTAssertEqual(remembered.lastActivityID, activity.id)
        XCTAssertEqual(remembered.lastSessionKey, target.id)

        let repeatSearch = await router.handle(query)
        XCTAssertEqual(repeatSearch.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.id), [target.id, target.id])
        XCTAssertEqual(recorder.offeredChoices().count, 1)
        await router.cancelPendingSelection()
    }

    /// Verifies choosing a preview cannot teach a spoken name or change continuation.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or association persistence failed.
    func testWeakChoicePreviewDoesNotLearnQueryAlias() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(
            store: store, catalog: CatalogFixture([descriptor("one", title: "MyType Desktop Agent Routing")]),
            recorder: recorder
        )

        let search = await router.handle("打开 MyType 体验包", launch: false)
        _ = try await waitForChoice(recorder)
        let selection = await router.handle("第一个")
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(selection.outcome, .matchedPreview)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty && $0.preferredSessionKey == nil })
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
        await router.cancelPendingSelection()
    }

    /// Verifies cancelling a weak search cannot teach its unconfirmed spoken name.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or association persistence failed.
    func testCancelledWeakSearchDoesNotLearnQueryAlias() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(
            store: store, catalog: CatalogFixture([descriptor("one", title: "MyType Desktop Agent Routing")]),
            recorder: recorder
        )

        let search = await router.handle("打开 MyType 体验包")
        _ = try await waitForChoice(recorder)
        let cancellation = await router.handle("取消")
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(cancellation.outcome, .cancelled)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty && $0.preferredSessionKey == nil })
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
    }

    /// Verifies a rejected explicit choice cannot teach its spoken name or continuation.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation or association persistence failed.
    func testFailedWeakChoiceDoesNotLearnQueryAlias() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(
            store: store, catalog: CatalogFixture([descriptor("one", title: "MyType Desktop Agent Routing")]),
            recorder: recorder, failOpening: true
        )

        let search = await router.handle("打开 MyType 体验包")
        _ = try await waitForChoice(recorder)
        let selection = await router.handle("第一个")
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(search.outcome, .selectionRequired)
        XCTAssertEqual(selection.outcome, .failed)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), ["one"])
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty && $0.preferredSessionKey == nil })
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
        await router.cancelPendingSelection()
    }

    /// Verifies an ordinal uses displayed order even after catalog recency changes.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testPendingOrdinalUsesFrozenCandidateOrder() async throws {
        let original = [descriptor("one", title: "算法评估", updatedAt: 300), descriptor("two", title: "算法评估", updatedAt: 200)]
        let catalog = CatalogFixture(original)
        let recorder = Recorder()
        let router = makeRouter(catalog: catalog, recorder: recorder)
        let initial = await router.handle("算法评估")
        XCTAssertEqual(initial.outcome, .selectionRequired)
        let frozen = try await waitForChoice(recorder)
        let firstID = try XCTUnwrap(frozen.first?.sessionID)
        await catalog.replace(with: [
            descriptor("one", title: "算法评估", updatedAt: 100),
            descriptor("two", title: "算法评估", updatedAt: 500),
        ])

        let result = await router.handle("第一个")

        XCTAssertEqual(result.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), [firstID])
        await router.cancelPendingSelection()
    }

    /// Verifies cancellation clears ordinals without opening arbitrary candidates.
    func testCancelClearsPendingSelection() async {
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([
            descriptor("one", title: "算法评估"), descriptor("two", title: "算法评估"),
        ]), recorder: recorder)
        _ = await router.handle("算法评估")

        let cancellation = await router.handle("取消")
        let ordinal = await router.handle("第一个")

        XCTAssertEqual(cancellation.outcome, .cancelled)
        XCTAssertEqual(ordinal.outcome, .noPendingSelection)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
    }

    /// Verifies a new query supersedes the previous choice and clears stale ordinals.
    func testNewQuerySupersedesPendingSelection() async {
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([
            descriptor("one", title: "算法评估"), descriptor("two", title: "算法评估"),
            descriptor("three", title: "论文修订"),
        ]), recorder: recorder)
        _ = await router.handle("算法评估")

        let replacement = await router.handle("论文修订")
        let staleOrdinal = await router.handle("第一个")

        XCTAssertEqual(replacement.outcome, .requestedOpen)
        XCTAssertEqual(staleOrdinal.outcome, .noPendingSelection)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), ["three"])
    }

    /// Verifies disappearing sessions cause no new-chat or other-session fallback.
    ///
    /// Raises:
    ///   Error: Bounded chooser observation failed.
    func testSessionDisappearanceDuringSelectionDoesNotOpen() async throws {
        let catalog = CatalogFixture([descriptor("one", title: "算法评估"), descriptor("two", title: "算法评估")])
        let recorder = Recorder()
        let router = makeRouter(catalog: catalog, recorder: recorder)
        _ = await router.handle("算法评估")
        _ = try await waitForChoice(recorder)
        await catalog.replace(with: [])

        let result = await router.handle("第一个")

        XCTAssertEqual(result.outcome, .noMatch)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        await router.cancelPendingSelection()
    }

    /// Verifies continue targets the last explicit session instead of the latest conversation.
    func testContinueUsesLastExplicitTarget() async {
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([
            descriptor("one", title: "算法评估", updatedAt: 100),
            descriptor("two", title: "论文修订", updatedAt: 500),
        ]), recorder: recorder)
        let emptyContinue = await router.handle("继续上次")
        _ = await router.handle("算法评估")

        let continuation = await router.handle("继续上次")

        XCTAssertEqual(emptyContinue.outcome, .noPreviousActivity)
        XCTAssertEqual(continuation.outcome, .requestedOpen)
        XCTAssertEqual(recorder.openedSessions().map(\.sessionID), ["one", "one"])
    }

    /// Verifies unsupported targets stay explicit and feedback supports both languages.
    func testUnsupportedTargetAndBilingualFeedback() async {
        let recorder = Recorder()
        let router = makeRouter(catalog: CatalogFixture([
            descriptor("local_one", title: "算法评估", application: .claudeCode),
        ]), recorder: recorder)

        let result = await router.handle("算法评估")

        XCTAssertEqual(result.outcome, .unsupported)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertFalse(result.message(language: .zh).isEmpty)
        XCTAssertFalse(result.message(language: .en).isEmpty)
        XCTAssertNotEqual(result.message(language: .zh), result.message(language: .en))
    }

    /// Verifies a failed opening does not become the continuation target.
    ///
    /// Raises:
    ///   Error: Isolated association storage could not be read.
    func testOpeningFailureDoesNotRecordContinuationTarget() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: CatalogFixture([descriptor("one", title: "算法评估")]), recorder: recorder, failOpening: true)

        let result = await router.handle("算法评估")
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty })
        XCTAssertEqual(recorder.openedSessions().count, 1)
    }

    /// Verifies matching previews neither dispatch navigation nor change the continuation target.
    ///
    /// Raises:
    ///   Error: Isolated association storage could not be read.
    func testMatchPreviewDoesNotOpenOrRecordContinuation() async throws {
        let store = makeStore()
        let recorder = Recorder()
        let router = makeRouter(store: store, catalog: CatalogFixture([descriptor("one", title: "算法评估")]), recorder: recorder)

        let result = await router.handle("算法评估", launch: false)
        let persisted = try await store.readSnapshot()

        XCTAssertEqual(result.outcome, .matchedPreview)
        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty })
        XCTAssertTrue(result.message(language: .zh).contains("算法评估"))
        XCTAssertTrue(result.message(language: .en).contains("算法评估"))
        XCTAssertNotEqual(result.message(language: .zh), result.message(language: .en))
    }

    /// Verifies a new request interrupts the prior picker's suspended opening task.
    ///
    /// Raises:
    ///   Error: Isolated association state could not be read.
    func testNewRequestCancelsPickerOpeningBeforeEffects() async throws {
        try await assertPickerOpeningIsCancelled(by: "完全无关的新主题", expectedOutcome: .selectionRequired)
    }

    /// Verifies cancellation interrupts the prior picker's suspended opening task.
    ///
    /// Raises:
    ///   Error: Isolated association state could not be read.
    func testCancelRequestCancelsPickerOpeningBeforeEffects() async throws {
        try await assertPickerOpeningIsCancelled(by: "取消", expectedOutcome: .cancelled)
    }

    /// Suspends a mocked picker opening, then verifies replacement cancels all old effects.
    ///
    /// Args:
    ///   replacement: Request that supersedes the old picker-owned opening.
    ///   expectedOutcome: Immediate result of the replacement request.
    ///
    /// Raises:
    ///   Error: Isolated association state could not be read.
    private func assertPickerOpeningIsCancelled(
        by replacement: String,
        expectedOutcome: AgentRouterResult.Outcome
    ) async throws {
        let openingStarted = expectation(description: "Old picker opening reached suspension")
        let openingCancelled = expectation(description: "Old opening observed cancellation")
        let unexpectedResult = expectation(description: "No result from superseded picker")
        unexpectedResult.isInverted = true
        let store = makeStore()
        let recorder = Recorder()
        let catalog = CatalogFixture([
            descriptor("old_one", title: "算法评估"), descriptor("old_two", title: "算法评估"),
        ])
        let router = AgentRouterService(
            store: store,
            catalogProvider: { await catalog.snapshot() },
            opener: { session in
                openingStarted.fulfill()
                do {
                    try await Task.sleep(nanoseconds: Self.pausedOpeningNanoseconds)
                    try Task.checkCancellation()
                    recorder.recordOpen(session)
                } catch {
                    if error is CancellationError { openingCancelled.fulfill() }
                    throw error
                }
            },
            chooser: { query, candidates, _, _ in
                guard query == "算法评估" else {
                    try? await Task.sleep(nanoseconds: Self.chooserTimeoutNanoseconds)
                    return nil
                }
                return candidates.first
            },
            resultSink: { result in
                recorder.recordResult(result)
                unexpectedResult.fulfill()
            }
        )
        let initial = await router.handle("算法评估")
        XCTAssertEqual(initial.outcome, .selectionRequired)
        await fulfillment(of: [openingStarted], timeout: Self.expectationTimeout)

        let interrupted = await router.handle(replacement)
        XCTAssertEqual(interrupted.outcome, expectedOutcome)
        await fulfillment(of: [openingCancelled], timeout: Self.expectationTimeout)
        await fulfillment(of: [unexpectedResult], timeout: Self.effectObservationTimeout)
        let persisted = try await store.readSnapshot()

        XCTAssertTrue(recorder.openedSessions().isEmpty)
        XCTAssertTrue(recorder.publishedResults().isEmpty)
        XCTAssertNil(persisted.lastActivityID)
        XCTAssertNil(persisted.lastSessionKey)
        XCTAssertTrue(persisted.activities.allSatisfy { $0.aliases.isEmpty })
        await router.cancelPendingSelection()
    }

    /// Creates a router with isolated catalog, chooser and opening effects.
    ///
    /// Args:
    ///   store: Existing synthetic association store, when needed.
    ///   catalog: Actor containing synthetic metadata.
    ///   recorder: Thread-safe effect recorder.
    ///   failOpening: Whether the fake app opener rejects its request.
    ///
    /// Returns:
    ///   Router without real scanning, UI or app dispatch.
    private func makeRouter(
        store: AgentActivityStore? = nil,
        catalog: CatalogFixture,
        recorder: Recorder,
        failOpening: Bool = false
    ) -> AgentRouterService {
        AgentRouterService(
            store: store ?? makeStore(),
            catalogProvider: { await catalog.snapshot() },
            opener: { session in
                recorder.recordOpen(session)
                if failOpening { throw MockError.openRejected }
            },
            chooser: { _, candidates, _, _ in
                recorder.recordChoice(candidates)
                try? await Task.sleep(nanoseconds: Self.chooserTimeoutNanoseconds)
                return nil
            },
            resultSink: { recorder.recordResult($0) }
        )
    }

    /// Creates an association actor confined to the fixture directory.
    ///
    /// Returns:
    ///   Store which never accesses the user's profile.
    private func makeStore() -> AgentActivityStore {
        AgentActivityStore(fileURL: rootURL.appendingPathComponent("activities.json"))
    }

    /// Creates synthetic title-only metadata with application-specific capabilities.
    ///
    /// Args:
    ///   id: Technical session identifier.
    ///   title: Original conversation title.
    ///   application: Source app identity.
    ///   workspace: Context directory which must not become match text.
    ///   updatedAt: Simulated update time for ordering.
    ///   capability: Explicit route; nil preserves Codex support and unsupported Claude defaults.
    ///
    /// Returns:
    ///   Synthetic descriptor.
    private func descriptor(
        _ id: String,
        title: String,
        application: AgentDesktopApplication = .codex,
        workspace: String? = nil,
        updatedAt: TimeInterval = 100,
        capability: AgentSessionOpenCapability? = nil
    ) -> AgentSessionDescriptor {
        .init(sessionID: id, application: application, title: title, workspacePath: workspace,
              updatedAt: updatedAt, matchTexts: [title],
              openCapability: capability ?? (application == .codex ? .codexDeepLink : .unsupported))
    }

    /// Observes the asynchronous mock chooser within a finite polling budget.
    ///
    /// Args:
    ///   recorder: Thread-safe chooser recorder.
    ///
    /// Returns:
    ///   First frozen candidate rows.
    ///
    /// Raises:
    ///   Error: No selection appeared within the polling budget.
    private func waitForChoice(_ recorder: Recorder) async throws -> [AgentActivityCandidate] {
        for _ in 0..<Self.maximumPollAttempts {
            if let choices = recorder.offeredChoices().first { return choices }
            try await Task.sleep(nanoseconds: Self.pollDelayNanoseconds)
        }
        throw NSError(domain: "AgentRouterFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock chooser exceeded its observation bound."])
    }
}
