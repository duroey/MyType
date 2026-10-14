import Foundation
import LocalAuthentication
import Security

/// Operations available after the user explicitly presses the Agent shortcut.
enum AgentIntent: String, Codable, CaseIterable, Sendable {
    case wake
    case handoff
    case uncertain
}

/// A routing judgment; neither its confidence nor its label authorizes delivery.
struct AgentIntentDecision: Equatable, Sendable {
    let intent: AgentIntent
    let probabilities: [String: Double]
    let confidence: Double
    let model: String
}

enum AgentIntentClassifierError: Error, LocalizedError, Equatable, Sendable {
    case configurationUnavailable
    case invalidConfiguration
    case emptyInput
    case inputTooLong
    case missingCredential
    case credentialAccessRequired
    case credentialUnavailable
    case unauthorized
    case timedOut
    case unavailable
    case rejected(status: Int)
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? { message(language: .current) }

    /// Renders a safe explanation without including the utterance, key or server body.
    ///
    /// Args:
    ///   language: Language currently selected by the user.
    ///
    /// Returns:
    ///   A localized reason for showing the manual action picker.
    func message(language: AppLanguage) -> String {
        let chinese = language == .zh
        switch self {
        case .configurationUnavailable, .invalidConfiguration:
            return chinese ? "Agent 意图识别配置不可用，请手动选择操作。" : "Agent intent settings are unavailable. Choose an action."
        case .emptyInput:
            return chinese ? "没有可识别的内容，请重新说一次。" : "No speech text was received. Please try again."
        case .inputTooLong:
            return chinese ? "这段内容过长，请缩短要求或手动选择操作。" : "This request is too long. Shorten it or choose an action."
        case .missingCredential:
            return chinese ? "尚未配置 TypeSafe 密钥，请手动选择操作。" : "The TypeSafe API key is not configured. Choose an action."
        case .credentialAccessRequired:
            return chinese ? "MyType 尚未获准读取 TypeSafe 密钥，请手动选择操作。" : "MyType is not authorized to read the TypeSafe API key. Choose an action."
        case .credentialUnavailable:
            return chinese ? "暂时无法从钥匙串读取 TypeSafe 密钥，请手动选择操作。" : "The TypeSafe API key cannot be read from Keychain. Choose an action."
        case .unauthorized:
            return chinese ? "TypeSafe 密钥不可用，请手动选择操作。" : "The TypeSafe API key was rejected. Choose an action."
        case .timedOut:
            return chinese ? "意图识别超时，请手动选择操作。" : "Intent detection timed out. Choose an action."
        case .unavailable:
            return chinese ? "暂时无法连接意图识别服务，请手动选择操作。" : "Intent detection is unavailable. Choose an action."
        case .rejected:
            return chinese ? "意图识别服务暂时无法处理请求，请手动选择操作。" : "Intent detection could not process this request. Choose an action."
        case .invalidResponse, .responseTooLarge:
            return chinese ? "意图识别结果无效，请手动选择操作。" : "Intent detection returned an invalid result. Choose an action."
        }
    }
}

