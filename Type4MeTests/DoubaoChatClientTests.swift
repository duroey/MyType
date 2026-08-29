import XCTest
@testable import Type4Me

final class DoubaoChatClientTests: XCTestCase {

    func testProcessInterpolatesPlainTextIntoTemplate() {
        let prompt = "请修正以下文本：{text}"
        let finalPrompt = prompt.replacingOccurrences(of: "{text}", with: "200毫秒")

        XCTAssertEqual(finalPrompt, "请修正以下文本：200毫秒")
    }

    func testOpenRouterDisableThinkingUsesUnifiedReasoningParameter() throws {
        let request = ChatRequest(
            model: "deepseek/deepseek-v4-flash-0731",
            messages: [ChatMessage(role: "user", content: "test")],
            stream: true,
            thinking: nil,
            enable_thinking: nil,
            reasoning: ReasoningConfig(effort: "none"),
            reasoning_effort: nil,
            think: nil,
            reasoning_split: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: String])

        XCTAssertEqual(reasoning["effort"], "none")
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["reasoning_effort"])
    }
}
