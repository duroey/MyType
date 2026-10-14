import Foundation
import XCTest
@testable import Type4Me

/// Opt-in local-search and recorded-response probe; native delivery is always replaced.
final class AgentHandoffSuggestionIntegrationTests: XCTestCase {
    private struct Entry: Codable {
        let session: AgentSessionDescriptor
        let snippet: String
        let timestamp: Date?

        var candidate: AgentHandoffSuggestionCandidate {
            .init(session: session, snippet: snippet, timestamp: timestamp)
        }
    }

    private struct Snapshot: Codable {
        let utterance: String
        let sources: [Entry]
        let targets: [Entry]
    }

    /// Captures search evidence, prepares a frozen-candidate request, or reviews a recorded response.
    ///
    /// Returns:
    ///   Nothing. This opt-in probe never calls the native sender, opener, or credential reader.
    ///
    /// Raises:
    ///   Error: The explicit probe setup, local search, or recorded response is invalid.
    @MainActor
    func testOptInSearchAndReviewFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["MYTYPE_HANDOFF_PROBE_PHASE"], ["capture", "prepare", "review"].contains(phase),
              let directory = environment["MYTYPE_HANDOFF_PROBE_DIRECTORY"] else {
            throw XCTSkip("Requires explicit read-only handoff probe configuration")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let settings = AgentHandoffSuggestionConfiguration()
        if phase == "capture" {
            let utterance = try XCTUnwrap(environment["MYTYPE_HANDOFF_PROBE_UTTERANCE"])
            let catalog = try AgentSessionCatalog.shared.loadSessions()
            let service = AgentHandoffSuggestionService(configuration: settings, rank: { payload, _ in
                try Self.save(payload, to: root.appendingPathComponent("request.json"))
                throw AgentIntentClassifierError.unavailable
            })
            let result = try await service.suggest(utterance, sessions: catalog.sessions)
            XCTAssertEqual(result.notice, .rankingUnavailable)
            XCTAssertFalse(result.sources.isEmpty)
            XCTAssertFalse(result.targets.isEmpty)
            XCTAssertNil(result.sourceID)
            XCTAssertNil(result.targetID)
            let snapshot = Snapshot(utterance: utterance,
                                    sources: result.sources.map { Entry(session: $0.session, snippet: $0.snippet, timestamp: $0.timestamp) },
                                    targets: result.targets.map { Entry(session: $0.session, snippet: $0.snippet, timestamp: $0.timestamp) })
            try Self.save(JSONEncoder().encode(snapshot), to: root.appendingPathComponent("candidates.json"))
            return
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: root.appendingPathComponent("candidates.json")))
        let sources = snapshot.sources.map(\.candidate)
        let targets = snapshot.targets.map(\.candidate)
        if phase == "prepare" {
            let request = try AgentHandoffSuggestionService.payload(snapshot.utterance, sources: sources,
                                                                     targets: targets, configuration: settings)
            try Self.save(request, to: root.appendingPathComponent("request.json"))
            return
        }
        let response = try Data(contentsOf: root.appendingPathComponent("response.json"))
        let choice = try AgentHandoffSuggestionService.decodeResponse(response, sources: sources, targets: targets, configuration: settings)
        let sourceID = try XCTUnwrap(choice.sourceID)
        let targetID = try XCTUnwrap(choice.targetID)
        XCTAssertNotEqual(sourceID, targetID)
        let suggestion = AgentHandoffSuggestion(sources: sources, targets: targets, sourceID: sourceID,
                                               targetID: targetID, notice: choice.ambiguous ? .ambiguous : nil)
        let catalog = Dictionary((sources + targets).map { ($0.session.id, $0.session) }, uniquingKeysWith: { first, _ in first })
        let calls = ProbeSends()
        let model = AgentHandoffViewModel(
            catalogLoader: { .init(sessions: Array(catalog.values), unavailableApplications: []) },
            historyLoader: { source in
                AgentHandoffHistory(source: source, markdown: "Synthetic preview for confirmation-gate verification",
                                    messageCount: 1, snapshotDate: Date(timeIntervalSince1970: 1),
                                    fileURL: URL(fileURLWithPath: "/synthetic-fixture/never-written.md"))
            },
            sender: { _, target, _ in
                await calls.record()
                return .init(route: .codexQueue, messageID: "fixture-only", target: target, usesHistoryFile: false)
            },
            opener: { _ in XCTFail("Suggestion review must not open a native application") },
            discarder: { _ in }, suggester: { _, _ in suggestion }
        )
        XCTAssertTrue(model.beginVoiceDraft(snapshot.utterance))
        await model.refreshSessions()
        XCTAssertEqual(model.sourceID, sourceID)
        XCTAssertEqual(model.targetID, targetID)
        XCTAssertTrue(model.canSend)
        let before = await calls.count
        XCTAssertEqual(before, 0)
        await model.send()
        await model.send()
        let after = await calls.count
        XCTAssertEqual(after, 1)
        let report: [String: Any] = [
            "source_id": sourceID, "target_id": targetID,
            "source_title": model.source?.title ?? "", "target_title": model.target?.title ?? "",
            "ambiguous": choice.ambiguous, "source_candidates": sources.count, "target_candidates": targets.count,
            "before_confirmation_fixture_sends": before, "after_confirmation_fixture_sends": after,
            "native_messages_sent": 0, "response_mode": "recorded_live_Jev_response",
            "history_mode": "synthetic_preview", "installed_app_modified": false
        ]
        try Self.save(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                      to: root.appendingPathComponent("review-receipt.json"))
    }

    /// Saves a bounded probe checkpoint with private local file permissions.
    ///
    /// Args:
    ///   data: Credential-free request, response context, or verification receipt.
    ///   url: Explicit output path in the opt-in probe directory.
    ///
    /// Raises:
    ///   Error: The file cannot be saved privately.
    private nonisolated static func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor ProbeSends {
    private(set) var count = 0

    /// Records only an injected transport call; no real Agent is contacted.
    func record() { count += 1 }
}
