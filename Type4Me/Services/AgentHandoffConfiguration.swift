import Foundation

enum AgentHandoffConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration

    var errorDescription: String? {
        L("会话交接配置无效。", "The conversation handoff configuration is invalid.")
    }
}

/// Non-secret limits shared by history export and native message transports.
struct AgentHandoffConfiguration: Decodable, Sendable {
    var endpoint: String
    var requestTimeoutSeconds: Double
    var resourceTimeoutSeconds: Double
    var maximumHistoryBytes: Int
    var pageSize: Int
    var maximumPages: Int
    var maximumInstructionCharacters: Int
    var maximumInlineHistoryBytes: Int
    var processTimeoutSeconds: Double
    var maximumProcessOutputBytes: Int
    var socketTimeoutSeconds: Double
    var maximumClaudeRegistryEntries: Int
    var maximumClaudeRegistryFileBytes: Int
    var processTerminationGraceSeconds: Double
    var maximumTranscriptDirectories: Int
    var maximumIdentityProbeBytes: Int
    var maximumClaudePacketBytes: Int

    /// Creates explicit limits without requiring resources in development executables.
    ///
    /// Args:
    ///   endpoint: Numeric loopback root URL of the local AgentsView service.
    ///   requestTimeoutSeconds: Deadline for one local HTTP request.
    ///   resourceTimeoutSeconds: Deadline for a complete history load.
    ///   maximumHistoryBytes: Maximum complete export and individual response size.
    ///   pageSize: Number of archive rows requested per page.
    ///   maximumPages: Maximum number of pages, including the final empty page.
    ///   maximumInstructionCharacters: Maximum continuation instruction length.
    ///   maximumInlineHistoryBytes: Maximum history delivered directly as message text.
    ///   processTimeoutSeconds: Deadline for the native Codex queue command.
    ///   maximumProcessOutputBytes: Maximum combined subprocess output size.
    ///   socketTimeoutSeconds: Deadline for a native Claude inbox write.
    ///   maximumClaudeRegistryEntries: Maximum native active-session registry entries.
    ///   maximumClaudeRegistryFileBytes: Maximum bytes read from one registry file.
    ///   processTerminationGraceSeconds: Grace period before terminating a stalled child.
    ///   maximumTranscriptDirectories: Maximum shallow project entries considered for source discovery.
    ///   maximumIdentityProbeBytes: Maximum bytes read to verify a Codex rollout header.
    ///   maximumClaudePacketBytes: Maximum complete serialized native Claude inbox packet.
    init(
        endpoint: String = "http://127.0.0.1:18742",
        requestTimeoutSeconds: Double = 15,
        resourceTimeoutSeconds: Double = 30,
        maximumHistoryBytes: Int = 16_777_216,
        pageSize: Int = 500,
        maximumPages: Int = 1_000,
        maximumInstructionCharacters: Int = 8_000,
        maximumInlineHistoryBytes: Int = 262_144,
        processTimeoutSeconds: Double = 15,
        maximumProcessOutputBytes: Int = 65_536,
        socketTimeoutSeconds: Double = 5,
        maximumClaudeRegistryEntries: Int = 512,
        maximumClaudeRegistryFileBytes: Int = 65_536,
        processTerminationGraceSeconds: Double = 0.3,
        maximumTranscriptDirectories: Int = 2_048,
        maximumIdentityProbeBytes: Int = 65_536,
        maximumClaudePacketBytes: Int = 1_048_576
    ) {
        self.endpoint = endpoint
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.maximumHistoryBytes = maximumHistoryBytes
        self.pageSize = pageSize
        self.maximumPages = maximumPages
        self.maximumInstructionCharacters = maximumInstructionCharacters
        self.maximumInlineHistoryBytes = maximumInlineHistoryBytes
        self.processTimeoutSeconds = processTimeoutSeconds
        self.maximumProcessOutputBytes = maximumProcessOutputBytes
        self.socketTimeoutSeconds = socketTimeoutSeconds
        self.maximumClaudeRegistryEntries = maximumClaudeRegistryEntries
        self.maximumClaudeRegistryFileBytes = maximumClaudeRegistryFileBytes
        self.processTerminationGraceSeconds = processTerminationGraceSeconds
        self.maximumTranscriptDirectories = maximumTranscriptDirectories
        self.maximumIdentityProbeBytes = maximumIdentityProbeBytes
        self.maximumClaudePacketBytes = maximumClaudePacketBytes
    }

    /// Reads packaged defaults and preserves invalid-resource failures.
    ///
    /// Args:
    ///   bundle: Application bundle containing the optional non-secret resource.
    ///
    /// Returns:
    ///   Packaged settings, or typed defaults when a development binary has no resource.
    ///
    /// Raises:
    ///   AgentHandoffConfigurationError: An existing resource is unreadable or invalid.
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "AgentHandoffConfig", withExtension: "json") else {
            return Self()
        }
        do {
            let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            _ = try configuration.validatedEndpoint()
            return configuration
        } catch {
            throw AgentHandoffConfigurationError.invalidConfiguration
        }
    }

    /// Rejects remote endpoints, credentials, unbounded work and invalid deadlines.
    ///
    /// Returns:
    ///   A numeric loopback HTTP root URL.
    ///
    /// Raises:
    ///   AgentHandoffConfigurationError: Any endpoint or resource limit is invalid.
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
              resourceTimeoutSeconds <= 300,
              maximumHistoryBytes > 0, maximumHistoryBytes <= 67_108_864,
              (1...1_000).contains(pageSize), (1...1_000).contains(maximumPages),
              (1...65_536).contains(maximumInstructionCharacters),
              maximumInlineHistoryBytes > 0, maximumInlineHistoryBytes <= maximumHistoryBytes,
              processTimeoutSeconds.isFinite, processTimeoutSeconds > 0, processTimeoutSeconds <= 60,
              maximumProcessOutputBytes > 0, maximumProcessOutputBytes <= 1_048_576,
              socketTimeoutSeconds.isFinite, socketTimeoutSeconds > 0, socketTimeoutSeconds <= 30,
              (1...10_000).contains(maximumClaudeRegistryEntries),
              maximumClaudeRegistryFileBytes > 0, maximumClaudeRegistryFileBytes <= 1_048_576,
              processTerminationGraceSeconds.isFinite, processTerminationGraceSeconds > 0,
              processTerminationGraceSeconds <= processTimeoutSeconds,
              (1...10_000).contains(maximumTranscriptDirectories),
              maximumIdentityProbeBytes > 0, maximumIdentityProbeBytes <= 1_048_576,
              maximumClaudePacketBytes > 0, maximumClaudePacketBytes <= 1_048_576,
              let url = components.url else {
            throw AgentHandoffConfigurationError.invalidConfiguration
        }
        return url
    }
}
