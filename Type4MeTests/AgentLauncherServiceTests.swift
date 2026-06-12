import XCTest
@testable import Type4Me

final class AgentLauncherServiceTests: XCTestCase {
    private final class RunRecorder: @unchecked Sendable {
        var runs: [[String]] = []
        var cmuxWorkspaces: [(name: String, cwd: String, command: String)] = []
    }

    private var tempRoot: URL!
    private var homeDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-launcher-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func testParsesLauncherQueries() {
        let service = makeService()

        XCTAssertEqual(service.parseQuery(from: "打开 VoiceInterface 项目。"), "VoiceInterface")
        XCTAssertEqual(service.parseQuery(from: "go to my native project"), "my native")
        XCTAssertEqual(service.parseQuery(from: "项目"), "")
    }

    func testMatchesProjectFromZshHistory() throws {
        let projectURL = homeDirectory.appendingPathComponent("Projects/MyCoolApp", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ": 1700000000:0;cd ~/Projects/MyCoolApp\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService()
        let result = service.handle("打开 My Cool 项目", launch: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.project?.path, projectURL.standardizedFileURL.path)
        XCTAssertEqual(result.message, "已启动 Agent：MyCoolApp")
    }

    func testNoMatchDoesNotLaunch() {
        let recorder = RunRecorder()
        let service = makeService(recorder: recorder)

        let result = service.handle("打开不存在的项目", launch: true)

        XCTAssertFalse(result.launched)
        XCTAssertNil(result.project)
        XCTAssertTrue(recorder.runs.isEmpty)
    }

    func testMatchesProjectFromSpotlightFolderSearch() throws {
        let projectURL = homeDirectory.appendingPathComponent("Downloads/计算机图形学", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = makeService(spotlightSearcher: { query in
            query == "计算机图形学" ? [projectURL] : []
        })

        let result = service.handle("去计算机图形学", launch: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.project?.path, projectURL.standardizedFileURL.path)
        XCTAssertEqual(result.project?.name, "计算机图形学")
    }

    func testRejectsAmbiguousProjectNames() throws {
        let mechanismURL = homeDirectory.appendingPathComponent("Work/自动唤醒机制", isDirectory: true)
        let flowURL = homeDirectory.appendingPathComponent("Work/自动唤醒流程", isDirectory: true)
        try FileManager.default.createDirectory(at: mechanismURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flowURL, withIntermediateDirectories: true)
        try """
        : 1700000000:0;cd ~/Work/自动唤醒机制
        : 1700000001:0;cd ~/Work/自动唤醒流程
        """.write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )
        let service = makeService()

        let result = service.handle("去自动唤醒", launch: false)

        XCTAssertFalse(result.launched)
        XCTAssertNil(result.project)
        XCTAssertEqual(result.message, "未找到匹配项目：自动唤醒")
    }

    func testShellCommandUsesCodexResumeCommand() throws {
        let service = makeService()
        let projectURL = homeDirectory.appendingPathComponent("Work/Space's App", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = AgentLauncherProject(
            path: projectURL.path,
            name: projectURL.lastPathComponent,
            normalizedName: service.normalize(projectURL.lastPathComponent),
            lastSeen: 0
        )

        let command = service.shellCommand(for: project)

        XCTAssertTrue(command.contains("codex --dangerously-bypass-approvals-and-sandbox resume"))
        XCTAssertTrue(command.contains("'\\''"))
    }

    func testCmuxCommandUsesWorkingDirectoryFlagOnly() throws {
        let service = makeService()
        let projectURL = homeDirectory.appendingPathComponent("Downloads/计算机图形学", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = AgentLauncherProject(
            path: projectURL.path,
            name: projectURL.lastPathComponent,
            normalizedName: service.normalize(projectURL.lastPathComponent),
            lastSeen: 0
        )

        let command = service.cmuxCommand(for: project)

        XCTAssertEqual(command, "codex --dangerously-bypass-approvals-and-sandbox resume")
        XCTAssertFalse(command.contains("cd "))
    }

    func testCmuxLaunchCreatesNewWorkspaceForMatchedProject() throws {
        let recorder = RunRecorder()
        let projectURL = homeDirectory.appendingPathComponent("Downloads/计算机图形学", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ": 1700000000:0;cd ~/Downloads/计算机图形学\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )
        let service = makeService(
            recorder: recorder,
            preferredTerminalProvider: { .cmux },
            cmuxWorkspaceCreator: { project, command in
                recorder.cmuxWorkspaces.append((project.name, project.path, command))
                return true
            }
        )

        let result = service.handle("去计算机图形学", launch: true)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.project?.path, projectURL.standardizedFileURL.path)
        XCTAssertTrue(recorder.runs.isEmpty)
        XCTAssertEqual(recorder.cmuxWorkspaces.count, 1)
        XCTAssertEqual(recorder.cmuxWorkspaces.first?.name, "计算机图形学")
        XCTAssertEqual(recorder.cmuxWorkspaces.first?.cwd, projectURL.standardizedFileURL.path)
        XCTAssertEqual(
            recorder.cmuxWorkspaces.first?.command,
            "codex --dangerously-bypass-approvals-and-sandbox resume"
        )
    }

    func testReconcileProjectIndexAddsDiscoveredProjectsAndRemovesMissingCachedProjects() throws {
        let service = makeService()
        let existingURL = homeDirectory.appendingPathComponent("Work/ExistingApp", isDirectory: true)
        let newURL = homeDirectory.appendingPathComponent("Work/NewApp", isDirectory: true)
        let missingURL = homeDirectory.appendingPathComponent("Work/MissingApp", isDirectory: true)
        try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
        let staleCache = [
            AgentLauncherProject(
                path: existingURL.path,
                name: existingURL.lastPathComponent,
                normalizedName: service.normalize(existingURL.lastPathComponent),
                lastSeen: 1
            ),
            AgentLauncherProject(
                path: missingURL.path,
                name: missingURL.lastPathComponent,
                normalizedName: service.normalize(missingURL.lastPathComponent),
                lastSeen: 2
            ),
        ]
        let cacheURL = tempRoot.appendingPathComponent("agent-projects.json")
        try JSONEncoder().encode(staleCache).write(to: cacheURL, options: .atomic)
        try ": 1700000003:0;cd ~/Work/NewApp\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )

        let reconciled = service.reconcileProjectIndex()
        let cached = try JSONDecoder().decode([AgentLauncherProject].self, from: Data(contentsOf: cacheURL))
        let cachedNames = Set(cached.map(\.name))

        XCTAssertEqual(Set(reconciled.map(\.name)), ["ExistingApp", "NewApp"])
        XCTAssertEqual(cachedNames, ["ExistingApp", "NewApp"])
        XCTAssertTrue(service.handle("去 ExistingApp", launch: false).launched)
        XCTAssertTrue(service.handle("去 NewApp", launch: false).launched)
        XCTAssertFalse(service.handle("去 MissingApp", launch: false).launched)
    }

    /// Builds a launcher service with isolated filesystem and process dependencies.
    ///
    /// Args:
    ///   recorder: Recorder for terminal launch commands.
    ///   spotlightSearcher: Injected Spotlight folder searcher.
    ///
    /// Returns:
    ///   Configured launcher service.
    private func makeService(
        recorder: RunRecorder = RunRecorder(),
        spotlightSearcher: @escaping @Sendable (String) -> [URL] = { _ in [] },
        preferredTerminalProvider: (@Sendable () -> AgentLauncherTerminal)? = nil,
        cmuxWorkspaceCreator: (@Sendable (AgentLauncherProject, String) -> Bool)? = nil
    ) -> AgentLauncherService {
        AgentLauncherService(
            homeDirectory: homeDirectory,
            cacheURL: tempRoot.appendingPathComponent("agent-projects.json"),
            spotlightSearcher: spotlightSearcher,
            processRunner: { args in
                recorder.runs.append(args)
            },
            preferredTerminalProvider: preferredTerminalProvider,
            cmuxWorkspaceCreator: cmuxWorkspaceCreator
        )
    }
}
