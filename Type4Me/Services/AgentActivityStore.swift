import Foundation

struct AgentActivityRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var customTitle: String?
    var aliases: [String]
    var sessionKeys: [String]
    var preferredSessionKey: String?
}

struct AgentActivitySnapshot: Equatable, Sendable {
    let activities: [AgentActivityRecord]
    let lastActivityID: UUID?
    let lastSessionKey: String?
}

/// Carries transient history evidence; the activity store never persists these messages.
struct AgentActivityEvidence: Equatable, Sendable {
    let snippet: String
    let timestamp: Date?
    let ordinal: Int?
}

struct AgentActivityCandidate: Equatable, Identifiable, Sendable {
    let activityID: UUID
    let activityTitle: String
    let session: AgentSessionDescriptor
    let score: Double
    var evidence: AgentActivityEvidence? = nil

    var id: String { activityID.uuidString + ":" + session.id }
    var sessionID: String { session.sessionID }
    var sessionTitle: String { session.title }
    var application: AgentDesktopApplication { session.application }
    var canOpen: Bool { session.canOpenExistingConversation }
}

enum AgentActivityStoreError: LocalizedError, Equatable {
    case invalidStore
    case unsupportedVersion
    case tooManyActivities
    case unknownActivity
    case unknownSession
    case invalidTitle

    var errorDescription: String? {
        switch self {
        case .invalidStore:
            return L("事情索引无法读取，原数据已保留。", "The activities index could not be read. Its data was preserved.")
        case .unsupportedVersion:
            return L("事情索引来自更新的版本，请升级 MyType。", "The activities index requires a newer MyType version.")
        case .tooManyActivities:
            return L("事情索引已达到容量上限。", "The activities index has reached its capacity.")
        case .unknownActivity:
            return L("这件事已不在当前列表中，请重新查找。", "This activity is no longer in the list. Search again.")
        case .unknownSession:
            return L("该会话的归属已变化，请重新查找。", "This session's association changed. Search again.")
        case .invalidTitle:
            return L("称呼不能为空或超过长度上限。", "The name must be nonempty and within the length limit.")
        }
    }
}

