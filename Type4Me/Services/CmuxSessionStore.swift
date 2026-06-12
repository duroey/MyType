import Foundation

struct CmuxAgentSurface: Equatable, Sendable {
    let workspaceID: String
    let panelID: String
    let title: String
    let directory: String?
    let latestMessage: String?
    let latestMessageCreatedAt: TimeInterval
    let target: CmuxSurfaceTarget

    var displayName: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if let directory,
           !directory.isEmpty {
            return URL(fileURLWithPath: directory).lastPathComponent
        }
        return panelID
    }
}

struct CmuxSessionSnapshot: Equatable, Sendable {
    let waitingSurfaces: [CmuxAgentSurface]
    let terminalSurfaces: [CmuxAgentSurface]
    let terminalSurfaceCount: Int
    let focusedSurface: CmuxAgentSurface?
}

protocol CmuxSessionSnapshotLoading: Sendable {
    func loadSnapshot() -> CmuxSessionSnapshot
}

final class CmuxSessionStore: CmuxSessionSnapshotLoading, @unchecked Sendable {
    static let shared = CmuxSessionStore()

    private let sessionFileURL: URL
    private let fileManager: FileManager
    private let commandClient: CmuxCommandClient?

    /// Creates a store that reads cmux session state from disk.
    ///
    /// Args:
    ///   sessionFileURL: cmux session JSON path.
    ///   fileManager: File manager used to read the session file.
    ///   commandClient: cmux RPC client used to read live runtime state.
    init(
        sessionFileURL: URL = CmuxSessionStore.defaultSessionFileURL(),
        fileManager: FileManager = .default,
        commandClient: CmuxCommandClient? = CmuxCommandClient()
    ) {
        self.sessionFileURL = sessionFileURL
        self.fileManager = fileManager
        self.commandClient = commandClient
    }

    /// Loads the current cmux session snapshot.
    ///
    /// Returns:
    ///   Snapshot containing terminal surfaces, waiting surfaces, and the focused terminal surface.
    func loadSnapshot() -> CmuxSessionSnapshot {
        let fileSnapshot = loadFileSnapshot()
        guard let rpcSnapshot = loadRPCSnapshot() else {
            return fileSnapshot
        }
        return CmuxSessionSnapshot(
            waitingSurfaces: fileSnapshot.waitingSurfaces,
            terminalSurfaces: rpcSnapshot.terminalSurfaces,
            terminalSurfaceCount: rpcSnapshot.terminalSurfaceCount,
            focusedSurface: rpcSnapshot.focusedSurface ?? fileSnapshot.focusedSurface
        )
    }

