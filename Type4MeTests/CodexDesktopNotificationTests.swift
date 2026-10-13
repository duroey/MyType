import Foundation
import XCTest
@testable import Type4Me

final class CodexDesktopNotificationTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"
    private let ownerID = "22222222-2222-4222-8222-222222222222"

    /// Historical completion and runtime idle must never create new completion alerts.
    func testInitialSnapshotAndIdleAreQuiet() throws {
        var reducer = CodexInboxStateReducer()
        let initial = try reducer.accept(packet: snapshot(turns: [turn(status: "completed")]), ownerID: ownerID, session: session())
        XCTAssertEqual(initial.status, .completed)
        XCTAssertNil(initial.completionID)
        let idle = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
        ]), ownerID: ownerID, session: session())
        XCTAssertNil(idle.completionID)
    }

    /// A live completed turn alerts exactly once, independently of a preceding idle update.
    func testExplicitCompletedTransitionIsRequired() throws {
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")], active: true), ownerID: ownerID, session: session())
        let idle = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
        ]), ownerID: ownerID, session: session())
        XCTAssertNil(idle.completionID)
        let completed = try reducer.accept(packet: patches(base: 2, next: 3, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(completed.completionID, "turn-1")
        let unchanged = try reducer.accept(packet: patches(base: 3, next: 4, values: []), ownerID: ownerID, session: session())
        XCTAssertNil(unchanged.completionID)
    }

    /// Never applies a previous turn's read state to a fresh completion patch.
    func testReadStateRequiresFreshOwnerEvidence() throws {
        var reducer = CodexInboxStateReducer()
        var packet = snapshot(turns: [turn(status: "inProgress")], active: true)
        var params = packet["params"] as! [String: Any]
        var change = params["change"] as! [String: Any]
        var state = change["conversationState"] as! [String: Any]
        state["hasUnreadTurn"] = false
        change["conversationState"] = state; params["change"] = change; packet["params"] = params
        let initial = try reducer.accept(packet: packet, ownerID: ownerID, session: session())
        XCTAssertEqual(initial.nativeHasUnreadTurn, false)
        let completion = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
        ]), ownerID: ownerID, session: session())
        XCTAssertNil(completion.nativeHasUnreadTurn)
        let read = try reducer.accept(packet: patches(base: 2, next: 3, values: [
            ["op": "replace", "path": ["hasUnreadTurn"], "value": false],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(read.nativeHasUnreadTurn, false)
    }

    /// A native read hint can require a same-revision owner snapshot because read changes omit patches.
    func testReadRefreshSnapshotAtSameRevisionRemovesUnreadWithoutReplayingCompletion() throws {
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")], unread: false),
                               ownerID: ownerID, session: session())
        let completed = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["hasUnreadTurn"], "value": true],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(completed.completionID, "turn-1")
        XCTAssertEqual(completed.nativeHasUnreadTurn, true)

        let read = try reducer.accept(packet: snapshot(turns: [turn(status: "completed")], revision: 2, unread: false),
                                     ownerID: ownerID, session: session())
        XCTAssertEqual(reducer.revision, 2)
        XCTAssertEqual(read.status, .completed)
        XCTAssertEqual(read.nativeHasUnreadTurn, false)
        XCTAssertNil(read.completionID)
        let laterPatch = try reducer.accept(packet: patches(base: 2, next: 3, values: []),
                                           ownerID: ownerID, session: session())
        XCTAssertNil(laterPatch.nativeHasUnreadTurn)
        XCTAssertNil(laterPatch.completionID)
    }

    /// Unknown and wrongly typed read fields retain the completion instead of silently marking it read.
    func testMalformedAndMissingNativeReadStateIsUnknown() throws {
        for unread in [0 as Any, 1 as Any, "false" as Any, NSNull()] {
            var reducer = CodexInboxStateReducer()
            let update = try reducer.accept(packet: snapshot(turns: [turn(status: "completed")], unread: unread),
                                            ownerID: ownerID, session: session())
            XCTAssertNil(update.nativeHasUnreadTurn)
            let malformedPatch = try reducer.accept(packet: patches(base: 1, next: 2, values: [
                ["op": "replace", "path": ["hasUnreadTurn"], "value": unread],
            ]), ownerID: ownerID, session: session())
            XCTAssertNil(malformedPatch.nativeHasUnreadTurn)
        }
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")], unread: false),
                               ownerID: ownerID, session: session())
        let removed = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "remove", "path": ["hasUnreadTurn"]],
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(removed.completionID, "turn-1")
        XCTAssertNil(removed.nativeHasUnreadTurn)
    }

    /// Treats local read broadcasts as refresh hints, excluding remote, malformed and unread events.
    func testReadRefreshHintValidation() {
        let params: [String: Any] = ["hostId": "local", "conversationId": sessionID, "hasUnreadTurn": false]
        let packet: [String: Any] = ["type": "broadcast", "method": "thread-read-state-changed", "version": 3, "params": params]
        XCTAssertEqual(CodexInboxStateReducer.readStateRefreshSessionID(packet: packet), sessionID)
        for (key, value) in [("hostId", "remote" as Any), ("conversationId", "invalid" as Any),
                             ("hasUnreadTurn", true as Any), ("hasUnreadTurn", 0 as Any)] {
            var bad = packet
            var changed = params; changed[key] = value; bad["params"] = changed
            XCTAssertNil(CodexInboxStateReducer.readStateRefreshSessionID(packet: bad))
        }
        for (key, value) in [("type", "request" as Any), ("method", "unrelated" as Any), ("version", 2 as Any)] {
            var bad = packet; bad[key] = value
            XCTAssertNil(CodexInboxStateReducer.readStateRefreshSessionID(packet: bad))
        }
        for key in ["hostId", "conversationId", "hasUnreadTurn"] {
            var bad = packet
            var changed = params; changed.removeValue(forKey: key); bad["params"] = changed
            XCTAssertNil(CodexInboxStateReducer.readStateRefreshSessionID(packet: bad))
        }
    }

    /// The turn-completed event can precede native idle without losing or duplicating its popup receipt.
    func testCompletedThenIdleInSeparateFrames() throws {
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")], active: true), ownerID: ownerID, session: session())
        let completed = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.completionID, "turn-1")
        let idle = try reducer.accept(packet: patches(base: 2, next: 3, values: [
            ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(idle.status, .completed)
        XCTAssertNil(idle.completionID)
    }

    /// Errors and user interruptions do not become successful completions.
    func testFailureAndInterruptionNeverAlert() throws {
        for terminal in ["failed", "interrupted"] {
            var reducer = CodexInboxStateReducer()
            _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")]), ownerID: ownerID, session: session())
            let update = try reducer.accept(packet: patches(base: 1, next: 2, values: [
                ["op": "replace", "path": ["turns", 0, "status"], "value": terminal],
            ]), ownerID: ownerID, session: session())
            XCTAssertNil(update.completionID)
            XCTAssertEqual(update.status.rawValue, terminal)
        }
    }

    /// An asynchronous question remains outstanding after its turn completes or another assistant turn starts.
    func testAsyncQuestionSurvivesCompletionUntilLaterUserInput() throws {
        var reducer = CodexInboxStateReducer()
        let question: [String: Any] = ["type": "agentMessage", "id": "question-1", "text": "Which language?",
                                       "delivery": "async", "phase": "final_answer",
                                       "questions": [["title": "Language", "options": ["中文", "English"]]]]
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress", items: [question])]), ownerID: ownerID, session: session())
        let completed = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.pendingRequests?.map(\.id), ["async:question-1"])
        XCTAssertEqual(completed.completionID, "turn-1")
        let nextTurn = turn(id: "turn-2", status: "inProgress", time: 2, items: [])
        let assistantOnly = try reducer.accept(packet: patches(base: 2, next: 3, values: [
            ["op": "add", "path": ["turns", 1], "value": nextTurn],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(assistantOnly.pendingRequests?.count, 1)
        let replied = try reducer.accept(packet: patches(base: 3, next: 4, values: [
            ["op": "add", "path": ["turns", 1, "items", 0], "value": ["type": "userMessage", "id": "reply", "content": []]],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(replied.pendingRequests, [])
    }

    /// Blocking request removal is authoritative; no tool execution details enter the visible preview.
    func testBlockingApprovalIsSeparateFromVisibleDialogue() throws {
        var reducer = CodexInboxStateReducer()
        let request: [String: Any] = ["id": 370, "method": "item/commandExecution/requestApproval",
                                     "params": ["threadId": sessionID, "reason": "Approval needed", "command": "SECRET TOOL PAYLOAD"]]
        let response: [String: Any] = ["type": "agentMessage", "id": "answer", "text": "Visible answer", "phase": "final_answer"]
        let tool: [String: Any] = ["type": "commandExecution", "id": "tool", "aggregatedOutput": "SECRET TOOL OUTPUT"]
        let first = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress", items: [response, tool])], requests: [request]), ownerID: ownerID, session: session())
        XCTAssertEqual(first.pendingRequests?.first?.kind, .approval)
        XCTAssertEqual(first.pendingRequests?.first?.text, "Approval needed")
        XCTAssertEqual(first.preview, "Visible answer")
        let removed = try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "remove", "path": ["requests", 0]],
        ]), ownerID: ownerID, session: session())
        XCTAssertEqual(removed.pendingRequests, [])
    }

    /// Wrong owner, host, session, and unsupported schema do not commit any state.
    func testSenderIdentityAndSchemaAreRequired() throws {
        var reducer = CodexInboxStateReducer()
        let valid = snapshot(turns: [turn(status: "inProgress")])
        _ = try reducer.accept(packet: valid, ownerID: ownerID, session: session())
        for field in ["owner", "host", "session", "version"] {
            var packet = snapshot(turns: [turn(status: "completed")], revision: 2)
            if field == "owner" { packet["sourceClientId"] = "wrong-owner" }
            if field == "version" { packet["version"] = 12 }
            if field == "host" || field == "session" {
                var params = packet["params"] as! [String: Any]
                params[field == "host" ? "hostId" : "conversationId"] = "wrong"
                packet["params"] = params
            }
            XCTAssertThrowsError(try reducer.accept(packet: packet, ownerID: ownerID, session: session()))
            XCTAssertEqual(reducer.revision, 1)
        }
    }

    /// Gaps cannot fabricate completion, and the recovery snapshot remains quiet.
    func testRevisionGapAndRecoverySnapshot() throws {
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")]), ownerID: ownerID, session: session())
        XCTAssertThrowsError(try reducer.accept(packet: patches(base: 2, next: 3, values: []), ownerID: ownerID, session: session())) {
            XCTAssertEqual($0 as? CodexInboxError, .revisionGap)
        }
        reducer.invalidateRevision()
        let recovered = try reducer.accept(packet: snapshot(turns: [turn(status: "completed")], revision: 3), ownerID: ownerID, session: session())
        XCTAssertNil(recovered.completionID)
        XCTAssertThrowsError(try reducer.accept(packet: snapshot(turns: [], revision: 2), ownerID: ownerID, session: session()))
    }

    /// A malformed late patch must not retain successful earlier patches from the same transaction.
    func testPatchSetIsAtomicAndArrayBoundsAreStrict() throws {
        var reducer = CodexInboxStateReducer()
        _ = try reducer.accept(packet: snapshot(turns: [turn(status: "inProgress")]), ownerID: ownerID, session: session())
        XCTAssertThrowsError(try reducer.accept(packet: patches(base: 1, next: 2, values: [
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
            ["op": "remove", "path": ["turns", 5]],
        ]), ownerID: ownerID, session: session()))
        XCTAssertEqual(reducer.revision, 1)
        XCTAssertEqual((reducer.state?["turns"] as? [[String: Any]])?.first?["status"] as? String, "inProgress")
        let json = try JSONSerialization.jsonObject(with: Data("{\"path\":[\"turns\",0,\"status\"]}".utf8)) as! [String: Any]
        let result = try CodexInboxStateReducer.patch(["turns": [["status": "inProgress"]]],
                                                      path: ArraySlice(json["path"] as! [Any]), operation: "replace", value: "completed")
        XCTAssertEqual(((result as? [String: Any])?["turns"] as? [[String: Any]])?.first?["status"] as? String, "completed")
        XCTAssertThrowsError(try CodexInboxStateReducer.patch(["x"], path: ArraySlice([true] as [Any]), operation: "remove", value: nil))
    }

    /// Native paginated history is supported even when the legacy turns array is empty.
    func testTurnHistoryAndPreviewBounds() throws {
        var config = AgentNotificationConfiguration()
        config.maximumPreviewCharacters = 8
        var reducer = CodexInboxStateReducer(configuration: config)
        var packet = snapshot(turns: [])
        var params = packet["params"] as! [String: Any]
        var change = params["change"] as! [String: Any]
        var state = change["conversationState"] as! [String: Any]
        state["turnHistory"] = ["history": ["entitiesByKey": ["tail:0:fixture": turn(status: "completed", items: [
            ["type": "agentMessage", "id": "a", "text": "123456789abcdef", "phase": "final_answer"],
        ])]]]
        change["conversationState"] = state; params["change"] = change; packet["params"] = params
        let update = try reducer.accept(packet: packet, ownerID: ownerID, session: session())
        XCTAssertEqual(update.status, .completed)
        XCTAssertEqual(update.preview, "12345678")
        XCTAssertNil(update.completionID)
    }

    /// Fragmented headers and coalesced frames preserve boundaries without premature JSON parsing.
    func testFrameDecoderHandlesFragmentationAndCoalescing() throws {
        let first = Data("{\"id\":1}".utf8), second = Data("{\"id\":2}".utf8)
        var buffer = Data([UInt8(first.count), 0])
        XCTAssertNil(try CodexInboxSocket.decodeFrame(from: &buffer, maximumBytes: 1_024))
        buffer.append(contentsOf: [0, 0]); buffer.append(first.prefix(2))
        XCTAssertNil(try CodexInboxSocket.decodeFrame(from: &buffer, maximumBytes: 1_024))
        buffer.append(first.dropFirst(2)); buffer.append(contentsOf: [UInt8(second.count), 0, 0, 0]); buffer.append(second)
        XCTAssertEqual(try CodexInboxSocket.decodeFrame(from: &buffer, maximumBytes: 1_024)?["id"] as? Int, 1)
        XCTAssertEqual(try CodexInboxSocket.decodeFrame(from: &buffer, maximumBytes: 1_024)?["id"] as? Int, 2)
        XCTAssertTrue(buffer.isEmpty)
        var oversized = Data([1, 4, 0, 0])
        XCTAssertThrowsError(try CodexInboxSocket.decodeFrame(from: &oversized, maximumBytes: 1_024))
        XCTAssertEqual(oversized.count, 4)
    }

    /// A state exceeding its configured memory budget is rejected before it can replace known state.
    func testOversizedSnapshotDoesNotCommit() throws {
        var configuration = AgentNotificationConfiguration()
        configuration.maximumCodexStateBytes = 512
        var reducer = CodexInboxStateReducer(configuration: configuration)
        _ = try reducer.accept(packet: snapshot(turns: []), ownerID: ownerID, session: session())
        let oversized = snapshot(turns: [turn(status: "completed", items: [
            ["type": "agentMessage", "id": "large", "text": String(repeating: "x", count: 1_024)],
        ])], revision: 2)
        XCTAssertThrowsError(try reducer.accept(packet: oversized, ownerID: ownerID, session: session())) {
            XCTAssertEqual($0 as? CodexInboxError, .capacityExceeded)
        }
        XCTAssertEqual(reducer.revision, 1)
    }

    /// Replays an explicitly supplied private trace without checking dialogue into the repository.
    func testOptInRecordedDesktopTrace() throws {
        guard let tracePath = ProcessInfo.processInfo.environment["MYTYPE_CODEX_TRACE_PATH"] else {
            throw XCTSkip("Private recorded trace requires an explicit path")
        }
        let rows = try String(contentsOfFile: tracePath, encoding: .utf8).split(separator: "\n")
        var owner: String?
        var target: AgentSessionDescriptor?
        var reducer = CodexInboxStateReducer()
        var count = 0
        var completions = 0
        var questions = 0
        var approvals = 0
        for row in rows {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            let packet = try XCTUnwrap(record["message"] as? [String: Any])
            if packet["method"] as? String == "thread-owner-discovery", packet["resultType"] as? String == "success" {
                owner = packet["handledByClientId"] as? String
            }
            guard packet["method"] as? String == "thread-stream-state-changed" else { continue }
            let params = try XCTUnwrap(packet["params"] as? [String: Any])
            let id = try XCTUnwrap(params["conversationId"] as? String)
            if target == nil { target = .init(sessionID: id, application: .codex, title: "Private fixture", workspacePath: nil,
                                              updatedAt: 1, matchTexts: [], openCapability: .codexDeepLink) }
            let update = try reducer.accept(packet: packet, ownerID: XCTUnwrap(owner), session: XCTUnwrap(target))
            count += 1
            if update.completionID != nil { completions += 1 }
            if update.pendingRequests?.contains(where: { $0.kind == .input }) == true { questions += 1 }
            if update.pendingRequests?.contains(where: { $0.kind == .approval }) == true { approvals += 1 }
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(completions, 0)
        XCTAssertGreaterThan(questions, 0)
        XCTAssertGreaterThan(approvals, 0)
    }

    /// Opt-in smoke probe only subscribes to existing owners; it sends no task, input, or approval.
    func testOptInPassiveDesktopSubscription() async throws {
        guard ProcessInfo.processInfo.environment["MYTYPE_RUN_CODEX_OBSERVER_LIVE"] == "1" else {
            throw XCTSkip("Live desktop subscription requires explicit opt-in")
        }
        var config = AgentNotificationConfiguration()
        config.maximumSessions = 3
        let received = expectation(description: "Existing signed desktop owner emitted a native snapshot")
        received.assertForOverFulfill = false
        let source = CodexDesktopNotificationSource(configuration: config)
        let task = Task {
            await source.run { update in
                if update.status != .unknown { received.fulfill() }
            }
        }
        await fulfillment(of: [received], timeout: 15)
        task.cancel()
        await task.value
    }

    /// Builds a stable native session identity for protocol fixtures.
    private func session() -> AgentSessionDescriptor {
        .init(sessionID: sessionID, application: .codex, title: "Fixture", workspacePath: nil,
              updatedAt: 1, matchTexts: [], openCapability: .codexDeepLink)
    }

    /// Builds one minimal native turn with ordered visible and tool items.
    private func turn(id: String = "turn-1", status: String, time: Double = 1, items: [[String: Any]] = []) -> [String: Any] {
        ["turnId": id, "status": status, "turnStartedAtMs": time, "items": items]
    }

    /// Builds a versioned owner snapshot without reading a real transcript.
    private func snapshot(turns: [[String: Any]], requests: [[String: Any]] = [], active: Bool = false,
                          revision: Int = 1, unread: Any? = nil) -> [String: Any] {
        var state: [String: Any] = [
            "id": sessionID, "hostId": "local", "turns": turns, "requests": requests,
            "threadRuntimeStatus": ["type": active ? "active" : "idle"],
        ]
        if let unread { state["hasUnreadTurn"] = unread }
        return envelope(["type": "snapshot", "revision": revision, "conversationState": state])
    }

    /// Builds one atomic native patch batch for exact revision-boundary tests.
    private func patches(base: Int, next: Int, values: [[String: Any]]) -> [String: Any] {
        envelope(["type": "patches", "baseRevision": base, "revision": next, "patches": values])
    }

    /// Wraps a fixture in the desktop's current stream schema and exact source identity.
    private func envelope(_ change: [String: Any]) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
         "sourceClientId": ownerID, "params": ["hostId": "local", "conversationId": sessionID, "change": change]]
    }
}
