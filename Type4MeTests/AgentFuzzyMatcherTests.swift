import XCTest
@testable import Type4Me

final class AgentFuzzyMatcherTests: XCTestCase {
    func testChineseBigramMatchesSharedChinesePhrasesWithoutContainment() {
        let matcher = AgentFuzzyMatcher()

        let score = matcher.score(query: "机制自动唤醒", candidate: "自动唤醒机制")

        XCTAssertGreaterThanOrEqual(score, AgentFuzzyMatcher.defaultThreshold)
    }

    func testRejectsUnrelatedChineseQuery() {
        let matcher = AgentFuzzyMatcher()

        let score = matcher.score(query: "自动唤醒", candidate: "计算机图形学")

        XCTAssertLessThan(score, AgentFuzzyMatcher.defaultThreshold)
    }

    func testEnglishTokenOverlapMatchesReorderedTokens() {
        let matcher = AgentFuzzyMatcher()

        let score = matcher.score(query: "router agent", candidate: "agent router")

        XCTAssertGreaterThanOrEqual(score, AgentFuzzyMatcher.defaultThreshold)
    }

    func testSelectsBestMatchWhenScoreIsClear() {
        let matcher = AgentFuzzyMatcher()

        let match = matcher.acceptedBestMatch(
            for: "机制自动唤醒",
            in: ["语音唤醒", "自动唤醒机制", "等待队列"],
            candidateText: { $0 }
        )

        XCTAssertEqual(match, "自动唤醒机制")
    }

    func testRejectsAmbiguousTopMatches() {
        let matcher = AgentFuzzyMatcher()

        let match = matcher.acceptedBestMatch(
            for: "自动唤醒",
            in: ["自动唤醒机制", "自动唤醒流程", "计算机图形学"],
            candidateText: { $0 }
        )

        XCTAssertNil(match)
    }
}
