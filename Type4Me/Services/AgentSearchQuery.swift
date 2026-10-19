import Foundation

enum AgentSearchQueryError: Error, Equatable, Sendable {
    case invalidConfiguration
    case inputTooLong
    case invalidDate
}

/// Separates explicit conversation ownership and message dates from a spoken topic.
struct AgentSearchQuery: Equatable, Sendable {
    let text: String
    let agent: String?
    let messageInterval: DateInterval?
    let timezoneIdentifier: String
    let isRefinement: Bool

    struct Configuration: Codable, Sendable {
        var maximumInputCharacters = 2_048
        var maximumInputBytes = 8_192
        var contextLifetimeSeconds: TimeInterval = 300
        var providerPatterns = [
            "codex": [
                #"(?i)(?<![A-Za-z0-9])(?:在\s*)?(?:codex|code\s*x)(?![A-Za-z0-9])\s*(?:里面|里|中)(?:\s*的)?"#,
                #"(?i)(?<![A-Za-z0-9])(?:codex|code\s*x)(?![A-Za-z0-9])\s*的\s*(?=(?:那个|这个|会话|对话|agent)(?:\s|$|[，,。.!！?？]))"#,
                #"(?i)\b(?:in|from|on)\s+(?:codex|code\s*x)\b"#,
            ],
            "claude": [
                #"(?i)(?<![A-Za-z0-9])(?:在\s*)?(?:claude|cloud)(?:\s+code)?(?![A-Za-z0-9])\s*(?:里面|里|中)(?:\s*的)?"#,
                #"(?i)(?<![A-Za-z0-9])(?:claude|cloud)(?:\s+code)?(?![A-Za-z0-9])\s*的\s*(?=(?:那个|这个|会话|对话|agent)(?:\s|$|[，,。.!！?？]))"#,
                #"(?i)\b(?:in|from|on)\s+(?:claude|cloud)(?:\s+code)?\b"#,
            ],
        ]
        var timePatterns = [
            #"(前天|昨天|今天|本周|这周|上周)\s*(?=(?:我(?:们)?\s*)?(?:聊(?:过|天)?|讨论(?:过)?|谈(?:过)?|交流(?:过)?|提到(?:过)?|说过))"#,
            #"(前天|昨天|今天|本周|这周|上周)\s*(?:的\s*)?(?=(?:那个|这个|会话|对话)(?:\s|$|[，,。.!！?？]))"#,
            #"(?i)\b(day before yesterday|yesterday|today|this week|last week)\b(?=\s+(?:(?:we|i)\s+)?(?:talked|discussed|chatted|spoke)\b)"#,
            #"(?i)\b(?:the\s+)?(?:conversation|chat|session)\s+(?:from|on)\s+(?:the\s+)?(day before yesterday|yesterday|today|this week|last week)\b"#,
            #"(?i)\b(?:(?:we|i)\s+)?(?:discussed|talked|chatted|spoke)\s+(?:on\s+)?(day before yesterday|yesterday|today|this week|last week)\b(?!['’])"#,
        ]
        var ambiguousSourcePattern = #"(?i)^\s*(?:在\s*)?(?:codex|code\s*x|claude(?:\s+code)?|cloud(?:\s+code)?)\s*(?:和|或(?:者)?|、|/|\band\b|\bor\b)\s*(?:codex|code\s*x|claude(?:\s+code)?|cloud(?:\s+code)?)(?![A-Za-z0-9])\s*(?:里面|里|中|的)"#
        var ambiguousTimePattern = #"(?:前天|昨天|今天|本周|这周|上周)\s*(?:或(?:者)?|和|、|/)?\s*(?:前天|昨天|今天|本周|这周|上周)\s*(?:的\s*)?(?=聊|讨论|谈|交流|提到|说过|那个|这个|会话|对话)"#
        var negatedMetadataPrefixPattern = #"(?i)(?:不是|不要|别|并非|非|不在|不想(?:找|要)?|不|\bnot|\bexcept|\bexcluding|\banything\s+but)\s*$"#
        var dayOffsets = ["今天": 0, "昨天": -1, "前天": -2, "today": 0, "yesterday": -1, "day before yesterday": -2]
        var weekOffsets = ["本周": 0, "这周": 0, "上周": -1, "this week": 0, "last week": -1]
        var topicCleanupPatterns = [
            #"^[\s,，:：;；]*(?:我(?:们)?\s*)?(?:聊(?:过|天)?|讨论(?:过)?|谈(?:过)?|交流(?:过)?|提到(?:过)?|说过)(?:的|关于)?\s*"#,
            #"(?i)^\s*(?:(?:we|i)\s+)?(?:talked|discussed|chatted|spoke)(?:\s+about)?\s*"#,
        ]
        var emptyTopicPattern = #"(?i)^(?:\s|[，,。.!！?？:：;；]|那个|这个|会话|对话|的|聊的|讨论的|agent|the|one|conversation|session|chat)*$"#
        var whitespacePattern = #"\s+"#
        var mondayWeekday = 2

