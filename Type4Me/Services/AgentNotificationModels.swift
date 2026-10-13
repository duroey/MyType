import Foundation

/// Native runtime state, independent of outstanding questions and unread messages.
enum AgentInboxStatus: String, Codable, Sendable {
    case running, waiting, idle, completed, interrupted, failed, unknown
}

struct AgentInboxRequest: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case input, approval }
    let id: String
    let kind: Kind
    let text: String
}

struct AgentInboxItem: Codable, Equatable, Identifiable, Sendable {
    var session: AgentSessionDescriptor
    var status: AgentInboxStatus
    var pendingRequests: [AgentInboxRequest]
    var preview: String
    var updatedAt: Date
    var isUnread: Bool
    var id: String { session.id }
}

struct AgentInboxUpdate: Sendable {
    let session: AgentSessionDescriptor
    let status: AgentInboxStatus
    let pendingRequests: [AgentInboxRequest]?
    let preview: String
    let completionID: String?
    let nativeHasUnreadTurn: Bool?
    let observedAt: Date

    /// Creates a verified observation without conflating idle with completion.
    ///
    /// Args:
    ///   session: Exact original desktop conversation identity.
    ///   status: Observed runtime state, or unknown after a connection failure.
    ///   pendingRequests: Authoritative requests; nil preserves last known requests.
    ///   preview: Visible assistant text only, without tool payloads.
    ///   completionID: Stable ID only for a newly observed successful turn.
    ///   nativeHasUnreadTurn: Fresh owner read state or verified same-turn completion receipt; nil means unavailable.
    ///   observedAt: Local observation time used to reject late updates.
    init(session: AgentSessionDescriptor, status: AgentInboxStatus,
         pendingRequests: [AgentInboxRequest]? = nil, preview: String = "",
         completionID: String? = nil, nativeHasUnreadTurn: Bool? = nil, observedAt: Date = Date()) {
        self.session = session
        self.status = status
        self.pendingRequests = pendingRequests
        self.preview = preview
        self.completionID = completionID
        self.nativeHasUnreadTurn = nativeHasUnreadTurn
        self.observedAt = observedAt
    }
}

/// Bounded, non-secret defaults shared by the two passive native observers.
struct AgentNotificationConfiguration: Codable, Equatable, Sendable {
    var discoveryIntervalSeconds: Double = 30
    var reconnectDelaySeconds: Double = 3
    var ioTimeoutSeconds: Double = 3
    var socketPollSeconds: Double = 0.25
    var claudeReconcileIntervalSeconds: Double = 2
    var codexReadReconcileIntervalSeconds: Double = 2
    var maximumCodexReadRefreshes = 4
    var persistenceDebounceSeconds: Double = 0.25
    var completionAlertDelaySeconds: Double = 2.5
    var inboxAutoHideSeconds: Double = 8
    var viewingPollSeconds: Double = 0.25
    var viewingStableSeconds: Double = 1
    var viewingEvidenceMaxAgeSeconds: Double = 1
    var maximumClaudeFocusLogBytes = 262_144
    var maximumClaudeFocusMetadataBytes = 16_777_216
    var maximumClaudeFocusMetadataEntries = 2_048
    var claudeSigningTeamIdentifier = "Q6L2SF6YDW"
    var maximumFrameBytes = 16_777_216
    var maximumCodexStateBytes = 67_108_864
    var maximumSnapshotRetries = 3
    var maximumSubscriptionAttempts = 3
    var codexSigningTeamIdentifier = "2DC432GLL2"
    var maximumSessions = 256
    var maximumPreviewCharacters = 1_000
    var maximumRegistryEntries = 512
    var maximumRegistryFileBytes = 65_536
    var maximumTranscriptTailBytes = 2_097_152
    var maximumInboxItems = 256
    var maximumPendingRequests = 20
    var maximumCompletionReceipts = 4_096
    var maximumStoreBytes = 8_388_608

    /// Reads packaged limits, retaining defaults for an unpackaged development build.
    ///
    /// Args:
    ///   bundle: Application containing AgentNotificationConfig.json.
    ///
    /// Returns:
    ///   Validated notification bounds.
    ///
    /// Raises:
    ///   Error: The existing resource is invalid; it is never silently ignored.
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        let value: Self
        if let url = bundle.url(forResource: "AgentNotificationConfig", withExtension: "json") {
            value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } else {
            value = Self()
        }
        try value.validate()
        return value
    }

    /// Rejects busy loops, unlimited memory, and unsupported retry counts.
    ///
    /// Raises:
    ///   CocoaError: At least one configured bound is invalid.
    func validate() throws {
        let intervals = [discoveryIntervalSeconds, reconnectDelaySeconds, ioTimeoutSeconds,
                         socketPollSeconds, claudeReconcileIntervalSeconds, persistenceDebounceSeconds,
                         viewingPollSeconds, viewingStableSeconds, viewingEvidenceMaxAgeSeconds]
        guard intervals.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 300 }),
              discoveryIntervalSeconds >= 5, reconnectDelaySeconds >= 1,
              socketPollSeconds >= 0.05, claudeReconcileIntervalSeconds >= 0.5,
              codexReadReconcileIntervalSeconds.isFinite, (0.5...30).contains(codexReadReconcileIntervalSeconds),
              (1...16).contains(maximumCodexReadRefreshes),
              completionAlertDelaySeconds.isFinite, (0...10).contains(completionAlertDelaySeconds),
              inboxAutoHideSeconds.isFinite, (3...60).contains(inboxAutoHideSeconds),
              (0.1...2).contains(viewingPollSeconds), (0.5...5).contains(viewingStableSeconds),
              viewingEvidenceMaxAgeSeconds >= viewingPollSeconds, viewingEvidenceMaxAgeSeconds <= 5,
              (1_024...1_048_576).contains(maximumClaudeFocusLogBytes),
              (1_024...16_777_216).contains(maximumClaudeFocusMetadataBytes),
              (1...4_096).contains(maximumClaudeFocusMetadataEntries),
              claudeSigningTeamIdentifier == "Q6L2SF6YDW",
              (1_024...33_554_432).contains(maximumFrameBytes),
              (maximumFrameBytes...134_217_728).contains(maximumCodexStateBytes),
              (1...3).contains(maximumSnapshotRetries), (1...512).contains(maximumSessions),
              (1...3).contains(maximumSubscriptionAttempts), codexSigningTeamIdentifier == "2DC432GLL2",
              (1...4_000).contains(maximumPreviewCharacters),
              (1...2_048).contains(maximumRegistryEntries),
              (1_024...262_144).contains(maximumRegistryFileBytes),
              (1_024...8_388_608).contains(maximumTranscriptTailBytes),
              (1...512).contains(maximumInboxItems), (1...32).contains(maximumPendingRequests),
              (1...8_192).contains(maximumCompletionReceipts),
              (1_024...16_777_216).contains(maximumStoreBytes) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
    }
}