/// Persists activity identity and explicit session associations without message content.
actor AgentActivityStore {
    struct Configuration: Sendable {
        var maximumActivities = 5_000
        var maximumStoreBytes = 2 * 1_024 * 1_024
        var maximumTitleCharacters = 200
        var maximumAliases = 8
    }

    private struct Document: Codable, Equatable {
        var version = 1
        var activities: [AgentActivityRecord] = []
        var lastActivityID: UUID?
        var lastSessionKey: String?
    }

    static let shared = AgentActivityStore()
    private let fileURL: URL
    private let configuration: Configuration
    private let fileManager: FileManager
    private var cachedDocument: Document?

    /// Creates a store; tests supply an isolated path instead of a user profile.
    ///
    /// Args:
    ///   fileURL: Persistent association file, with no session bodies or credentials.
    ///   configuration: Storage and name bounds.
    ///   fileManager: Filesystem used for atomic persistence.
    init(
        fileURL: URL? = nil,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? AppIdentity.appSupportDirectory().appendingPathComponent("agent-activities-v1.json")
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Imports new sessions independently; similar titles never merge activities.
    ///
    /// Args:
    ///   sessions: Current metadata-only catalog, identified by application and session ID.
    ///
    /// Returns:
    ///   Stable activities and the explicitly last-used session.
    ///
    /// Throws:
    ///   A corrupt, unsupported, full, or unwritable index error.
    func reconcile(sessions: [AgentSessionDescriptor]) throws -> AgentActivitySnapshot {
        try Task.checkCancellation()
        var document = try load()
        let boundKeys = Set(document.activities.flatMap(\.sessionKeys))
        let newKeys = Set(sessions.map(\.id)).subtracting(boundKeys).sorted()
        guard document.activities.count + newKeys.count <= configuration.maximumActivities else {
            throw AgentActivityStoreError.tooManyActivities
        }
        for key in newKeys {
            document.activities.append(AgentActivityRecord(
                id: UUID(), customTitle: nil, aliases: [], sessionKeys: [key], preferredSessionKey: nil
            ))
        }
        if document != cachedDocument { try save(document) }
        return snapshot(document)
    }

    /// Reads persistent activity metadata without scanning agent conversations.
    ///
    /// Returns:
    ///   Names, associations, and last-used identity.
    ///
    /// Throws:
    ///   An invalid or unsupported persisted index error.
    func readSnapshot() throws -> AgentActivitySnapshot { snapshot(try load()) }

    /// Sets an optional user name while retaining previous user names as aliases.
    ///
    /// Args:
    ///   activityID: Stable activity identity.
    ///   title: User-entered name, independent of any application's conversation title.
    ///
    /// Throws:
    ///   An invalid name, stale activity, or persistence error.
    func rename(activityID: UUID, title: String) throws {
        try Task.checkCancellation()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= configuration.maximumTitleCharacters else {
            throw AgentActivityStoreError.invalidTitle
        }
        var document = try load()
        guard let index = document.activities.firstIndex(where: { $0.id == activityID }) else {
            throw AgentActivityStoreError.unknownActivity
        }
        if let previous = document.activities[index].customTitle, previous != name {
            var aliases = document.activities[index].aliases.filter { $0 != previous && $0 != name }
            aliases.append(previous)
            document.activities[index].aliases = Array(aliases.suffix(configuration.maximumAliases))
        }
        document.activities[index].customTitle = name
        try save(document)
    }

    /// Moves a session to an explicitly chosen activity; names are never evidence of ownership.
    ///
    /// Args:
    ///   sessionKey: Application-qualified session identity.
    ///   activityID: Destination activity chosen by the user.
    ///
    /// Throws:
    ///   A stale association, unknown activity, or persistence error.
    func link(sessionKey: String, to activityID: UUID) throws {
        try Task.checkCancellation()
        var document = try load()
        guard let targetIndex = document.activities.firstIndex(where: { $0.id == activityID }) else {
            throw AgentActivityStoreError.unknownActivity
        }
        guard let sourceIndex = document.activities.firstIndex(where: { $0.sessionKeys.contains(sessionKey) }) else {
            throw AgentActivityStoreError.unknownSession
        }
        guard sourceIndex != targetIndex else { return }
        document.activities[sourceIndex].sessionKeys.removeAll { $0 == sessionKey }
        if document.activities[sourceIndex].preferredSessionKey == sessionKey {
            document.activities[sourceIndex].preferredSessionKey = nil
        }
        document.activities[targetIndex].sessionKeys.append(sessionKey)
        if document.lastSessionKey == sessionKey { document.lastActivityID = activityID }
        // Empty source activities retain their names so an explicit move is reversible.
        try save(document)
    }

    /// Records the target only after an existing-session open request is accepted.
    ///
    /// Args:
    ///   activityID: Activity that still owns the selected session.
    ///   sessionKey: Application-qualified selected session identity.
    ///   queryAlias: Optional spoken name explicitly associated by a picker choice.
    ///
    /// Throws:
    ///   A changed association or persistence error; no second open is attempted.
    func markOpened(activityID: UUID, sessionKey: String, queryAlias: String? = nil) throws {
        try Task.checkCancellation()
        var document = try load()
        guard let index = document.activities.firstIndex(where: { $0.id == activityID }) else {
            throw AgentActivityStoreError.unknownActivity
        }
        guard document.activities[index].sessionKeys.contains(sessionKey) else {
            throw AgentActivityStoreError.unknownSession
        }
        document.activities[index].preferredSessionKey = sessionKey
        if let name = queryAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name.count <= configuration.maximumTitleCharacters,
           name != document.activities[index].customTitle {
            var aliases = document.activities[index].aliases.filter { $0 != name }
            aliases.append(name)
            document.activities[index].aliases = Array(aliases.suffix(configuration.maximumAliases))
        }
        document.lastActivityID = activityID
        document.lastSessionKey = sessionKey
        try save(document)
    }

    /// Loads bounded data, refusing to overwrite malformed or newer documents.
    ///
    /// Returns:
    ///   Cached or validated persistent state.
    ///
    /// Throws:
    ///   A read, size, schema, or version error.
    private func load() throws -> Document {
        if let cachedDocument { return cachedDocument }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let document = Document()
            cachedDocument = document
            return document
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= configuration.maximumStoreBytes else {
            throw AgentActivityStoreError.invalidStore
        }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL)) }
        catch { throw AgentActivityStoreError.invalidStore }
        guard document.version == 1 else { throw AgentActivityStoreError.unsupportedVersion }
        guard document.activities.count <= configuration.maximumActivities,
              Set(document.activities.map(\.id)).count == document.activities.count else {
            throw AgentActivityStoreError.invalidStore
        }
        let keys = document.activities.flatMap(\.sessionKeys)
        guard Set(keys).count == keys.count,
              document.activities.allSatisfy({ activity in
                  activity.aliases.count <= configuration.maximumAliases
                    && (activity.customTitle?.count ?? 0) <= configuration.maximumTitleCharacters
                    && activity.aliases.allSatisfy { $0.count <= configuration.maximumTitleCharacters }
                    && activity.sessionKeys.allSatisfy { !$0.isEmpty }
                    && (activity.preferredSessionKey.map { activity.sessionKeys.contains($0) } ?? true)
              }) else { throw AgentActivityStoreError.invalidStore }
        cachedDocument = document
        return document
    }

    /// Atomically saves associations before advancing in-memory state.
    ///
    /// Args:
    ///   document: Validated next state.
    ///
    /// Throws:
    ///   An encoding, capacity, or filesystem error.
    private func save(_ document: Document) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= configuration.maximumStoreBytes else { throw AgentActivityStoreError.tooManyActivities }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cachedDocument = document
    }

    /// Projects names and associations without exposing the persistence schema.
    ///
    /// Args:
    ///   document: Validated internal state.
    ///
    /// Returns:
    ///   Router-facing metadata snapshot.
    private func snapshot(_ document: Document) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            activities: document.activities, lastActivityID: document.lastActivityID,
            lastSessionKey: document.lastSessionKey
        )
    }
}