        /// Loads packaged expressions, with validated defaults for an unpackaged development binary.
        ///
        /// Args:
        ///   bundle: Application bundle containing the non-secret query configuration.
        ///
        /// Returns:
        ///   Validated local parsing rules and context lifetime.
        ///
        /// Raises:
        ///   AgentSearchQueryError: An existing configuration resource is malformed or invalid.
        static func bundled(in bundle: Bundle = .main) throws -> Self {
            guard let url = bundle.url(forResource: "AgentSearchQueryConfig", withExtension: "json") else {
                let defaults = Self()
                try defaults.validate()
                return defaults
            }
            do {
                let settings = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                try settings.validate()
                return settings
            } catch { throw AgentSearchQueryError.invalidConfiguration }
        }

        /// Rejects excessive bounds, unknown sources, invalid date offsets and malformed expressions.
        ///
        /// Raises:
        ///   AgentSearchQueryError: A rule cannot be safely used for bounded local parsing.
        func validate() throws {
            guard (1...8_192).contains(maximumInputCharacters), (1...32_768).contains(maximumInputBytes),
                  contextLifetimeSeconds.isFinite, (1...3_600).contains(contextLifetimeSeconds),
                  Set(providerPatterns.keys) == ["codex", "claude"],
                  providerPatterns.values.allSatisfy({ !$0.isEmpty && $0.count <= 8 }),
                  !timePatterns.isEmpty, timePatterns.count <= 16, topicCleanupPatterns.count <= 8,
                  !dayOffsets.isEmpty, dayOffsets.count <= 32, !weekOffsets.isEmpty, weekOffsets.count <= 16,
                  Set(dayOffsets.keys).isDisjoint(with: Set(weekOffsets.keys)),
                  dayOffsets.values.allSatisfy({ (-31...0).contains($0) }),
                  weekOffsets.values.allSatisfy({ (-4...0).contains($0) }), mondayWeekday == 2,
                  (Array(dayOffsets.keys) + Array(weekOffsets.keys)).allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
                throw AgentSearchQueryError.invalidConfiguration
            }
            let patterns = providerPatterns.values.flatMap { $0 } + timePatterns
                + topicCleanupPatterns + [emptyTopicPattern, whitespacePattern, ambiguousSourcePattern,
                                          ambiguousTimePattern, negatedMetadataPrefixPattern]
            for pattern in patterns {
                guard !pattern.isEmpty, pattern.utf8.count <= 2_048,
                      (try? NSRegularExpression(pattern: pattern)) != nil else {
                    throw AgentSearchQueryError.invalidConfiguration
                }
            }
            for pattern in timePatterns {
                guard try NSRegularExpression(pattern: pattern).numberOfCaptureGroups == 1 else {
                    throw AgentSearchQueryError.invalidConfiguration
                }
            }
        }
    }

    /// Creates a resolved query, including fields inherited from a prior metadata-only follow-up.
    ///
    /// Args:
    ///   text: Topic content without confirmed ownership or conversation-date phrases.
    ///   agent: Explicit source, either codex or claude, or nil when unspecified.
    ///   messageInterval: Local-calendar conversation interval, treated as start-inclusive/end-exclusive.
    ///   timezoneIdentifier: Time zone used when resolving relative conversation dates.
    ///   isRefinement: Whether this utterance only supplied metadata for an earlier topic.
    init(text: String, agent: String? = nil, messageInterval: DateInterval? = nil,
         timezoneIdentifier: String = TimeZone.current.identifier, isRefinement: Bool = false) {
        self.text = text
        self.agent = agent
        self.messageInterval = messageInterval
        self.timezoneIdentifier = timezoneIdentifier
        self.isRefinement = isRefinement
    }

    /// Extracts only explicit source ownership and conversation dates without network or model calls.
    ///
    /// Args:
    ///   text: Spoken search request after any navigation command is removed by the caller.
    ///   now: Clock anchor for relative dates.
    ///   calendar: User calendar and time zone; weeks start on Monday.
    ///   configuration: Bounded source/date expressions and follow-up lifetime.
    ///
    /// Returns:
    ///   Structured metadata and remaining topic. Conflicting metadata stays in the topic.
    ///
    /// Raises:
    ///   AgentSearchQueryError: Configuration, input size or calendar arithmetic is invalid.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current,
                      configuration: Configuration = Configuration()) throws -> Self {
        try configuration.validate()
        guard text.count <= configuration.maximumInputCharacters, text.utf8.count <= configuration.maximumInputBytes else {
            throw AgentSearchQueryError.inputTooLong
        }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var topic = original
        var sourceRanges: [String: [NSRange]] = [:]
        var sourceNegated = false
        for (agent, patterns) in configuration.providerPatterns {
            let ranges = try patterns.flatMap { try matches($0, in: original).map(\.range) }
            if try ranges.contains(where: { try isNegated($0, in: original, configuration: configuration) }) {
                sourceNegated = true
            }
            if !ranges.isEmpty { sourceRanges[agent] = ranges }
        }
        let ambiguousSource = !(try matches(configuration.ambiguousSourcePattern, in: original)).isEmpty
        let agent = sourceRanges.count == 1 && !ambiguousSource && !sourceNegated ? sourceRanges.keys.first : nil
        if let agent { topic = removing(sourceRanges[agent] ?? [], from: topic) }

        var timeMatches: [(range: NSRange, interval: DateInterval)] = []
        var timeNegated = false
        for pattern in configuration.timePatterns {
            for match in try matches(pattern, in: topic) {
                if try isNegated(match.range, in: topic, configuration: configuration) { timeNegated = true }
                let token = (topic as NSString).substring(with: match.range(at: 1)).lowercased()
                if let interval = try interval(for: token, now: now, calendar: calendar, configuration: configuration) {
                    timeMatches.append((match.range, interval))
                }
            }
        }
        let intervals = Set(timeMatches.map(\.interval))
        let ambiguousTime = !(try matches(configuration.ambiguousTimePattern, in: topic)).isEmpty
        let messageInterval = intervals.count == 1 && !ambiguousTime && !timeNegated ? intervals.first : nil
        if messageInterval != nil { topic = removing(timeMatches.map(\.range), from: topic) }
        let hasMetadata = agent != nil || messageInterval != nil
        if hasMetadata {
            for pattern in configuration.topicCleanupPatterns {
                let expression = try NSRegularExpression(pattern: pattern)
                topic = expression.stringByReplacingMatches(in: topic, range: NSRange(topic.startIndex..., in: topic), withTemplate: "")
            }
            let whitespace = try NSRegularExpression(pattern: configuration.whitespacePattern)
            topic = whitespace.stringByReplacingMatches(in: topic, range: NSRange(topic.startIndex..., in: topic), withTemplate: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !(try matches(configuration.emptyTopicPattern, in: topic)).isEmpty { topic = "" }
        }
        return Self(text: topic, agent: agent, messageInterval: messageInterval,
                    timezoneIdentifier: calendar.timeZone.identifier, isRefinement: hasMetadata && topic.isEmpty)
    }

    /// Finds UTF-16 spans without mutating the source string.
    ///
    /// Args:
    ///   pattern: Validated regular expression.
    ///   text: Bounded input.
    ///
    /// Returns:
    ///   All matched spans and their capture groups.
    private static func matches(_ pattern: String, in text: String) throws -> [NSTextCheckingResult] {
        try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Detects an explicit negation immediately before metadata without interpreting general negation.
    ///
    /// Args:
    ///   range: Candidate metadata span.
    ///   text: Bounded original string containing the span.
    ///   configuration: Validated negation expression.
    ///
    /// Returns:
    ///   Whether applying this span as a positive filter would reverse the user's words.
    private static func isNegated(_ range: NSRange, in text: String, configuration: Configuration) throws -> Bool {
        let prefix = (text as NSString).substring(to: range.location)
        return !(try matches(configuration.negatedMetadataPrefixPattern, in: prefix)).isEmpty
    }

    /// Removes confirmed metadata spans, merging overlaps before modifying UTF-16 offsets.
    ///
    /// Args:
    ///   ranges: Matched spans in the original string.
    ///   text: Original topic or query.
    ///
    /// Returns:
    ///   Text with one separating space for each removed span.
    private static func removing(_ ranges: [NSRange], from text: String) -> String {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        let result = NSMutableString(string: text)
        for range in merged.reversed() { result.replaceCharacters(in: range, with: " ") }
        return result as String
    }

    /// Resolves a relative calendar day or Monday-based week without fixed-second arithmetic.
    ///
    /// Args:
    ///   token: Lowercased explicit conversation-date token.
    ///   now: Reference date.
    ///   calendar: User calendar carrying the intended time zone.
    ///   configuration: Supported relative offsets and first weekday.
    ///
    /// Returns:
    ///   A half-open calendar interval, or nil for an unsupported token.
    ///
    /// Raises:
    ///   AgentSearchQueryError: Calendar arithmetic cannot produce a positive interval.
    private static func interval(for token: String, now: Date, calendar: Calendar,
                                 configuration: Configuration) throws -> DateInterval? {
        var local = calendar
        local.firstWeekday = configuration.mondayWeekday
        let start: Date?
        let end: Date?
        if let offset = configuration.dayOffsets[token] {
            start = local.date(byAdding: .day, value: offset, to: local.startOfDay(for: now))
            end = start.flatMap { local.date(byAdding: .day, value: 1, to: $0) }
        } else if let offset = configuration.weekOffsets[token] {
            start = (local.dateInterval(of: .weekOfYear, for: now)?.start)
                .flatMap { local.date(byAdding: .weekOfYear, value: offset, to: $0) }
            end = start.flatMap { local.date(byAdding: .weekOfYear, value: 1, to: $0) }
        } else { return nil }
        guard let start, let end, start < end else { throw AgentSearchQueryError.invalidDate }
        return DateInterval(start: start, end: end)
    }
}
