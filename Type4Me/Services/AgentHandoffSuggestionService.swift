import Foundation

/// Search evidence for an editable handoff choice; it never authorizes delivery.
struct AgentHandoffSuggestionCandidate: Equatable, Sendable {
    let session: AgentSessionDescriptor
    let snippet: String
    let timestamp: Date?
}

enum AgentHandoffSuggestionNotice: Equatable, Sendable {
    case ambiguous
    case rankingUnavailable
}

struct AgentHandoffSuggestion: Sendable {
    let sources: [AgentHandoffSuggestionCandidate]
    let targets: [AgentHandoffSuggestionCandidate]
    let sourceID: String?
    let targetID: String?
    let notice: AgentHandoffSuggestionNotice?
}

enum AgentHandoffSuggestionError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L("交接建议配置不可用，请手动选择会话。", "Handoff suggestion settings are unavailable. Choose conversations manually.")
        case .invalidResponse:
            return L("交接建议无效，请核对并选择会话。", "The handoff suggestion is invalid. Review and choose conversations.")
        case .invalidInput:
            return L("请用简短的一句话描述要交接的工作。", "Describe the work to hand off in a short request.")
        }
    }
}

/// Finds and ranks existing native sessions without opening them or sending messages.
actor AgentHandoffSuggestionService {
    typealias SearchProvider = @Sendable (String, String?, Int, Int) async throws -> [AgentsViewSearchHit]
    typealias RankingProvider = @Sendable (Data, Int) async throws -> Data

    struct Lane: Equatable, Sendable {
        let query: String
        let provider: String?
    }

    struct RolePlan: Equatable, Sendable {
        let source: Lane
        let destination: Lane
    }

    struct Ranking: Equatable, Sendable {
        let sourceID: String?
        let targetID: String?
        let ambiguous: Bool
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            let type: String
            let choice: String
            let confidence: Double
            let probabilities: [String: Double]
        }
        let model: String
        let answers: [String: Answer]
    }

    static let shared = AgentHandoffSuggestionService()
    private let configuration: Result<AgentHandoffSuggestionConfiguration, AgentHandoffSuggestionError>
    private let search: SearchProvider
    private let rank: RankingProvider

    /// Installs bounded read-only providers without accessing credentials or starting work.
    ///
    /// Args:
    ///   configuration: Optional deterministic settings; otherwise packaged defaults are loaded.
    ///   search: Optional local content-search fixture.
    ///   rank: Optional typed-choice fixture; production shares the existing Jev transport.
    init(
        configuration: AgentHandoffSuggestionConfiguration? = nil,
        search: SearchProvider? = nil,
        rank: RankingProvider? = nil
    ) {
        do {
            let settings = try configuration ?? AgentHandoffSuggestionConfiguration.bundled()
            try settings.validate()
            self.configuration = .success(settings)
        } catch {
            self.configuration = .failure(.invalidConfiguration)
        }
        self.search = search ?? { query, provider, limit, bytes in
            try await AgentsViewSearchService.shared.searchForHandoff(
                query, agent: provider, maximumResults: limit, maximumResponseBytes: bytes
            )
        }
        self.rank = rank ?? { payload, maximumBytes in
            try await AgentIntentClassifier.shared.requestJSON(payload, maximumRequestBytes: maximumBytes)
        }
    }

    /// Prepares editable suggestions, leaving unsupported or missing choices empty.
    ///
    /// Args:
    ///   text: The original handoff utterance, used as evidence rather than instructions.
    ///   sessions: Current native catalog; only exact identity joins are eligible.
    ///
    /// Returns:
    ///   Two candidate lists and optional preselected native IDs for explicit user confirmation.
    ///
    /// Raises:
    ///   Error: Configuration, input, local search or cancellation failed. Ranking failure is recoverable.
    func suggest(_ text: String, sessions: [AgentSessionDescriptor]) async throws -> AgentHandoffSuggestion {
        let settings = try configuration.get()
        try Task.checkCancellation()
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, utterance.count <= settings.maximumInputCharacters,
              utterance.utf8.count <= settings.maximumInputBytes else { throw AgentHandoffSuggestionError.invalidInput }
        let plan = Self.rolePlan(utterance, configuration: settings)
        let sourceHits: [AgentsViewSearchHit]
        let targetHits: [AgentsViewSearchHit]
        if plan.source == plan.destination {
            sourceHits = try await search(plan.source.query, plan.source.provider, settings.maximumSearchHits, settings.maximumSearchResponseBytes)
            targetHits = sourceHits
        } else {
            async let source = search(plan.source.query, plan.source.provider, settings.maximumSearchHits, settings.maximumSearchResponseBytes)
            async let target = search(plan.destination.query, plan.destination.provider, settings.maximumSearchHits, settings.maximumSearchResponseBytes)
            (sourceHits, targetHits) = try await (source, target)
        }
        try Task.checkCancellation()
        let sources = Self.candidates(sourceHits, sessions: sessions, provider: plan.source.provider, configuration: settings)
        let targets = Self.candidates(targetHits, sessions: sessions, provider: plan.destination.provider, configuration: settings)
        guard !sources.isEmpty || !targets.isEmpty else {
            return AgentHandoffSuggestion(sources: [], targets: [], sourceID: nil, targetID: nil, notice: nil)
        }
        do {
            let payload = try Self.payload(utterance, sources: sources, targets: targets, configuration: settings)
            let response = try await rank(payload, settings.maximumRequestBytes)
            try Task.checkCancellation()
            let choice = try Self.decodeResponse(response, sources: sources, targets: targets, configuration: settings)
            return AgentHandoffSuggestion(sources: sources, targets: targets, sourceID: choice.sourceID,
                                          targetID: choice.targetID, notice: choice.ambiguous ? .ambiguous : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A failed judge cannot turn search rank into an unverified automatic selection.
            return AgentHandoffSuggestion(sources: sources, targets: targets, sourceID: nil,
                                          targetID: nil, notice: .rankingUnavailable)
        }
    }

    /// Extracts only explicit direction forms; unsupported grammar uses the full utterance.
    ///
    /// Args:
    ///   text: Original user request, never a model-generated rewrite.
    ///   configuration: Query bounds and relative-reference patterns.
    ///
    /// Returns:
    ///   Separate source and destination lanes with unambiguous literal provider constraints.
    nonisolated static func rolePlan(
        _ text: String, configuration: AgentHandoffSuggestionConfiguration
    ) -> RolePlan {
        let fallback = Lane(query: String(text.prefix(configuration.maximumQueryCharacters)), provider: nil)
        var pair: (String, String)?
        for pattern in configuration.directionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges == 3,
                  let sourceRange = Range(match.range(at: 1), in: text),
                  let targetRange = Range(match.range(at: 2), in: text) else { continue }
            let source = String(text[sourceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(text[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty else { continue }
            pair = (source, target)
            break
        }
        guard let (source, destination) = pair else { return RolePlan(source: fallback, destination: fallback) }
        let sourceProvider = provider(in: source, configuration: configuration)
        let targetProvider = provider(in: destination, configuration: configuration)
        let relative = destination.range(of: configuration.relativeReferencePattern, options: .regularExpression) != nil
        var targetQuery = destination
        if relative {
            var topic = source
            for pattern in configuration.providerPatterns.values {
                topic = topic.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            }
            targetQuery += " " + topic
        }
        return RolePlan(
            source: Lane(query: String(source.prefix(configuration.maximumQueryCharacters)), provider: sourceProvider),
            destination: Lane(query: String(targetQuery.prefix(configuration.maximumQueryCharacters)), provider: targetProvider)
        )
    }

    /// Resolves a provider only when one supported name appears in a literal role span.
    ///
    /// Args:
    ///   text: One source or destination span.
    ///   configuration: Supported provider aliases.
    ///
    /// Returns:
    ///   A single provider name, or nil when absent or conflicting.
    private nonisolated static func provider(in text: String, configuration: AgentHandoffSuggestionConfiguration) -> String? {
        let matches = configuration.providerPatterns.filter {
            text.range(of: $0.value, options: [.regularExpression, .caseInsensitive]) != nil
        }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }

    /// Groups finite search hits by exact native identity while preserving relevance order.
    ///
    /// Args:
    ///   hits: Ranked local search evidence.
    ///   sessions: Current native catalog, including the Claude engine-to-native mapping.
    ///   provider: Optional literal provider restriction, rechecked independently of the server.
    ///   configuration: Candidate and snippet bounds.
    ///
    /// Returns:
    ///   At most the configured number of independent native sessions; equal titles stay separate.
    nonisolated static func candidates(
        _ hits: [AgentsViewSearchHit], sessions: [AgentSessionDescriptor], provider: String?,
        configuration: AgentHandoffSuggestionConfiguration
    ) -> [AgentHandoffSuggestionCandidate] {
        var result: [AgentHandoffSuggestionCandidate] = []
        var seen = Set<String>()
        for hit in hits.prefix(configuration.maximumSearchHits) {
            guard provider == nil || hit.agent == provider,
                  let session = AgentsViewSearchService.nativeSession(for: hit, in: sessions),
                  session.canOpenExistingConversation, seen.insert(session.id).inserted else { continue }
            result.append(AgentHandoffSuggestionCandidate(
                session: session, snippet: boundedText(hit.snippet, limit: configuration.maximumSnippetCharacters),
                timestamp: hit.timestamp
            ))
            if result.count == configuration.maximumCandidatesPerRole { break }
        }
        return result
    }

    /// Creates two bounded Choice questions without exposing native IDs or transcript paths.
    ///
    /// Args:
    ///   text: Original user utterance.
    ///   sources: Ranked source evidence.
    ///   targets: Ranked receiver evidence.
    ///   configuration: Model, prompts and payload limits.
    ///
    /// Returns:
    ///   JSON containing finite choices plus explicit none and ambiguous outcomes.
    ///
    /// Raises:
    ///   Error: Invalid configuration or an oversized request.
    nonisolated static func payload(
        _ text: String, sources: [AgentHandoffSuggestionCandidate], targets: [AgentHandoffSuggestionCandidate],
        configuration: AgentHandoffSuggestionConfiguration
    ) throws -> Data {
        try configuration.validate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= configuration.maximumInputCharacters, text.utf8.count <= configuration.maximumInputBytes,
              sources.count <= configuration.maximumCandidatesPerRole, targets.count <= configuration.maximumCandidatesPerRole else {
            throw AgentHandoffSuggestionError.invalidInput
        }
        var questions: [String: Any] = [:]
        var evidence: [[String: Any]] = []
        for (role, candidates) in [("source", sources), ("destination", targets)] {
            var criteria = ["none": configuration.noneCriterion, "ambiguous": configuration.ambiguousCriterion]
            for (index, candidate) in candidates.enumerated() {
                let key = option(role, index: index)
                criteria[key] = configuration.candidateCriterion + " " + key
                let session = candidate.session
                var item: [String: Any] = [
                    "option": key, "role": role,
                    "provider": session.application == .codex ? "codex" : "claude",
                    "title": boundedText(session.title, limit: configuration.maximumTitleCharacters),
                    "snippet": boundedText(candidate.snippet, limit: configuration.maximumSnippetCharacters),
                ]
                if let path = session.workspacePath,
                   path.hasPrefix("/"), !path.contains("\0"),
                   path.trimmingCharacters(in: .whitespacesAndNewlines) == path {
                    let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name != "/", name != ".", name != ".." {
                        item["workspace_name"] = boundedText(name, limit: configuration.maximumTitleCharacters)
                    }
                }
                if session.updatedAt.isFinite, session.updatedAt > 0 {
                    item["last_activity"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: session.updatedAt))
                }
                if let timestamp = candidate.timestamp { item["matched_message_at"] = ISO8601DateFormatter().string(from: timestamp) }
                evidence.append(item)
            }
            questions[role] = ["type": "choice", "instructions": configuration.instructions + " " + (role == "source" ? configuration.sourceInstructions : configuration.targetInstructions), "criteria": criteria]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "state": ["utterance": text, "user_confirmation_required": true, "candidates": evidence],
            "questions": questions,
        ], options: [.sortedKeys])
        guard data.count <= configuration.maximumRequestBytes else { throw AgentHandoffSuggestionError.invalidInput }
        return data
    }

    /// Validates each answer against the exact role choices before producing native IDs.
    ///
    /// Args:
    ///   data: Bounded service response.
    ///   sources: Exact source pool used for this request.
    ///   targets: Exact destination pool used for this request.
    ///   configuration: Expected model and probability tolerance.
    ///
    /// Returns:
    ///   Optional suggestions; ambiguity may preselect a candidate, but never authorizes sending.
    ///
    /// Raises:
    ///   AgentHandoffSuggestionError: Any model, type, option or probability is invalid.
    nonisolated static func decodeResponse(
        _ data: Data, sources: [AgentHandoffSuggestionCandidate], targets: [AgentHandoffSuggestionCandidate],
        configuration: AgentHandoffSuggestionConfiguration
    ) throws -> Ranking {
        guard data.count <= configuration.maximumResponseBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.model == configuration.model, Set(response.answers.keys) == ["source", "destination"] else {
            throw AgentHandoffSuggestionError.invalidResponse
        }
        var ids: [String: String] = [:]
        var ambiguous = false
        for (role, candidates) in [("source", sources), ("destination", targets)] {
            let keys = candidates.indices.map { option(role, index: $0) }
            let allowed = Set(keys + ["none", "ambiguous"])
            guard let answer = response.answers[role], answer.type == "choice", allowed.contains(answer.choice),
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  Set(answer.probabilities.keys) == allowed,
                  answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(answer.probabilities.values.reduce(0, +) - 1) <= configuration.probabilitySumTolerance,
                  answer.probabilities[answer.choice] == answer.probabilities.values.max() else {
                throw AgentHandoffSuggestionError.invalidResponse
            }
            if answer.choice == "none" { continue }
            let index: Int?
            if answer.choice == "ambiguous" {
                // The highest-ranked actual choice remains a suggestion for the human to review.
                ambiguous = true
                index = candidates.indices.sorted {
                    let left = answer.probabilities[keys[$0], default: 0]
                    let right = answer.probabilities[keys[$1], default: 0]
                    return left == right ? $0 < $1 : left > right
                }.first
            } else {
                index = keys.firstIndex(of: answer.choice)
            }
            if let index { ids[role] = candidates[index].session.id }
        }
        if let source = ids["source"], source == ids["destination"] {
            ids["destination"] = nil
            ambiguous = true
        }
        return Ranking(sourceID: ids["source"], targetID: ids["destination"], ambiguous: ambiguous)
    }

    /// Makes a role-qualified opaque option key without sending native identity to the model.
    ///
    /// Args:
    ///   role: Source or destination question.
    ///   index: Position in that question's candidate list.
    ///
    /// Returns:
    ///   The stable option key for one request.
    private nonisolated static func option(_ role: String, index: Int) -> String { role + "_" + String(index) }

    /// Bounds transient evidence and removes recognizable credential-like values.
    ///
    /// Args:
    ///   text: Local search evidence or native title.
    ///   limit: Maximum retained character count.
    ///
    /// Returns:
    ///   Redacted evidence; no transcript file or complete history is read.
    private nonisolated static func boundedText(_ text: String, limit: Int) -> String {
        let redacted = text.replacingOccurrences(
            of: #"(?i)\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{15,}|Bearer\s+[^\s\"<>]+)"#,
            with: "[REDACTED]", options: .regularExpression
        )
        return String(redacted.prefix(limit))
    }
}
