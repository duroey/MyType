import Foundation
import XCTest
@testable import Type4Me

final class AgentIntentClassifierTests: XCTestCase {
    /// Loads the production prompt without depending on a packaged application bundle.
    ///
    /// Returns:
    ///   The checked-in, non-secret classifier configuration.
    ///
    /// Raises:
    ///   Error: The fixture resource is missing or malformed.
    private func configuration() throws -> AgentIntentClassifier.Configuration {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = project.appendingPathComponent("Type4Me/Resources/AgentIntentConfig.json")
        return try JSONDecoder().decode(AgentIntentClassifier.Configuration.self, from: Data(contentsOf: url))
    }

    /// Builds a documented response fixture without making a network request.
    ///
    /// Args:
    ///   answerChanges: Fields overriding a valid Choice answer.
    ///   model: Version returned by the fixture service.
    ///
    /// Returns:
    ///   Serialized fixture response.
    ///
    /// Raises:
    ///   Error: The fixture cannot be serialized.
    private func response(answerChanges: [String: Any] = [:], model: String = "jev-1.13.0") throws -> Data {
        var answer: [String: Any] = [
            "type": "choice", "choice": "wake", "confidence": 0.85,
            "probabilities": ["wake": 0.9, "handoff": 0.05, "uncertain": 0.05],
        ]
        answer.merge(answerChanges) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: ["model": model, "answers": ["route": answer]])
    }

    /// Verifies the API receives explicit shortcut context and exactly three supported choices.
    ///
    /// Raises:
    ///   Error: Request construction or JSON decoding fails.
    func testRequestCarriesHotkeyContextWithoutAdditionalHistory() throws {
        let config = try configuration()
        let request = try AgentIntentClassifier.request(text: "  之前的研究  ", apiKey: "fixture-key", configuration: config)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        let route = try XCTUnwrap(questions["route"])
        let criteria = try XCTUnwrap(route["criteria"] as? [String: String])
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertEqual(body["model"] as? String, "jev-1.13.0")
        XCTAssertEqual(state["user_explicitly_pressed_agent_hotkey"] as? Bool, true)
        XCTAssertEqual(state["entrypoint"] as? String, "agent_hotkey")
        XCTAssertEqual(state["utterance"] as? String, "之前的研究")
        XCTAssertEqual(Set(state.keys), ["entrypoint", "user_explicitly_pressed_agent_hotkey", "utterance"])
        XCTAssertEqual(Set(criteria.keys), ["wake", "handoff", "uncertain"])
    }

    /// Verifies credentials cannot be sent to changed hosts, paths or insecure transports.
    ///
    /// Raises:
    ///   Error: The configuration fixture is unavailable.
    func testEndpointIsPinnedBeforeAddingCredential() throws {
        let invalid = [
            "http://api.typesafe.ai/v1/systemone", "https://example.com/v1/systemone",
            "https://api.typesafe.ai/v1/systemone?token=x", "https://api.typesafe.ai/elsewhere",
            "https://user@api.typesafe.ai/v1/systemone",
        ]
        for endpoint in invalid {
            var config = try configuration()
            config.endpoint = endpoint
            XCTAssertThrowsError(try AgentIntentClassifier.request(text: "研究", apiKey: "fixture-key", configuration: config)) { error in
                XCTAssertEqual(error as? AgentIntentClassifierError, .invalidConfiguration)
            }
        }
    }

    /// Verifies oversized text is rejected rather than truncated into a different intent.
    ///
    /// Raises:
    ///   Error: The configuration fixture is unavailable.
    func testInputBoundsAndEmptyInputFailBeforeNetwork() throws {
        var config = try configuration()
        config.maximumInputCharacters = 4
        config.maximumInputBytes = 8
        XCTAssertThrowsError(try AgentIntentClassifier.request(text: "五个字符了", apiKey: "fixture-key", configuration: config)) { error in
            XCTAssertEqual(error as? AgentIntentClassifierError, .inputTooLong)
        }
        XCTAssertThrowsError(try AgentIntentClassifier.request(text: "中文啊", apiKey: "fixture-key", configuration: config)) { error in
            XCTAssertEqual(error as? AgentIntentClassifierError, .inputTooLong)
        }
        XCTAssertThrowsError(try AgentIntentClassifier.request(text: " \n ", apiKey: "fixture-key", configuration: config)) { error in
            XCTAssertEqual(error as? AgentIntentClassifierError, .emptyInput)
        }
    }

    /// Verifies malformed header values never enter a request.
    ///
    /// Raises:
    ///   Error: The configuration fixture is unavailable.
    func testCredentialRejectsHeaderControlCharacters() throws {
        let config = try configuration()
        for credential in ["", "   ", "fixture\r\nInjected: yes", "fixture\u{0}key"] {
            XCTAssertThrowsError(try AgentIntentClassifier.request(text: "研究", apiKey: credential, configuration: config)) { error in
                XCTAssertEqual(error as? AgentIntentClassifierError, .missingCredential)
            }
        }
    }

    /// Verifies a valid distribution remains a judgment without inferred authorization.
    ///
    /// Raises:
    ///   Error: A valid fixture fails to decode.
    func testResponsePreservesChoiceAndDistribution() throws {
        let decision = try AgentIntentClassifier.decodeResponse(response(), configuration: configuration())
        XCTAssertEqual(decision.intent, .wake)
        XCTAssertEqual(decision.probabilities, ["wake": 0.9, "handoff": 0.05, "uncertain": 0.05])
        XCTAssertEqual(decision.model, "jev-1.13.0")
        XCTAssertEqual(decision.confidence, 0.85)
    }

    /// Verifies every malformed label, distribution and answer type fails closed.
    ///
    /// Raises:
    ///   Error: A fixture cannot be serialized.
    func testMalformedAnswersNeverBecomeAnOperation() throws {
        let config = try configuration()
        let invalid: [[String: Any]] = [
            ["type": "noul"], ["choice": "polish"], ["confidence": -0.1], ["confidence": 1.1],
            ["probabilities": ["wake": 0.9, "handoff": 0.1]],
            ["probabilities": ["wake": 0.9, "handoff": 0.05, "uncertain": 0.05, "other": 0.0]],
            ["probabilities": ["wake": 0.9, "handoff": 0.9, "uncertain": 0.9]],
            ["probabilities": ["wake": 0.9, "handoff": -0.1, "uncertain": 0.2]],
            ["probabilities": ["wake": true, "handoff": 0.0, "uncertain": 0.0]],
            ["choice": "handoff"],
        ]
        for changes in invalid {
            XCTAssertThrowsError(try AgentIntentClassifier.decodeResponse(response(answerChanges: changes), configuration: config)) { error in
                XCTAssertEqual(error as? AgentIntentClassifierError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try AgentIntentClassifier.decodeResponse(response(model: "jev-other"), configuration: config))
        XCTAssertThrowsError(try AgentIntentClassifier.decodeResponse(Data("not JSON".utf8), configuration: config))
    }

    /// Verifies response bounds are enforced before JSON parsing.
    ///
    /// Raises:
    ///   Error: The configuration fixture is unavailable.
    func testOversizedResponseFailsWithSizeError() throws {
        var config = try configuration()
        config.maximumResponseBytes = 2
        XCTAssertThrowsError(try AgentIntentClassifier.decodeResponse(Data("{} ".utf8), configuration: config)) { error in
            XCTAssertEqual(error as? AgentIntentClassifierError, .responseTooLarge)
        }
    }

    /// Verifies callers can render persistent errors in either language after a setting change.
    func testErrorMessagesAreResolvedForTheRequestedLanguage() {
        XCTAssertTrue(AgentIntentClassifierError.timedOut.message(language: .zh).contains("超时"))
        XCTAssertTrue(AgentIntentClassifierError.timedOut.message(language: .en).contains("timed out"))
        XCTAssertTrue(AgentIntentClassifierError.missingCredential.message(language: .zh).contains("密钥"))
        XCTAssertTrue(AgentIntentClassifierError.missingCredential.message(language: .en).contains("API key"))
    }

    /// Verifies an expired deadline fails before a worker can perform credential access.
    func testExpiredOverallDeadlineNeverStartsWork() async {
        do {
            _ = try await AgentIntentClassifier.withDeadline(.now.advanced(by: .seconds(-1))) {
                XCTFail("Expired classification must not start its worker")
                return AgentIntentDecision(intent: .wake, probabilities: [:], confidence: 1, model: "fixture")
            }
            XCTFail("An expired overall deadline must throw")
        } catch {
            XCTAssertEqual(error as? AgentIntentClassifierError, .timedOut)
        }
    }

    /// Verifies the caller times out while a non-cooperative worker remains suspended.
    func testOverallDeadlineDoesNotAwaitBlockedWorkerAndIgnoresLateResult() async {
        let deferred = AgentIntentDeferredDecision()
        var failure: Error?
        do {
            _ = try await AgentIntentClassifier.withDeadline(.now.advanced(by: .milliseconds(20))) {
                await deferred.value()
            }
        } catch {
            failure = error
        }
        // Release after the caller has returned; awaiting a structured worker would deadlock here.
        await deferred.release()
        XCTAssertEqual(failure as? AgentIntentClassifierError, .timedOut)
    }

    /// Verifies cancellation releases the caller before its unresponsive worker is released.
    func testCallerCancellationDoesNotAwaitBlockedWorker() async {
        let deferred = AgentIntentDeferredDecision()
        let caller = Task {
            try await AgentIntentClassifier.withDeadline(.now.advanced(by: .seconds(30))) {
                await deferred.value()
            }
        }
        await deferred.waitUntilStarted()
        caller.cancel()
        var failure: Error?
        do {
            _ = try await caller.value
        } catch {
            failure = error
        }
        await deferred.release()
        XCTAssertTrue(failure is CancellationError)
    }
}

/// A deterministic fixture whose suspended operation deliberately ignores Task cancellation.
private actor AgentIntentDeferredDecision {
    private var continuation: CheckedContinuation<AgentIntentDecision, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var released = false
    private let decision = AgentIntentDecision(intent: .handoff, probabilities: [:], confidence: 1, model: "fixture")

    /// Suspends until the test explicitly releases the worker, even after cancellation.
    ///
    /// Returns:
    ///   The late fixture judgment, which must never replace a timeout or cancellation.
    func value() async -> AgentIntentDecision {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        if released { return decision }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Suspends the test until the worker reaches the cancellation-resistant operation.
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    /// Delivers the late result and ensures no fixture continuation remains suspended.
    func release() {
        released = true
        continuation?.resume(returning: decision)
        continuation = nil
    }
}