/// Classifies a bounded transcript without opening a conversation or sending history.
actor AgentIntentClassifier {
    struct Configuration: Decodable, Sendable {
        var endpoint: String
        var model: String
        var promptVersion: String
        var requestTimeoutSeconds: Double
        var resourceTimeoutSeconds: Double
        var overallTimeoutSeconds: Double
        var maximumInputCharacters: Int
        var maximumInputBytes: Int
        var maximumRequestBytes: Int
        var maximumResponseBytes: Int
        var probabilitySumTolerance: Double
        var instructions: String
        var criteria: [String: String]

        /// Loads the non-secret prompt and limits from an installed application.
        ///
        /// Args:
        ///   bundle: Bundle containing AgentIntentConfig.json.
        ///
        /// Returns:
        ///   Validated configuration; missing resources never enable implicit defaults.
        ///
        /// Raises:
        ///   AgentIntentClassifierError: The resource is missing or malformed.
        static func bundled(in bundle: Bundle = .main) throws -> Self {
            guard let url = bundle.url(forResource: "AgentIntentConfig", withExtension: "json") else {
                throw AgentIntentClassifierError.configurationUnavailable
            }
            do {
                let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                _ = try configuration.validatedEndpoint()
                return configuration
            } catch {
                throw AgentIntentClassifierError.invalidConfiguration
            }
        }

        /// Pins the destination and model and rejects invalid resource limits.
        ///
        /// Returns:
        ///   The only HTTPS destination permitted to receive the TypeSafe credential.
        ///
        /// Raises:
        ///   AgentIntentClassifierError: A destination, prompt or limit is invalid.
        func validatedEndpoint() throws -> URL {
            guard endpoint == "https://api.typesafe.ai/v1/systemone",
                  let url = URL(string: endpoint), model == "jev-1.13.0",
                  !promptVersion.isEmpty, promptVersion.utf8.count <= 128,
                  requestTimeoutSeconds.isFinite, requestTimeoutSeconds > 0, requestTimeoutSeconds <= 15,
                  resourceTimeoutSeconds.isFinite, resourceTimeoutSeconds >= requestTimeoutSeconds,
                  resourceTimeoutSeconds <= 30,
                  overallTimeoutSeconds.isFinite, overallTimeoutSeconds > 0, overallTimeoutSeconds <= 15,
                  (1...16_000).contains(maximumInputCharacters),
                  (1...65_536).contains(maximumInputBytes),
                  (1...131_072).contains(maximumRequestBytes),
                  (1...262_144).contains(maximumResponseBytes),
                  probabilitySumTolerance.isFinite, (0...0.05).contains(probabilitySumTolerance),
                  !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  instructions.utf8.count <= 16_384,
                  Set(criteria.keys) == Set(AgentIntent.allCases.map(\.rawValue)),
                  criteria.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_096 }) else {
                throw AgentIntentClassifierError.invalidConfiguration
            }
            return url
        }
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            let type: String
            let choice: AgentIntent
            let confidence: Double
            let probabilities: [String: Double]
        }

        let model: String
        let answers: [String: Answer]
    }

    static let shared = AgentIntentClassifier()
    private nonisolated let configuration: Configuration?
    private var session: URLSession?

    /// Creates an actor without keychain access, resource reads or network activity.
    ///
    /// Args:
    ///   configuration: Optional configuration for a deterministic fixture.
    init(configuration: Configuration? = nil) {
        self.configuration = configuration
    }

    /// Determines the intended Agent operation using the dedicated shortcut context.
    ///
    /// Args:
    ///   text: Original ASR transcript after an explicit Agent shortcut activation.
    ///
    /// Returns:
    ///   A schema-validated judgment with the model's complete probability distribution.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: Configuration, credential, transport or schema failed.
    ///   CancellationError: The recording or owning routing operation was cancelled.
    nonisolated func classify(_ text: String) async throws -> AgentIntentDecision {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let settings = try configuration ?? Configuration.bundled()
        _ = try settings.validatedEndpoint()
        let deadline = started.advanced(by: .seconds(settings.overallTimeoutSeconds))
        return try await Self.withDeadline(deadline) {
            try await self.performClassification(text, configuration: settings)
        }
    }

    /// Bounds caller waiting independently of actor execution and synchronous Security IPC.
    ///
    /// Args:
    ///   deadline: Monotonic deadline covering the complete classification operation.
    ///   operation: Isolated classification work; cancellation is propagated to its task.
    ///
    /// Returns:
    ///   The first result produced before cancellation or the deadline.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: The complete operation exceeds its deadline.
    ///   CancellationError: The caller is cancelled, even if its worker is still blocked.
    nonisolated static func withDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AgentIntentClassifierError.timedOut }
        let gate = AgentIntentCompletionGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    do {
                        try Task.checkCancellation()
                        let decision = try await operation()
                        try Task.checkCancellation()
                        if ContinuousClock.now >= deadline {
                            gate.finish(.failure(AgentIntentClassifierError.timedOut))
                        } else {
                            gate.finish(.success(decision))
                        }
                    } catch {
                        gate.finish(.failure(ContinuousClock.now >= deadline ? AgentIntentClassifierError.timedOut : error))
                    }
                }
                gate.register(worker)
                let timer = Task.detached(priority: .userInitiated) {
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        gate.finish(.failure(AgentIntentClassifierError.timedOut))
                    } catch {
                        // A resolved gate cancels its timer; cancellation produces no second result.
                    }
                }
                gate.register(timer)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Performs actor-isolated credential and network work behind the caller's deadline.
    ///
    /// Args:
    ///   text: Original ASR transcript.
    ///   configuration: Validated prompt and transport limits.
    ///
    /// Returns:
    ///   The validated model judgment, unless its worker was cancelled.
    ///
    /// Raises:
    ///   Error: Credential, transport, response or cancellation failure.
    private func performClassification(_ text: String, configuration settings: Configuration) async throws -> AgentIntentDecision {
        try Task.checkCancellation()
        let transcript = try Self.validatedInput(text, configuration: settings)
        let key = try loadCredentialWithoutInteraction()
        try Task.checkCancellation()
        let request = try Self.request(text: transcript, apiKey: key, configuration: settings)
        let body = try await performRequest(request, configuration: settings)
        return try Self.decodeResponse(body, configuration: settings)
    }

    /// Sends bounded typed questions through the same credential and transport boundary.
    ///
    /// Args:
    ///   payload: JSON encoded by the handoff suggestion service, without credentials.
    ///   maximumRequestBytes: Explicit bound needed for a finite candidate list.
    ///
    /// Returns:
    ///   A bounded response body, whose application schema the caller must validate.
    ///
    /// Raises:
    ///   Error: Invalid input, credential access, cancellation or transport failure.
    nonisolated func requestJSON(_ payload: Data, maximumRequestBytes: Int) async throws -> Data {
        var settings = try configuration ?? Configuration.bundled()
        settings.maximumRequestBytes = maximumRequestBytes
        _ = try settings.validatedEndpoint()
        guard payload.count <= maximumRequestBytes,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["model"] as? String == settings.model else {
            throw AgentIntentClassifierError.invalidConfiguration
        }
        let configuration = settings
        let deadline = ContinuousClock.now.advanced(by: .seconds(settings.overallTimeoutSeconds))
        return try await Self.withDeadline(deadline) {
            try await self.performJSONRequest(payload, configuration: configuration)
        }
    }

    /// Adds a non-interactive credential only after the payload and endpoint are validated.
    ///
    /// Args:
    ///   payload: Bounded JSON payload for the pinned service.
    ///   configuration: Validated transport limits.
    ///
    /// Returns:
    ///   The service response without exposing the credential to the caller.
    ///
    /// Raises:
    ///   Error: Credential, transport or cancellation failure.
    private func performJSONRequest(_ payload: Data, configuration: Configuration) async throws -> Data {
        try Task.checkCancellation()
        let key = try loadCredentialWithoutInteraction()
        try Task.checkCancellation()
        let request = try Self.authenticatedRequest(payload, apiKey: key, configuration: configuration)
        return try await performRequest(request, configuration: configuration)
    }

    /// Reads one bounded response while preserving cancellation and redirect protections.
    ///
    /// Args:
    ///   request: Authenticated request to the pinned endpoint.
    ///   configuration: Transport and response limits.
    ///
    /// Returns:
    ///   Bounded JSON bytes for independent schema validation.
    ///
    /// Raises:
    ///   Error: HTTP, size, cancellation or transport failure.
    private func performRequest(_ request: URLRequest, configuration settings: Configuration) async throws -> Data {
        let transport = transportSession(configuration: settings)
        do {
            let (bytes, response) = try await transport.bytes(for: request)
            // Cancels only this request; the shared session retains reusable connections.
            defer { bytes.task.cancel() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else {
                    throw AgentIntentClassifierError.invalidResponse
                }
                switch response.statusCode {
                case 200: break
                case 401, 403: throw AgentIntentClassifierError.unauthorized
                default: throw AgentIntentClassifierError.rejected(status: response.statusCode)
                }
                guard response.expectedContentLength <= Int64(settings.maximumResponseBytes) else {
                    throw AgentIntentClassifierError.responseTooLarge
                }
                var body = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < settings.maximumResponseBytes else {
                        throw AgentIntentClassifierError.responseTooLarge
                    }
                    body.append(byte)
                }
                try Task.checkCancellation()
                return body
            } onCancel: {
                bytes.task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentIntentClassifierError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? AgentIntentClassifierError.timedOut : .unavailable
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentIntentClassifierError.invalidResponse
        }
    }

    /// Builds a single typed question with no conversation history or target identities.
    ///
    /// Args:
    ///   text: User's ASR transcript.
    ///   apiKey: Credential obtained from the application's keychain.
    ///   configuration: Validated prompt, destination and limits.
    ///
    /// Returns:
    ///   A bounded JSON request that explicitly marks the Agent shortcut activation.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: Input, credential or configuration is invalid.
    nonisolated static func request(text: String, apiKey: String, configuration: Configuration) throws -> URLRequest {
        let transcript = try validatedInput(text, configuration: configuration)
        let payload: [String: Any] = [
            "model": configuration.model,
            "state": ["entrypoint": "agent_hotkey", "user_explicitly_pressed_agent_hotkey": true, "utterance": transcript],
            "questions": ["route": ["type": "choice", "instructions": configuration.instructions, "criteria": configuration.criteria]],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try authenticatedRequest(body, apiKey: apiKey, configuration: configuration)
    }

    /// Authenticates JSON only for the fixed endpoint and rejects header control characters.
    ///
    /// Args:
    ///   body: Serialized, bounded request payload.
    ///   apiKey: Credential read through the application's non-interactive boundary.
    ///   configuration: Validated endpoint and resource limits.
    ///
    /// Returns:
    ///   An authenticated JSON POST request with no redirect authorization.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: Endpoint, credential or body validation failed.
    private nonisolated static func authenticatedRequest(
        _ body: Data, apiKey: String, configuration: Configuration
    ) throws -> URLRequest {
        let endpoint = try configuration.validatedEndpoint()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw AgentIntentClassifierError.missingCredential
        }
        guard body.count <= configuration.maximumRequestBytes else {
            throw AgentIntentClassifierError.inputTooLong
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// Validates every option and its distribution before exposing a routing result.
    ///
    /// Args:
    ///   data: Bounded response body from the pinned endpoint.
    ///   configuration: Expected model and response bounds.
    ///
    /// Returns:
    ///   The declared highest-probability choice; no confidence threshold is inferred.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: JSON, model, answer type or probabilities are invalid.
    nonisolated static func decodeResponse(_ data: Data, configuration: Configuration) throws -> AgentIntentDecision {
        guard data.count <= configuration.maximumResponseBytes else {
            throw AgentIntentClassifierError.responseTooLarge
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.model == configuration.model, Set(response.answers.keys) == ["route"],
                  let answer = response.answers["route"], answer.type == "choice",
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  Set(answer.probabilities.keys) == Set(AgentIntent.allCases.map(\.rawValue)),
                  answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(answer.probabilities.values.reduce(0, +) - 1) <= configuration.probabilitySumTolerance,
                  answer.probabilities[answer.choice.rawValue] == answer.probabilities.values.max() else {
                throw AgentIntentClassifierError.invalidResponse
            }
            return AgentIntentDecision(intent: answer.choice, probabilities: answer.probabilities,
                                       confidence: answer.confidence, model: response.model)
        } catch {
            throw AgentIntentClassifierError.invalidResponse
        }
    }

    /// Rejects empty or oversized transcripts without silently truncating their intent.
    ///
    /// Args:
    ///   text: Raw transcript to validate.
    ///   configuration: Character and UTF-8 byte limits.
    ///
    /// Returns:
    ///   The transcript with only surrounding whitespace removed.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: Input is empty or exceeds either bound.
    private nonisolated static func validatedInput(_ text: String, configuration: Configuration) throws -> String {
        guard text.utf8.count <= configuration.maximumInputBytes else {
            throw AgentIntentClassifierError.inputTooLong
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AgentIntentClassifierError.emptyInput }
        guard value.count <= configuration.maximumInputCharacters else { throw AgentIntentClassifierError.inputTooLong }
        return value
    }

    /// Reads only the dedicated TypeSafe item and refuses interactive keychain authorization.
    ///
    /// Returns:
    ///   The configured API key when the installed application already has read access.
    ///
    /// Raises:
    ///   AgentIntentClassifierError: The item is missing, requires authorization or is unreadable.
    private func loadCredentialWithoutInteraction() throws -> String {
        // Actor isolation keeps Security IPC off MainActor; interaction is explicitly disabled.
        // No legacy lookup, automatic migration or credential write occurs in this boundary.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mytype.scalar",
            kSecAttrAccount as String: "tf_typesafeAPIKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentIntentClassifierError.credentialUnavailable
            }
            return key
        case errSecItemNotFound:
            throw AgentIntentClassifierError.missingCredential
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw AgentIntentClassifierError.credentialAccessRequired
        default:
            throw AgentIntentClassifierError.credentialUnavailable
        }
    }

    /// Reuses one ephemeral session while avoiding disk caches and cookie persistence.
    ///
    /// Args:
    ///   configuration: Connection and complete-request deadlines.
    ///
    /// Returns:
    ///   The actor's reusable session with all redirects refused.
    private func transportSession(configuration: Configuration) -> URLSession {
        if let session { return session }
        let options = URLSessionConfiguration.ephemeral
        options.urlCache = nil
        options.httpCookieStorage = nil
        options.httpShouldSetCookies = false
        options.requestCachePolicy = .reloadIgnoringLocalCacheData
        options.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        options.timeoutIntervalForResource = configuration.resourceTimeoutSeconds
        options.waitsForConnectivity = false
        let session = URLSession(configuration: options, delegate: AgentIntentNoRedirectDelegate(), delegateQueue: nil)
        self.session = session
        return session
    }
}

