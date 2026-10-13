import Foundation
import XCTest
@testable import Type4Me

final class AgentsViewSearchServiceTests: XCTestCase {
    private let codexID = "11111111-1111-4111-8111-111111111111"
    private let claudeID = "22222222-2222-4222-8222-222222222222"

    /// Verifies the content endpoint uses hybrid mode and never accepts a launch URL.
    ///
    /// Raises:
    ///   Error: The deterministic request cannot be constructed.
    func testRequestUsesOnlyLocalContentSearch() throws {
        let query = "MyType 体验包 + 打包"
        let request = try AgentsViewSearchService.request(query: query, configuration: .init())
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/api/v1/search/content")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(items["pattern"], query)
        XCTAssertEqual(items["mode"], "hybrid")
        XCTAssertEqual(items["scope"], "top")
        XCTAssertEqual(items["include_one_shot"], "true")
        XCTAssertEqual(items["exclude_system"], "true")
        XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") ?? false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AgentsView-Search-Intent"), "semantic")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// Verifies external, credential-bearing and alternate-path endpoints fail before any request.
    func testEndpointRejectsExternalHostsCredentialsAndPaths() {
        let invalid = [
            "http://localhost:18742", "http://127.0.0.2:18742", "https://127.0.0.1:18742",
            "http://example.com:18742", "http://user:secret@127.0.0.1:18742",
            "http://127.0.0.1:18742/resume", "http://127.0.0.1:18742?token=x",
            "http://127.0.0.1:18742#fragment",
        ]
        for endpoint in invalid {
            var configuration = AgentsViewSearchService.Configuration()
            configuration.endpoint = endpoint
            XCTAssertThrowsError(try configuration.validatedEndpoint(), endpoint)
        }
    }

    /// Verifies explicit IPv6 loopback remains a supported local endpoint.
    ///
    /// Raises:
    ///   Error: Valid IPv6 loopback configuration was rejected.
    func testEndpointAcceptsNumericIPv6Loopback() throws {
        var configuration = AgentsViewSearchService.Configuration()
        configuration.endpoint = "http://[::1]:18742"
        XCTAssertNoThrow(try configuration.validatedEndpoint())
    }

    /// Verifies query and response limits fail explicitly without performing network access.
    ///
    /// Raises:
    ///   Error: The synthetic oversized body could not be serialized.
    func testOversizedQueryAndResponseAreRejected() throws {
        var configuration = AgentsViewSearchService.Configuration()
        configuration.maximumQueryCharacters = 3
        XCTAssertThrowsError(try AgentsViewSearchService.request(query: "four", configuration: configuration)) { error in
            XCTAssertEqual(error as? AgentsViewSearchError, .queryTooLong)
        }
        configuration.maximumResponseBytes = 3
        XCTAssertThrowsError(try AgentsViewSearchService.decodeResponse(Data("{}xx".utf8), configuration: configuration)) { error in
            XCTAssertEqual(error as? AgentsViewSearchError, .responseTooLarge)
        }
    }

    /// Verifies actual evidence timestamps decode and snippet limits preserve a matching lead.
    ///
    /// Raises:
    ///   Error: The synthetic backend payload cannot be serialized or decoded.
    func testTimestampAndSnippetAreBounded() throws {
        var configuration = AgentsViewSearchService.Configuration()
        configuration.maximumSnippetCharacters = 4
        let data = try payload([
            ["session_id": "codex:" + codexID, "agent": "codex", "snippet": "已交付体验包",
             "ordinal": 66, "ordinal_range": [58, 66], "timestamp": "2026-10-08T12:29:40.446Z", "score": 0.03],
        ])
        let hit = try XCTUnwrap(AgentsViewSearchService.decodeResponse(data, configuration: configuration).first)
        XCTAssertEqual(hit.snippet, "已交付体")
        XCTAssertEqual(hit.ordinal, 66)
        XCTAssertEqual(hit.ordinalRange, [58, 66])
        XCTAssertNotNil(hit.timestamp)
        XCTAssertEqual(hit.score, 0.03)
    }

    /// Verifies repeated hits share one result while distinct forks remain separate.
    ///
    /// Raises:
    ///   Error: The synthetic backend payload cannot be serialized or decoded.
    func testRepeatedSessionKeepsBestEvidenceWithoutMergingForks() throws {
        let first = "codex:" + codexID
        let fork = "codex:33333333-3333-4333-8333-333333333333"
        let data = try payload([
            ["session_id": first, "agent": "codex", "snippet": "old evidence", "score": 0.01],
            ["session_id": fork, "agent": "codex", "snippet": "independent fork", "score": 0.02],
            ["session_id": first, "agent": "codex", "snippet": "best evidence", "score": 0.03],
        ])
        let hits = try AgentsViewSearchService.decodeResponse(data, configuration: .init())
        XCTAssertEqual(hits.map(\.sessionID), [first, fork])
        XCTAssertEqual(hits.first?.snippet, "best evidence")
    }

    /// Verifies missing content produces no leads and malformed JSON has a distinct error.
    ///
    /// Raises:
    ///   Error: The empty synthetic payload cannot be serialized or decoded.
    func testEmptyEvidenceNeverBecomesARecentSessionFallback() throws {
        let data = try payload([["session_id": "codex:" + codexID, "agent": "codex", "snippet": "   "]])
        XCTAssertEqual(try AgentsViewSearchService.decodeResponse(data, configuration: .init()), [])
        XCTAssertThrowsError(try AgentsViewSearchService.decodeResponse(Data("not JSON".utf8), configuration: .init())) { error in
            XCTAssertEqual(error as? AgentsViewSearchError, .invalidResponse)
        }
    }

    /// Verifies Codex search IDs can only join an existing native catalog identity.
    func testCodexMappingRequiresPrefixAndExactNativeIdentity() {
        let session = descriptor(id: codexID, application: .codex)
        let hit = AgentsViewSearchHit(sessionID: "codex:" + codexID, agent: "codex", snippet: "delivery")
        XCTAssertEqual(AgentsViewSearchService.nativeSession(for: hit, in: [session]), session)
        XCTAssertNil(AgentsViewSearchService.nativeSession(for: hit, in: []))
        XCTAssertNil(AgentsViewSearchService.nativeSession(
            for: AgentsViewSearchHit(sessionID: codexID, agent: "codex", snippet: "delivery"), in: [session]
        ))
        XCTAssertNil(AgentsViewSearchService.nativeSession(for: hit, in: [session, session]))
    }

    /// Verifies the Claude transcript UUID joins native metadata without replacing the local ID.
    func testClaudeMappingUsesExactEngineUUIDAndPreservesNativeIdentity() {
        let session = descriptor(id: "local_native-one", application: .claudeCode, engineID: claudeID.uppercased())
        let hit = AgentsViewSearchHit(sessionID: claudeID, agent: "claude", snippet: "delivery")
        let native = AgentsViewSearchService.nativeSession(for: hit, in: [session])
        XCTAssertEqual(native?.sessionID, "local_native-one")
        XCTAssertNotEqual(native?.sessionID, hit.sessionID)
        XCTAssertNil(AgentsViewSearchService.nativeSession(
            for: AgentsViewSearchHit(sessionID: "claude:" + claudeID, agent: "claude", snippet: "delivery"), in: [session]
        ))
        XCTAssertNil(AgentsViewSearchService.nativeSession(
            for: hit, in: [descriptor(id: "local_unmapped", application: .claudeCode)]
        ))
    }

    /// Verifies an ambiguous engine-to-native association never selects a target by recency or title.
    func testClaudeDuplicateEngineMappingFailsClosed() {
        let hit = AgentsViewSearchHit(sessionID: claudeID, agent: "claude", snippet: "delivery")
        let first = descriptor(id: "local_first", application: .claudeCode, engineID: claudeID)
        let second = descriptor(id: "local_second", application: .claudeCode, engineID: claudeID)
        XCTAssertNil(AgentsViewSearchService.nativeSession(for: hit, in: [first, second]))
    }

    /// Verifies older descriptor JSON remains readable when no engine identity was saved.
    ///
    /// Raises:
    ///   Error: The synthetic legacy descriptor cannot be decoded.
    func testLegacyDescriptorDecodesWithoutEngineIdentity() throws {
        let data = Data("""
            {"sessionID":"old","application":"codex","title":"old title","updatedAt":1,
             "matchTexts":["old title"],"openCapability":"codexDeepLink"}
            """.utf8)
        let session = try JSONDecoder().decode(AgentSessionDescriptor.self, from: data)
        XCTAssertNil(session.engineSessionID)
    }

    /// Builds a synthetic response with no reads of a user's Agent history.
    ///
    /// Args:
    ///   matches: Fixture search matches.
    ///
    /// Returns:
    ///   Encoded backend response JSON.
    ///
    /// Raises:
    ///   Error: Fixture JSON serialization failed.
    private func payload(_ matches: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["matches": matches])
    }

    /// Builds a native descriptor isolated from installed applications and history.
    ///
    /// Args:
    ///   id: Fixture native identifier.
    ///   application: Fixture owning provider.
    ///   engineID: Optional fixture transcript UUID.
    ///
    /// Returns:
    ///   A synthetic native catalog entry with identical titles across independent identities.
    private func descriptor(
        id: String, application: AgentDesktopApplication, engineID: String? = nil
    ) -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: id, application: application, title: "Same title", workspacePath: nil,
                               updatedAt: 1, matchTexts: [],
                               openCapability: application == .codex ? .codexDeepLink : .claudeNativeDeepLink,
                               engineSessionID: engineID)
    }
}
