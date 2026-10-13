import Foundation

final class ClaudeCodeSessionCatalog: @unchecked Sendable {
    struct Configuration: Sendable {
        var maximumSessions = 500
        var maximumMetadataEntries = 2000
        var maximumMetadataFiles = 500
        var maximumFileBytes = 256 * 1024
        var maximumTitleCharacters = 512
        var millisecondsPerSecond: Double = 1000
    }

    // Claude Desktop's local metadata is an undocumented format. Decode only the observed
    // fields and fail closed for missing native identity/title; CLI transcripts are separate.
    private struct NativeMetadata: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let cwd: String?
        let originCwd: String?
        let lastActivityAt: Double?
        let lastFocusedAt: Double?
        let createdAt: Double?
        let isArchived: Bool
    }

    private let metadataDirectory: URL
    private let configuration: Configuration
    private let fileManager: FileManager
    private let openingAvailability: @Sendable () -> Bool

    /// Creates a native Code-tab metadata reader without importing terminal conversations.
    ///
    /// Args:
    ///   metadataDirectory: Native Desktop metadata root, containing account and organization folders.
    ///   configuration: Directory, file, title and result bounds.
    ///   fileManager: Filesystem interface used for shallow discovery.
    ///   openingAvailability: Whether the installed Desktop version supports native navigation.
    init(
        metadataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        openingAvailability: @escaping @Sendable () -> Bool = {
            AgentDesktopLauncherService.shared.supportsClaudeNativeSessionNavigation()
        }
    ) {
        precondition(configuration.maximumSessions > 0 && configuration.maximumMetadataEntries > 0)
        precondition(configuration.maximumMetadataFiles > 0 && configuration.maximumFileBytes > 0)
        precondition(configuration.maximumTitleCharacters > 0 && configuration.millisecondsPerSecond > 0)
        precondition(configuration.millisecondsPerSecond.isFinite)
        self.metadataDirectory = metadataDirectory
        self.configuration = configuration
        self.fileManager = fileManager
        self.openingAvailability = openingAvailability
    }

    /// Lists titled native conversations with the installed app's navigation capability.
    ///
    /// Returns:
    ///   Bounded metadata candidates. Their native ID is never replaced with a CLI resume ID.
    ///
    /// Raises:
    ///   Error: The native metadata directory cannot be read.
    ///   CancellationError: The containing routing task was cancelled.
    func loadSessions() throws -> [AgentSessionDescriptor] {
        guard fileManager.fileExists(atPath: metadataDirectory.path) else {
            throw AgentSessionCatalogError.metadataUnavailable
        }
        var inspectedEntries = 0
        var metadataFiles: [(url: URL, modifiedAt: TimeInterval)] = []
        for account in try children(of: metadataDirectory, inspectedEntries: &inspectedEntries) {
            guard isDirectory(account) else { continue }
            for organization in try children(of: account, inspectedEntries: &inspectedEntries) {
                guard isDirectory(organization) else { continue }
                for url in try children(of: organization, inspectedEntries: &inspectedEntries) {
                    try Task.checkCancellation()
                    guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else { continue }
                    let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate?.timeIntervalSince1970 ?? 0
                    metadataFiles.append((url, modifiedAt))
                }
            }
        }
        var sessions: [AgentSessionDescriptor] = []
        let canOpen = openingAvailability()
        let newestFiles = metadataFiles.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }.prefix(configuration.maximumMetadataFiles)
        for file in newestFiles {
            if let session = try readMetadata(at: file.url, canOpen: canOpen) { sessions.append(session) }
        }
        return Array(sessions.sorted {
            $0.updatedAt == $1.updatedAt ? $0.sessionID < $1.sessionID : $0.updatedAt > $1.updatedAt
        }.prefix(configuration.maximumSessions))
    }

    /// Enumerates one directory while sharing a finite traversal budget across the load.
    ///
    /// Args:
    ///   directory: One known metadata directory, never a transcript or project tree.
    ///   inspectedEntries: Shared remaining-work counter.
    ///
    /// Returns:
    ///   Bounded, non-symlink direct children.
    ///
    /// Raises:
    ///   AgentSessionCatalogError: The directory is unreadable.
    ///   CancellationError: Routing was cancelled.
    private func children(of directory: URL, inspectedEntries: inout Int) throws -> [URL] {
        guard inspectedEntries < configuration.maximumMetadataEntries else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw AgentSessionCatalogError.metadataReadFailed }
        var result: [URL] = []
        for item in enumerator {
            try Task.checkCancellation()
            guard inspectedEntries < configuration.maximumMetadataEntries else { break }
            inspectedEntries += 1
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            result.append(url)
        }
        return result
    }

    /// Checks that a direct metadata child is an actual directory.
    ///
    /// Args:
    ///   url: Candidate account or organization directory.
    ///
    /// Returns:
    ///   Whether the child is a non-symlink directory.
    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Decodes only native identity, title, workspace, archive and time fields from a bounded file.
    ///
    /// Args:
    ///   url: A native local_<id>.json metadata file.
    ///   canOpen: Whether the installed app supports the verified native navigation entry point.
    ///
    /// Returns:
    ///   A native descriptor, or nil for malformed, archived or untitled data.
    ///
    /// Raises:
    ///   CancellationError: Routing was cancelled before decoding.
    private func readMetadata(at url: URL, canOpen: Bool) throws -> AgentSessionDescriptor? {
        try Task.checkCancellation()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= configuration.maximumFileBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: configuration.maximumFileBytes + 1),
              data.count <= configuration.maximumFileBytes,
              let metadata = try? JSONDecoder().decode(NativeMetadata.self, from: data),
              !metadata.isArchived, metadata.sessionId == url.deletingPathExtension().lastPathComponent,
              AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(metadata.sessionId),
              let title = AgentSessionMetadataValidation.title(metadata.title, maximumCharacters: configuration.maximumTitleCharacters) else { return nil }
        let rawTimestamp = [metadata.lastActivityAt, metadata.lastFocusedAt, metadata.createdAt]
            .compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.max()
        guard let rawTimestamp else { return nil }
        return AgentSessionDescriptor(
            sessionID: metadata.sessionId, application: .claudeCode, title: title,
            workspacePath: AgentSessionMetadataValidation.workspace(metadata.cwd)
                ?? AgentSessionMetadataValidation.workspace(metadata.originCwd),
            updatedAt: rawTimestamp / configuration.millisecondsPerSecond,
            matchTexts: [title], openCapability: canOpen ? .claudeNativeDeepLink : .unsupported,
            engineSessionID: metadata.cliSessionId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        )
    }
}
