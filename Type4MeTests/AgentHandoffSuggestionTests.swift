import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffSuggestionTests: XCTestCase {
    /// Checks that production JSON and development defaults describe the same bounded behavior.
    ///
    /// Raises:
    ///   Error: A packaged prompt is malformed or diverges from the development defaults.
    func testPackagedConfigurationMatchesDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Type4Me/Resources/AgentHandoffSuggestionConfig.json"))
        let packaged = try JSONDecoder().decode(AgentHandoffSuggestionConfiguration.self, from: data)
        try packaged.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(packaged), try encoder.encode(AgentHandoffSuggestionConfiguration()))
    }

    /// Checks literal direction constraints and relative receiver context without a topic-specific rule.
    func testRolePlanPreservesDirectionAndRelativeContext() {
        let configuration = AgentHandoffSuggestionConfiguration()
        let plan = AgentHandoffSuggestionService.rolePlan(
            "CodeX 里研究转录延迟的会话，把这个工作交给 Cloud 中相同主题的会话接手", configuration: configuration
        )
        XCTAssertEqual(plan.source.provider, "codex")
        XCTAssertEqual(plan.destination.provider, "claude")
        XCTAssertTrue(plan.destination.query.contains("转录延迟"))
        let reverse = AgentHandoffSuggestionService.rolePlan("把 Claude 的设计工作交给 Codex 的界面会话", configuration: configuration)
        XCTAssertEqual(reverse.source.provider, "claude")
        XCTAssertEqual(reverse.destination.provider, "codex")
        let fromTo = AgentHandoffSuggestionService.rolePlan("从 Claude 的接口研究到 Codex 的实现会话", configuration: configuration)
        XCTAssertEqual(fromTo.source.provider, "claude")
        XCTAssertEqual(fromTo.destination.provider, "codex")
        let english = AgentHandoffSuggestionService.rolePlan("Transfer Claude research to Codex implementation", configuration: configuration)
        XCTAssertEqual(english.source.provider, "claude")
        XCTAssertEqual(english.destination.provider, "codex")
    }

    /// Checks unsupported grammar and conflicting provider mentions never manufacture a direction.
    func testUnsupportedGrammarFallsBackAndConflictingProviderStaysUnspecified() {
        let configuration = AgentHandoffSuggestionConfiguration()
        let original = "Claude 接收一下之前 Codex 的进展"
        let plan = AgentHandoffSuggestionService.rolePlan(original, configuration: configuration)
        XCTAssertEqual(plan.source.query, original)
        XCTAssertEqual(plan.destination.query, original)
        XCTAssertNil(plan.source.provider)
        XCTAssertNil(plan.destination.provider)
        let conflicting = AgentHandoffSuggestionService.rolePlan("Codex 或 Claude 的研究交给 Claude", configuration: configuration)
        XCTAssertNil(conflicting.source.provider)
    }

    /// Checks provider aliases remain whole English tokens while allowing adjacent Chinese characters.
    func testProviderAliasesDoNotCaptureProductNameSubstrings() {
        let configuration = AgentHandoffSuggestionConfiguration()
        for topic in ["Cloudflare", "iCloud", "CloudKit", "MyCodexTool", "CodecXYZ"] {
            let plan = AgentHandoffSuggestionService.rolePlan("把 \(topic) 研究交给 Claude实现", configuration: configuration)
            XCTAssertNil(plan.source.provider)
            XCTAssertEqual(plan.destination.provider, "claude")
        }
        let explicit = AgentHandoffSuggestionService.rolePlan("把CodeX里的研究交给Cloud里的实现会话", configuration: configuration)
        XCTAssertEqual(explicit.source.provider, "codex")
        XCTAssertEqual(explicit.destination.provider, "claude")
    }

    /// Checks exact native mapping, independent forks, provider filtering and candidate bounds.
    func testCandidateAggregationRejectsWrongProviderAndAmbiguousNativeMapping() {
        let source = session(1)
        let fork = session(2)
        let target = session(3, claude: true)
        let hits = [hit(source), hit(source), hit(target), hit(fork), AgentsViewSearchHit(sessionID: "codex:untrusted", agent: "codex", snippet: "x")]
        var settings = AgentHandoffSuggestionConfiguration()
        settings.maximumCandidatesPerRole = 2
        let candidates = AgentHandoffSuggestionService.candidates(hits, sessions: [source, fork, target], provider: "codex", configuration: settings)
        XCTAssertEqual(candidates.map(\.session.id), [source.id, fork.id])
        let duplicate = AgentHandoffSuggestionService.candidates([hit(target)], sessions: [target, target], provider: "claude", configuration: settings)
        XCTAssertTrue(duplicate.isEmpty)
    }

    /// Checks the wider local query cannot alter the normal wake search limit or escape its provider allowlist.
    ///
    /// Raises:
    ///   Error: A bounded local request cannot be built.
    func testWiderRequestHasExplicitProviderAndPreservesNormalLimit() throws {
        let normal = AgentsViewSearchService.Configuration()
        var wider = normal
        wider.maximumResults = 500
        let request = try AgentsViewSearchService.request(query: "A+B", configuration: wider, agent: "claude")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "agent" })?.value, "claude")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "pattern" })?.value, "A+B")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "500")
        XCTAssertEqual(normal.maximumResults, 20)
        XCTAssertThrowsError(try AgentsViewSearchService.request(query: "A", configuration: wider, agent: "untrusted"))
    }

    /// Checks typed choices contain bounded evidence and never expose transcript paths or native IDs.
    ///
    /// Raises:
    ///   Error: Payload construction or parsing fails.
    func testPayloadUsesOpaqueRoleChoicesWithNoneAndAmbiguous() throws {
        let source = candidate(session(1))
        let target = candidate(session(2, claude: true))
        let data = try AgentHandoffSuggestionService.payload("把研究交给实现", sources: [source], targets: [target], configuration: .init())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["user_confirmation_required"] as? Bool, true)
        let evidence = try XCTUnwrap(state["candidates"] as? [[String: Any]])
        XCTAssertEqual(evidence.first?["workspace_name"] as? String, "project")
        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        let sourceOptions = try XCTUnwrap(questions["source"]?["criteria"] as? [String: String])
        let targetOptions = try XCTUnwrap(questions["destination"]?["criteria"] as? [String: String])
        XCTAssertEqual(Set(sourceOptions.keys), ["source_0", "none", "ambiguous"])
        XCTAssertEqual(Set(targetOptions.keys), ["destination_0", "none", "ambiguous"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(source.session.sessionID))
        XCTAssertFalse(text.contains("/synthetic/private"))
    }

    /// Checks absent or invalid workspace metadata does not create project evidence.
    ///
    /// Raises:
    ///   Error: The isolated request cannot be encoded or parsed.
    func testMissingOrInvalidWorkspaceOmitsName() throws {
        let original = session(1)
        for path: String? in [nil, "", "relative/project", "/", " /synthetic/project", "/synthetic/\0project", "/synthetic/   /"] {
            let descriptor = AgentSessionDescriptor(
                sessionID: original.sessionID, application: original.application, title: original.title,
                workspacePath: path, updatedAt: original.updatedAt, matchTexts: [],
                openCapability: original.openCapability
            )
            let data = try AgentHandoffSuggestionService.payload("把研究交给实现", sources: [candidate(descriptor)], targets: [], configuration: .init())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            let evidence = try XCTUnwrap(state["candidates"] as? [[String: Any]])
            XCTAssertNil(evidence.first?["workspace_name"])
        }
    }

    /// Checks valid choices, explicit none and ambiguity yield only editable native suggestions.
    ///
    /// Raises:
    ///   Error: A valid response fixture fails validation.
    func testDecodeAllowsSuggestionButNoneStaysEmpty() throws {
        let sources = [candidate(session(1))]
        let targets = [candidate(session(2, claude: true)), candidate(session(3, claude: true))]
        let data = try response(source: "source_0", target: "ambiguous", sourceCount: 1, targetCount: 2)
        let result = try AgentHandoffSuggestionService.decodeResponse(data, sources: sources, targets: targets, configuration: .init())
        XCTAssertEqual(result.sourceID, sources[0].session.id)
        XCTAssertEqual(result.targetID, targets[0].session.id)
        XCTAssertTrue(result.ambiguous)
        let none = try AgentHandoffSuggestionService.decodeResponse(
            response(source: "none", target: "none", sourceCount: 1, targetCount: 2),
            sources: sources, targets: targets, configuration: .init()
        )
        XCTAssertNil(none.sourceID)
        XCTAssertNil(none.targetID)
    }

    /// Checks cross-role labels, unrecognized model outputs and a duplicate source/receiver cannot be sent onward.
    ///
    /// Raises:
    ///   Error: Fixture encoding fails.
    func testInvalidChoicesAreRejectedAndSameSessionClearsReceiver() throws {
        let candidates = [candidate(session(1))]
        let valid = try response(source: "source_0", target: "destination_0", sourceCount: 1, targetCount: 1)
        let same = try AgentHandoffSuggestionService.decodeResponse(valid, sources: candidates, targets: candidates, configuration: .init())
        XCTAssertEqual(same.sourceID, candidates[0].session.id)
        XCTAssertNil(same.targetID)
        XCTAssertTrue(same.ambiguous)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var answers = try XCTUnwrap(object["answers"] as? [String: [String: Any]])
        answers["destination"]?["choice"] = "source_0"
        object["answers"] = answers
        XCTAssertThrowsError(try AgentHandoffSuggestionService.decodeResponse(JSONSerialization.data(withJSONObject: object), sources: candidates, targets: candidates, configuration: .init()))
        object["model"] = "other-model"
        XCTAssertThrowsError(try AgentHandoffSuggestionService.decodeResponse(JSONSerialization.data(withJSONObject: object), sources: candidates, targets: candidates, configuration: .init()))
    }

    /// Checks an ambiguous empty role stays unselected and malformed distributions fail closed.
    ///
    /// Raises:
    ///   Error: Response fixture construction fails.
    func testEmptyPoolCannotBecomeASelectionAndBadProbabilitiesAreRejected() throws {
        let empty = try response(source: "ambiguous", target: "none", sourceCount: 0, targetCount: 0)
        let result = try AgentHandoffSuggestionService.decodeResponse(empty, sources: [], targets: [], configuration: .init())
        XCTAssertNil(result.sourceID)
        XCTAssertNil(result.targetID)
        let candidates = [candidate(session(1))]
        let valid = try response(source: "source_0", target: "none", sourceCount: 1, targetCount: 0)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var answers = try XCTUnwrap(object["answers"] as? [String: [String: Any]])
        answers["source"]?["probabilities"] = ["source_0": 0.1, "none": 0.9, "ambiguous": 0.0]
        object["answers"] = answers
        XCTAssertThrowsError(try AgentHandoffSuggestionService.decodeResponse(JSONSerialization.data(withJSONObject: object), sources: candidates, targets: [], configuration: .init()))
        answers["source"]?["probabilities"] = ["source_0": 1.0, "none": 0.9, "ambiguous": 0.0]
        object["answers"] = answers
        XCTAssertThrowsError(try AgentHandoffSuggestionService.decodeResponse(JSONSerialization.data(withJSONObject: object), sources: candidates, targets: [], configuration: .init()))
    }

    /// Checks ranking failures retain usable search candidates without inventing an automatic selection.
    ///
    /// Raises:
    ///   Error: The isolated search fixture unexpectedly fails.
    func testRankingFailureKeepsCandidatesAndLeavesSelectionsEmpty() async throws {
        let source = session(1)
        let target = session(2, claude: true)
        let sourceHit = hit(source)
        let targetHit = hit(target)
        let service = AgentHandoffSuggestionService(search: { _, provider, limit, _ in
            XCTAssertEqual(limit, 500)
            return provider == "codex" ? [sourceHit] : [targetHit]
        }, rank: { _, _ in throw AgentIntentClassifierError.credentialAccessRequired })
        let suggestion = try await service.suggest("把 Codex 研究交给 Claude 实现", sessions: [source, target])
        XCTAssertEqual(suggestion.sources.map(\.session.id), [source.id])
        XCTAssertEqual(suggestion.targets.map(\.session.id), [target.id])
        XCTAssertNil(suggestion.sourceID)
        XCTAssertNil(suggestion.targetID)
        XCTAssertEqual(suggestion.notice, .rankingUnavailable)
    }

    /// Checks the complete pipeline joins Claude engine identity to the desktop identity before preselection.
    ///
    /// Raises:
    ///   Error: Any deterministic fixture fails.
    func testSuggestionUsesNativeIdentifiersAndDoesNotHaveDeliveryCapability() async throws {
        let source = session(1)
        let target = session(2, claude: true)
        let sourceHit = hit(source)
        let targetHit = hit(target)
        let reply = try response(source: "source_0", target: "destination_0", sourceCount: 1, targetCount: 1)
        let service = AgentHandoffSuggestionService(search: { _, provider, _, _ in
            provider == "codex" ? [sourceHit] : [targetHit]
        }, rank: { _, _ in reply })
        let suggestion = try await service.suggest("把 Codex 研究交给 Claude 实现", sessions: [source, target])
        XCTAssertEqual(suggestion.sourceID, source.id)
        XCTAssertEqual(suggestion.targetID, target.id)
        XCTAssertNotEqual(suggestion.targetID, target.engineSessionID)
        XCTAssertNil(suggestion.notice)
    }

    /// Checks cancellation is not downgraded to a recoverable ranking failure.
    ///
    /// Raises:
    ///   Error: The fixture unexpectedly bypasses cancellation.
    func testCancellationRemainsCancellation() async throws {
        let source = session(1)
        let sourceHit = hit(source)
        let service = AgentHandoffSuggestionService(search: { _, _, _, _ in [sourceHit] }, rank: { _, _ in throw CancellationError() })
        do {
            _ = try await service.suggest("研究转接一下", sessions: [source])
            XCTFail("Cancellation must reach the owning draft")
        } catch is CancellationError {
            // The owner invalidates the draft, so no late preselection can be applied.
        }
    }

    /// Creates a synthetic native descriptor with a distinct Claude engine mapping.
    ///
    /// Args:
    ///   number: Stable fixture suffix.
    ///   claude: Whether this is a Claude desktop conversation.
    ///
    /// Returns:
    ///   A descriptor without access to real user files.
    private func session(_ number: Int, claude: Bool = false) -> AgentSessionDescriptor {
        let engine = String(format: "00000000-0000-4000-8000-%012d", number)
        return AgentSessionDescriptor(sessionID: claude ? "local_fixture-\(number)" : engine,
                                      application: claude ? .claudeCode : .codex, title: "同一研究",
                                      workspacePath: "/synthetic/private/project", updatedAt: 100,
                                      matchTexts: [], openCapability: claude ? .claudeNativeDeepLink : .codexDeepLink,
                                      engineSessionID: claude ? engine : nil, transcriptPath: "/synthetic/private/history.jsonl")
    }

    /// Creates a bounded search hit with the backend's own identity format.
    ///
    /// Args:
    ///   session: Synthetic native descriptor.
    ///
    /// Returns:
    ///   Search evidence for a safe exact join.
    private func hit(_ session: AgentSessionDescriptor) -> AgentsViewSearchHit {
        AgentsViewSearchHit(sessionID: session.application == .codex ? "codex:" + session.sessionID : session.engineSessionID!,
                            agent: session.application == .codex ? "codex" : "claude", snippet: "研究进展", timestamp: Date(timeIntervalSince1970: 50))
    }

    /// Wraps a native descriptor with visible synthetic evidence.
    ///
    /// Args:
    ///   session: Synthetic native descriptor.
    ///
    /// Returns:
    ///   One editable candidate.
    private func candidate(_ session: AgentSessionDescriptor) -> AgentHandoffSuggestionCandidate {
        AgentHandoffSuggestionCandidate(session: session, snippet: "研究进展", timestamp: Date(timeIntervalSince1970: 50))
    }

    /// Encodes complete normalized Choice distributions for two independent role pools.
    ///
    /// Args:
    ///   source: Winning source option.
    ///   target: Winning destination option.
    ///   sourceCount: Number of source candidates.
    ///   targetCount: Number of destination candidates.
    ///
    /// Returns:
    ///   An isolated Jev response with no network access.
    ///
    /// Raises:
    ///   Error: JSON encoding fails.
    private func response(source: String, target: String, sourceCount: Int, targetCount: Int) throws -> Data {
        var answers: [String: Any] = [:]
        for (role, count, choice) in [("source", sourceCount, source), ("destination", targetCount, target)] {
            let keys = (0..<count).map { role + "_" + String($0) } + ["none", "ambiguous"]
            var probabilities = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.0) })
            probabilities[choice] = 1
            answers[role] = ["type": "choice", "choice": choice, "confidence": 1.0, "probabilities": probabilities]
        }
        return try JSONSerialization.data(withJSONObject: ["model": "jev-1.13.0", "answers": answers])
    }
}
