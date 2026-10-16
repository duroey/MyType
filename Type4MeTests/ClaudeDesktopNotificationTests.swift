import Darwin
import Foundation
import XCTest
@testable import Type4Me

final class ClaudeDesktopNotificationTests: XCTestCase {
    private let engineID = "22222222-2222-4222-8222-222222222222"
    private let hostID = "local_11111111-1111-4111-8111-111111111111"
    private var inbox: AgentHandoffDeliveryService.ClaudeInbox {
        .init(processID: 123, socketURL: URL(fileURLWithPath: "/tmp/cc-socks/123.sock"), processStartSeconds: 1_791_638_193)
    }
    private var session: AgentSessionDescriptor {
        .init(sessionID: hostID, application: .claudeCode, title: "Test", workspacePath: nil, updatedAt: 0,
              matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: engineID)
    }

    /// Verifies registry identity requires both native and engine IDs plus the original PID generation.
    func testRegistrationRejectsWrongHostAndProcessGeneration() throws {
        let valid = try registry(status: "busy")
        XCTAssertTrue(valid.matches(session: session, inbox: inbox))
        XCTAssertFalse(try registry(status: "busy", host: "local_33333333-3333-4333-8333-333333333333").matches(session: session, inbox: inbox))
        let reused = AgentHandoffDeliveryService.ClaudeInbox(processID: 123, socketURL: inbox.socketURL,
                                                           processStartSeconds: inbox.processStartSeconds + 1)
        XCTAssertFalse(valid.matches(session: session, inbox: reused))
    }

