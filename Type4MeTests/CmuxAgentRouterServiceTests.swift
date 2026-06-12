import XCTest
@testable import Type4Me

final class CmuxAgentRouterServiceTests: XCTestCase {
    private final class SessionStoreStub: CmuxSessionSnapshotLoading, @unchecked Sendable {
        let snapshot: CmuxSessionSnapshot

        /// Creates a fixed cmux session snapshot loader.
        ///
        /// Args:
        ///   snapshot: Snapshot returned from every load.
        init(snapshot: CmuxSessionSnapshot) {
            self.snapshot = snapshot
        }

        /// Loads the fixed cmux session snapshot.
        ///
        /// Returns:
        ///   The snapshot supplied at initialization time.
        func loadSnapshot() -> CmuxSessionSnapshot {
            snapshot
        }
    }

    private final class CommandRecorder: @unchecked Sendable {
        var rpcCalls: [(String, [String: Any])] = []
        var workspaceCalls: [(name: String, cwd: String, command: String)] = []
    }

    private var tempRoot: URL!
    private var homeDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-router-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func testDirectoryMatchCreatesNewCmuxWorkspaceInsteadOfFocusingExistingSurface() throws {
        let projectURL = homeDirectory.appendingPathComponent("work/graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ": 1700000000:0;cd ~/work/graphics\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )
        let recorder = CommandRecorder()
        let service = makeService(
            snapshot: CmuxSessionSnapshot(
                waitingSurfaces: [],
                terminalSurfaces: [
                    makeSurface(
                        workspaceID: "workspace-existing",
                        panelID: "panel-existing",
                        title: "graphics",
                        directory: projectURL.path
                    ),
                ],
                terminalSurfaceCount: 1,
                focusedSurface: nil
            ),
            recorder: recorder
        )

        let result = service.handle("去 graphics", launch: true)

        XCTAssertTrue(result.handled)
        XCTAssertEqual(result.historyStatus, "agent_launched")
        XCTAssertEqual(result.message, "已启动 Agent：graphics")
        XCTAssertTrue(recorder.rpcCalls.isEmpty)
        XCTAssertEqual(recorder.workspaceCalls.count, 1)
        XCTAssertEqual(recorder.workspaceCalls.first?.name, "graphics")
        XCTAssertEqual(recorder.workspaceCalls.first?.cwd, projectURL.standardizedFileURL.path)
        XCTAssertEqual(
            recorder.workspaceCalls.first?.command,
            "codex --dangerously-bypass-approvals-and-sandbox resume"
        )
    }

    func testCurrentCmuxSessionTextIsNotUsedWhenDirectoryDoesNotMatch() {
        let recorder = CommandRecorder()
        let service = makeService(
            snapshot: CmuxSessionSnapshot(
                waitingSurfaces: [],
                terminalSurfaces: [
                    makeSurface(
                        workspaceID: "workspace-existing",
                        panelID: "panel-existing",
                        title: "VoiceInterface",
                        directory: "/work/VoiceInterface",
                        latestMessage: "我正在定位自动唤醒异常"
                    ),
                ],
                terminalSurfaceCount: 1,
                focusedSurface: nil
            ),
            recorder: recorder
        )

        let result = service.handle("自动唤醒", launch: true)

        XCTAssertFalse(result.handled)
        XCTAssertEqual(result.historyStatus, "agent_no_match")
        XCTAssertTrue(recorder.rpcCalls.isEmpty)
        XCTAssertTrue(recorder.workspaceCalls.isEmpty)
    }

