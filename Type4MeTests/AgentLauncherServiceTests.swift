import XCTest
@testable import Type4Me

final class AgentLauncherServiceTests: XCTestCase {
    private final class RunRecorder: @unchecked Sendable {
        var opens: [(application: AgentDesktopApplication, projectURL: URL?, sessionID: String?)] = []
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

    func testMatchesProjectFromZshHistory() async throws {
        let projectURL = homeDirectory.appendingPathComponent("Projects/MyCoolApp", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ": 1700000000:0;cd ~/Projects/MyCoolApp\n".write(
            to: homeDirectory.appendingPathComponent(".zsh_history"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService()
        let result = await service.handle("打开 My Cool 项目", launch: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.project?.path, projectURL.standardizedFileURL.path)
        XCTAssertEqual(result.application, .codex)
        XCTAssertEqual(result.outcome, .opened)
    }

    func testNoMatchDoesNotLaunch() async {
        let recorder = RunRecorder()
        let service = makeService(recorder: recorder)

        let result = await service.handle("打开不存在的项目", launch: true)

        XCTAssertFalse(result.launched)
        XCTAssertNil(result.project)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    func testMatchesProjectFromSpotlightFolderSearch() async throws {
        let projectURL = homeDirectory.appendingPathComponent("Downloads/计算机图形学", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = makeService(spotlightSearcher: { query in
            query == "计算机图形学" ? [projectURL] : []
        })

        let result = await service.handle("去计算机图形学", launch: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.project?.path, projectURL.standardizedFileURL.path)
        XCTAssertEqual(result.project?.name, "计算机图形学")
    }

    func testRejectsAmbiguousProjectNames() async throws {
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

        let result = await service.handle("去自动唤醒", launch: false)

        XCTAssertFalse(result.launched)
        XCTAssertNil(result.project)
        XCTAssertEqual(result.outcome, .noProjectMatch)
    }

    /// Verifies the chosen desktop agent receives the original project path.
    func testSelectedClaudeOpensMatchedProject() async throws {
        let recorder = RunRecorder()
        let projectURL = homeDirectory.appendingPathComponent("Downloads/计算机图形学", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = makeService(
            recorder: recorder,
            spotlightSearcher: { _ in [projectURL] },
            preferredApplicationProvider: { .claudeCode }
        )

        let result = await service.handle("去计算机图形学")

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.application, .claudeCode)
        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.opens.first?.application, .claudeCode)
        XCTAssertEqual(recorder.opens.first?.projectURL, projectURL.standardizedFileURL)
        XCTAssertNil(recorder.opens.first?.sessionID)
    }

    /// Verifies an app-only request does not require a matching project folder.
    func testSpokenApplicationNameOpensDesktopWithoutProject() async {
        let recorder = RunRecorder()
        let service = makeService(recorder: recorder)

        let result = await service.handle("打开 Claude Code")

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.application, .claudeCode)
        XCTAssertNil(result.project)
        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertNil(recorder.opens.first?.projectURL)
    }

    /// Verifies a missing chosen app ends routing before directory discovery.
    func testMissingApplicationDoesNotSearchOrOpenAnotherAgent() async {
        let recorder = RunRecorder()
        let service = makeService(
            recorder: recorder,
            spotlightSearcher: { _ in XCTFail("Missing apps must not search projects"); return [] },
            preferredApplicationProvider: { .claudeCode },
            installationChecker: { $0 == .codex }
        )

        let result = await service.handle("打开 MyType")

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.application, .claudeCode)
        XCTAssertEqual(result.outcome, .applicationUnavailable)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies an explicit project suffix preserves folders named after an agent.
    func testProjectNamedCodexDoesNotBecomeAppOnlyRequest() async throws {
        let recorder = RunRecorder()
        let projectURL = homeDirectory.appendingPathComponent("Work/codex", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let service = makeService(
            recorder: recorder, spotlightSearcher: { _ in [projectURL] },
            preferredApplicationProvider: { .claudeCode }
        )

        let result = await service.handle("打开 Codex 项目")

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.application, .claudeCode)
        XCTAssertEqual(recorder.opens.first?.projectURL, projectURL.standardizedFileURL)
    }

    func testReconcileProjectIndexAddsDiscoveredProjectsAndRemovesMissingCachedProjects() async throws {
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
        let existing = await service.handle("去 ExistingApp", launch: false)
        let newProject = await service.handle("去 NewApp", launch: false)
        let missing = await service.handle("去 MissingApp", launch: false)
        XCTAssertTrue(existing.launched)
        XCTAssertTrue(newProject.launched)
        XCTAssertFalse(missing.launched)
    }

    /// Builds a launcher with isolated storage and recorded desktop open requests.
    ///
    /// Args:
    ///   recorder: Recorder for desktop open requests.
    ///   spotlightSearcher: Injected Spotlight folder searcher.
    ///   preferredApplicationProvider: Optional desktop agent selector.
    ///   installationChecker: Injected installed-app check.
    ///
    /// Returns:
    ///   Configured launcher service.
    private func makeService(
        recorder: RunRecorder = RunRecorder(),
        spotlightSearcher: @escaping @Sendable (String) -> [URL] = { _ in [] },
        preferredApplicationProvider: (@Sendable () -> AgentDesktopApplication)? = { .codex },
        installationChecker: @escaping @Sendable (AgentDesktopApplication) -> Bool = { _ in true }
    ) -> AgentLauncherService {
        AgentLauncherService(
            homeDirectory: homeDirectory,
            cacheURL: tempRoot.appendingPathComponent("agent-projects.json"),
            spotlightSearcher: spotlightSearcher,
            preferredApplicationProvider: preferredApplicationProvider,
            installationChecker: installationChecker,
            desktopOpener: { application, projectURL, sessionID in
                recorder.opens.append((application, projectURL, sessionID))
            }
        )
    }
}