    /// Loads cmux session state from the legacy on-disk JSON file.
    ///
    /// Returns:
    ///   Snapshot parsed from disk, or an empty snapshot when the file is missing.
    private func loadFileSnapshot() -> CmuxSessionSnapshot {
        guard fileManager.fileExists(atPath: sessionFileURL.path),
              let data = try? Data(contentsOf: sessionFileURL),
              let state = try? JSONDecoder().decode(CmuxSessionState.self, from: data) else {
            return CmuxSessionSnapshot(
                waitingSurfaces: [],
                terminalSurfaces: [],
                terminalSurfaceCount: 0,
                focusedSurface: nil
            )
        }

        var waiting: [CmuxAgentSurface] = []
        var terminalSurfaces: [CmuxAgentSurface] = []
        var focusedSurface: CmuxAgentSurface?
        var terminalCount = 0

        for window in state.windows {
            for (index, workspace) in window.tabManager.workspaces.enumerated() {
                for panel in workspace.panels {
                    guard panel.type == "terminal" else { continue }
                    terminalCount += 1

                    let surface = makeSurface(workspace: workspace, panel: panel)
                    terminalSurfaces.append(surface)
                    if index == window.tabManager.selectedWorkspaceIndex,
                       panel.id == workspace.focusedPanelId {
                        focusedSurface = surface
                    }
                    if isWaiting(panel) {
                        waiting.append(surface)
                    }
                }
            }
        }

        let sortedWaiting = waiting.sorted {
            if $0.latestMessageCreatedAt == $1.latestMessageCreatedAt {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.latestMessageCreatedAt > $1.latestMessageCreatedAt
        }
        let sortedTerminalSurfaces = terminalSurfaces.sorted {
            if $0.latestMessageCreatedAt == $1.latestMessageCreatedAt {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.latestMessageCreatedAt > $1.latestMessageCreatedAt
        }
        return CmuxSessionSnapshot(
            waitingSurfaces: sortedWaiting,
            terminalSurfaces: sortedTerminalSurfaces,
            terminalSurfaceCount: terminalCount,
            focusedSurface: focusedSurface
        )
    }

    /// Loads live cmux terminal state through the socket RPC API.
    ///
    /// Returns:
    ///   Live snapshot when cmux RPC responds with windows and terminals.
    private func loadRPCSnapshot() -> CmuxSessionSnapshot? {
        guard let commandClient,
              let windowPayload = commandClient.rpc(method: "window.list", params: [:]),
              let windows = windowPayload["windows"] as? [[String: Any]],
              !windows.isEmpty else {
            return nil
        }

        var workspaceByID: [String: RPCWorkspaceMetadata] = [:]
        var workspaceByRef: [String: RPCWorkspaceMetadata] = [:]
        for window in windows {
            guard let windowID = Self.firstString(in: window, keys: ["id", "ref", "window_id", "window_ref"]),
                  let workspacePayload = commandClient.rpc(
                    method: "workspace.list",
                    params: ["window_id": windowID]
                  ),
                  let workspaces = workspacePayload["workspaces"] as? [[String: Any]] else {
                continue
            }
            let resolvedWindowID = Self.firstString(
                in: workspacePayload,
                keys: ["window_id", "window_ref"]
            ) ?? windowID
            for workspace in workspaces {
                guard let workspaceID = Self.firstString(in: workspace, keys: ["id", "workspace_id"]) else {
                    continue
                }
                let metadata = RPCWorkspaceMetadata(
                    id: workspaceID,
                    ref: Self.firstString(in: workspace, keys: ["ref", "workspace_ref"]),
                    windowID: resolvedWindowID,
                    title: Self.firstString(in: workspace, keys: ["title", "name"]) ?? "",
                    currentDirectory: Self.firstString(in: workspace, keys: ["current_directory", "currentDirectory"]),
                    latestMessage: Self.firstString(in: workspace, keys: ["latest_conversation_message", "latestConversationMessage"]),
                    latestMessageCreatedAt: Self.timestamp(from: workspace["latest_submitted_at"] ?? workspace["latestSubmittedAt"]),
                    selected: workspace["selected"] as? Bool == true
                )
                workspaceByID[metadata.id] = metadata
                if let ref = metadata.ref {
                    workspaceByRef[ref] = metadata
                }
            }
        }

        guard let terminalPayload = commandClient.rpc(method: "debug.terminals", params: [:]),
              let terminals = terminalPayload["terminals"] as? [[String: Any]] else {
            return nil
        }

        var terminalSurfaces: [CmuxAgentSurface] = []
        var focusedSurface: CmuxAgentSurface?
        for terminal in terminals {
            if terminal["mapped"] as? Bool == false { continue }
            if terminal["runtime_surface_ready"] as? Bool == false { continue }
            guard let workspaceID = Self.firstString(in: terminal, keys: ["workspace_id", "workspace_ref"]),
                  let surfaceID = Self.firstString(in: terminal, keys: ["surface_id", "surface_ref"]) else {
                continue
            }
            let metadata = workspaceByID[workspaceID] ?? workspaceByRef[workspaceID]
            let windowID = Self.firstString(in: terminal, keys: ["window_id", "window_ref"]) ?? metadata?.windowID
            let directory = Self.firstString(
                in: terminal,
                keys: ["current_directory", "requested_working_directory"]
            ) ?? metadata?.currentDirectory
            let tty = Self.firstString(in: terminal, keys: ["tty"]).map(CmuxCommandClient.normalizedTTYPath)
            let surface = CmuxAgentSurface(
                workspaceID: workspaceID,
                panelID: surfaceID,
                title: Self.firstString(in: terminal, keys: ["surface_title"]) ?? metadata?.title ?? "",
                directory: directory,
                latestMessage: metadata?.latestMessage,
                latestMessageCreatedAt: metadata?.latestMessageCreatedAt ?? 0,
                target: CmuxSurfaceTarget(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    tty: tty,
                    windowID: windowID
                )
            )
            terminalSurfaces.append(surface)
            if (terminal["surface_focused"] as? Bool) == true,
               (terminal["workspace_selected"] as? Bool) == true {
                focusedSurface = surface
            }
        }

        guard !terminalSurfaces.isEmpty else {
            return nil
        }
        let sortedTerminalSurfaces = terminalSurfaces.sorted {
            if $0.latestMessageCreatedAt == $1.latestMessageCreatedAt {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.latestMessageCreatedAt > $1.latestMessageCreatedAt
        }
        return CmuxSessionSnapshot(
            waitingSurfaces: [],
            terminalSurfaces: sortedTerminalSurfaces,
            terminalSurfaceCount: terminalSurfaces.count,
            focusedSurface: focusedSurface
        )
    }

    /// Resolves cmux's default session JSON path.
    ///
    /// Args:
    ///   homeDirectory: Home directory containing Library/Application Support.
    ///
    /// Returns:
    ///   Default session JSON URL for the main cmux app bundle.
    static func defaultSessionFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("session-\(CmuxCommandClient.bundleID).json")
    }

    private func makeSurface(workspace: CmuxWorkspace, panel: CmuxPanel) -> CmuxAgentSurface {
        let latest = latestMessage(in: panel)
        let directory = panel.directory ?? panel.terminal?.workingDirectory ?? workspace.currentDirectory
        let tty = panel.ttyName.map(CmuxCommandClient.normalizedTTYPath)
        return CmuxAgentSurface(
            workspaceID: workspace.workspaceId,
            panelID: panel.id,
            title: panel.title ?? "",
            directory: directory,
            latestMessage: latest?.body ?? latest?.title,
            latestMessageCreatedAt: latest?.createdAt ?? 0,
            target: CmuxSurfaceTarget(
                workspaceID: workspace.workspaceId,
                surfaceID: panel.id,
                tty: tty
            )
        )
    }

    private func latestMessage(in panel: CmuxPanel) -> CmuxNotification? {
        let unread = panel.notifications.filter { $0.isRead != true }
        let candidates = unread.isEmpty ? panel.notifications : unread
        return candidates.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }

    private func isWaiting(_ panel: CmuxPanel) -> Bool {
        panel.hasUnreadIndicator == true
            || panel.isManuallyUnread == true
            || panel.notifications.contains { $0.isRead != true }
    }

    /// Reads the first non-empty string from a dictionary.
    ///
    /// Args:
    ///   dictionary: Source dictionary.
    ///   keys: Candidate keys in priority order.
    ///
    /// Returns:
    ///   First non-empty string value, if present.
    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String,
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    /// Converts cmux timestamps into Unix seconds.
    ///
    /// Args:
    ///   value: ISO8601 string or numeric timestamp.
    ///
    /// Returns:
    ///   Unix timestamp seconds, or zero when absent.
    private static func timestamp(from value: Any?) -> TimeInterval {
        if let number = value as? TimeInterval {
            return number
        }
        if let string = value as? String,
           let date = ISO8601DateFormatter().date(from: string) {
            return date.timeIntervalSince1970
        }
        return 0
    }
}

private struct RPCWorkspaceMetadata {
    let id: String
    let ref: String?
    let windowID: String
    let title: String
    let currentDirectory: String?
    let latestMessage: String?
    let latestMessageCreatedAt: TimeInterval
    let selected: Bool
}

private struct CmuxSessionState: Decodable {
    let windows: [CmuxWindow]
}

private struct CmuxWindow: Decodable {
    let tabManager: CmuxTabManager
}

private struct CmuxTabManager: Decodable {
    let selectedWorkspaceIndex: Int?
    let workspaces: [CmuxWorkspace]
}

private struct CmuxWorkspace: Decodable {
    let workspaceId: String
    let currentDirectory: String?
    let focusedPanelId: String?
    let panels: [CmuxPanel]
}

private struct CmuxPanel: Decodable {
    let id: String
    let type: String?
    let title: String?
    let directory: String?
    let ttyName: String?
    let hasUnreadIndicator: Bool?
    let isManuallyUnread: Bool?
    let notifications: [CmuxNotification]
    let terminal: CmuxTerminalInfo?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case directory
        case ttyName
        case hasUnreadIndicator
        case isManuallyUnread
        case notifications
        case terminal
    }

    /// Decodes a cmux panel, treating missing notifications as an empty list.
    ///
    /// Args:
    ///   decoder: Decoder containing panel JSON.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        ttyName = try container.decodeIfPresent(String.self, forKey: .ttyName)
        hasUnreadIndicator = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadIndicator)
        isManuallyUnread = try container.decodeIfPresent(Bool.self, forKey: .isManuallyUnread)
        notifications = try container.decodeIfPresent([CmuxNotification].self, forKey: .notifications) ?? []
        terminal = try container.decodeIfPresent(CmuxTerminalInfo.self, forKey: .terminal)
    }
}

private struct CmuxNotification: Decodable {
    let title: String?
    let body: String?
    let isRead: Bool?
    let createdAt: TimeInterval?
}

private struct CmuxTerminalInfo: Decodable {
    let workingDirectory: String?
}