/// Resolves one caller exactly once while allowing non-cooperative work to finish later.
private final class AgentIntentCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    /// Registers a caller or immediately delivers cancellation that arrived before registration.
    ///
    /// Args:
    ///   continuation: The single suspended classification caller.
    ///
    /// Returns:
    ///   Whether worker and timer tasks should be created.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result = terminalResult {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Registers a task, or cancels it if a competing result already completed the caller.
    ///
    /// Args:
    ///   task: One worker or timer created for this request.
    func register(_ task: Task<Void, Never>) {
        lock.lock()
        let completed = terminalResult != nil
        if !completed { tasks.append(task) }
        lock.unlock()
        if completed { task.cancel() }
    }

    /// Claims the first result, releases the caller and cancels both outstanding tasks.
    ///
    /// Args:
    ///   result: Worker completion, overall timeout or caller cancellation.
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let caller = continuation
        continuation = nil
        let pending = tasks
        tasks.removeAll()
        lock.unlock()
        // Resume outside the lock and before cancellation, which can invoke other handlers.
        caller?.resume(with: result)
        for task in pending { task.cancel() }
    }
}

/// Prevents redirects from replaying either the credential or the spoken transcript.
private final class AgentIntentNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Refuses every redirect, including redirects to another path on the same host.
    ///
    /// Args:
    ///   session: Reusable classifier session.
    ///   task: Task that received the redirect.
    ///   response: Redirect response; its body and headers are never logged.
    ///   request: Proposed redirected request.
    ///   completionHandler: Receives nil to stop redirect handling.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
