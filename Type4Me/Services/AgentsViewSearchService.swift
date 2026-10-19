import Foundation

/// A transient content-search lead, with no authority to launch an application.
struct AgentsViewSearchHit: Decodable, Equatable, Sendable {
    let sessionID: String
    let agent: String
    let snippet: String
    let ordinal: Int?
    let ordinalRange: [Int]?
    let timestamp: Date?
    let score: Double?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agent, snippet, ordinal, timestamp, score
        case ordinalRange = "ordinal_range"
    }

    /// Creates an evidence-bearing lead without treating its rank as confidence.
    ///
    /// Args:
    ///   sessionID: Identifier emitted by the search backend.
    ///   agent: Backend provider identifier, independent of the Desktop application name.
    ///   snippet: Matching conversation text, kept only for the current search.
    ///   ordinal: Optional archive message number, never a native GUI message ID.
    ///   ordinalRange: Optional archive message range surrounding the match.
    ///   timestamp: Optional timestamp of the matching message.
    ///   score: Optional backend ranking score, never an automatic-open probability.
    init(
        sessionID: String, agent: String, snippet: String, ordinal: Int? = nil,
        ordinalRange: [Int]? = nil, timestamp: Date? = nil, score: Double? = nil
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.snippet = snippet
        self.ordinal = ordinal
        self.ordinalRange = ordinalRange
        self.timestamp = timestamp
        self.score = score
    }

    /// Decodes the backend schema while accepting timestamps with or without fractions.
    ///
    /// Args:
    ///   decoder: JSON decoder positioned at one search match.
    ///
    /// Raises:
    ///   DecodingError: Required identity or text fields have an incompatible type.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        agent = try values.decode(String.self, forKey: .agent)
        snippet = try values.decode(String.self, forKey: .snippet)
        ordinal = try values.decodeIfPresent(Int.self, forKey: .ordinal)
        ordinalRange = try values.decodeIfPresent([Int].self, forKey: .ordinalRange)
        score = try values.decodeIfPresent(Double.self, forKey: .score)
        if let value = try values.decodeIfPresent(String.self, forKey: .timestamp) {
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            timestamp = nil
        }
    }
}

enum AgentsViewSearchError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case queryTooLong
    case unavailable
    case unauthorized
    case timedOut
    case rejected(status: Int)
    case invalidResponse
    case responseTooLarge
    case networkFailure(code: Int)
    case indexUpdating
    case messageTimeFilterUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L("本地会话搜索配置无效。", "The local session-search configuration is invalid.")
        case .queryTooLong:
            return L("查找内容过长，请缩短后重试。", "The search request is too long. Shorten it and try again.")
        case .unavailable:
            return L("本地会话搜索服务未运行。", "The local session-search service is unavailable.")
        case .unauthorized:
            return L("本地会话搜索服务需要授权。", "The local session-search service requires authorization.")
        case .timedOut:
            return L("本地会话搜索超时，请重试。", "The local session search timed out. Try again.")
        case .rejected(let status):
            return L("本地会话搜索请求被拒绝（\(status)）。", "The local session-search request was rejected (\(status)).")
        case .invalidResponse:
            return L("本地会话搜索返回了无法识别的数据。", "The local session-search response could not be recognized.")
        case .responseTooLarge:
            return L("本地会话搜索结果超过大小上限。", "The local session-search response exceeded its size limit.")
        case .networkFailure(let code):
            return L("本地会话搜索连接失败（\(code)）。", "The local session-search connection failed (\(code)).")
        case .indexUpdating:
            return L("会话索引尚未确认完整，部分内容可能还未加入，请查看索引状态。", "Index coverage is not yet confirmed. Some content may be missing; check the index status.")
        case .messageTimeFilterUnavailable:
            return L("当前搜索服务暂不支持按对话时间查找。", "The current search service cannot filter by conversation time.")
        }
    }
}