    /// Verifies an initial idle snapshot and a historical final answer cannot pop the queue.
    func testInitialIdleNeverCompletes() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "idle"))
        XCTAssertFalse(cycle.receive(try notice(), inbox: inbox))
        XCTAssertNil(cycle.completion(tail: finalTail(), status: "idle"))
    }

    /// Verifies idle alone and an uncorrelated notice cannot turn busy into success.
    func testCompletionRequiresMatchingPushAndNewFinal() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "busy"))
        cycle.subscriptionID = "current"
        XCTAssertNil(cycle.completion(tail: finalTail(), status: "idle"))
        XCTAssertFalse(cycle.receive(try notice(identifier: "old"), inbox: inbox))
        XCTAssertTrue(cycle.receive(try notice(), inbox: inbox))
        var oldTail = finalTail()
        oldTail.finalDate = Date(timeIntervalSince1970: 99)
        XCTAssertNil(cycle.completion(tail: oldTail, status: "idle"))
        XCTAssertNil(cycle.completion(tail: finalTail(), status: "waiting"))
        XCTAssertEqual(cycle.completion(tail: finalTail(), status: "idle"), "answer")
        XCTAssertNil(cycle.completion(tail: finalTail(), status: "idle"))
    }

    /// Verifies exited and unavailable notices never count as completed tasks.
    func testExitAndUnavailableAreNotCompletion() throws {
        for state in ["exited", "unavailable"] {
            var cycle = ClaudeDesktopNotificationSource.Cycle()
            cycle.observe(try registry(status: "busy"))
            cycle.subscriptionID = "current"
            XCTAssertTrue(cycle.receive(try notice(state: state), inbox: inbox))
            XCTAssertNil(cycle.completion(tail: finalTail(), status: "idle"))
        }
    }

    /// Verifies a same-user push still needs the expected sender, protocol and current finish time.
    func testWrongSocketProtocolAndStaleNoticeAreRejected() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "busy"))
        cycle.subscriptionID = "current"
        XCTAssertFalse(cycle.receive(try notice(from: "uds:/tmp/cc-socks/999.sock"), inbox: inbox))
        XCTAssertFalse(cycle.receive(try notice(version: 2), inbox: inbox))
        XCTAssertFalse(cycle.receive(try notice(finished: 99_000), inbox: inbox))
        XCTAssertNil(cycle.notice)
    }

    /// Verifies a later turn does not reuse the subscription from a prior incomplete observation.
    func testNewBusyAfterIdleCreatesNewCycle() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "busy"))
        cycle.subscriptionID = "old"
        cycle.observe(try registry(status: "idle"))
        cycle.observe(try registry(status: "busy", timestamp: 200_000))
        XCTAssertNil(cycle.subscriptionID)
        XCTAssertEqual(cycle.busySince, Date(timeIntervalSince1970: 200))
    }

    /// Verifies a late notice from turn A cannot prevent subscribing to turn B when idle was missed.
    func testLateNoticeBeforeNewBusyStartsFreshCycle() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "busy"))
        cycle.subscriptionID = "current"
        XCTAssertTrue(cycle.receive(try notice(finished: 110_000), inbox: inbox))
        cycle.observe(try registry(status: "busy", timestamp: 111_000))
        XCTAssertEqual(cycle.busySince, Date(timeIntervalSince1970: 111))
        XCTAssertNil(cycle.subscriptionID)
        XCTAssertNil(cycle.notice)
        XCTAssertEqual(cycle.subscriptionAttempts, 0)
        cycle.subscriptionID = "next"
        XCTAssertTrue(cycle.receive(try notice(identifier: "next", finished: 120_000), inbox: inbox))
        var answer = finalTail()
        answer.finalID = "next-answer"
        answer.finalDate = Date(timeIntervalSince1970: 119)
        XCTAssertEqual(cycle.completion(tail: answer, status: "idle"), "next-answer")
    }

    /// Verifies text previews exclude internal tool arguments, tool results and thinking.
    func testVisibleTailFiltersInternalInformationAndForeignSessions() throws {
        let body = try transcriptRow(blocks: [
            ["type": "thinking", "thinking": "secret thought"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "secret command"]],
            ["type": "text", "text": "Visible reply"],
        ])
        let foreign = try transcriptRow(blocks: [["type": "text", "text": "Other chat"]], sessionID: "different")
        let tail = ClaudeDesktopNotificationSource.visibleTail(data: body + foreign, engineID: engineID, maximumCharacters: 1_000)
        XCTAssertEqual(tail.finalText, "Visible reply")
        XCTAssertEqual(tail.finalID, "answer")
        XCTAssertNil(tail.questionID)
    }

    /// Verifies an internal-only assistant event cannot provide a completed visible result.
    func testInternalOnlyAndMalformedRecordsCannotComplete() throws {
        let body = try transcriptRow(blocks: [["type": "thinking", "thinking": "not visible"]])
        let tail = ClaudeDesktopNotificationSource.visibleTail(data: body + Data("{broken}\n".utf8),
                                                               engineID: engineID, maximumCharacters: 1_000)
        XCTAssertNil(tail.finalID)
        XCTAssertEqual(tail.finalText, "")
        XCTAssertNil(tail.questionID)
    }

    /// Verifies native input and approval waits have different actions without exposing commands.
    func testInputAndApprovalAreSeparateRequests() throws {
        let body = try transcriptRow(blocks: [["type": "tool_use", "name": "AskUserQuestion", "id": "question",
                                              "input": ["questions": [["question": "用哪种语言？"]]]]], stop: "tool_use")
        let tail = ClaudeDesktopNotificationSource.visibleTail(data: body, engineID: engineID, maximumCharacters: 1_000)
        XCTAssertNil(tail.finalID)
        let input = ClaudeDesktopNotificationSource.stateUpdate(registry: try registry(status: "waiting", waiting: "input needed"),
                                                               session: session, tail: tail, completionID: nil)
        XCTAssertEqual(input.pendingRequests?.first?.kind, .input)
        XCTAssertEqual(input.pendingRequests?.first?.text, "用哪种语言？")
        let approval = ClaudeDesktopNotificationSource.stateUpdate(registry: try registry(status: "waiting", waiting: "permission prompt"),
                                                                  session: session, tail: tail, completionID: nil)
        XCTAssertEqual(approval.pendingRequests?.first?.kind, .approval)
        XCTAssertEqual(approval.pendingRequests?.first?.text, "")
    }

    /// Verifies interrupted/tool-output rows invalidate an earlier final answer.
    func testUserRecordInvalidatesOldFinal() throws {
        let final = try transcriptRow(blocks: [["type": "text", "text": "Old answer"]])
        let user: [String: Any] = ["type": "user", "sessionId": engineID, "timestamp": "1970-01-01T00:01:43.000Z",
                                   "message": ["role": "user", "content": "[Request interrupted]"]]
        let data = final + (try JSONSerialization.data(withJSONObject: user)) + Data([10])
        XCTAssertNil(ClaudeDesktopNotificationSource.visibleTail(data: data, engineID: engineID, maximumCharacters: 1_000).finalID)
    }

    /// Reproduces a desktop wrap-up card that asks the user to choose the next step.
    func testAcknowledgedBlockedWrapUpIsWaitingEvenWhenRegistryIsIdle() throws {
        let tail = try wrapUpTail(blocked: true)
        let update = ClaudeDesktopNotificationSource.stateUpdate(
            registry: try registry(status: "idle", timestamp: 103_000),
            session: session, tail: tail, completionID: nil
        )
        XCTAssertEqual(update.status, .waiting)
        XCTAssertEqual(update.pendingRequests?.first?.kind, .input)
        XCTAssertEqual(update.pendingRequests?.first?.text, "继续下一步吗？")
        XCTAssertNil(update.completionID)
    }

    /// Accepts the native end-turn receipt even if the one-shot idle push was missed.
    func testAcknowledgedWrapUpCompletesObservedTurnWithoutIdlePush() throws {
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(try registry(status: "busy"))
        cycle.observe(try registry(status: "idle", timestamp: 103_000))
        let tail = try wrapUpTail(blocked: false)
        XCTAssertEqual(tail.finalText, "已完成本轮核对。")
        XCTAssertEqual(cycle.completion(tail: tail, status: "idle"), "answer")
        XCTAssertNil(cycle.completion(tail: tail, status: "idle"))
    }

    /// Rejects an old, future or still-running wrap-up as a new completed turn.
    func testWrapUpReceiptMustBelongToObservedIdleTurn() throws {
        let tail = try wrapUpTail(blocked: false)
        for (busy, idle, status): (Double?, Double, String) in [
            (nil, 103_000, "idle"), (104_000, 105_000, "idle"),
            (100_000, 101_000, "idle"), (100_000, 103_000, "busy"),
        ] {
            var cycle = ClaudeDesktopNotificationSource.Cycle()
            if let busy { cycle.observe(try registry(status: "busy", timestamp: busy)) }
            cycle.observe(try registry(status: status, timestamp: idle))
            XCTAssertNil(cycle.completion(tail: tail, status: status))
        }
    }

    /// Rejects tool failures and uncorrelated or non-terminal tool results.
    func testWrapUpNeedsSuccessfulExactNativeReceipt() throws {
        for (resultID, sourceID, terminal, failed): (String, String, Bool, Bool) in [
            ("other-tool", "answer", true, false), ("wrap-up", "other-answer", true, false),
            ("wrap-up", "answer", false, false), ("wrap-up", "answer", true, true),
        ] {
            let tail = try wrapUpTail(blocked: true, resultID: resultID, sourceID: sourceID,
                                      terminal: terminal, failed: failed)
            XCTAssertNil(tail.finalID)
            XCTAssertNil(tail.questionID)
        }
    }

    /// Keeps ordinary progress tools and unacknowledged wrap-up calls out of the inbox.
    func testUnacknowledgedOrUnrelatedToolCannotFinishTurn() throws {
        for tool in ["mcp__ccd_turn__wrap_up", "mcp__other__wrap_up", "Bash"] {
            let data = try transcriptRow(blocks: [["type": "tool_use", "id": "wrap-up", "name": tool,
                                                  "input": ["recap": "未确认的内容", "blocked": true, "ask": "继续？"]]],
                                         stop: "tool_use")
            let tail = ClaudeDesktopNotificationSource.visibleTail(data: data, engineID: engineID, maximumCharacters: 1_000)
            XCTAssertNil(tail.finalID)
            XCTAssertNil(tail.questionID)
        }
    }

    /// Clears the old card when the person replies and preserves only the current turn.
    func testUserReplyClearsAcknowledgedWrapUp() throws {
        let user: [String: Any] = ["type": "user", "sessionId": engineID, "timestamp": "1970-01-01T00:01:44.000Z",
                                   "message": ["role": "user", "content": "继续"]]
        let data = try wrapUpTranscript(blocked: true) + JSONSerialization.data(withJSONObject: user) + Data([10])
        let tail = ClaudeDesktopNotificationSource.visibleTail(data: data, engineID: engineID, maximumCharacters: 1_000)
        XCTAssertNil(tail.finalID)
        XCTAssertNil(tail.questionID)
    }

    /// Exercises the actual inbox merge: one question alert, then a clear when work resumes.
    @MainActor
    func testBlockedCardAlertsOnceAndDoesNotReturnAfterReply() throws {
        var configuration = AgentNotificationConfiguration()
        configuration.completionAlertDelaySeconds = 0
        let store = AgentInboxStore(configuration: configuration)
        var requests = 0
        var completions = 0
        store.onRequest = { _ in requests += 1 }
        store.onCompletion = { _ in completions += 1 }
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        let busy = try registry(status: "busy")
        cycle.observe(busy)
        store.apply(ClaudeDesktopNotificationSource.reconciledUpdate(registry: busy, session: session,
                                                                    tail: .init(), cycle: &cycle))
        let idle = try registry(status: "idle", timestamp: 103_000)
        let tail = try wrapUpTail(blocked: true)
        for _ in 0..<2 {
            cycle.observe(idle)
            store.apply(ClaudeDesktopNotificationSource.reconciledUpdate(registry: idle, session: session,
                                                                        tail: tail, cycle: &cycle))
        }
        XCTAssertEqual(store.items.first?.status, .waiting)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(completions, 0)
        let resumed = try registry(status: "busy", timestamp: 104_000)
        cycle.observe(resumed)
        store.apply(ClaudeDesktopNotificationSource.reconciledUpdate(registry: resumed, session: session,
                                                                    tail: tail, cycle: &cycle))
        XCTAssertEqual(store.items.first?.status, .running)
        XCTAssertEqual(store.items.first?.pendingRequests.count, 0)
        let laterIdle = try registry(status: "idle", timestamp: 105_000)
        cycle.observe(laterIdle)
        store.apply(ClaudeDesktopNotificationSource.reconciledUpdate(registry: laterIdle, session: session,
                                                                    tail: tail, cycle: &cycle))
        XCTAssertEqual(store.items.first?.pendingRequests.count, 0, "A previous turn's card must not reopen.")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(completions, 0)
    }

    /// Restores pending native cards at startup without replaying historical completions.
    @MainActor
    func testStartupShowsBlockedCardButNotOldCompletedWrapUp() throws {
        for blocked in [false, true] {
            let store = AgentInboxStore()
            var cycle = ClaudeDesktopNotificationSource.Cycle()
            let idle = try registry(status: "idle", timestamp: 103_000)
            cycle.observe(idle)
            let update = ClaudeDesktopNotificationSource.reconciledUpdate(registry: idle, session: session,
                                                                          tail: try wrapUpTail(blocked: blocked), cycle: &cycle)
            store.apply(update)
            XCTAssertEqual(store.items.count, blocked ? 1 : 0)
            XCTAssertNil(update.completionID)
        }
    }

    /// Checks an explicitly selected native pending card without writing to or opening its app.
    @MainActor
    func testOptInReadOnlyNativeWrapUpProjection() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYTYPE_CLAUDE_WRAPUP_REGISTRY"] else {
            throw XCTSkip("Set MYTYPE_CLAUDE_WRAPUP_REGISTRY to an existing pending-card fixture.")
        }
        let configuration = AgentNotificationConfiguration()
        let registration = try XCTUnwrap(ClaudeDesktopNotificationSource.readRegistration(
            URL(fileURLWithPath: path), maximumBytes: configuration.maximumRegistryFileBytes
        ))
        let hostID = try XCTUnwrap(registration.hostSessionId)
        let target = AgentSessionDescriptor(sessionID: hostID, application: .claudeCode, title: "",
                                            workspacePath: registration.cwd, updatedAt: 0, matchTexts: [],
                                            openCapability: .claudeNativeDeepLink, engineSessionID: registration.sessionId)
        let app = try XCTUnwrap(AgentDesktopLauncherService.shared.detectInstallation(for: .claudeCode).applicationURL)
        let verified = try await AgentHandoffDeliveryService.findClaudeInbox(target: target, applicationURL: app,
                                                                            configuration: .init())
        XCTAssertTrue(registration.matches(session: target, inbox: verified))
        let directory = try XCTUnwrap(registration.cwd).replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let transcript = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            .appendingPathComponent(directory).appendingPathComponent(registration.sessionId + ".jsonl")
        let handle = try FileHandle(forReadingFrom: transcript)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > configuration.maximumTranscriptTailBytes ? size - UInt64(configuration.maximumTranscriptTailBytes) : 0
        try handle.seek(toOffset: offset)
        var data = try XCTUnwrap(handle.read(upToCount: configuration.maximumTranscriptTailBytes))
        if offset > 0, let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
        let tail = ClaudeDesktopNotificationSource.visibleTail(data: data, engineID: registration.sessionId,
                                                               maximumCharacters: configuration.maximumPreviewCharacters)
        var cycle = ClaudeDesktopNotificationSource.Cycle()
        cycle.observe(registration)
        let update = ClaudeDesktopNotificationSource.reconciledUpdate(registry: registration, session: target,
                                                                      tail: tail, cycle: &cycle)
        let store = AgentInboxStore()
        store.apply(update)
        XCTAssertTrue(tail.nativeTurnEnd)
        XCTAssertEqual(update.status, .waiting)
        XCTAssertEqual(store.items.first?.pendingRequests.first?.kind, .input)
        XCTAssertFalse(store.items.first?.pendingRequests.first?.text.isEmpty ?? true)
        XCTAssertNil(update.completionID)
    }

    /// Builds the same tool-call/receipt structure as the native desktop next-step card.
    ///
    /// Args:
    ///   blocked: Whether the native card requires a user decision.
    ///   resultID: Tool identity echoed by the result.
    ///   sourceID: Assistant UUID echoed by the result.
    ///   terminal: Whether the native host acknowledged the end of this turn.
    ///   failed: Whether execution of the card failed.
    ///
    /// Returns:
    ///   Sanitized JSONL fixtures containing no actual conversation content.
    private func wrapUpTranscript(blocked: Bool, resultID: String = "wrap-up", sourceID: String = "answer",
                                  terminal: Bool = true, failed: Bool = false) throws -> Data {
        let call = try transcriptRow(blocks: [[
            "type": "tool_use", "id": "wrap-up", "name": "mcp__ccd_turn__wrap_up",
            "input": ["recap": "已完成本轮核对。", "blocked": blocked, "ask": "继续下一步吗？",
                      "actions": [["label": "继续", "message": "继续下一步"]]],
        ]], stop: "tool_use")
        let receipt: [String: Any] = [
            "type": "user", "sessionId": engineID, "entrypoint": "claude-desktop", "uuid": "receipt",
            "parentUuid": sourceID, "sourceToolAssistantUUID": sourceID,
            "timestamp": "1970-01-01T00:01:42.100Z", "isSidechain": false,
            "mcpMeta": ["_meta": ["claude/endTurn": terminal]],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": resultID,
                                                        "is_error": failed, "content": "Wrap-up shown."]]],
        ]
        return try call + JSONSerialization.data(withJSONObject: receipt) + Data([10])
    }

    /// Parses a native card fixture through the production visible-tail projection.
    ///
    /// Args:
    ///   blocked: Whether user input is required.
    ///   resultID: Result correlation override.
    ///   sourceID: Assistant correlation override.
    ///   terminal: Native end-turn marker override.
    ///   failed: Tool execution error override.
    ///
    /// Returns:
    ///   The production projection used by the notification state machine.
    private func wrapUpTail(blocked: Bool, resultID: String = "wrap-up", sourceID: String = "answer",
                            terminal: Bool = true, failed: Bool = false) throws -> ClaudeDesktopNotificationSource.VisibleTail {
        ClaudeDesktopNotificationSource.visibleTail(
            data: try wrapUpTranscript(blocked: blocked, resultID: resultID, sourceID: sourceID,
                                        terminal: terminal, failed: failed),
            engineID: engineID, maximumCharacters: 1_000
        )
    }

    /// Verifies an incomplete registry write is unknown rather than idle.
    func testPartialRegistryReadFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("123.json")
        try Data("{\"pid\":123,\"status\":\"idle\"".utf8).write(to: file)
        XCTAssertNil(ClaudeDesktopNotificationSource.readRegistration(file, maximumBytes: 1_024))
    }

    /// Exercises production identity discovery and cancellation only after explicit local opt-in.
    ///
    /// The observer can send only native passive subscriptions. It sends no task text,
    /// starts no runtime, and never changes the observed desktop conversation.
    func testOptInPassiveDesktopSubscription() async throws {
        guard ProcessInfo.processInfo.environment["MYTYPE_RUN_CLAUDE_OBSERVER_LIVE"] == "1" else {
            throw XCTSkip("Set MYTYPE_RUN_CLAUDE_OBSERVER_LIVE=1 to observe an existing native desktop runtime.")
        }
        var configuration = AgentNotificationConfiguration()
        configuration.maximumSessions = 3
        configuration.ioTimeoutSeconds = 1
        configuration.discoveryIntervalSeconds = 5
        try configuration.validate()
        let receipts = PassiveLiveReceipts()
        let replyPaths = ["/tmp/cc-socks/\(getpid()).sock", "/tmp/cc-socks-\(getuid())/\(getpid()).sock"]
        let existedBefore = replyPaths.map { FileManager.default.fileExists(atPath: $0) }
        let source = ClaudeDesktopNotificationSource(configuration: configuration, subscriptionWriter: { inbox, packet, timeout in
            try await receipts.recordPassivePacket(packet)
            try await AgentHandoffDeliveryService.writeInbox(inbox: inbox, packet: packet, timeout: timeout)
        })
        let observer = Task { await source.run { await receipts.record($0) } }
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline, !(await receipts.hasVerifiedState()) {
            try await Task.sleep(for: .milliseconds(100))
        }
        observer.cancel()
        await observer.value
        let snapshot = await receipts.snapshot()
        XCTAssertTrue(snapshot.verifiedState, "No independently verified Claude desktop state was observed within the deadline.")
        XCTAssertEqual(snapshot.invalidPackets, 0, "A passive observer attempted a non-subscription packet.")
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(15))
        XCTAssertEqual(replyPaths.map { FileManager.default.fileExists(atPath: $0) }, existedBefore,
                       "The observer must remove only its own reply socket on cancellation.")
    }

    /// Builds a minimal exact-identity native registry fixture.
    ///
    /// Args:
    ///   status: Native runtime state.
    ///   timestamp: State transition milliseconds.
    ///   waiting: Optional reason for waiting.
    ///   host: Optional native conversation override.
    ///
    /// Returns:
    ///   A decoded fixture using production decoding.
    private func registry(status: String, timestamp: Double = 100_000, waiting: String? = nil,
                          host: String? = nil) throws -> ClaudeDesktopNotificationSource.Registration {
        var value: [String: Any] = ["pid": 123, "sessionId": engineID, "hostSessionId": host ?? hostID,
                                    "entrypoint": "claude-desktop", "peerProtocol": 1,
                                    "procStart": "Sat Oct 10 13:16:33 2026", "messagingSocketPath": "/tmp/cc-socks/123.sock",
                                    "status": status, "statusUpdatedAt": timestamp]
        if let waiting { value["waitingFor"] = waiting }
        return try JSONDecoder().decode(ClaudeDesktopNotificationSource.Registration.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Builds a native idle-push fixture with explicit correlation and terminal state.
    ///
    /// Args:
    ///   identifier: Subscription identifier to echo.
    ///   state: Native notice state.
    ///   from: Claimed sender socket.
    ///   version: Native protocol version.
    ///   finished: Native finish timestamp in milliseconds.
    ///
    /// Returns:
    ///   A decoded native push.
    private func notice(identifier: String = "current", state: String = "idle", from: String = "uds:/tmp/cc-socks/123.sock",
                        version: Int = 1, finished: Double = 103_000) throws -> ClaudeDesktopNotificationSource.IdleNotice {
        let value: [String: Any] = ["type": "control", "action": "peer_idle_notice", "orig_msg_id": identifier,
                                    "state": state, "finished_at": finished, "from": from, "msgV": version]
        return try JSONDecoder().decode(ClaudeDesktopNotificationSource.IdleNotice.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Provides a visible final result newer than the busy transition.
    ///
    /// Returns:
    ///   A minimal completion-evidence fixture.
    private func finalTail() -> ClaudeDesktopNotificationSource.VisibleTail {
        .init(finalID: "answer", finalDate: Date(timeIntervalSince1970: 102), finalText: "Done")
    }

    /// Serializes a transcript fixture without any dependency on actual session logs.
    ///
    /// Args:
    ///   blocks: Structured native content blocks.
    ///   stop: Native model stop reason.
    ///   sessionID: Optional foreign-session identity.
    ///
    /// Returns:
    ///   One newline-terminated native JSON row.
    private func transcriptRow(blocks: [[String: Any]], stop: String = "end_turn", sessionID: String? = nil) throws -> Data {
        let value: [String: Any] = ["type": "assistant", "sessionId": sessionID ?? engineID, "entrypoint": "claude-desktop",
                                    "uuid": "answer", "timestamp": "1970-01-01T00:01:42.000Z", "isSidechain": false,
                                    "message": ["role": "assistant", "stop_reason": stop, "content": blocks]]
        return try JSONSerialization.data(withJSONObject: value) + Data([10])
    }
}

/// Collects only test receipts; it never stores native conversation text or identifiers.
private actor PassiveLiveReceipts {
    private var verifiedState = false
    private var invalidPackets = 0

    /// Records whether production discovery emitted an independently verified native state.
    ///
    /// Args:
    ///   update: One passive observation, discarded after checking its structural identity.
    func record(_ update: AgentInboxUpdate) {
        if update.session.application == .claudeCode, update.status != .unknown,
           AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(update.session.sessionID),
           update.session.engineSessionID.flatMap(UUID.init(uuidString:)) != nil {
            verifiedState = true
        }
    }

    /// Rejects any transport packet other than the exact passive native subscription schema.
    ///
    /// Args:
    ///   packet: The serialized outgoing frame, which is never persisted by this test.
    ///
    /// Raises:
    ///   CocoaError: The source attempted task text or an unsupported native action.
    func recordPassivePacket(_ packet: Data) throws {
        guard let value = try JSONSerialization.jsonObject(with: packet) as? [String: Any],
              Set(value.keys) == Set(["type", "action", "msgV", "from", "msg_id"]),
              value["type"] as? String == "control", value["action"] as? String == "notify_when_idle",
              value["msgV"] as? Int == 1, (value["from"] as? String)?.hasPrefix("uds:") == true,
              (value["msg_id"] as? String).flatMap(UUID.init(uuidString:)) != nil else {
            invalidPackets += 1
            throw CocoaError(.propertyListReadCorrupt)
        }
    }

    /// Returns whether a verified state has arrived without exposing private session data.
    ///
    /// Returns:
    ///   True after at least one production identity check succeeded.
    func hasVerifiedState() -> Bool { verifiedState }

    /// Returns compact pass/fail evidence after the observer has stopped.
    ///
    /// Returns:
    ///   Verified-state presence and the number of disallowed outbound packets.
    func snapshot() -> (verifiedState: Bool, invalidPackets: Int) { (verifiedState, invalidPackets) }
}
