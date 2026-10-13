import Foundation
import XCTest
@testable import Type4Me

final class AgentHandoffNativeHistoryTests: XCTestCase {
    private let nativeID = "11111111-1111-4111-8111-111111111111"

    /// Verifies copied fork dialogue stays in order and private response fields never become text.
    ///
    /// Raises:
    ///   Error: The complete visible native snapshot cannot be decoded.
    func testCompleteCopiedDialoguePreservesDuplicatesAndIgnoresToolProperties() throws {
        var assistant = message(ordinal: 7, role: "assistant", content: "可见回答\nKeep this line.")
        assistant["thinking_text"] = "private reasoning"
        assistant["tool_calls"] = [["input_json": "private arguments", "result_content": "private result"]]
        let data = try response(messages: [
            message(ordinal: 0, role: "user", content: "重复的历史问题"),
            message(ordinal: 2, role: "user", content: "重复的历史问题"),
            message(ordinal: 5, role: "assistant", content: " \n\t "), assistant,
        ])
        let draft = try decode(data)
        XCTAssertEqual(draft.messageCount, 3)
        XCTAssertEqual(draft.markdown.components(separatedBy: "重复的历史问题").count - 1, 2)
        XCTAssertTrue(draft.markdown.contains("## 1. 用户 / User"))
        XCTAssertTrue(draft.markdown.contains("## 3. 模型 / Assistant\n\n可见回答\nKeep this line."))
        XCTAssertTrue(draft.markdown.contains("归档标识 / Archive ID: codex:" + nativeID))
        XCTAssertTrue(draft.markdown.contains("记录截至 / Recorded through: 2026-10-10T19:44:33Z"))
        for hidden in ["private reasoning", "private arguments", "private result", "opaque-native-revision"] {
            XCTAssertFalse(draft.markdown.contains(hidden), hidden)
        }
    }