/// Searches a local AgentsView service without importing its launch commands or credentials.
actor AgentsViewSearchService {
    struct Configuration: Decodable, Equatable, Sendable {
        private static let maximumTimeoutSeconds: TimeInterval = 60
        var endpoint = "http://127.0.0.1:18742"
        var requestTimeoutSeconds: TimeInterval = 15
        var resourceTimeoutSeconds: TimeInterval = 30
        var maximumResponseBytes = 262_144
        var maximumQueryCharacters = 512
        var maximumResults = 20
        var maximumWakeSearchHits = 120
        var maximumWakeResponseBytes = 1_048_576
        var maximumSnippetCharacters = 400
        var maximumSessionIdentifierCharacters = 256
        var maximumOrdinalRangeEntries = 32

        /// Reads non-secret packaged defaults, preserving explicit configuration failures.
        ///
        /// Args:
        ///   bundle: Application bundle containing the JSON resource.
        ///
        /// Returns:
        ///   Packaged settings, or typed defaults when a development binary has no resource.
        ///
        /// Raises:
        ///   AgentsViewSearchError: The existing resource cannot be read or decoded.
        static func bundled(in bundle: Bundle = .main) throws -> Configuration {
            guard let url = bundle.url(forResource: "AgentsViewSearchConfig", withExtension: "json") else {
                return Configuration()
            }
            do {
                return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            } catch {
                throw AgentsViewSearchError.invalidConfiguration
            }
        }

        /// Rejects external hosts, embedded credentials, endpoint paths and invalid bounds.
        ///
        /// Returns:
        ///   A root HTTP URL with an explicit numeric loopback address.
        ///
        /// Raises:
        ///   AgentsViewSearchError: Any endpoint or resource limit is invalid.
        func validatedEndpoint() throws -> URL {
            guard let components = URLComponents(string: endpoint),
                  components.scheme == "http", let host = components.host,
                  ["127.0.0.1", "::1", "[::1]"].contains(host),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  components.port.map({ (1...65_535).contains($0) }) ?? true,
                  requestTimeoutSeconds.isFinite, requestTimeoutSeconds > 0,
                  resourceTimeoutSeconds.isFinite, resourceTimeoutSeconds >= requestTimeoutSeconds,
                  resourceTimeoutSeconds <= Self.maximumTimeoutSeconds,
                  maximumResponseBytes > 0, maximumQueryCharacters > 0, maximumResults > 0,
                  (1...500).contains(maximumWakeSearchHits), (1...4_194_304).contains(maximumWakeResponseBytes),
                  maximumSnippetCharacters > 0, maximumSessionIdentifierCharacters > 0,
                  maximumOrdinalRangeEntries > 0,
                  let url = components.url else { throw AgentsViewSearchError.invalidConfiguration }
            return url
        }
    }

    private struct Response: Decodable {
        let matches: [AgentsViewSearchHit]
        let messageTimeFilterApplied: Bool?

        private enum CodingKeys: String, CodingKey {
            case matches
            case messageTimeFilterApplied = "message_time_filter_applied"
        }
    }

    static let shared = AgentsViewSearchService()
    private let settings: Result<Configuration, AgentsViewSearchError>

    /// Creates a search boundary using explicit fixtures or a non-secret bundle resource.
    ///
    /// Args:
    ///   configuration: Optional settings for deterministic fixture checks.
    init(configuration: Configuration? = nil) {
        do {
            let value = try configuration ?? Configuration.bundled()
            _ = try value.validatedEndpoint()
            settings = .success(value)
        } catch {
            settings = .failure(.invalidConfiguration)
        }
    }

    /// Retrieves transient content leads and keeps the best hit for each independent session.
    ///
    /// Args:
    ///   query: User's request to resume prior work, never sent outside loopback.
    ///
    /// Returns:
    ///   Backend-ranked leads with bounded snippets; an empty query returns no leads.
    ///
    /// Raises:
    ///   AgentsViewSearchError: Configuration, HTTP, schema or size validation failed.
    ///   CancellationError: The owning routing task was replaced or cancelled.
    func search(_ query: String) async throws -> [AgentsViewSearchHit] {
        try Task.checkCancellation()
        return try await search(query, agent: nil, configuration: settings.get())
    }

    /// Searches an already resolved topic with independent source and message-time constraints.
    ///
    /// Args:
    ///   query: Topic and metadata resolved by the wake router, including any explicit refinement.
    ///
    /// Returns:
    ///   Distinct conversations with evidence satisfying every explicit constraint.
    ///
    /// Raises:
    ///   Error: Transport, configuration or unsupported message-time filtering failed.
    func search(_ query: AgentSearchQuery) async throws -> [AgentsViewSearchHit] {
        var configuration = try settings.get()
        configuration.maximumResults = configuration.maximumWakeSearchHits
        configuration.maximumResponseBytes = configuration.maximumWakeResponseBytes
        return try await search(query.text, agent: query.agent, configuration: configuration,
                                messageInterval: query.messageInterval, timezoneIdentifier: query.timezoneIdentifier)
    }

    /// Retrieves a finite wider pool for handoff suggestions without changing normal wake search.
    ///
    /// Args:
    ///   query: Role-specific text derived from the user's original request.
    ///   agent: Optional explicit provider constraint, either codex or claude.
    ///   maximumResults: Maximum message hits requested before local session aggregation.
    ///   maximumResponseBytes: Byte limit for the wider response.
    ///
    /// Returns:
    ///   Distinct session leads after the bounded backend hit limit.
    ///
    /// Raises:
    ///   Error: Invalid bounds, configuration, cancellation or search failure.
    func searchForHandoff(
        _ query: String, agent: String?, maximumResults: Int, maximumResponseBytes: Int
    ) async throws -> [AgentsViewSearchHit] {
        guard (1...500).contains(maximumResults), (1...4_194_304).contains(maximumResponseBytes) else {
            throw AgentsViewSearchError.invalidConfiguration
        }
        var configuration = try settings.get()
        configuration.maximumResults = maximumResults
        configuration.maximumResponseBytes = maximumResponseBytes
        return try await search(query, agent: agent, configuration: configuration)
    }

    /// Executes one local read using caller-specific bounds and no redirect or proxy forwarding.
    ///
    /// Args:
    ///   query: Search text, kept on the loopback service.
    ///   agent: Optional validated provider filter.
    ///   configuration: Transport and result bounds.
    ///   messageInterval: Optional matching-message dates, with an exclusive end.
    ///   timezoneIdentifier: User time zone used to resolve relative dates.
    ///
    /// Returns:
    ///   Sanitized, session-deduplicated search leads.
    ///
    /// Raises:
    ///   Error: Validation, cancellation or transport failure.
    private func search(
        _ query: String, agent: String?, configuration: Configuration,
        messageInterval: DateInterval? = nil, timezoneIdentifier: String? = nil
    ) async throws -> [AgentsViewSearchHit] {
        try Task.checkCancellation()
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || messageInterval != nil else { return [] }
        guard value.count <= configuration.maximumQueryCharacters else { throw AgentsViewSearchError.queryTooLong }
        let request = try Self.request(query: value, configuration: configuration, agent: agent,
                                       messageInterval: messageInterval, timezoneIdentifier: timezoneIdentifier)
        let transport = URLSessionConfiguration.ephemeral
        transport.connectionProxyDictionary = [:]
        transport.urlCache = nil
        transport.httpCookieStorage = nil
        transport.httpShouldSetCookies = false
        transport.requestCachePolicy = .reloadIgnoringLocalCacheData
        transport.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        transport.timeoutIntervalForResource = configuration.resourceTimeoutSeconds
        let session = URLSession(configuration: transport, delegate: AgentsViewNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw AgentsViewSearchError.invalidResponse }
                switch response.statusCode {
                case 200: break
                case 401, 403: throw AgentsViewSearchError.unauthorized
                default: throw AgentsViewSearchError.rejected(status: response.statusCode)
                }
                if response.expectedContentLength > Int64(configuration.maximumResponseBytes) {
                    throw AgentsViewSearchError.responseTooLarge
                }
                var body: [UInt8] = []
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < configuration.maximumResponseBytes else { throw AgentsViewSearchError.responseTooLarge }
                    body.append(byte)
                }
                try Task.checkCancellation()
                return try Self.decodeResponse(Data(body), configuration: configuration,
                                                agent: agent, messageInterval: messageInterval)
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentsViewSearchError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            switch error.code {
            case .timedOut: throw AgentsViewSearchError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw AgentsViewSearchError.unavailable
            default: throw AgentsViewSearchError.networkFailure(code: error.errorCode)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentsViewSearchError.invalidResponse
        }
    }

    /// Builds a local content-search request, including this fork's message-time extension.
    ///
    /// Args:
    ///   query: Validated user request.
    ///   configuration: Endpoint, deadline and result bounds.
    ///   agent: Optional owning-provider constraint for wake or handoff lookup.
    ///   messageInterval: Optional half-open bounds on the matching message, not the session lifetime.
    ///   timezoneIdentifier: User timezone retained independently of the UTC request bounds.
    ///
    /// Returns:
    ///   An HTTP GET request with explicit semantic-search consent for the local index.
    ///
    /// Raises:
    ///   AgentsViewSearchError: The endpoint is not a numeric loopback root URL.
    nonisolated static func request(
        query: String, configuration: Configuration, agent: String? = nil,
        messageInterval: DateInterval? = nil, timezoneIdentifier: String? = nil
    ) throws -> URLRequest {
        let endpoint = try configuration.validatedEndpoint()
        guard query.count <= configuration.maximumQueryCharacters else { throw AgentsViewSearchError.queryTooLong }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AgentsViewSearchError.invalidConfiguration
        }
        components.path = "/api/v1/search/content"
        let timeOnly = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && messageInterval != nil
        components.queryItems = [
            URLQueryItem(name: "pattern", value: timeOnly ? "." : query),
            URLQueryItem(name: "mode", value: timeOnly ? "regex" : "hybrid"),
            URLQueryItem(name: "in", value: "messages"),
            URLQueryItem(name: "include_one_shot", value: "true"), URLQueryItem(name: "exclude_system", value: "true"),
            URLQueryItem(name: "limit", value: String(configuration.maximumResults)),
        ]
        if !timeOnly { components.queryItems?.append(URLQueryItem(name: "scope", value: "top")) }
        if let agent {
            guard ["codex", "claude"].contains(agent) else { throw AgentsViewSearchError.invalidConfiguration }
            components.queryItems?.append(URLQueryItem(name: "agent", value: agent))
        }
        if let messageInterval {
            guard messageInterval.duration > 0, messageInterval.duration.isFinite,
                  messageInterval.start.timeIntervalSince1970.isFinite,
                  messageInterval.end.timeIntervalSince1970.isFinite else {
                throw AgentsViewSearchError.invalidConfiguration
            }
            let formatter = ISO8601DateFormatter()
            components.queryItems?.append(URLQueryItem(name: "message_from", value: formatter.string(from: messageInterval.start)))
            components.queryItems?.append(URLQueryItem(name: "message_to", value: formatter.string(from: messageInterval.end)))
        }
        if let timezoneIdentifier {
            guard TimeZone(identifier: timezoneIdentifier) != nil else { throw AgentsViewSearchError.invalidConfiguration }
            components.queryItems?.append(URLQueryItem(name: "timezone", value: timezoneIdentifier))
        }
        // Go's query decoder treats literal plus signs as spaces; preserve the user's text.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw AgentsViewSearchError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.requestTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("semantic", forHTTPHeaderField: "X-AgentsView-Search-Intent")
        return request
    }

    /// Validates evidence and deduplicates exact identities without merging equal titles or forks.
    ///
    /// Args:
    ///   data: Bounded backend JSON payload.
    ///   configuration: Result, snippet and identifier bounds.
    ///   agent: Optional owning-provider restriction, independently rechecked after transport.
    ///   messageInterval: Optional half-open interval requiring an explicit backend capability receipt.
    ///
    /// Returns:
    ///   At most the configured number of distinct provider-qualified sessions.
    ///
    /// Raises:
    ///   AgentsViewSearchError: The response schema or required evidence is invalid.
    nonisolated static func decodeResponse(
        _ data: Data, configuration: Configuration, agent: String? = nil, messageInterval: DateInterval? = nil
    ) throws -> [AgentsViewSearchHit] {
        _ = try configuration.validatedEndpoint()
        guard data.count <= configuration.maximumResponseBytes else { throw AgentsViewSearchError.responseTooLarge }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AgentsViewSearchError.invalidResponse }
        if messageInterval != nil, decoded.messageTimeFilterApplied != true {
            throw AgentsViewSearchError.messageTimeFilterUnavailable
        }
        var hits: [AgentsViewSearchHit] = []
        var indexes: [String: Int] = [:]
        for hit in decoded.matches {
            guard agent == nil || hit.agent == agent else { continue }
            if let messageInterval {
                guard let timestamp = hit.timestamp, timestamp >= messageInterval.start,
                      timestamp < messageInterval.end else { continue }
            }
            guard !hit.sessionID.isEmpty, hit.sessionID.count <= configuration.maximumSessionIdentifierCharacters,
                  !hit.sessionID.contains("\0"), ["codex", "claude"].contains(hit.agent),
                  hit.ordinal.map({ $0 >= 0 }) ?? true,
                  hit.ordinalRange.map({ $0.count <= configuration.maximumOrdinalRangeEntries && $0.allSatisfy { $0 >= 0 } }) ?? true,
                  hit.score.map({ $0.isFinite }) ?? true else { continue }
            let snippet = String(hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(configuration.maximumSnippetCharacters))
            guard !snippet.isEmpty, !snippet.contains("\0") else { continue }
            let bounded = AgentsViewSearchHit(sessionID: hit.sessionID, agent: hit.agent, snippet: snippet,
                                             ordinal: hit.ordinal, ordinalRange: hit.ordinalRange,
                                             timestamp: hit.timestamp, score: hit.score)
            let key = hit.agent + ":" + hit.sessionID
            if let index = indexes[key] {
                if (bounded.score ?? -.infinity) > (hits[index].score ?? -.infinity) { hits[index] = bounded }
            } else if hits.count < configuration.maximumResults {
                indexes[key] = hits.count
                hits.append(bounded)
            }
        }
        return hits
    }

    /// Joins a search identity to one exact native conversation without guessing from paths.
    ///
    /// Args:
    ///   hit: Backend search lead, with no trusted Desktop destination URL.
    ///   sessions: Current native metadata catalog reloaded by the router.
    ///
    /// Returns:
    ///   The uniquely identified native conversation, or nil for missing, invalid or ambiguous mappings.
    nonisolated static func nativeSession(
        for hit: AgentsViewSearchHit, in sessions: [AgentSessionDescriptor]
    ) -> AgentSessionDescriptor? {
        switch hit.agent {
        case "codex":
            let prefix = "codex:"
            guard hit.sessionID.hasPrefix(prefix) else { return nil }
            let nativeID = String(hit.sessionID.dropFirst(prefix.count))
            guard AgentSessionMetadataValidation.isValidIdentifier(nativeID) else { return nil }
            let matches = sessions.filter { $0.application == .codex && $0.sessionID == nativeID }
            return matches.count == 1 ? matches.first : nil
        case "claude":
            guard let engineID = UUID(uuidString: hit.sessionID) else { return nil }
            let matches = sessions.filter {
                $0.application == .claudeCode && AgentSessionMetadataValidation.isValidClaudeNativeIdentifier($0.sessionID)
                    && $0.engineSessionID.flatMap { UUID(uuidString: $0) } == engineID
            }
            return matches.count == 1 ? matches.first : nil
        default:
            return nil
        }
    }
}

/// Refuses redirects so a local search query cannot be forwarded to an external host.
private final class AgentsViewNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// Keeps the original response instead of following any HTTP redirect.
    ///
    /// Args:
    ///   session: Ephemeral local search session.
    ///   task: Current search request.
    ///   response: Redirect response received from the local service.
    ///   request: Proposed redirected request, which is never executed.
    ///   completionHandler: Receives nil to reject the redirect.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
