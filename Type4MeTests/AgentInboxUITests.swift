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
            var didClose = false
            let model = AgentInboxViewModel(
                opener: { session in
                    XCTAssertTrue(read.isEmpty)
                    opened.append(session)
                },
                markRead: { read.append($0.id) },
                onOpened: { didClose = true }
            )
            await model.open(item)
            XCTAssertEqual(opened, [item.session])
            XCTAssertEqual(read, [item.id])
            XCTAssertTrue(didClose)
            XCTAssertNil(model.failure)
            XCTAssertNil(model.openingID)
        }
    }

    /// Keeps unread updates and the queue visible when the native application rejects opening.
    @MainActor
    func testFailedNavigationDoesNotConsumeUnreadUpdate() async {
        var markedRead = false
        var didClose = false
        let model = AgentInboxViewModel(
            opener: { _ in throw FixtureFailure.unavailable },
            markRead: { _ in markedRead = true },
            onOpened: { didClose = true }
        )
        let item = fixture(status: .completed)
        await model.open(item)
        XCTAssertFalse(markedRead)
        XCTAssertFalse(didClose)
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
        let controller = AgentInboxPanelController(
            storeProvider: { fatalError("Window-free tests must not load the live store") },
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

    /// Collapses after navigation while preserving requests and other rows for manual reopening.
    @MainActor
    func testSuccessfulNavigationHidesPanelWithoutRemovingPendingRequestsOrOtherRows() async throws {
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
        let model = AgentInboxViewModel(
            opener: { _ in }, markRead: { store.markRead($0.id) }, onOpened: { controller.close() }
        )
        controller.show()
        await model.open(selected)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first { $0.id == selected.id }?.pendingRequests, selected.pendingRequests)
        XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == selected.id }).isUnread)
        XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == other.id }).isUnread)
        controller.show()
        XCTAssertTrue(isPresented, "The menu entry can reopen all remaining items")
        controller.close()
        controller.showCompletion(other)
        XCTAssertTrue(isPresented, "Later completion events can reveal the queue again")
    }

    /// Keeps a newer notification visible if an older native opening completes afterward.
    @MainActor
    func testLateNavigationDoesNotCollapseANewerPresentation() async {
        let started = expectation(description: "Native opening started")
        var finish: CheckedContinuation<Void, Never>?
        var revision = 1
        var closed = 0
        var selectedRead: [AgentInboxItem] = []
        let model = AgentInboxViewModel(
            opener: { _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            },
            markRead: { selectedRead.append($0) }, onOpened: { closed += 1 },
            presentationRevision: { revision }
        )
        let selected = fixture(status: .completed)
        let opening = Task { await model.open(selected) }
        await fulfillment(of: [started], timeout: 1)
        revision += 1
        finish?.resume()
        await opening.value
        XCTAssertEqual(selectedRead, [selected])
        XCTAssertEqual(closed, 0)
        XCTAssertNil(model.openingID)
        XCTAssertNil(model.failure)
    }

    /// Prevents a closed presentation's late result from touching a manually reopened inbox.
    @MainActor
    func testResetInvalidatesAnInFlightNavigationResult() async {
        let started = expectation(description: "Native opening started")
        var finish: CheckedContinuation<Void, Never>?
        var markedRead = false
        var closed = false
        let model = AgentInboxViewModel(
            opener: { _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            },
            markRead: { _ in markedRead = true }, onOpened: { closed = true }
        )
        let opening = Task { await model.open(fixture(status: .completed)) }
        await fulfillment(of: [started], timeout: 1)
        model.resetPresentation()
        finish?.resume()
        await opening.value
        XCTAssertFalse(markedRead)
        XCTAssertFalse(closed)
        XCTAssertNil(model.openingID)
        XCTAssertNil(model.failure)
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
