import Foundation

struct CmuxAgentRouterResult: Equatable, Sendable {
    let handled: Bool
    let message: String
    let historyStatus: String
}

final class CmuxAgentRouterService: @unchecked Sendable {
    static let shared = CmuxAgentRouterService()

    private let sessionIndex: CodexSessionIndexStore
    private let sessionWorkspaceCreator: @Sendable (CodexSessionIndexEntry, String) -> Bool
    private let launcher: AgentLauncherService

    /// Creates an agent router service backed by cmux.
    ///
    /// Args:
    ///   sessionStore: Kept for initializer compatibility; routing does not inspect live cmux surfaces.
    ///   commandClient: cmux command client used to create session fallback workspaces.
    ///   sessionIndex: Codex session index used after directory matching misses.
    ///   sessionWorkspaceCreator: Optional workspace creator injected by tests.
    ///   launcher: Directory launcher used before session fallback.
    init(
        sessionStore: CmuxSessionSnapshotLoading = CmuxSessionStore.shared,
        commandClient: CmuxCommandClient = CmuxCommandClient(),
        sessionIndex: CodexSessionIndexStore = .shared,
        sessionWorkspaceCreator: (@Sendable (CodexSessionIndexEntry, String) -> Bool)? = nil,
        launcher: AgentLauncherService = .shared
    ) {
        _ = sessionStore
        self.sessionIndex = sessionIndex
        self.sessionWorkspaceCreator = sessionWorkspaceCreator ?? { entry, command in
            commandClient.newWorkspace(name: entry.workspaceName, cwd: entry.cwd, command: command)
        }
        self.launcher = launcher
    }

    /// Routes recognized speech to a new cmux agent workspace by directory or session name.
    ///
    /// Args:
    ///   text: Final ASR transcript.
    ///   launch: Whether to execute side-effecting cmux workspace creation commands.
    ///
    /// Returns:
    ///   User-facing routing result and history status.
    func handle(_ text: String, launch: Bool = true) -> CmuxAgentRouterResult {
        let launchResult = launcher.handle(text, launch: launch)
        if launchResult.launched {
            return CmuxAgentRouterResult(
                handled: true,
                message: launchResult.message,
                historyStatus: "agent_launched"
            )
        }
        if launchResult.project != nil {
            return CmuxAgentRouterResult(
                handled: false,
                message: launchResult.message,
                historyStatus: "agent_launch_failed"
            )
        }

        guard let session = sessionIndex.bestMatch(for: launchResult.query) else {
            return CmuxAgentRouterResult(
                handled: false,
                message: launchResult.message,
                historyStatus: "agent_no_match"
            )
        }

        let command = launcher.cmuxSessionCommand(for: session.id)
        if launch, !sessionWorkspaceCreator(session, command) {
            return CmuxAgentRouterResult(
                handled: false,
                message: "恢复失败：\(session.workspaceName)",
                historyStatus: "agent_launch_failed"
            )
        }

        return CmuxAgentRouterResult(
            handled: true,
            message: "已恢复 Agent：\(session.workspaceName)",
            historyStatus: "agent_launched"
        )
    }

    /// Reconciles the persistent directory and Codex session indexes.
    ///
    /// Args:
    ///   None.
    ///
    /// Returns:
    ///   Nothing. The updated indexes are persisted to disk for later routing.
    func reconcileIndexes() {
        _ = launcher.reconcileProjectIndex()
        _ = sessionIndex.reconcileSessionIndex()
    }
}
