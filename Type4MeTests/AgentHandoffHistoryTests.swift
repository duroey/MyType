import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffHistoryTests: XCTestCase {
    private let codexID = "11111111-1111-4111-8111-111111111111"
    private let claudeID = "22222222-2222-4222-8222-222222222222"

    private actor FixtureTransport {
        private let replies: [Result<Data, AgentHandoffHistoryError>]
        private var index = 0
        private var received: [URLRequest] = []

        /// Creates a deterministic archive transport without live network access.
        ///
        /// Args:
        ///   replies: Ordered responses, including explicit HTTP failures.
        ///   policy: Running archive policy returned by the mandatory settings handshake.
        ///   authenticated: Whether this fixture returns a dummy native loopback bootstrap token.
        ///   nativeExport: Whether the server advertises the fork-aware native export capability.
        init(_ replies: [Result<Data, AgentHandoffHistoryError>], policy: String = "dialogue", authenticated: Bool = false,
             nativeExport: Bool = false) {
            let authentication = authenticated ? ",\"require_auth\":true,\"auth_token\":\"fixture-bootstrap-token\"" : ""
            let capability = nativeExport ? ",\"visible_history_export\":true" : ""
            self.replies = [.success(Data("{\"archive_content\":\"\(policy)\"\(authentication)\(capability)}".utf8))] + replies
        }

        /// Returns one fixture reply while recording the exact request.
        ///
        /// Args:
        ///   request: Request emitted by the history exporter.
        ///
        /// Returns:
        ///   The next fixture response.
        ///
        /// Raises:
        ///   AgentHandoffHistoryError: Fixture failure or unexpected extra request.
        func load(_ request: URLRequest) throws -> Data {
            received.append(request)
            guard index < replies.count else { throw AgentHandoffHistoryError.invalidResponse }
            defer { index += 1 }
            return try replies[index].get()
        }

        /// Returns captured requests for pagination and selected-sync assertions.
        ///
        /// Returns:
        ///   Requests in their original order.
        func requests() -> [URLRequest] { received }
    }

    /// Verifies native and engine identities stay distinct across provider boundaries.
    ///
    /// Raises:
    ///   Error: An exact provider-qualified source identity cannot be resolved.
    func testArchiveIdentityRequiresExactNativeAndEngineIdentifiers() throws {
        XCTAssertEqual(try AgentHandoffHistoryService.archiveIdentifier(for: codex()), "codex:" + codexID)
        XCTAssertEqual(try AgentHandoffHistoryService.archiveIdentifier(for: claude()), claudeID)
        let missingEngine = AgentSessionDescriptor(sessionID: "local_test", application: .claudeCode,
            title: "Task", workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .claudeNativeDeepLink)
        XCTAssertThrowsError(try AgentHandoffHistoryService.archiveIdentifier(for: missingEngine)) { error in
            XCTAssertEqual(error as? AgentHandoffHistoryError, .invalidSource)
        }
    }

    /// Verifies full sparse pagination, selected refresh, visible filtering and private file permissions.
    ///
    /// Raises:
    ///   Error: A complete deterministic snapshot cannot be prepared.
    func testCompletePaginationExportsOnlyVisibleDialogueAndProtectsSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        var firstAssistant = message(id: id, ordinal: 4, role: "assistant", content: "可见回复 / Visible reply")
        firstAssistant["thinking_text"] = "private thinking payload"
        firstAssistant["tool_calls"] = [["input_json": "private tool arguments", "result_content": "private tool output"]]
        let transport = FixtureTransport([
            .success(metadata), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: "用户意图 / User intent"), firstAssistant])),
            .success(try page([message(id: id, ordinal: 7, role: "assistant", content: ""),
                              message(id: id, ordinal: 9, role: "user", content: "hidden system", isSystem: true)])),
            .success(try page([message(id: id, ordinal: 11, role: "assistant", content: "hidden sidechain", isSidechain: true),
                              message(id: id, ordinal: 13, role: "user", content: "hidden tool result", subtype: "tool_result")])),
            .success(try page([message(id: id, ordinal: 15, role: "tool", content: "hidden tool role"),
                              message(id: id, ordinal: 16, role: "user", content: " \n ")])),
            .success(try page([])), .success(metadata),
        ], authenticated: true)
        var configuration = AgentHandoffConfiguration()
        configuration.pageSize = 2
        let history = try await AgentHandoffHistoryService(configuration: configuration, outputDirectory: directory,
            requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
        XCTAssertEqual(history.messageCount, 2)
        XCTAssertTrue(history.markdown.contains("用户意图 / User intent"))
        XCTAssertTrue(history.markdown.contains("可见回复 / Visible reply"))
        for hidden in ["private thinking", "private tool", "hidden system", "hidden sidechain", "hidden tool"] {
            XCTAssertFalse(history.markdown.contains(hidden), hidden)
        }
        XCTAssertEqual(try String(contentsOf: history.fileURL, encoding: .utf8), history.markdown)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: history.fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: history.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let requests = await transport.requests()
        XCTAssertEqual(requests[0].url?.path, "/api/v1/settings")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        for request in requests.dropFirst() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bootstrap-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:18742")
        }
        XCTAssertEqual(requests[2].httpMethod, "POST")
        let syncBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(syncBody["expected_id"] as? String, id)
        XCTAssertEqual(syncBody["path"] as? String, "/fixture/native/source.jsonl")
        XCTAssertNil(syncBody["id"])
        XCTAssertEqual(syncBody["subagents"] as? Bool, false)
        let pages = requests.filter { $0.url?.path.hasSuffix("/messages") ?? false }
        XCTAssertEqual(pages.compactMap { parameters($0)["from"] }, ["0", "5", "10", "14", "17"])
        XCTAssertNil(parameters(pages[0])["expected_revision"])
        for request in pages.dropFirst() {
            XCTAssertEqual(parameters(request)["expected_revision"], "1")
            XCTAssertEqual(parameters(request)["evidence_source"], "archive+binding")
        }
    }

    /// Verifies unarchived Codex sources use only their exact native path and verified header UUID.
    ///
    /// Raises:
    ///   Error: A deterministic native source fixture cannot be prepared.
    func testMissingCodexArchiveImportsAuthoritativeSourcePath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let rollout = home.appendingPathComponent(".codex/sessions/2026/10/10/rollout.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": codexID]])
        try (header + Data("\n".utf8)).write(to: rollout)
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        let transport = FixtureTransport([.failure(.rejected(status: 404)), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: "Continue this task")])),
            .success(try page([])), .success(metadata)])
        let history = try await AgentHandoffHistoryService(configuration: .init(),
            outputDirectory: directory.appendingPathComponent("exports"),
            requestLoader: { request, _ in try await transport.load(request) }, sourceHomeDirectory: home)
            .load(source: codex(transcriptPath: rollout.path))
        XCTAssertEqual(history.messageCount, 1)
        let requests = await transport.requests()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, rollout.path)
        XCTAssertEqual(body["expected_id"] as? String, id)
        XCTAssertNil(body["id"])
    }

    /// Verifies an unarchived Claude conversation imports its unique exact engine UUID filename.
    ///
    /// Raises:
    ///   Error: A deterministic native source fixture cannot be prepared.
    func testMissingClaudeArchiveUsesUniqueEngineFileAndVerifiesBackendIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let transcript = home.appendingPathComponent(".claude/projects/opaque-project/" + claudeID + ".jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("native source read by AgentsView".utf8).write(to: transcript)
        let metadata = try session(id: claudeID, agent: "claude")
        let transport = FixtureTransport([.failure(.rejected(status: 404)), .success(metadata),
            .success(try page([message(id: claudeID, ordinal: 0, role: "user", content: "Claude task")])),
            .success(try page([])), .success(metadata)])
        let history = try await AgentHandoffHistoryService(configuration: .init(),
            outputDirectory: directory.appendingPathComponent("exports"),
            requestLoader: { request, _ in try await transport.load(request) }, sourceHomeDirectory: home).load(source: claude())
        XCTAssertEqual(history.source.sessionID, "local_" + claudeID)
        let requests = await transport.requests()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, transcript.path)
        XCTAssertEqual(body["expected_id"] as? String, claudeID)
    }

    /// Verifies a changed transcript never produces a mixed snapshot or any export file.
    ///
    /// Raises:
    ///   Error: Fixture data cannot be serialized.
    func testRevisionChangeFailsInsteadOfMixingPages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        let transport = FixtureTransport([.success(metadata), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: "old revision")])),
            .success(try page([message(id: id, ordinal: 1, role: "assistant", content: "new revision")], revision: "2"))])
        do {
            _ = try await AgentHandoffHistoryService(configuration: .init(), outputDirectory: directory,
                requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
            XCTFail("A changed source must not export")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .sourceChanged)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Verifies exhausting the page budget fails without silently exporting the first page.
    ///
    /// Raises:
    ///   Error: Fixture data cannot be serialized.
    func testPageBudgetRejectsIncompleteHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        let transport = FixtureTransport([.success(metadata), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: "First page")] ))])
        var configuration = AgentHandoffConfiguration()
        configuration.maximumPages = 1
        do {
            _ = try await AgentHandoffHistoryService(configuration: configuration, outputDirectory: directory,
                requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
            XCTFail("An incomplete history must not export")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .incompleteHistory)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Verifies source refresh cannot substitute a different provider or conversation.
    ///
    /// Raises:
    ///   Error: Fixture data cannot be serialized.
    func testRefreshedIdentityMustMatchExactSelectedConversation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureTransport([.success(try session(id: "codex:" + codexID)),
                                         .success(try session(id: claudeID, agent: "claude"))])
        do {
            _ = try await AgentHandoffHistoryService(configuration: .init(), outputDirectory: directory,
                requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
            XCTFail("A different refreshed source must not export")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .invalidResponse)
        }
    }

    /// Verifies duplicate ordinals are rejected rather than counted as independent visible messages.
    ///
    /// Raises:
    ///   Error: Fixture data cannot be serialized.
    func testDuplicateOrdinalsAreRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        let transport = FixtureTransport([.success(metadata), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: "one"),
                              message(id: id, ordinal: 0, role: "assistant", content: "duplicate")] ))])
        do {
            _ = try await AgentHandoffHistoryService(configuration: .init(), outputDirectory: directory,
                requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
            XCTFail("Duplicate ordinals must fail")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .invalidResponse)
        }
    }

    /// Verifies complete byte limits fail explicitly before writing a partial snapshot.
    ///
    /// Raises:
    ///   Error: Fixture data cannot be serialized.
    func testByteLimitNeverTruncatesAnOversizedConversation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "codex:" + codexID
        let metadata = try session(id: id)
        let transport = FixtureTransport([.success(metadata), .success(metadata),
            .success(try page([message(id: id, ordinal: 0, role: "user", content: String(repeating: "x", count: 4_096))]))])
        var configuration = AgentHandoffConfiguration()
        configuration.maximumHistoryBytes = 1_024
        configuration.maximumInlineHistoryBytes = 1_024
        do {
            _ = try await AgentHandoffHistoryService(configuration: configuration, outputDirectory: directory,
                requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
            XCTFail("Oversized histories must not export")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .historyTooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Verifies source ID probes reject a native path whose header belongs to another conversation.
    ///
    /// Raises:
    ///   Error: Fixture source files cannot be prepared.
    func testUnarchivedCodexHeaderMustMatchSelectedNativeUUID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home")
        let rollout = home.appendingPathComponent(".codex/sessions/other.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": claudeID]])
        try (data + Data("\n".utf8)).write(to: rollout)
        let transport = FixtureTransport([.failure(.rejected(status: 404))])
        do {
            _ = try await AgentHandoffHistoryService(configuration: .init(),
                outputDirectory: directory.appendingPathComponent("exports"),
                requestLoader: { request, _ in try await transport.load(request) }, sourceHomeDirectory: home)
                .load(source: codex(transcriptPath: rollout.path))
            XCTFail("Another session's source must never be imported")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .sourceUnavailable)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
    }

    /// Verifies full or unknown archives are rejected before any source is refreshed or exported.
    ///
    /// Raises:
    ///   Error: An isolated snapshot directory cannot be prepared.
    func testVisibleDialoguePolicyFailsClosedBeforeSourceRequests() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for policy in ["full", "transcript", "", "unknown"] {
            let transport = FixtureTransport([], policy: policy)
            do {
                _ = try await AgentHandoffHistoryService(configuration: .init(), outputDirectory: directory,
                    requestLoader: { request, _ in try await transport.load(request) },
                sourceLocator: { _, _, _ in URL(fileURLWithPath: "/fixture/native/source.jsonl") }).load(source: codex())
                XCTFail("A non-dialogue archive must never export")
            } catch {
                XCTAssertEqual(error as? AgentHandoffHistoryError, .visibleDialogueRequired)
            }
            let requests = await transport.requests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].url?.path, "/api/v1/settings")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Rejects inherited Codex history before the archive can omit replayed parent text.
    ///
    /// Raises:
    ///   Error: An isolated native fork source cannot be prepared.
    func testCodexForkFailsExplicitlyInsteadOfExportingOnlyChildMessages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let rollout = home.appendingPathComponent(".codex/sessions/fork.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta",
            "payload": ["id": codexID, "forked_from_id": claudeID]])
        try (header + Data("\n".utf8)).write(to: rollout)
        let transport = FixtureTransport([.failure(.rejected(status: 404))])
        do {
            _ = try await AgentHandoffHistoryService(configuration: .init(),
                outputDirectory: directory.appendingPathComponent("exports"),
                requestLoader: { request, _ in try await transport.load(request) }, sourceHomeDirectory: home)
                .load(source: codex(transcriptPath: rollout.path))
            XCTFail("Inherited history must not be silently omitted")
        } catch {
            XCTAssertEqual(error as? AgentHandoffHistoryError, .inheritedHistoryUnsupported)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("exports").path))
    }

    /// Uses the native capability for copied fork history without reading archive pages.
    ///
    /// Raises:
    ///   Error: An isolated source and complete native response cannot be prepared.
    func testNativeExportPreservesInheritedTextAndAuthenticatesExactSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let rollout = home.appendingPathComponent(".codex/sessions/fork.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta",
            "payload": ["id": codexID, "forked_from_id": claudeID]])
        try (header + Data("\n".utf8)).write(to: rollout)
        let id = "codex:" + codexID
        let response = try JSONSerialization.data(withJSONObject: ["id": id, "agent": "codex",
            "recorded_through": "2026-10-10T12:00:04Z", "source_revision": "fixture-stable-fork",
            "messages": [message(id: id, ordinal: 0, role: "user", content: "Inherited visible task"),
                         message(id: id, ordinal: 3, role: "assistant", content: "Own branch answer")]])
        let transport = FixtureTransport([.success(response)], policy: "full", authenticated: true, nativeExport: true)
        let history = try await AgentHandoffHistoryService(configuration: .init(),
            outputDirectory: directory.appendingPathComponent("exports"),
            requestLoader: { request, _ in try await transport.load(request) }, sourceHomeDirectory: home)
            .load(source: codex(transcriptPath: rollout.path))
        XCTAssertEqual(history.messageCount, 2)
        XCTAssertTrue(history.markdown.contains("Inherited visible task"))
        XCTAssertTrue(history.markdown.contains("Own branch answer"))
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.path, "/api/v1/sessions/visible-history")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bootstrap-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(body["expected_id"] as? String, id)
        XCTAssertEqual(body["path"] as? String, rollout.path)
        XCTAssertNil(body["id"])
    }

    /// Verifies external endpoints, invalid limits and semantic bilingual errors.
    ///
    /// Raises:
    ///   Error: Valid default configuration was rejected.
    func testConfigurationBoundsAndBilingualErrors() throws {
        XCTAssertNoThrow(try AgentHandoffConfiguration().validatedEndpoint())
        for endpoint in ["http://example.com", "http://user:secret@127.0.0.1", "http://127.0.0.1/other"] {
            XCTAssertThrowsError(try AgentHandoffConfiguration(endpoint: endpoint).validatedEndpoint())
        }
        XCTAssertThrowsError(try AgentHandoffConfiguration(pageSize: 1_001).validatedEndpoint())
        XCTAssertThrowsError(try AgentHandoffConfiguration(maximumPages: 0).validatedEndpoint())
        XCTAssertTrue(AgentHandoffHistoryError.sourceChanged.message(language: .zh).contains("变化"))
        XCTAssertTrue(AgentHandoffHistoryError.sourceChanged.message(language: .en).contains("changed"))
    }

    /// Creates an isolated directory with canonical parents for source-file safety fixtures.
    ///
    /// Returns:
    ///   A unique existing temporary directory.
    ///
    /// Raises:
    ///   Error: The directory cannot be created.
    private func temporaryDirectory() throws -> URL {
        // Foundation normalizes /private/var back to the system /var symlink.
        // Keep strict nonlink fixtures inside the isolated test cache instead.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Type4MeTests/AgentHandoffFixtures", isDirectory: true)
            .appendingPathComponent("mytype-handoff-history-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Creates an exact Codex descriptor without reading local metadata.
    ///
    /// Args:
    ///   transcriptPath: Optional authoritative native path for first-time archive import.
    ///
    /// Returns:
    ///   A fixture native conversation.
    private func codex(transcriptPath: String? = nil) -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: codexID, application: .codex, title: "中文任务 / Task",
            workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .codexDeepLink,
            transcriptPath: transcriptPath)
    }

    /// Creates an exact Claude native-to-engine binding without guessing from a title.
    ///
    /// Returns:
    ///   A fixture native Claude conversation.
    private func claude() -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: "local_" + claudeID, application: .claudeCode,
            title: "Claude task", workspacePath: nil, updatedAt: 0, matchTexts: [],
            openCapability: .claudeNativeDeepLink, engineSessionID: claudeID)
    }

    /// Serializes the narrow archive metadata response.
    ///
    /// Args:
    ///   id: Exact archive session identity.
    ///   agent: Exact archive provider name.
    ///
    /// Returns:
    ///   A complete JSON metadata response.
    ///
    /// Raises:
    ///   Error: The fixture cannot be serialized.
    private func session(id: String, agent: String = "codex") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "agent": agent,
            "started_at": "2026-10-10T19:00:00Z", "ended_at": "2026-10-10T19:44:33.000Z", "transcript_revision": "1"])
    }

    /// Creates a message fixture with explicit hidden-content markers.
    ///
    /// Args:
    ///   id: Exact archive session identity.
    ///   ordinal: Archive message ordinal, which may contain role-filtered gaps.
    ///   role: Archive role.
    ///   content: Text to include or omit according to the visible projection.
    ///   isSystem: Whether the row was injected system content.
    ///   isSidechain: Whether the row belongs to a subordinate conversation.
    ///   subtype: Optional tool-result marker.
    ///
    /// Returns:
    ///   A message dictionary consumed by the real narrow decoder.
    private func message(
        id: String, ordinal: Int, role: String, content: String,
        isSystem: Bool = false, isSidechain: Bool = false, subtype: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = ["session_id": id, "ordinal": ordinal, "role": role, "content": content,
            "timestamp": "2026-10-10T19:44:33.000Z", "is_system": isSystem, "is_sidechain": isSidechain]
        if let subtype { result["source_subtype"] = subtype }
        return result
    }

    /// Serializes page bounds and stable archive bindings, including a final empty page.
    ///
    /// Args:
    ///   rows: Messages in ascending ordinal order.
    ///   revision: Transcript revision emitted by the backend.
    ///
    /// Returns:
    ///   Complete JSON for one deterministic response page.
    ///
    /// Raises:
    ///   Error: The fixture cannot be serialized.
    private func page(_ rows: [[String: Any]], revision: String = "1") throws -> Data {
        var result: [String: Any] = ["messages": rows, "count": rows.count,
            "transcript_revision": revision, "evidence_source": "archive+binding"]
        if let first = rows.first, let last = rows.last {
            result["first_ordinal"] = first["ordinal"]
            result["last_ordinal"] = last["ordinal"]
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Extracts preserved query values from a fixture request.
    ///
    /// Args:
    ///   request: An emitted message-page request.
    ///
    /// Returns:
    ///   Explicit pagination and revision-binding parameters.
    private func parameters(_ request: URLRequest) -> [String: String] {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}
