import Foundation

struct AgentFuzzyMatcher: Sendable {
    static let defaultThreshold = 0.72
    static let defaultAmbiguityMargin = 0.08

    private static let exactScore = 1.0
    private static let prefixScore = 0.92
    private static let containsScore = 0.86

    let threshold: Double
    let ambiguityMargin: Double

    /// Creates a fuzzy matcher for spoken agent routing.
    ///
    /// Args:
    ///   threshold: Minimum accepted score in the 0...1 range.
    ///   ambiguityMargin: Required score gap between the best and second-best candidates.
    init(
        threshold: Double = Self.defaultThreshold,
        ambiguityMargin: Double = Self.defaultAmbiguityMargin
    ) {
        self.threshold = threshold
        self.ambiguityMargin = ambiguityMargin
    }

    /// Selects the best candidate only when it is confident and unambiguous.
    ///
    /// Args:
    ///   query: Spoken query text.
    ///   candidates: Candidate values to score.
    ///   candidateText: Text field used to score each candidate.
    ///
    /// Returns:
    ///   The accepted candidate, or `nil` when no candidate is strong enough.
    func acceptedBestMatch<Candidate>(
        for query: String,
        in candidates: [Candidate],
        candidateText: (Candidate) -> String
    ) -> Candidate? {
        let scored = candidates.enumerated()
            .map { index, candidate in
                (index: index, candidate: candidate, score: score(query: query, candidate: candidateText(candidate)))
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.index < $1.index
                }
                return $0.score > $1.score
            }

        guard let best = scored.first, best.score >= threshold else {
            return nil
        }
        if scored.count > 1, best.score - scored[1].score < ambiguityMargin {
            return nil
        }
        return best.candidate
    }

    /// Scores a query and candidate using exact, containment, Chinese bigram, and token overlap signals.
    ///
    /// Args:
    ///   query: Spoken query text.
    ///   candidate: Candidate display text or index text.
    ///
    /// Returns:
    ///   Similarity score in the 0...1 range.
    func score(query: String, candidate: String) -> Double {
        let normalizedQuery = normalize(query)
        let normalizedCandidate = normalize(candidate)
        guard !normalizedQuery.isEmpty, !normalizedCandidate.isEmpty else {
            return 0
        }
        if normalizedQuery == normalizedCandidate {
            return Self.exactScore
        }
        if normalizedCandidate.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(normalizedCandidate) {
            return Self.prefixScore
        }
        if significantContains(normalizedQuery, normalizedCandidate) {
            return Self.containsScore
        }
        return max(chineseBigramDice(normalizedQuery, normalizedCandidate), tokenOverlap(normalizedQuery, normalizedCandidate))
    }

    /// Normalizes launcher and session text before fuzzy matching.
    ///
    /// Args:
    ///   value: Raw query or candidate text.
    ///
    /// Returns:
    ///   Lowercase token string with separators flattened and camelCase split.
    func normalize(_ value: String) -> String {
        var output = ""
        var previousWasLowercase = false
        for scalar in value.unicodeScalars {
            let character = Character(scalar)
            if CharacterSet.uppercaseLetters.contains(scalar), previousWasLowercase {
                output.append(" ")
            }

            let isCJK = Self.isCJK(scalar)
            if CharacterSet.alphanumerics.contains(scalar) || isCJK {
                output.append(String(character).lowercased())
                previousWasLowercase = CharacterSet.lowercaseLetters.contains(scalar)
            } else {
                output.append(" ")
                previousWasLowercase = false
            }
        }
        return output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func significantContains(_ query: String, _ candidate: String) -> Bool {
        let compactQuery = query.replacingOccurrences(of: " ", with: "")
        let compactCandidate = candidate.replacingOccurrences(of: " ", with: "")
        guard min(compactQuery.count, compactCandidate.count) >= 2 else {
            return false
        }
        return candidate.contains(query) || query.contains(candidate)
    }

    private func chineseBigramDice(_ query: String, _ candidate: String) -> Double {
        guard containsCJK(query) || containsCJK(candidate) else {
            return 0
        }
        let queryBigrams = Set(bigrams(in: query.replacingOccurrences(of: " ", with: "")))
        let candidateBigrams = Set(bigrams(in: candidate.replacingOccurrences(of: " ", with: "")))
        guard !queryBigrams.isEmpty, !candidateBigrams.isEmpty else {
            return 0
        }
        let intersection = queryBigrams.intersection(candidateBigrams).count
        return Double(2 * intersection) / Double(queryBigrams.count + candidateBigrams.count)
    }

    private func tokenOverlap(_ query: String, _ candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard queryTokens.count > 1 || candidateTokens.count > 1 else {
            return 0
        }
        let overlap = queryTokens.intersection(candidateTokens).count
        let denominator = max(queryTokens.count, candidateTokens.count, 1)
        return Double(overlap) / Double(denominator)
    }

    private func bigrams(in value: String) -> [String] {
        let characters = Array(value)
        guard characters.count >= 2 else {
            return []
        }
        return (0..<(characters.count - 1)).map { index in
            String(characters[index]) + String(characters[index + 1])
        }
    }

    private func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: Self.isCJK)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x4e00 && scalar.value <= 0x9fff
    }
}
