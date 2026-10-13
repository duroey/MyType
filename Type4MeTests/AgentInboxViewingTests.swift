import Foundation
import XCTest
@testable import Type4Me

@MainActor
final class AgentInboxViewingTests: XCTestCase {
    /// Builds memory-only messages with explicit provider and native engine identities.
    private func session(_ app: AgentDesktopApplication = .claudeCode, id: String = "fixture") -> AgentSessionDescriptor {
        .init(sessionID: id, application: app, title: "Fixture", workspacePath: nil,
              updatedAt: 1, matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: "engine")
    }

    /// Uses a short injected grace period; production timing stays in the bundled config.
    private func store() -> AgentInboxStore {
        var configuration = AgentNotificationConfiguration()
        configuration.completionAlertDelaySeconds = 0.03
        return AgentInboxStore(configuration: configuration)
    }

    /// A stable currently viewed Claude completion is removed before its popup is presented.
    func testViewedClaudeCompletionCancelsPopupAndDoesNotReappear() async throws {
        let inbox = store()
        var popups = 0
        inbox.onCompletion = { _ in popups += 1 }
        let now = Date()
        inbox.apply(.init(session: session(), status: .completed, completionID: "turn-1", observedAt: now))
        XCTAssertEqual(popups, 0)
        inbox.applyViewedSession(.init(sessionID: "fixture", engineSessionID: "engine", observedAt: now), now: now)
        XCTAssertTrue(inbox.items.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(popups, 0)
        inbox.apply(.init(session: session(), status: .completed, completionID: "turn-1"))
        XCTAssertTrue(inbox.items.isEmpty)
        inbox.apply(.init(session: session(), status: .running))
        inbox.apply(.init(session: session(), status: .completed, completionID: "turn-2"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(popups, 1)
        XCTAssertEqual(inbox.items.count, 1)
    }

    /// Native Codex read evidence arriving after completion prevents a transient popup.
    func testCodexNativeReadDuringGraceCancelsPopup() async throws {
        let inbox = store()
        var popups = 0
        inbox.onCompletion = { _ in popups += 1 }
        inbox.apply(.init(session: session(.codex), status: .completed, completionID: "turn"))
        XCTAssertEqual(popups, 0)
        inbox.apply(.init(session: session(.codex), status: .completed, nativeHasUnreadTurn: false))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(popups, 0)
        XCTAssertTrue(inbox.items.isEmpty)
    }

    /// No reliable read/view evidence means the completion is retained and still alerts.
    func testUnknownViewRetainsBothProvidersAndAlertsOnce() async throws {
        let inbox = store()
        var popups = 0
        inbox.onCompletion = { _ in popups += 1 }
        for app: AgentDesktopApplication in [.codex, .claudeCode] {
            inbox.apply(.init(session: session(app), status: .completed, completionID: "turn"))
            inbox.apply(.init(session: session(app), status: .completed, completionID: "turn"))
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(popups, 2)
        XCTAssertEqual(inbox.items.count, 2)
    }

    /// Old, future, foreign-engine and pre-completion observations cannot consume a row.
    func testStaleOrMismatchedEvidenceIsNotReused() {
        let inbox = store()
        let now = Date()
        inbox.apply(.init(session: session(), status: .completed, completionID: "turn", observedAt: now))
        for time in [now.addingTimeInterval(-2), now.addingTimeInterval(-0.1), now.addingTimeInterval(1)] {
            inbox.applyViewedSession(.init(sessionID: "fixture", engineSessionID: "engine", observedAt: time), now: now)
            XCTAssertEqual(inbox.items.count, 1)
        }
        inbox.applyViewedSession(.init(sessionID: "fixture", engineSessionID: "other", observedAt: now), now: now)
        XCTAssertEqual(inbox.items.count, 1)
        inbox.cancelCompletionAlerts()
    }

    /// Viewing a question or approval does not resolve it or consume another provider's result.
    func testViewingPreservesRequestsRunningAndOtherSessions() {
        let inbox = store()
        let now = Date()
        inbox.apply(.init(session: session(.codex), status: .completed, completionID: "codex", observedAt: now))
        for kind: AgentInboxRequest.Kind in [.input, .approval] {
            let request = AgentInboxRequest(id: kind.rawValue, kind: kind, text: "Please respond")
            inbox.apply(.init(session: session(), status: .completed, pendingRequests: [request],
                              completionID: kind.rawValue, observedAt: now))
            inbox.applyViewedSession(.init(sessionID: "fixture", engineSessionID: "engine", observedAt: now), now: now)
            XCTAssertEqual(inbox.items.count, 2)
            XCTAssertEqual(inbox.items.first(where: { $0.session.application == .claudeCode })?.pendingRequests, [request])
        }
        inbox.apply(.init(session: session(), status: .running, pendingRequests: [], observedAt: now))
        inbox.applyViewedSession(.init(sessionID: "fixture", engineSessionID: "engine", observedAt: now), now: now)
        XCTAssertEqual(inbox.items.count, 2)
        inbox.cancelCompletionAlerts()
    }

    /// Later requests, new work, shutdown and explicit row opening cancel obsolete popups.
    func testPendingPopupDoesNotSurviveChangedAttention() async throws {
        for action in ["running", "request", "read", "stop"] {
            let inbox = store()
            var popups = 0
            inbox.onCompletion = { _ in popups += 1 }
            inbox.apply(.init(session: session(), status: .completed, completionID: "turn"))
            switch action {
            case "running": inbox.apply(.init(session: session(), status: .running))
            case "request": inbox.apply(.init(session: session(), status: .completed,
                 pendingRequests: [.init(id: "approval", kind: .approval, text: "Approve?")]))
            case "read": inbox.markRead(session().id)
            default: inbox.cancelCompletionAlerts()
            }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(popups, 0)
            XCTAssertEqual(inbox.items.count, 1)
        }
    }
}
