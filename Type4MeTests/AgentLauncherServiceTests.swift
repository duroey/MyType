import XCTest
@testable import Type4Me

final class AgentLauncherServiceTests: XCTestCase {
    private final class RunRecorder: @unchecked Sendable {
        var runs: [[String]] = []
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

    func testShellCommandUsesClaudeContinueWhenProjectHasHistory() throws {
        let service = makeService()
        let projectURL = homeDirectory.appendingPathComponent("Work/Space's App", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let encodedPath = projectURL.path.replacingOccurrences(of: "/", with: "-")
        let claudeProjectURL = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedPath, isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProjectURL, withIntermediateDirectories: true)
        try "{}\n".write(
            to: claudeProjectURL.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let project = AgentLauncherProject(
            path: projectURL.path,
            name: projectURL.lastPathComponent,
            normalizedName: service.normalize(projectURL.lastPathComponent),
            lastSeen: 0
        )

        let command = service.shellCommand(for: project)

        XCTAssertTrue(command.contains("claude --continue"))
        XCTAssertTrue(command.contains("'\\''"))
    }

    private func makeService(recorder: RunRecorder = RunRecorder()) -> AgentLauncherService {
        AgentLauncherService(
            homeDirectory: homeDirectory,
            cacheURL: tempRoot.appendingPathComponent("agent-projects.json"),
            processRunner: { args in
                recorder.runs.append(args)
            }
        )
    }
}
