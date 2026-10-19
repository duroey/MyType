import Foundation
import XCTest
@testable import Type4Me

final class AgentSearchQueryTests: XCTestCase {
    /// Checks explicit ownership while preserving provider names that describe the topic.
    func testSourceOwnershipIsSeparateFromTopicMentions() throws {
        let cases: [(String, String?, String)] = [
            ("Codex 的那个", "codex", ""),
            ("Codex里昨天聊MyType", "codex", "MyType"),
            ("在Claude里讨论Codex接口", "claude", "Codex接口"),
            ("Cloud Code 里的 MyType 会话", "claude", "MyType 会话"),
            ("讨论Codex接口的会话", nil, "讨论Codex接口的会话"),
            ("Codex和Claude对接方案", nil, "Codex和Claude对接方案"),
            ("iCloud里的文件", nil, "iCloud里的文件"),
            ("CodexKit里的文件", nil, "CodexKit里的文件"),
            ("the one in Codex", "codex", ""),
        ]
        for (input, agent, topic) in cases {
            let result = try parse(input)
            XCTAssertEqual(result.agent, agent, input)
            XCTAssertEqual(result.text, topic, input)
        }
    }

    /// Checks metadata-only follow-ups can reuse a previous topic without declaring new work a refinement.
    func testRealVoiceFollowUpsRemainMetadataOnly() throws {
        let original = try parse("My type 的开发是")
        XCTAssertEqual(original.text, "My type 的开发是")
        XCTAssertFalse(original.isRefinement)
        let followUp = try parse("CoDex 的那个")
        XCTAssertEqual(followUp.agent, "codex")
        XCTAssertEqual(followUp.text, "")
        XCTAssertTrue(followUp.isRefinement)
        let yesterday = try parse("昨天的那个")
        XCTAssertNotNil(yesterday.messageInterval)
        XCTAssertTrue(yesterday.isRefinement)
        XCTAssertFalse(try parse("Codex里的另外一个项目").isRefinement)
        XCTAssertFalse(try parse("那个").isRefinement)
    }

    /// Checks local day boundaries, relative day offsets and explicitly conversational English dates.
    func testConversationDatesUseShanghaiCalendarBoundaries() throws {
        let cases: [(String, String, String)] = [
            ("昨天聊的MyType", "2026-10-14T16:00:00Z", "2026-10-15T16:00:00Z"),
            ("今天讨论的MyType", "2026-10-15T16:00:00Z", "2026-10-16T16:00:00Z"),
            ("前天的那个", "2026-10-13T16:00:00Z", "2026-10-14T16:00:00Z"),
            ("yesterday we discussed MyType", "2026-10-14T16:00:00Z", "2026-10-15T16:00:00Z"),
            ("the conversation from the day before yesterday", "2026-10-13T16:00:00Z", "2026-10-14T16:00:00Z"),
            ("本周聊的MyType", "2026-10-11T16:00:00Z", "2026-10-18T16:00:00Z"),
            ("上周聊的MyType", "2026-10-04T16:00:00Z", "2026-10-11T16:00:00Z"),
            ("the session from last week", "2026-10-04T16:00:00Z", "2026-10-11T16:00:00Z"),
        ]
        for (input, start, end) in cases {
            let result = try parse(input)
            let interval = try XCTUnwrap(result.messageInterval, input)
            XCTAssertEqual(interval.start, date(start), input)
            XCTAssertEqual(interval.end, date(end), input)
            XCTAssertEqual(result.timezoneIdentifier, "Asia/Shanghai")
        }
    }

    /// Checks a date inside the subject is not confused with the time the conversation happened.
    func testTopicDatesAreNotConversationFilters() throws {
        for input in ["讨论昨天发布的模型", "昨天发布的模型的会话", "Codex里讨论昨天发布的模型",
                      "讨论前天的新闻", "the model released yesterday", "discuss yesterday's model release"] {
            XCTAssertNil(try parse(input).messageInterval, input)
        }
    }

