import Darwin
import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffDeliveryTests: XCTestCase {
    private let codexID = "11111111-1111-4111-8111-111111111111"
    private let engineID = "22222222-2222-4222-8222-222222222222"
    private var temporaryDirectories: [URL] = []

    /// Removes only fixture directories created by this test instance.
    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories = []
        super.tearDown()
    }

    /// Verifies a Codex queue receipt must name the exact selected native UUID.
    func testQueueReceiptRejectsWrongConversationAndMalformedMessage() {
        let messageID = "33333333-3333-4333-8333-333333333333"
        XCTAssertEqual(AgentHandoffDeliveryService.queueReceiptID(output: "Queued message \(messageID) for thread \(codexID).\n", targetID: codexID), messageID)
        XCTAssertNil(AgentHandoffDeliveryService.queueReceiptID(output: "Queued message \(messageID) for thread \(engineID).", targetID: codexID))
        XCTAssertNil(AgentHandoffDeliveryService.queueReceiptID(output: "queued successfully", targetID: codexID))
        XCTAssertNil(AgentHandoffDeliveryService.queueReceiptID(output: "Queued message invalid for thread \(codexID).", targetID: codexID))
    }

    /// Verifies a Claude engine identity cannot silently address a different native chat.
    func testClaudeRegistrationRequiresBothIdentitiesAndProtocol() throws {
        let target = claudeTarget()
        let record = try JSONDecoder().decode(AgentHandoffDeliveryService.ClaudeRegistration.self, from: Data("""
        {"pid":123,"sessionId":"\(engineID)","hostSessionId":"\(target.sessionID)","entrypoint":"claude-desktop","peerProtocol":1,"procStart":"Sat Oct 10 13:16:33 2026"}
        """.utf8))
        XCTAssertTrue(AgentHandoffDeliveryService.registrationMatches(record, target: target, filenamePID: 123))
        XCTAssertFalse(AgentHandoffDeliveryService.registrationMatches(record, target: target, filenamePID: 124))
        let anotherNative = AgentSessionDescriptor(sessionID: "local_44444444-4444-4444-8444-444444444444", application: .claudeCode, title: "Other", workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: engineID)
        XCTAssertFalse(AgentHandoffDeliveryService.registrationMatches(record, target: anotherNative, filenamePID: 123))
    }

    /// Verifies PID reuse cannot pass the registry generation check.
    func testClaudeProcessStartUsesExactKernelGeneration() {
        XCTAssertTrue(AgentHandoffDeliveryService.processStartMatches("Sat Oct 10 13:16:33 2026", kernelStartSeconds: 1_791_638_193))
        XCTAssertFalse(AgentHandoffDeliveryService.processStartMatches("Sat Oct 10 13:16:33 2026", kernelStartSeconds: 1_791_638_194))
        XCTAssertFalse(AgentHandoffDeliveryService.processStartMatches(nil, kernelStartSeconds: 1_791_638_193))
    }

    /// Verifies arbitrary socket paths and other process sockets are rejected.
    func testClaudeSocketPathsAreRestrictedToNativeInboxDirectories() {
        XCTAssertTrue(AgentHandoffDeliveryService.validSocketPath(URL(fileURLWithPath: "/tmp/cc-socks/123.sock"), processID: 123))
        XCTAssertTrue(AgentHandoffDeliveryService.validSocketPath(URL(fileURLWithPath: "/private/tmp/cc-socks-\(getuid())/123.sock"), processID: 123))
        XCTAssertFalse(AgentHandoffDeliveryService.validSocketPath(URL(fileURLWithPath: "/tmp/other/123.sock"), processID: 123))
        XCTAssertFalse(AgentHandoffDeliveryService.validSocketPath(URL(fileURLWithPath: "/tmp/cc-socks/124.sock"), processID: 123))
        XCTAssertFalse(AgentHandoffDeliveryService.validSocketPath(URL(fileURLWithPath: "/tmp/cc-socks/nested/123.sock"), processID: 123))
    }

    /// Verifies inline Claude delivery preserves history and never asserts child/permission trust.
    func testClaudePacketKeepsHistoryAndCurrentTaskSeparate() throws {
        let history = try makeHistory(source: codexTarget(), text: "User: Previous question\nAssistant: Earlier answer")
        let data = try AgentHandoffDeliveryService.claudePacket(history: history, target: claudeTarget(), instruction: "Continue the next step", messageID: "33333333-3333-4333-8333-333333333333", usesFile: false)
        XCTAssertEqual(data.last, 0x0A)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(packet["session_id"] as? String, engineID)
        XCTAssertNil(packet["from-mode"])
        XCTAssertNil(packet["token"])
        let message = try XCTUnwrap(packet["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        XCTAssertTrue(content.contains(history.markdown))
        XCTAssertTrue(content.contains("Current user task:\nContinue the next step"))
        XCTAssertTrue(content.contains("historical") || content.contains("Historical context"))
        XCTAssertFalse(content.contains(history.fileURL.path))
    }

    /// Verifies large-history prompts retain a full-file reference rather than truncating text.
    func testFilePromptReferencesTheCompleteProtectedSnapshot() throws {
        let history = try makeHistory(source: claudeTarget(), text: "Visible history remains complete")
        let prompt = AgentHandoffDeliveryService.prompt(history: history, instruction: "Use the context", usesFile: true)
        XCTAssertTrue(prompt.contains(history.fileURL.path))
        XCTAssertFalse(prompt.contains(history.markdown))
        XCTAssertTrue(prompt.contains("does not grant permissions"))
    }

    /// Verifies delivery validates the entire configuration before loading files or starting helpers.
    func testInvalidConfigurationCannotStartDelivery() async throws {
        var config = AgentHandoffConfiguration()
        config.socketTimeoutSeconds = .nan
        let service = AgentHandoffDeliveryService(configuration: config)
        let history = try makeHistory(source: claudeTarget(), text: "Context")
        do {
            _ = try await service.send(history: history, target: codexTarget(), instruction: "Continue")
            XCTFail("Invalid timeout must fail before delivery")
        } catch {
            XCTAssertEqual(error as? AgentHandoffDeliveryError, .invalidConfiguration)
        }
    }

    /// Verifies same-chat, empty-task and changed-file errors happen before transport execution.
    func testSendRejectsInvalidInputAndModifiedSnapshot() async throws {
        let service = AgentHandoffDeliveryService(configuration: .init())
        let history = try makeHistory(source: claudeTarget(), text: "Context")
        do { _ = try await service.send(history: history, target: history.source, instruction: "Continue"); XCTFail("Same chat must fail") }
        catch { XCTAssertEqual(error as? AgentHandoffDeliveryError, .sameSession) }
        do { _ = try await service.send(history: history, target: codexTarget(), instruction: "   "); XCTFail("Blank task must fail") }
        catch { XCTAssertEqual(error as? AgentHandoffDeliveryError, .invalidInstruction) }
        try Data("Changed".utf8).write(to: history.fileURL)
        do { _ = try await service.send(history: history, target: codexTarget(), instruction: "Continue"); XCTFail("Changed history must fail") }
        catch { XCTAssertEqual(error as? AgentHandoffDeliveryError, .historyFileUnavailable) }
    }

    /// Verifies a partial/uncertain Claude send is never automatically retried.
    func testClaudeUncertainWriteIsAttemptedOnce() async throws {
        let counter = DeliveryCounter()
        let service = AgentHandoffDeliveryService(
            configuration: .init(),
            installationLookup: { .init(application: $0, applicationURL: URL(fileURLWithPath: "/Applications/Claude.app"), commandURL: nil) },
            inboxLookup: { _, _, _ in .init(processID: 123, socketURL: URL(fileURLWithPath: "/tmp/cc-socks/123.sock"), processStartSeconds: 1) },
            inboxWriter: { _, _, _ in await counter.increment(); throw AgentHandoffDeliveryError.deliveryUncertain }
        )
        let history = try makeHistory(source: codexTarget(), text: "Context")
        do { _ = try await service.send(history: history, target: claudeTarget(), instruction: "Continue"); XCTFail("Uncertain write must remain uncertain") }
        catch { XCTAssertEqual(error as? AgentHandoffDeliveryError, .deliveryUncertain) }
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    /// Verifies the queue helper is capability-probed and receives exact IDs as separate arguments.
    func testCodexQueueUsesExactNativeUUIDAndOneSubmission() async throws {
        let application = try fakeCodexBundle()
        let counter = DeliveryCounter()
        let target = codexTarget()
        let messageID = "33333333-3333-4333-8333-333333333333"
        let service = AgentHandoffDeliveryService(
            configuration: .init(),
            installationLookup: { .init(application: $0, applicationURL: application, commandURL: nil) },
            commandRunner: { _, arguments, _ in
                await counter.record(arguments)
                if arguments == ["queue", "--help"] {
                    return .init(status: 0, output: "Usage: queue --thread UUID --message TEXT", timedOut: false, outputExceeded: false)
                }
                return .init(status: 0, output: "Queued message \(messageID) for thread \(target.sessionID).\n", timedOut: false, outputExceeded: false)
            }
        )
        let history = try makeHistory(source: claudeTarget(), text: "Earlier work")
        let receipt = try await service.send(history: history, target: target, instruction: "Next step with `literal` and $(literal)")
        XCTAssertEqual(receipt.route, .codexQueue)
        XCTAssertEqual(receipt.messageID, messageID)
        XCTAssertTrue(receipt.usesHistoryFile)
        let invocations = await counter.arguments
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], ["queue", "--help"])
        XCTAssertEqual(Array(invocations[1].prefix(4)), ["queue", "--thread", target.sessionID, "--message"])
        XCTAssertEqual(invocations[1].count, 5)
        XCTAssertTrue(invocations[1][4].contains("`literal` and $(literal)"))
        XCTAssertTrue(invocations[1][4].contains(history.fileURL.path))
    }

    /// Verifies a missing queue capability never falls back to a new CLI chat or a UI action.
    func testUnavailableQueueCannotSubmit() async throws {
        let application = try fakeCodexBundle()
        let counter = DeliveryCounter()
        let service = AgentHandoffDeliveryService(
            configuration: .init(),
            installationLookup: { .init(application: $0, applicationURL: application, commandURL: nil) },
            commandRunner: { _, arguments, _ in
                await counter.record(arguments)
                return .init(status: 1, output: "unrecognized subcommand queue", timedOut: false, outputExceeded: false)
            }
        )
        let history = try makeHistory(source: claudeTarget(), text: "Earlier work")
        do { _ = try await service.send(history: history, target: codexTarget(), instruction: "Continue"); XCTFail("Unsupported queue must stop") }
        catch { XCTAssertEqual(error as? AgentHandoffDeliveryError, .queueUnavailable) }
        let invocations = await counter.arguments
        XCTAssertEqual(invocations, [["queue", "--help"]])
    }

    /// Verifies an exited helper's inherited output cannot evade the total capture bound.
    func testExitedHelperWithInheritedWriterRemainsBounded() async throws {
        let application = try fakeCodexBundle()
        let helper = application.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let script = """
        #!/bin/sh
        if [ "$2" = "--help" ]; then
          printf 'queue --thread --message\n'
          exit 0
        fi
        /usr/bin/yes 'fixture output' 2>/dev/null &
        exit 0
        """
        try Data(script.utf8).write(to: helper)
        var config = AgentHandoffConfiguration()
        // macOS may delay the first execution of a fresh bundle fixture. The deadline
        // still bounds both phases; the 512-byte cap, not launch latency, is under test.
        config.processTimeoutSeconds = 3
        config.maximumProcessOutputBytes = 512
        let service = AgentHandoffDeliveryService(
            configuration: config,
            installationLookup: { .init(application: $0, applicationURL: application, commandURL: nil) }
        )
        let history = try makeHistory(source: claudeTarget(), text: "Fixture history")
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await service.send(history: history, target: codexTarget(), instruction: "Fixture task")
            XCTFail("An overflowing inherited stream must not confirm queueing")
        } catch {
            XCTAssertTrue(
                [AgentHandoffDeliveryError.deliveryUncertain, .commandFailed].contains(error as? AgentHandoffDeliveryError ?? .invalidConfiguration),
                "Unexpected bounded-helper error: \(error)"
            )
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, config.processTimeoutSeconds + config.processTerminationGraceSeconds * 4)
    }

    /// Verifies rapidly exiting helpers retain both capability output and their final queue receipt.
    ///
    /// Raises:
    ///   Error: The isolated executable fixture or protected history cannot be created.
    func testFastExitPreservesCapabilityAndQueueReceiptTail() async throws {
        let application = try fakeCodexBundle()
        let helper = application.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let messageID = "33333333-3333-4333-8333-333333333333"
        let target = codexTarget()
        let script = """
        #!/bin/sh
        if [ "$2" = "--help" ]; then
          printf 'queue --thread --message\\n'
        else
          printf 'Queued message \(messageID) for thread \(target.sessionID).\\n'
        fi
        exit 0
        """
        try Data(script.utf8).write(to: helper)
        let service = AgentHandoffDeliveryService(configuration: .init(),
            installationLookup: { .init(application: $0, applicationURL: application, commandURL: nil) })
        let history = try makeHistory(source: claudeTarget(), text: "Fixture history")
        // Repeated immediate exits exercise the read/EAGAIN-to-process-exit scheduling window.
        let repetitions = 64
        for attempt in 0..<repetitions {
            do {
                let receipt = try await service.send(history: history, target: target, instruction: "Fixture task")
                XCTAssertEqual(receipt.messageID, messageID)
            } catch {
                XCTFail("A fast helper lost capability or receipt output on attempt \(attempt + 1): \(error)")
                return
            }
        }
    }

    /// Verifies oversized Claude wire packets use the complete protected file instead of truncating.
    func testClaudeFrameLimitFallsBackToFullSnapshotFile() async throws {
        var configuration = AgentHandoffConfiguration()
        configuration.maximumClaudePacketBytes = 2_048
        let writer = PacketRecorder()
        let service = AgentHandoffDeliveryService(
            configuration: configuration,
            installationLookup: { .init(application: $0, applicationURL: URL(fileURLWithPath: "/Applications/Claude.app"), commandURL: nil) },
            inboxLookup: { _, _, _ in .init(processID: 123, socketURL: URL(fileURLWithPath: "/tmp/cc-socks/123.sock"), processStartSeconds: 1) },
            inboxWriter: { _, data, _ in await writer.record(data) }
        )
        let history = try makeHistory(source: codexTarget(), text: String(repeating: "Complete visible history. ", count: 500))
        let receipt = try await service.send(history: history, target: claudeTarget(), instruction: "Continue")
        XCTAssertTrue(receipt.usesHistoryFile)
        let recordedData = await writer.data
        let data = try XCTUnwrap(recordedData)
        XCTAssertLessThanOrEqual(data.count, configuration.maximumClaudePacketBytes)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(packet["message"] as? [String: Any])
        XCTAssertTrue((message["content"] as? String)?.contains(history.fileURL.path) ?? false)
    }

    /// Verifies the observed 198 KB history stays complete and inline with production defaults.
    ///
    /// Raises:
    ///   Error: The isolated history fixture cannot be prepared or delivered to the recorder.
    func testDefaultClaudeInlineLimitHandlesObserved198KBHistoryWithoutFileRead() async throws {
        let configuration = AgentHandoffConfiguration()
        let writer = PacketRecorder()
        let service = AgentHandoffDeliveryService(
            configuration: configuration,
            installationLookup: { .init(application: $0, applicationURL: URL(fileURLWithPath: "/Applications/Claude.app"), commandURL: nil) },
            inboxLookup: { _, _, _ in .init(processID: 123, socketURL: URL(fileURLWithPath: "/tmp/cc-socks/123.sock"), processStartSeconds: 1) },
            inboxWriter: { _, data, _ in await writer.record(data) }
        )
        let history = try makeHistory(source: codexTarget(), text: String(repeating: "V", count: 198_086))
        XCTAssertEqual(configuration.maximumInlineHistoryBytes, 262_144)
        let receipt = try await service.send(history: history, target: claudeTarget(), instruction: "Answer directly from the attached history; do not use tools.")
        XCTAssertFalse(receipt.usesHistoryFile)
        let recordedData = await writer.data
        let data = try XCTUnwrap(recordedData)
        XCTAssertLessThanOrEqual(data.count, configuration.maximumClaudePacketBytes)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(packet["priority"] as? String, "next")
        let message = try XCTUnwrap(packet["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? String)
        XCTAssertTrue(content.contains(history.markdown))
        XCTAssertFalse(content.contains(history.fileURL.path))
    }

    /// Verifies provider errors remain renderable when language changes without recreating state.
    func testErrorsSupportChineseAndEnglishAtDisplayTime() {
        let errors: [AgentHandoffDeliveryError] = [.invalidConfiguration, .sameSession, .invalidSession, .invalidInstruction, .historyFileUnavailable, .applicationUnavailable(.codex), .queueUnavailable, .commandFailed, .deliveryInProgress, .deliveryUncertain, .claudeSessionUnavailable, .claudeSessionAmbiguous, .socketUnavailable]
        for error in errors {
            XCTAssertNotEqual(error.message(language: .zh), error.message(language: .en))
            XCTAssertFalse(error.message(language: .zh).isEmpty)
            XCTAssertFalse(error.message(language: .en).isEmpty)
        }
    }

    /// Runs an opt-in handoff through the production service into the dedicated Claude test chat.
    ///
    /// Raises:
    ///   XCTSkip: The root has not explicitly enabled native live verification.
    ///   Error: Native lookup, complete history preparation or delivery failed.
    func testLiveCodexToClaude() async throws {
        try await runLiveHandoff(sourceApplication: .codex, targetApplication: .claudeCode)
    }

    /// Runs an opt-in handoff through the production service into the dedicated Codex test chat.
    ///
    /// Raises:
    ///   XCTSkip: The root has not explicitly enabled native live verification.
    ///   Error: Native lookup, complete history preparation or delivery failed.
    func testLiveClaudeToCodex() async throws {
        try await runLiveHandoff(sourceApplication: .claudeCode, targetApplication: .codex)
    }

    /// Dispatches only to the two fixed existing verification chats, never arbitrary user chats.
    ///
    /// Args:
    ///   sourceApplication: One of the two dedicated verification history sources.
    ///   targetApplication: The other dedicated verification chat.
    ///
    /// Raises:
    ///   XCTSkip: Live verification is disabled by default.
    ///   Error: Preparation, transport, identity or evidence output failed.
    private func runLiveHandoff(sourceApplication: AgentDesktopApplication, targetApplication: AgentDesktopApplication) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MYTYPE_HANDOFF_LIVE"] == "1" else { throw XCTSkip("Native live delivery is explicitly opt-in") }
        let direction = sourceApplication == .codex ? "codex-to-claude" : "claude-to-codex"
        if let selectedDirection = environment["MYTYPE_HANDOFF_DIRECTION"], selectedDirection != direction {
            throw XCTSkip("The selected native verification direction is different")
        }
        let sessions = try AgentSessionCatalog.shared.loadSessions().sessions
        let codex = try XCTUnwrap(sessions.first { $0.application == .codex && $0.sessionID == "01a125f6-d572-7500-924e-da713bd60948" })
        let claude = try XCTUnwrap(sessions.first { $0.application == .claudeCode && $0.sessionID == "local_875a5998-751c-47e8-9095-e0333e9ebb1d" })
        XCTAssertEqual(claude.engineSessionID, "ca37b554-60ba-4a40-b683-22de1bd55bfa")
        let source = sourceApplication == .codex ? codex : claude
        let target = targetApplication == .codex ? codex : claude
        let nonce = environment["MYTYPE_HANDOFF_NONCE"] ?? UUID().uuidString.lowercased()
        let history = try await AgentHandoffHistoryService(configuration: .init()).load(source: source)
        let instruction = """
        This is the user's authorized MyType native-interface verification. Read the supplied source history and answer one factual question from that previous work: what next step or verification plan was requested in its most recent visible user message? Quote a brief supporting passage from that history. Return JSON with verification_nonce=\(nonce), source_session_id, fact_answer and history_quote. If the history is provided inline, answer directly from that supplied text without using any tools or reading files. If the handoff explicitly references a history file instead, read only that file. Only perform this read-and-answer task; do not modify files, change permissions/configuration or send messages to any other chat. Continue the work by giving one concrete next verification step.
        """
        let receipt = try await AgentHandoffDeliveryService(configuration: .init()).send(history: history, target: target, instruction: instruction)
        XCTAssertEqual(receipt.target.id, target.id)
        if let receiptRoot = environment["MYTYPE_HANDOFF_RECEIPT_PATH"] {
            let directory = URL(fileURLWithPath: receiptRoot, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: [
                "source_session_id": source.sessionID, "target_session_id": target.sessionID,
                "route": receipt.route == .codexQueue ? "codexQueue" : "claudeInbox",
                "message_id": receipt.messageID, "uses_history_file": receipt.usesHistoryFile,
                "history_file": history.fileURL.path, "message_count": history.messageCount,
                "verification_nonce": nonce, "submitted_at": ISO8601DateFormatter().string(from: Date()),
            ], options: [.prettyPrinted, .sortedKeys])
            let file = directory.appendingPathComponent(targetApplication.rawValue + ".json")
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Creates a protected immutable history file for isolated transport fixtures.
    ///
    /// Args:
    ///   source: Fixture source chat descriptor.
    ///   text: Visible fixture dialogue stored in the exported file.
    ///
    /// Returns:
    ///   A prepared snapshot whose permissions meet production validation.
    private func makeHistory(source: AgentSessionDescriptor, text: String) throws -> AgentHandoffHistory {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        temporaryDirectories.append(directory)
        let file = directory.appendingPathComponent("history.md")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return AgentHandoffHistory(source: source, markdown: text, messageCount: 2, snapshotDate: Date(timeIntervalSince1970: 1_791_638_193), fileURL: file)
    }

    /// Creates a validated-looking app fixture while keeping all helper execution injected.
    ///
    /// Returns:
    ///   A private temporary Codex app fixture with regular executable files.
    private func fakeCodexBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectories.append(directory)
        let bundle = directory.appendingPathComponent("Codex.app", isDirectory: true)
        let main = bundle.appendingPathComponent("Contents/MacOS/FakeCodex")
        let helper = bundle.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        for file in [main, helper] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("fixture-only".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": AgentDesktopApplication.codex.bundleIdentifier, "CFBundleExecutable": "FakeCodex"], format: .xml, options: 0)
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    /// Creates the native Codex fixture identity without consulting the user's metadata.
    ///
    /// Returns:
    ///   A deterministic existing-chat descriptor.
    private func codexTarget() -> AgentSessionDescriptor {
        .init(sessionID: codexID, application: .codex, title: "Codex fixture", workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .codexDeepLink)
    }

    /// Creates the native and engine Claude fixture identities without reading user history.
    ///
    /// Returns:
    ///   A deterministic linked Desktop descriptor.
    private func claudeTarget() -> AgentSessionDescriptor {
        .init(sessionID: "local_\(engineID)", application: .claudeCode, title: "Claude fixture", workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .claudeNativeDeepLink, engineSessionID: engineID)
    }
}

private actor DeliveryCounter {
    private(set) var value = 0
    private(set) var arguments: [[String]] = []

    /// Counts attempted writes so fixtures can detect accidental automatic retries.
    func increment() { value += 1 }

    /// Records direct helper arguments for deterministic queue capability/submission fixtures.
    ///
    /// Args:
    ///   arguments: Argument array supplied to the injected runner.
    func record(_ arguments: [String]) { self.arguments.append(arguments) }
}

private actor PacketRecorder {
    private(set) var data: Data?

    /// Records the single serialized frame accepted by an injected socket writer.
    ///
    /// Args:
    ///   data: Complete bounded native inbox frame.
    func record(_ data: Data) { self.data = data }
}