    func testSessionMatchCreatesNewCmuxWorkspaceWhenDirectoryDoesNotMatch() throws {
        let projectURL = homeDirectory.appendingPathComponent("VoiceInterface", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try writeCodexSession(
            sessionsRoot: sessionsRoot,
            id: "session-auto",
            cwd: projectURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )
        let sessionIndex = CodexSessionIndexStore(sessionsRoot: sessionsRoot)
        _ = sessionIndex.reconcileSessionIndex()
        let recorder = CommandRecorder()
        let service = makeService(
            snapshot: CmuxSessionSnapshot(
                waitingSurfaces: [],
                terminalSurfaces: [],
                terminalSurfaceCount: 0,
                focusedSurface: nil
            ),
            recorder: recorder,
            sessionIndex: sessionIndex
        )

        let result = service.handle("自动唤醒", launch: true)

        XCTAssertTrue(result.handled)
        XCTAssertEqual(result.historyStatus, "agent_launched")
        XCTAssertEqual(result.message, "已恢复 Agent：VoiceInterface")
        XCTAssertEqual(recorder.workspaceCalls.count, 1)
        XCTAssertEqual(recorder.workspaceCalls.first?.name, "VoiceInterface")
        XCTAssertEqual(recorder.workspaceCalls.first?.cwd, projectURL.path)
        XCTAssertEqual(
            recorder.workspaceCalls.first?.command,
            "codex --dangerously-bypass-approvals-and-sandbox resume 'session-auto'"
        )
    }

    func testReconcileIndexesWritesDirectoryAndSessionCaches() throws {
        let projectURL = homeDirectory.appendingPathComponent("Work/WarmApp", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("codex-sessions", isDirectory: true)
        let sessionCacheURL = tempRoot.appendingPathComponent("codex-sessions-index.json")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try ": 1700000000:0;cd ~/Work/WarmApp\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )
        try writeCodexSession(
            sessionsRoot: sessionsRoot,
            id: "session-warm",
            cwd: projectURL.path,
            messages: ["启动索引预热"]
        )
        let recorder = CommandRecorder()
        let service = makeService(
            snapshot: CmuxSessionSnapshot(
                waitingSurfaces: [],
                terminalSurfaces: [],
                terminalSurfaceCount: 0,
                focusedSurface: nil
            ),
            recorder: recorder,
            sessionIndex: CodexSessionIndexStore(sessionsRoot: sessionsRoot, cacheURL: sessionCacheURL)
        )

        service.reconcileIndexes()

        let projectCacheURL = tempRoot.appendingPathComponent("agent-router-projects.json")
        let projects = try JSONDecoder().decode([AgentLauncherProject].self, from: Data(contentsOf: projectCacheURL))
        let sessions = try JSONDecoder().decode([CodexSessionIndexEntry].self, from: Data(contentsOf: sessionCacheURL))
        XCTAssertEqual(projects.map(\.name), ["WarmApp"])
        XCTAssertEqual(sessions.map(\.id), ["session-warm"])
    }

    /// Builds a router service with fake cmux state and commands.
    ///
    /// Args:
    ///   snapshot: cmux snapshot returned to the router.
    ///   recorder: Command recorder for cmux RPC and workspace creation.
    ///
    /// Returns:
    ///   Configured router service.
    private func makeService(
        snapshot: CmuxSessionSnapshot,
        recorder: CommandRecorder,
        sessionIndex: CodexSessionIndexStore = CodexSessionIndexStore(
            sessionsRoot: URL(fileURLWithPath: "/tmp/type4me-empty-codex-sessions")
        )
    ) -> CmuxAgentRouterService {
        let commandClient = CmuxCommandClient(
            executableURLProvider: { URL(fileURLWithPath: "/bin/echo") },
            rpcRunner: { method, params in
                recorder.rpcCalls.append((method, params))
                return [:]
            }
        )
        return CmuxAgentRouterService(
            sessionStore: SessionStoreStub(snapshot: snapshot),
            commandClient: commandClient,
            sessionIndex: sessionIndex,
            sessionWorkspaceCreator: { entry, command in
                recorder.workspaceCalls.append((entry.workspaceName, entry.cwd, command))
                return true
            },
            launcher: AgentLauncherService(
                homeDirectory: homeDirectory,
                cacheURL: tempRoot.appendingPathComponent("agent-router-projects.json"),
                spotlightSearcher: { _ in [] },
                processRunner: { _ in },
                preferredTerminalProvider: { .cmux },
                cmuxWorkspaceCreator: { project, command in
                    recorder.workspaceCalls.append((project.name, project.path, command))
                    return true
                }
            )
        )
    }

    /// Writes a minimal Codex session fixture.
    ///
    /// Args:
    ///   sessionsRoot: Directory that receives the jsonl fixture.
    ///   id: Codex session identifier.
    ///   cwd: Working directory stored in the session metadata.
    ///   messages: User messages used for session matching.
    private func writeCodexSession(
        sessionsRoot: URL,
        id: String,
        cwd: String,
        messages: [String]
    ) throws {
        let fileURL = sessionsRoot.appendingPathComponent("\(id).jsonl")
        var lines = [
            #"{"timestamp":"2026-06-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-06-12T00:00:00Z","cwd":"\#(cwd)"}}"#,
        ]
        lines += messages.map { message in
            #"{"timestamp":"2026-06-12T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"\#(message)"}}"#
        }
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Creates a minimal cmux terminal surface for router tests.
    ///
    /// Args:
    ///   workspaceID: cmux workspace identifier.
    ///   panelID: cmux terminal panel identifier.
    ///   title: Surface title shown to the user.
    ///   directory: Working directory associated with the surface.
    ///   latestMessage: Latest agent reply associated with the surface.
    ///
    /// Returns:
    ///   Test cmux terminal surface.
    private func makeSurface(
        workspaceID: String,
        panelID: String,
        title: String,
        directory: String,
        latestMessage: String = "agent reply"
    ) -> CmuxAgentSurface {
        CmuxAgentSurface(
            workspaceID: workspaceID,
            panelID: panelID,
            title: title,
            directory: directory,
            latestMessage: latestMessage,
            latestMessageCreatedAt: 10,
            target: CmuxSurfaceTarget(workspaceID: workspaceID, surfaceID: panelID, tty: nil, windowID: "window-main")
        )
    }
}
