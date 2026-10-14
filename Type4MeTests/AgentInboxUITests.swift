import AppKit
import XCTest
@testable import Type4Me

final class AgentInboxUITests: XCTestCase {
    /// Verifies persistent queue copy changes language without translating native titles.
    func testCopyAndAccessibilityFollowCurrentLanguage() {
        let item = fixture(status: .completed, pending: [
            AgentInboxRequest(id: "question", kind: .input, text: "用户原文")
        ])
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(AgentInboxCopy.text(.title, language: language),
                           language == .zh ? "Agent 消息" : "Agent inbox")
            XCTAssertEqual(AgentInboxCopy.text(.showInbox, language: language),
                           language == .zh ? "打开消息队列" : "Open agent inbox")
            XCTAssertEqual(AgentInboxCopy.text(.entryDetail, language: language),
                           language == .zh ? "查看 Agent 进度、完成消息和待办请求" : "View agent progress, results, and requests")
            let label = AgentInboxCopy.accessibilityLabel(for: item, language: language)
            XCTAssertTrue(label.contains("MyType 体验包"))
            XCTAssertTrue(label.contains(language == .zh ? "需要你回复" : "Needs your reply"))
            XCTAssertTrue(label.contains(language == .zh ? "未读" : "Unread"))
            XCTAssertFalse(label.contains(language == .zh ? "Needs your reply" : "需要你回复"))
        }
        for label in AgentInboxCopy.Label.allCases {
            XCTAssertFalse(AgentInboxCopy.text(label, language: .zh).isEmpty)
            XCTAssertFalse(AgentInboxCopy.text(label, language: .en).isEmpty)
        }
    }

    /// Keeps pending input and approval visible when a turn later reports completed.
    func testPendingRequestsTakePriorityOverTurnCompletion() {
        let item = fixture(status: .completed, pending: [
            AgentInboxRequest(id: "question", kind: .input, text: "请选择"),
            AgentInboxRequest(id: "approval", kind: .approval, text: "请批准")
        ])
        XCTAssertEqual(AgentInboxCopy.statusLabels(for: item), [.approval, .input])
        XCTAssertEqual(AgentInboxCopy.statusLabels(for: fixture(status: .completed)), [.completed])
        XCTAssertEqual(AgentInboxCopy.statusLabels(for: fixture(status: .unknown)), [.unknown])
        XCTAssertEqual(AgentInboxCopy.statusLabels(for: fixture(status: .unknown, pending: [
            AgentInboxRequest(id: "old-question", kind: .input, text: "保留的历史问题")
        ])), [.unknown, .input])
        XCTAssertEqual(AgentInboxCopy.statusLabels(for: fixture(status: .interrupted)), [.interrupted])
    }

    /// Opens the exact provider-qualified session and marks it read after acceptance only.
    @MainActor
    func testNavigationPreservesNativeIdentityForBothProviders() async {
        for provider in AgentDesktopApplication.allCases {
            let item = fixture(application: provider, status: .completed)
            var opened: [AgentSessionDescriptor] = []
            var read: [String] = []
            let model = AgentInboxViewModel(
                opener: { session in
                    XCTAssertTrue(read.isEmpty)
                    opened.append(session)
                },
                markRead: { read.append($0.id) }
            )
            await model.open(item)
            XCTAssertEqual(opened, [item.session])
            XCTAssertEqual(read, [item.id])
            XCTAssertNil(model.failure)
            XCTAssertNil(model.openingID)
        }
    }

    /// Keeps unread updates and the queue visible when the native application rejects opening.
    @MainActor
    func testFailedNavigationDoesNotConsumeUnreadUpdate() async {
        var markedRead = false
        let model = AgentInboxViewModel(
            opener: { _ in throw FixtureFailure.unavailable },
            markRead: { _ in markedRead = true }
        )
        let item = fixture(status: .completed)
        await model.open(item)
        XCTAssertFalse(markedRead)
        XCTAssertEqual(model.failedID, item.id)
        XCTAssertEqual(model.failure, .openFailed)
        XCTAssertNil(model.openingID)
        model.resetPresentation()
        XCTAssertNil(model.failure)
    }

    /// Rejects unsupported navigation without substituting the session's workspace.
    @MainActor
    func testUnsupportedSessionDoesNotLaunchAReplacementConversation() async {
        var opened = false
        var markedRead = false
        let model = AgentInboxViewModel(
            opener: { _ in opened = true }, markRead: { _ in markedRead = true }
        )
        await model.open(fixture(status: .completed, capability: .unsupported))
        XCTAssertFalse(opened)
        XCTAssertFalse(markedRead)
        XCTAssertEqual(model.failure, .cannotOpen)
    }

    /// Ensures only completed events reveal the panel and only manual opening requests focus.
    @MainActor
    func testCompletionPresentationDoesNotRequestFocus() {
        var reasons: [AgentInboxPresentation] = []
        var dismissed = 0
        let store = AgentInboxStore()
        let controller = AgentInboxPanelController(
            storeProvider: { store },
            present: { reasons.append($0) }, dismiss: { dismissed += 1 }
        )
        for status in [AgentInboxStatus.running, .waiting, .idle, .interrupted, .failed, .unknown] {
            controller.showCompletion(fixture(status: status))
        }
        XCTAssertTrue(reasons.isEmpty)
        controller.showCompletion(fixture(status: .completed))
        XCTAssertEqual(reasons, [.taskCompleted])
        XCTAssertFalse(reasons[0].requestsKeyboardFocus)
        controller.show()
        XCTAssertEqual(reasons, [.taskCompleted, .userRequested])
        XCTAssertTrue(reasons[1].requestsKeyboardFocus)
        controller.close()
        XCTAssertEqual(dismissed, 1)
    }

    /// Native navigation keeps the persistent queue visible and preserves unanswered requests.
    @MainActor
    func testSuccessfulNavigationKeepsPanelAndOtherRowsVisible() async throws {
        let store = AgentInboxStore()
        let pending = fixture(status: .completed, pending: [
            AgentInboxRequest(id: "approval", kind: .approval, text: "请批准")
        ])
        let other = fixture(application: .claudeCode, status: .completed)
        store.apply(.init(session: pending.session, status: pending.status,
                          pendingRequests: pending.pendingRequests, completionID: "pending-turn"))
        store.apply(.init(session: other.session, status: other.status, completionID: "other-turn"))
        let selected = try XCTUnwrap(store.items.first { $0.id == pending.id })
        var isPresented = false
        let controller = AgentInboxPanelController(
            storeProvider: { store }, present: { _ in isPresented = true }, dismiss: { isPresented = false }
        )
        let model = AgentInboxViewModel(opener: { _ in }, markRead: { store.markRead($0.id) })
        controller.show()
        await model.open(selected)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(controller.presentation, .userRequested)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first { $0.id == selected.id }?.pendingRequests, selected.pendingRequests)
        XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == selected.id }).isUnread)
        XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == other.id }).isUnread)
        controller.close()
        XCTAssertFalse(isPresented)
        controller.show()
        XCTAssertTrue(isPresented, "Explicitly hidden messages remain available from the menu")
    }

    /// Closing a draft invalidates late native callbacks without consuming the message.
    @MainActor
    func testResetInvalidatesAnInFlightNavigationResult() async {
        let started = expectation(description: "Native opening started")
        var finish: CheckedContinuation<Void, Never>?
        var markedRead = false
        let model = AgentInboxViewModel(
            opener: { _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            }, markRead: { _ in markedRead = true }
        )
        let opening = Task { await model.open(fixture(status: .completed)) }
        await fulfillment(of: [started], timeout: 1)
        model.resetPresentation()
        finish?.resume()
        await opening.value
        XCTAssertFalse(markedRead)
        XCTAssertNil(model.openingID)
        XCTAssertNil(model.failure)
    }

    /// Quiet automatic panels hide without clearing workers, and fresh attention can reveal them again.
    @MainActor
    func testAutomaticPresentationHidesWhenOnlyBackgroundWorkRemains() async {
        let store = AgentInboxStore()
        let completed = fixture(status: .completed)
        store.apply(.init(session: completed.session, status: .completed, completionID: "unread-turn"))
        let hidden = expectation(description: "Quiet notification closes")
        hidden.assertForOverFulfill = true
        var dismissals = 0
        let controller = AgentInboxPanelController(
            storeProvider: { store }, present: { _ in }, dismiss: { dismissals += 1; hidden.fulfill() }
        )
        controller.showCompletion(completed)
        store.apply(.init(session: completed.session, status: .running))
        await fulfillment(of: [hidden], timeout: 1)
        XCTAssertNil(controller.presentation)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.status, .running)
        let request = AgentInboxRequest(id: "input", kind: .input, text: "请选择")
        store.apply(.init(session: completed.session, status: .waiting, pendingRequests: [request]))
        controller.showRequest(fixture(status: .waiting, pending: [request]))
        await settlePublishedUpdates()
        XCTAssertEqual(controller.presentation, .needsResponse)
        XCTAssertEqual(controller.presentation?.requestsKeyboardFocus, false)
        XCTAssertEqual(dismissals, 1)
    }

    /// User-opened queues remain visible through later automatic alerts, worker-only and empty states.
    @MainActor
    func testManualPresentationStaysVisibleWhenAttentionClears() async {
        let store = AgentInboxStore()
        let completed = fixture(status: .completed)
        store.apply(.init(session: completed.session, status: .completed, completionID: "unread-turn"))
        var dismissals = 0
        let controller = AgentInboxPanelController(
            storeProvider: { store }, present: { _ in }, dismiss: { dismissals += 1 }
        )
        controller.showCompletion(completed)
        controller.show()
        controller.showCompletion(completed)
        store.apply(.init(session: completed.session, status: .running))
        await settlePublishedUpdates()
        XCTAssertEqual(controller.presentation, .userRequested)
        store.dismiss(completed.id)
        await settlePublishedUpdates()
        XCTAssertEqual(controller.presentation, .userRequested)
        XCTAssertEqual(dismissals, 0)
        controller.close()
        XCTAssertEqual(dismissals, 1)
    }

    /// Transient remove/append publications cannot hide an automatic queue with remaining requests.
    @MainActor
    func testCompletedStoreMutationKeepsPendingAttentionVisible() async {
        let store = AgentInboxStore()
        let request = AgentInboxRequest(id: "approval", kind: .approval, text: "请批准")
        let item = fixture(status: .running, pending: [request])
        store.apply(.init(session: item.session, status: .running, pendingRequests: [request]))
        var dismissals = 0
        let controller = AgentInboxPanelController(
            storeProvider: { store }, present: { _ in }, dismiss: { dismissals += 1 }
        )
        controller.showRequest(item)
        store.apply(.init(session: item.session, status: .running, pendingRequests: [request], preview: "Updated detail"))
        store.markRead(item.id)
        await settlePublishedUpdates()
        XCTAssertEqual(controller.presentation, .needsResponse)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(store.items.first?.pendingRequests, [request])
    }

    /// Empty queues and only background work are quiet; requests, unread results and failures are not.
    func testQuietPolicyPreservesAttentionAndNavigationFeedback() {
        for reason in [AgentInboxPresentation.taskCompleted, .needsResponse] {
            XCTAssertTrue(reason.shouldHideWhenQuiet(items: []))
            for status in [AgentInboxStatus.running, .waiting] {
                XCTAssertTrue(reason.shouldHideWhenQuiet(items: [fixture(status: status)]))
            }
            for status in [AgentInboxStatus.completed, .failed, .interrupted, .unknown, .idle] {
                XCTAssertFalse(reason.shouldHideWhenQuiet(items: [fixture(status: status)]))
            }
            for kind in [AgentInboxRequest.Kind.input, .approval] {
                var item = fixture(status: .running, pending: [.init(id: "request", kind: kind, text: "Review")])
                item.isUnread = false
                XCTAssertFalse(reason.shouldHideWhenQuiet(items: [item]))
            }
            XCTAssertFalse(reason.shouldHideWhenQuiet(items: [], storageError: true))
            XCTAssertFalse(reason.shouldHideWhenQuiet(items: [], isOpening: true))
            XCTAssertFalse(reason.shouldHideWhenQuiet(items: [], hasOpenFailure: true))
        }
        XCTAssertFalse(AgentInboxPresentation.userRequested.shouldHideWhenQuiet(items: []))
        XCTAssertFalse(AgentInboxPresentation.userRequested.shouldHideWhenQuiet(items: [fixture(status: .running)]))
    }

    /// Waits for already enqueued main-queue publications without a wall-clock delay or native window.
    @MainActor
    private func settlePublishedUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Sizes one, two, and three messages naturally while excess messages use the same viewport.
    func testMeasuredHeightCapsAtThreeRowsAndShrinksWhenRemoved() {
        let layout = AgentInboxPanelLayout()
        let measurements: [AgentInboxMeasuredElement: CGFloat] = [
            .header: 80, .row("a"): 100, .row("b"): 140, .row("c"): 120, .row("d"): 400
        ]
        let one = layout.contentHeight(itemIDs: ["a"], measurements: measurements)
        let two = layout.contentHeight(itemIDs: ["a", "b"], measurements: measurements)
        let three = layout.contentHeight(itemIDs: ["a", "b", "c"], measurements: measurements)
        XCTAssertEqual(one, 80 + 100 + layout.listBottomInset)
        XCTAssertEqual(two, 80 + 2 * 140 + layout.rowSpacing + layout.listBottomInset)
        XCTAssertEqual(three, 80 + 3 * 140 + 2 * layout.rowSpacing + layout.listBottomInset)
        XCTAssertEqual(layout.contentHeight(itemIDs: ["a", "b", "c", "d"], measurements: measurements), three)
        XCTAssertEqual(layout.minimumRowHeight(itemIDs: ["a", "b", "c", "d"], measurements: measurements), 140)
        XCTAssertGreaterThan(4 * 140 + 3 * layout.rowSpacing, three - 80 - layout.listBottomInset,
                             "Even shorter later rows occupy the minimum slot, so four cannot fit")
        XCTAssertLessThan(one, two)
        XCTAssertLessThan(two, three)
        XCTAssertEqual(layout.contentHeight(itemIDs: [], measurements: [.header: 80, .empty: 110]), 190)
    }

    /// Uses fresh language, warning, and row measurements rather than a cached fixed panel height.
    func testMeasuredHeightRespondsToLanguageAndVisibleErrors() {
        let layout = AgentInboxPanelLayout()
        let chinese: [AgentInboxMeasuredElement: CGFloat] = [.header: 80, .row("a"): 110]
        let english: [AgentInboxMeasuredElement: CGFloat] = [.header: 100, .row("a"): 125, .warning: 40]
        XCTAssertEqual(layout.contentHeight(itemIDs: ["a"], measurements: english)
                       - layout.contentHeight(itemIDs: ["a"], measurements: chinese), 75)
        XCTAssertEqual(layout.contentHeight(itemIDs: ["a"], measurements: chinese), 190 + layout.listBottomInset)
        for language in [AppLanguage.zh, .en, .zh] {
            XCTAssertEqual(AgentInboxCopy.text(.subtitle, language: language), language == .zh
                           ? "需要你看的在上，正在工作的在下。"
                           : "Updates needing attention come first, followed by ongoing work.")
        }
    }

    /// Resizing holds the top-right anchor and stays within even a smaller secondary display.
    func testPanelFrameKeepsTopEdgeAndClampsToScreen() {
        let layout = AgentInboxPanelLayout()
        let screen = NSRect(x: -1200, y: 100, width: 1200, height: 800)
        let one = layout.frame(contentHeight: 200, visibleFrame: screen)
        let three = layout.frame(contentHeight: 600, visibleFrame: screen, currentFrame: one)
        XCTAssertEqual(one.maxX, three.maxX)
        XCTAssertEqual(one.maxY, three.maxY)
        XCTAssertEqual(three.height, 600)
        let capped = layout.frame(contentHeight: 2000, visibleFrame: screen, currentFrame: three)
        XCTAssertEqual(capped.height, screen.height - layout.screenInset * 2)
        XCTAssertTrue(screen.contains(capped))
        let tiny = NSRect(x: 0, y: 0, width: 320, height: 480)
        XCTAssertTrue(tiny.contains(layout.frame(contentHeight: 700, visibleFrame: tiny)))
    }

    /// Builds a provider-qualified native conversation without reading user data.
    ///
    /// Args:
    ///   application: Native app used for exact routing assertions.
    ///   status: Current observed status.
    ///   pending: Independent unresolved native questions and approvals.
    ///   capability: Optional unsupported navigation fixture.
    ///
    /// Returns:
    ///   A deterministic unread queue item.
    private func fixture(
        application: AgentDesktopApplication = .codex,
        status: AgentInboxStatus,
        pending: [AgentInboxRequest] = [],
        capability: AgentSessionOpenCapability? = nil
    ) -> AgentInboxItem {
        let id = "12345678-1234-1234-1234-123456789abc"
        let session = AgentSessionDescriptor(
            sessionID: application == .codex ? id : "local_" + id,
            application: application, title: "MyType 体验包", workspacePath: "/fixture/unused",
            updatedAt: 100, matchTexts: [],
            openCapability: capability ?? (application == .codex ? .codexDeepLink : .claudeNativeDeepLink)
        )
        return AgentInboxItem(
            session: session, status: status, pendingRequests: pending,
            preview: "原始回复", updatedAt: Date(timeIntervalSince1970: 100), isUnread: true
        )
    }

    private enum FixtureFailure: Error {
        case unavailable
    }
}