    /// Checks ambiguous metadata is retained instead of silently choosing one source or date.
    func testConflictingSourcesAndDatesStayUnspecified() throws {
        let source = try parse("在Codex里和在Claude里聊MyType")
        XCTAssertNil(source.agent)
        XCTAssertTrue(source.text.contains("Codex"))
        XCTAssertTrue(source.text.contains("Claude"))
        XCTAssertNil(try parse("Codex 或 Claude 里的会话").agent)
        XCTAssertEqual(try parse("在Claude里讨论Codex和Claude的区别").agent, "claude")
        let time = try parse("昨天聊的或者前天聊的MyType")
        XCTAssertNil(time.messageInterval)
        XCTAssertTrue(time.text.contains("昨天"))
        XCTAssertTrue(time.text.contains("前天"))
        XCTAssertNil(try parse("昨天前天聊的MyType").messageInterval)
        XCTAssertNotNil(try parse("昨天聊前天发布的模型").messageInterval)
    }

    /// Keeps explicitly negated metadata in the topic instead of enforcing the opposite constraint.
    func testNegatedSourcesAndConversationDatesAreNotPositiveFilters() throws {
        for input in ["不是 Codex 的那个", "别在Claude里找", "不要Codex里的那个", "not in Codex"] {
            let parsed = try parse(input)
            XCTAssertNil(parsed.agent, input)
            XCTAssertEqual(parsed.text, input, input)
            XCTAssertFalse(parsed.isRefinement, input)
        }
        for input in ["不要昨天聊的那个", "不是前天的那个", "not the conversation from yesterday"] {
            let parsed = try parse(input)
            XCTAssertNil(parsed.messageInterval, input)
            XCTAssertEqual(parsed.text, input, input)
            XCTAssertFalse(parsed.isRefinement, input)
        }
        let positiveSource = try parse("Codex里不是昨天聊的那个")
        XCTAssertEqual(positiveSource.agent, "codex")
        XCTAssertNil(positiveSource.messageInterval)
        XCTAssertTrue(positiveSource.text.contains("不是昨天"))
    }

    /// Checks calendar arithmetic respects daylight-saving days instead of assuming 24 hours.
    func testDaylightSavingDaysAreNotFixedSecondOffsets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try AgentSearchQuery.parse("yesterday we discussed MyType",
                                              now: date("2026-03-09T19:00:00Z"), calendar: calendar)
        let autumn = try AgentSearchQuery.parse("昨天聊的MyType",
                                              now: date("2026-11-02T20:00:00Z"), calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(spring.messageInterval).duration, 23 * 60 * 60)
        XCTAssertEqual(try XCTUnwrap(autumn.messageInterval).duration, 25 * 60 * 60)
    }

    /// Checks packaged expressions match typed defaults and invalid configuration is rejected early.
    func testConfigurationBoundsAndPackagedDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Type4Me/Resources/AgentSearchQueryConfig.json"))
        let packaged = try JSONDecoder().decode(AgentSearchQuery.Configuration.self, from: data)
        try packaged.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(packaged), try encoder.encode(AgentSearchQuery.Configuration()))
        XCTAssertEqual(packaged.contextLifetimeSeconds, 300)
        var invalid = packaged
        invalid.contextLifetimeSeconds = .infinity
        XCTAssertThrowsError(try invalid.validate())
        invalid = packaged
        invalid.timePatterns = ["["]
        XCTAssertThrowsError(try AgentSearchQuery.parse("昨天的那个", configuration: invalid))
        XCTAssertThrowsError(try parse(String(repeating: "a", count: packaged.maximumInputCharacters + 1)))
    }

    /// Parses one fixture using a stable local clock near the beginning of the Shanghai day.
    ///
    /// Args:
    ///   value: Query under test.
    ///
    /// Returns:
    ///   Parsed fields anchored to 2026-10-16 00:30 in Shanghai.
    private func parse(_ value: String) throws -> AgentSearchQuery {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        return try AgentSearchQuery.parse(value, now: date("2026-10-15T16:30:00Z"), calendar: calendar)
    }

    /// Converts a fixed ISO timestamp used by the deterministic calendar fixtures.
    ///
    /// Args:
    ///   value: Complete ISO 8601 UTC timestamp.
    ///
    /// Returns:
    ///   The fixture date; malformed fixtures fail immediately.
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