    /// Rejects provider and session mismatches instead of sending a different conversation.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testIdentityAndProviderMustExactlyMatchSelectedCodex() throws {
        for overrides in [["id": nativeID], ["id": "codex:22222222-2222-4222-8222-222222222222"], ["agent": "claude"]] {
            try assertFailure(.invalidResponse, data: response(overrides: overrides))
        }
        let claude = AgentSessionDescriptor(sessionID: "local_fixture", application: .claudeCode,
            title: "Task", workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .claudeNativeDeepLink)
        XCTAssertThrowsError(try AgentHandoffNativeHistory.decode(data: response(), source: claude,
            configuration: .init())) { XCTAssertEqual($0 as? AgentHandoffHistoryError, .invalidResponse) }
    }

    /// Allows sparse ordinals while rejecting duplicates, reversals and negative indices.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testOrdinalsAreStrictlyIncreasingWithoutInventingMissingMessages() throws {
        for indices in [[0, 0], [3, 2], [-1, 2]] {
            try assertFailure(.invalidResponse, data: response(messages: indices.map {
                message(ordinal: $0, role: "user", content: "Visible")
            }))
        }
        let draft = try decode(response(messages: [message(ordinal: 4, role: "user", content: "First"),
            message(ordinal: 19, role: "assistant", content: "Last")]))
        XCTAssertEqual(draft.messageCount, 2)
    }

    /// Rejects non-dialogue rows from an endpoint claiming to return visible conversation text.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testUnexpectedRolesFailRatherThanSilentlyLosingHistory() throws {
        for role in ["tool", "system", "developer", "Assistant"] {
            try assertFailure(.invalidResponse, data: response(messages: [message(ordinal: 0, role: role, content: "Hidden")]))
        }
    }

    /// Refuses structured or missing content rather than extracting embedded tool arguments.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testContentMustBeAnExplicitString() throws {
        var structured = message(ordinal: 0, role: "assistant", content: "")
        structured["content"] = [["type": "tool_use", "text": "private tool input"]]
        try assertFailure(.invalidResponse, data: response(messages: [structured]))
        structured.removeValue(forKey: "content")
        structured["tool_result"] = "private result"
        try assertFailure(.invalidResponse, data: response(messages: [structured]))
    }

    /// Rejects a decoded NUL in visible text and metadata before constructing a message payload.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testNULIsRejectedInVisibleBodyAndTitle() throws {
        try assertFailure(.invalidResponse, data: response(messages: [message(ordinal: 0, role: "user", content: "hello\0world")]))
        let source = codex(title: "Task\0name")
        XCTAssertThrowsError(try AgentHandoffNativeHistory.decode(data: response(), source: source,
            configuration: .init())) { XCTAssertEqual($0 as? AgentHandoffHistoryError, .invalidResponse) }
    }

    /// Reports an empty visible history without using tool properties as replacement text.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testEmptyDialogueHasNoVisibleHistory() throws {
        try assertFailure(.noVisibleHistory, data: response(messages: []))
        try assertFailure(.noVisibleHistory, data: response(messages: [message(ordinal: 0, role: "user", content: " \n ")]))
    }

    /// Refuses invalid UTF-8 and truncated JSON instead of repairing or partially exporting it.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testInvalidUTF8AndTruncatedResponsesFailCompletely() throws {
        try assertFailure(.invalidResponse, data: Data([0xff, 0xfe]))
        var data = try response()
        data.removeLast()
        try assertFailure(.invalidResponse, data: data)
    }

    /// Requires proof that the endpoint read a complete stable native source snapshot.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testMissingSnapshotEvidenceIsIncompleteHistory() throws {
        for overrides in [["source_revision": NSNull()], ["source_revision": " \n "], ["recorded_through": NSNull()]] {
            try assertFailure(.incompleteHistory, data: response(overrides: overrides))
        }
    }

    /// Rejects malformed calendar dates and unparseable recorded-through values.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testRecordedThroughRequiresAValidRFC3339Date() throws {
        for value in ["not a date", "2026-02-30T19:44:33Z", "2026-10-10", "2026-10-10T25:00:00Z", "0000-01-01T00:00:00Z"] {
            try assertFailure(.invalidResponse, data: response(overrides: ["recorded_through": value]))
        }
        let draft = try decode(response(overrides: ["recorded_through": "2026-10-10T21:44:33.123+02:00"]))
        XCTAssertEqual(draft.snapshotDate.timeIntervalSince1970, 1_791_661_473.123, accuracy: 0.001)
    }

    /// Keeps missing message timestamps optional but rejects incompatible supplied dates.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testProvidedMessageTimestampMustBeValid() throws {
        var row = message(ordinal: 0, role: "user", content: "Visible")
        row["timestamp"] = NSNull()
        XCTAssertEqual(try decode(response(messages: [row])).messageCount, 1)
        row["timestamp"] = "broken"
        try assertFailure(.invalidResponse, data: response(messages: [row]))
    }

    /// Applies the byte cap to the full response before decoding any partial conversation.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testFullResponseByteLimitNeverTruncates() throws {
        let data = try response()
        var configuration = AgentHandoffConfiguration()
        configuration.maximumHistoryBytes = data.count - 1
        configuration.maximumInlineHistoryBytes = configuration.maximumHistoryBytes
        XCTAssertThrowsError(try AgentHandoffNativeHistory.decode(data: data, source: codex(), configuration: configuration)) {
            XCTAssertEqual($0 as? AgentHandoffHistoryError, .historyTooLarge)
        }
    }

    /// Counts Markdown headers and multibyte text toward the complete export byte limit.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testCompleteMarkdownByteLimitPreservesUnicodeExactly() throws {
        let content = String(repeating: "中文🧭\n", count: 100)
        let data = try response(messages: [message(ordinal: 0, role: "user", content: content)])
        let draft = try decode(data)
        XCTAssertTrue(draft.markdown.contains(content))
        XCTAssertLessThan(data.count, draft.markdown.utf8.count)
        var configuration = AgentHandoffConfiguration()
        configuration.maximumHistoryBytes = draft.markdown.utf8.count - 1
        configuration.maximumInlineHistoryBytes = configuration.maximumHistoryBytes
        XCTAssertThrowsError(try AgentHandoffNativeHistory.decode(data: data, source: codex(), configuration: configuration)) {
            XCTAssertEqual($0 as? AgentHandoffHistoryError, .historyTooLarge)
        }
    }

    /// Rejects invalid limits instead of admitting an unbounded or negative byte budget.
    ///
    /// Raises:
    ///   Error: A malformed fixture cannot be constructed.
    func testInvalidConfigurationFailsBeforeDecoding() throws {
        var configuration = AgentHandoffConfiguration()
        configuration.maximumHistoryBytes = -1
        XCTAssertThrowsError(try AgentHandoffNativeHistory.decode(data: response(), source: codex(), configuration: configuration)) {
            XCTAssertEqual($0 as? AgentHandoffHistoryError, .invalidResponse)
        }
    }

    /// Decodes one fixture with explicit production defaults and no network or native file access.
    ///
    /// Args:
    ///   data: Complete JSON response bytes.
    ///
    /// Returns:
    ///   The complete validated Markdown draft.
    ///
    /// Raises:
    ///   AgentHandoffHistoryError: The fixture violates the native history contract.
    private func decode(_ data: Data) throws -> AgentHandoffNativeHistoryDraft {
        try AgentHandoffNativeHistory.decode(data: data, source: codex(), configuration: .init())
    }

    /// Asserts one semantic failure without printing any supplied historical content.
    ///
    /// Args:
    ///   expected: Exact expected validation error.
    ///   data: Malformed complete JSON response.
    ///
    /// Raises:
    ///   Error: XCTest rejects fixture evaluation.
    private func assertFailure(_ expected: AgentHandoffHistoryError, data: Data) throws {
        XCTAssertThrowsError(try decode(data)) { XCTAssertEqual($0 as? AgentHandoffHistoryError, expected) }
    }

    /// Creates an exact selected Codex descriptor without accessing installed agent state.
    ///
    /// Args:
    ///   title: Verbatim native conversation title.
    ///
    /// Returns:
    ///   A deterministic selected-source descriptor.
    private func codex(title: String = "Fork / 分支任务") -> AgentSessionDescriptor {
        AgentSessionDescriptor(sessionID: nativeID, application: .codex, title: title,
            workspacePath: nil, updatedAt: 0, matchTexts: [], openCapability: .codexDeepLink)
    }

    /// Creates one explicit user or assistant string row, retaining its original ordinal.
    ///
    /// Args:
    ///   ordinal: Native source order, allowing gaps.
    ///   role: Explicit dialogue role.
    ///   content: Exact visible text.
    ///
    /// Returns:
    ///   JSON-compatible fixture fields.
    private func message(ordinal: Int, role: String, content: String) -> [String: Any] {
        ["ordinal": ordinal, "role": role, "content": content, "timestamp": "2026-10-10T19:44:33.000Z"]
    }

    /// Builds a complete native visible-history response with optional malformed field overrides.
    ///
    /// Args:
    ///   messages: Exact message rows, or one default visible user row.
    ///   overrides: Top-level field replacements used by validation fixtures.
    ///
    /// Returns:
    ///   Complete UTF-8 JSON bytes.
    ///
    /// Raises:
    ///   Error: Fixture fields cannot be encoded as JSON.
    private func response(messages: [[String: Any]]? = nil, overrides: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["id": "codex:" + nativeID, "agent": "codex",
            "messages": messages ?? [message(ordinal: 0, role: "user", content: "Visible history")],
            "recorded_through": "2026-10-10T19:44:33.000Z", "source_revision": "opaque-native-revision"]
        payload.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
