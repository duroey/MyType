import Foundation
import XCTest
@testable import Type4Me

final class AgentDesktopLauncherServiceTests: XCTestCase {
    private enum StubError: Error { case rejected }

    private struct CommandInvocation: Equatable {
        let executable: URL
        let arguments: [String]
        let projectURL: URL?
        let timeout: TimeInterval
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedOpens: [(URL, URL?)] = []
        private var recordedCommands: [CommandInvocation] = []

        var opens: [(URL, URL?)] {
            lock.lock()
            defer { lock.unlock() }
            return recordedOpens
        }

        var commands: [CommandInvocation] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCommands
        }

        /// Records an explicitly targeted app request without launching macOS UI.
        ///
        /// Args:
        ///   appURL: Targeted app bundle.
        ///   destinationURL: Optional public deep link.
        func recordOpen(_ appURL: URL, destinationURL: URL?) {
            lock.lock()
            defer { lock.unlock() }
            recordedOpens.append((appURL, destinationURL))
        }

        /// Records a helper invocation without executing a command.
        ///
        /// Args:
        ///   invocation: Executable, arguments, current directory, and timeout.
        func recordCommand(_ invocation: CommandInvocation) {
            lock.lock()
            defer { lock.unlock() }
            recordedCommands.append(invocation)
        }
    }

    private var rootURL: URL!
    private var homeURL: URL!
    private var appsURL: URL!

    /// Creates isolated app and home directories for launcher fixtures.
    ///
    /// Raises:
    ///   Error: Fixture directories could not be created.
    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-agent-launcher-\(UUID().uuidString)", isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        appsURL = rootURL.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appsURL, withIntermediateDirectories: true)
    }

    /// Removes only this test's isolated fixture directory.
    ///
    /// Raises:
    ///   Error: Fixture cleanup failed.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    /// Verifies CLI presence cannot turn into a false desktop installation.
    func testCommandOnlyDoesNotCountAsInstalledApp() {
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let service = makeService(executableValidator: { $0 == commandURL })

        let installation = service.detectInstallation(for: .claudeCode)

        XCTAssertFalse(installation.isInstalled)
        XCTAssertNil(installation.applicationURL)
        XCTAssertEqual(installation.commandURL, commandURL)
    }

    /// Verifies both supported choices stay visible when neither is installed.
    func testDetectionReportsBothUnavailableAppsWithoutCommands() {
        let recorder = Recorder()
        let installations = makeService(recorder: recorder).detectInstallations()

        XCTAssertEqual(installations.map(\.application), [.codex, .claudeCode])
        XCTAssertTrue(installations.allSatisfy { !$0.isInstalled })
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies an identity plist cannot hide a missing app entry executable.
    ///
    /// Raises:
    ///   Error: The isolated fixture could not be created.
    func testMissingMainExecutableDoesNotCountAsInstalled() throws {
        let url = try makeApplication(named: "Claude.app", application: .claudeCode)
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/MacOS/Agent"))

        XCTAssertFalse(makeService().detectInstallation(for: .claudeCode).isInstalled)
    }

    /// Verifies a non-executable app entry file is rejected during detection.
    ///
    /// Raises:
    ///   Error: The isolated fixture permissions could not be changed.
    func testNonExecutableMainFileDoesNotCountAsInstalled() throws {
        let url = try makeApplication(named: "ChatGPT.app", application: .codex)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/Agent").path
        )

        XCTAssertFalse(makeService().detectInstallation(for: .codex).isInstalled)
    }

    /// Verifies a plist executable name cannot escape the bundle's MacOS directory.
    ///
    /// Raises:
    ///   Error: The isolated fixture plist could not be changed.
    func testExecutablePathTraversalIsRejected() throws {
        let url = try makeApplication(named: "Claude.app", application: .claudeCode)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": AgentDesktopApplication.claudeCode.bundleIdentifier,
                "CFBundleExecutable": "../MacOS/Agent",
            ], format: .xml, options: 0
        )
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))

        XCTAssertFalse(makeService().detectInstallation(for: .claudeCode).isInstalled)
    }

    /// Verifies a deleted Launch Services entry is rejected.
    func testMissingRegisteredAppIsNotInstalled() {
        let staleURL = appsURL.appendingPathComponent("Removed.app")
        let service = makeService(applicationLookup: { _ in staleURL })

        XCTAssertFalse(service.detectInstallation(for: .codex).isInstalled)
    }

    /// Verifies trustworthy fallback bundles replace a stale registered path.
    ///
    /// Raises:
    ///   Error: The valid bundle fixture could not be written.
    func testStaleRegisteredURLUsesValidatedFallback() throws {
        let appURL = try makeApplication(named: "ChatGPT.app", application: .codex)
        let staleURL = appsURL.appendingPathComponent("Removed.app")
        let service = makeService(applicationLookup: { _ in staleURL })

        XCTAssertEqual(service.detectInstallation(for: .codex).applicationURL, appURL)
    }

    /// Verifies matching filenames cannot impersonate the chosen desktop app.
    ///
    /// Raises:
    ///   Error: The wrong-identity fixture could not be written.
    func testWrongBundleIdentifierIsRejected() throws {
        let appURL = try makeApplication(named: "ChatGPT.app", bundleIdentifier: "example.other-app")
        let service = makeService(applicationLookup: { _ in appURL })

        XCTAssertFalse(service.detectInstallation(for: .codex).isInstalled)
    }

    /// Verifies user-local app installs are found without a Launch Services result.
    ///
    /// Raises:
    ///   Error: The user app fixture could not be written.
    func testFindsValidatedAppInUserApplications() throws {
        let directory = homeURL.appendingPathComponent("Applications", isDirectory: true)
        let appURL = try makeApplication(named: "Codex.app", application: .codex, directory: directory)

        XCTAssertEqual(makeService().detectInstallation(for: .codex).applicationURL, appURL)
    }

    /// Verifies uncached identity checks notice an app replaced at the same path.
    ///
    /// Raises:
    ///   Error: Bundle fixtures could not be written.
    func testDetectionRechecksIdentityOnEveryRefresh() throws {
        let appURL = try makeApplication(named: "ChatGPT.app", application: .codex)
        let service = makeService(applicationLookup: { _ in appURL })
        XCTAssertTrue(service.detectInstallation(for: .codex).isInstalled)

        _ = try makeApplication(named: "ChatGPT.app", bundleIdentifier: "example.replaced-app")

        XCTAssertFalse(service.detectInstallation(for: .codex).isInstalled)
    }

    /// Verifies Codex activation opens the chosen bundle without making a chat.
    ///
    /// Raises:
    ///   Error: The fixture or opening request failed.
    func testBareCodexActivatesDetectedAppOnly() async throws {
        let appURL = try makeApplication(named: "ChatGPT.app", application: .codex)
        let recorder = Recorder()

        try await makeService(recorder: recorder).open(application: .codex)

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.opens.first?.0, appURL)
        XCTAssertNil(recorder.opens.first?.1)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies bare Claude routes into Code instead of its general Chat screen.
    ///
    /// Raises:
    ///   Error: The fixture or opening request failed.
    func testBareClaudeAlwaysOpensCodeWithoutCLI() async throws {
        let appURL = try makeApplication(named: "Claude.app", application: .claudeCode)
        let recorder = Recorder()

        try await makeService(recorder: recorder).open(application: .claudeCode)

        XCTAssertEqual(recorder.opens.first?.0, appURL)
        XCTAssertEqual(recorder.opens.first?.1?.absoluteString, "claude://code/new")
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies CLI-only users receive an error rather than terminal fallback.
    func testMissingDesktopAppDoesNotRunCLIOrOpenTerminal() async {
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let service = makeService(recorder: recorder, executableValidator: { $0 == commandURL })

        do {
            try await service.open(application: .claudeCode)
            XCTFail("Missing desktop app must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .applicationNotInstalled(.claudeCode))
        }
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies project names remain query data even with reserved characters.
    ///
    /// Raises:
    ///   Error: Public deep links could not be created.
    func testProjectDeepLinksEncodePathsAndNeverIncludePrompt() throws {
        let projectURL = URL(fileURLWithPath: "/Users/example/中文 + A&B #50% ?' Project", isDirectory: true)
        for application in AgentDesktopApplication.allCases {
            let url = try XCTUnwrap(AgentDesktopLauncherService.destinationURL(for: application, projectURL: projectURL))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let expectedKey = application == .codex ? "path" : "folder"

            XCTAssertEqual(components.queryItems, [URLQueryItem(name: expectedKey, value: projectURL.path)])
            XCTAssertTrue(url.absoluteString.contains("%2B"))
            XCTAssertTrue(url.absoluteString.contains("%26"))
            XCTAssertTrue(url.absoluteString.contains("%23"))
            XCTAssertFalse(components.queryItems?.contains { $0.name == "prompt" } ?? true)
        }
    }

    /// Verifies a new task preserves the complete prompt as query data in each app.
    ///
    /// Raises:
    ///   Error: A correctly encoded draft link could not be built.
    func testNewTaskDeepLinksPreserveUnicodeReservedCharactersAndNewlines() throws {
        let projectURL = URL(fileURLWithPath: "/Users/example/中文 + A&B #50%", isDirectory: true)
        let prompt = "  检查 A+B & C，保留 #1、50% 和 ?\n再看第二行 😀  "
        for application in AgentDesktopApplication.allCases {
            let url = try XCTUnwrap(AgentDesktopLauncherService.destinationURL(
                for: application, projectURL: projectURL, prompt: prompt
            ))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let pathKey = application == .codex ? "path" : "folder"
            let promptKey = application == .codex ? "prompt" : "q"
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: pathKey, value: projectURL.path),
                URLQueryItem(name: promptKey, value: prompt),
            ])
            XCTAssertNil(components.fragment)
            XCTAssertTrue(url.absoluteString.contains("%2B"))
            XCTAssertTrue(url.absoluteString.contains("%26"))
            XCTAssertTrue(url.absoluteString.contains("%0A"))
        }
    }

    /// Verifies adding draft text cannot accidentally modify an existing conversation link.
    func testExistingSessionRejectsPromptForBothApplications() {
        for application in AgentDesktopApplication.allCases {
            let sessionID = application == .codex ? "thread-abc" : "local_existing"
            XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(
                for: application, sessionID: sessionID, prompt: "new work"
            )) { error in
                XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidDestination)
            }
        }
    }

    /// Verifies empty and null-containing prompts never produce a new task request.
    func testNewTaskRejectsInvalidPromptWithoutTrimmingContent() {
        for application in AgentDesktopApplication.allCases {
            for prompt in ["", " \n\t ", "first\0second"] {
                XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(
                    for: application, prompt: prompt
                )) { error in
                    XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidPrompt)
                }
            }
        }
    }

    /// Verifies bounds use UTF-16 units and reject rather than truncate the task.
    ///
    /// Raises:
    ///   Error: The exact-boundary prompt could not be encoded.
    func testNewTaskPromptAndEncodedURLBoundsFailWithoutTruncating() throws {
        var configuration = AgentDesktopLauncherService.Configuration()
        configuration.maximumNewTaskPromptUTF16Units = 4
        for application in AgentDesktopApplication.allCases {
            let url = try XCTUnwrap(AgentDesktopLauncherService.destinationURL(
                for: application, prompt: "😀😀", configuration: configuration
            ))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "😀😀")
            XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(
                for: application, prompt: "😀😀a", configuration: configuration
            )) { error in
                XCTAssertEqual(error as? AgentDesktopLauncherError, .promptTooLong)
            }
            configuration.maximumNewTaskURLBytes = 20
            XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(
                for: application, prompt: "😀😀", configuration: configuration
            )) { error in
                XCTAssertEqual(error as? AgentDesktopLauncherError, .promptTooLong)
            }
            configuration.maximumNewTaskURLBytes = 48_000
        }
        configuration.maximumNewTaskPromptUTF16Units = 20_000
        configuration.maximumNewTaskURLBytes = 100_000
        XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(
            for: .claudeCode, prompt: String(repeating: "a", count: 14_337), configuration: configuration
        )) { error in
            XCTAssertEqual(error as? AgentDesktopLauncherError, .promptTooLong)
        }
    }

    /// Verifies a new task opens the native composer directly without a CLI probe or send.
    ///
    /// Raises:
    ///   Error: The isolated application, directory, or draft opening failed.
    func testOpenNewTaskDirectlyTargetsAppAndSkipsAvailableClaudeCLI() async throws {
        let projectURL = try makeProject()
        let recorder = Recorder()
        let service = makeService(recorder: recorder, executableValidator: { _ in true })
        for application in AgentDesktopApplication.allCases {
            let appURL = try makeApplication(
                named: application == .codex ? "ChatGPT.app" : "Claude.app", application: application
            )
            try await service.openNewTask(application: application, projectURL: projectURL, prompt: "检查录音\nA+B")
            XCTAssertEqual(recorder.opens.last?.0, appURL)
            let url = try XCTUnwrap(recorder.opens.last?.1)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.last?.value, "检查录音\nA+B")
            XCTAssertTrue(recorder.commands.isEmpty)
        }
        XCTAssertEqual(recorder.opens.count, 2)
    }

    /// Verifies No Folder reaches the native route without turning into a project deep link.
    ///
    /// Raises:
    ///   Error: The fixture or verified native opening failed.
    func testCodexNoFolderUsesExplicitNativeRoute() async throws {
        let appURL = try makeApplication(named: "ChatGPT.app", application: .codex)
        let recorder = Recorder()
        let service = makeService(recorder: recorder, nativeNoFolderOpener: { app, prompt in
            XCTAssertEqual(app, appURL)
            XCTAssertEqual(prompt, "原生任务\nA+B & C")
            recorder.recordOpen(app, destinationURL: nil)
        })
        try await service.openNewTask(application: .codex, destination: .nativeNoFolder, prompt: "原生任务\nA+B & C")
        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertNil(recorder.opens.first?.1)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies unverified native support cannot fall back to another app or a generated directory.
    ///
    /// Raises:
    ///   Error: The fixture could not be created.
    func testClaudeNoFolderFailsWithoutOpeningReplacementProject() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        do {
            try await service.openNewTask(application: .claudeCode, destination: .nativeNoFolder, prompt: "任务")
            XCTFail("Unverified No Folder must not fall back")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .nativeNoFolderUnavailable(.claudeCode))
        }
        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertNotEqual(AgentDesktopLauncherError.nativeNoFolderUnavailable(.claudeCode).message(language: .zh),
                          AgentDesktopLauncherError.nativeNoFolderUnavailable(.claudeCode).message(language: .en))
    }

    /// Verifies invalid directories and text fail before dispatching a draft to the app.
    ///
    /// Raises:
    ///   Error: The isolated application fixture could not be created.
    func testOpenNewTaskValidationHasNoOpeningSideEffects() async throws {
        _ = try makeApplication(named: "ChatGPT.app", application: .codex)
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let missing = rootURL.appendingPathComponent("missing-project")
        do {
            try await service.openNewTask(application: .codex, projectURL: missing, prompt: "work")
            XCTFail("Missing workspace must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidProject(missing.path))
        }
        let projectURL = try makeProject()
        do {
            try await service.openNewTask(application: .codex, projectURL: projectURL, prompt: " ")
            XCTFail("Empty task must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidPrompt)
        }
        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies a hanging native opening cannot keep the task picker waiting indefinitely.
    ///
    /// Raises:
    ///   Error: The isolated application or project fixture could not be created.
    func testOpenNewTaskReportsBoundedTimeoutWithoutCLIFallback() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let recorder = Recorder()
        var configuration = AgentDesktopLauncherService.Configuration()
        configuration.commandLaunchTimeout = 0.02
        let service = makeService(recorder: recorder, configuration: configuration, applicationOpener: { _, _ in
            try await Task.sleep(for: .seconds(10))
        })
        do {
            try await service.openNewTask(application: .claudeCode, projectURL: projectURL, prompt: "task")
            XCTFail("Opening must time out")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .launchTimedOut(.claudeCode))
        }
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies cancelling the draft prevents a pending opener from reporting success.
    ///
    /// Raises:
    ///   Error: The isolated application or project fixture could not be created.
    func testOpenNewTaskCancellationIsPreserved() async throws {
        _ = try makeApplication(named: "ChatGPT.app", application: .codex)
        let projectURL = try makeProject()
        let opened = expectation(description: "Draft opener started")
        let recorder = Recorder()
        let service = makeService(recorder: recorder, applicationOpener: { _, _ in
            opened.fulfill()
            try await Task.sleep(for: .seconds(10))
        })
        let task = Task { try await service.openNewTask(application: .codex, projectURL: projectURL, prompt: "task") }
        await fulfillment(of: [opened], timeout: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled opening must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies configured prompt limits apply to the service before any native request.
    ///
    /// Raises:
    ///   Error: The isolated application or project fixture could not be created.
    func testOpenNewTaskUsesConfiguredPromptLimitBeforeOpening() async throws {
        _ = try makeApplication(named: "ChatGPT.app", application: .codex)
        let projectURL = try makeProject()
        let recorder = Recorder()
        var configuration = AgentDesktopLauncherService.Configuration()
        configuration.maximumNewTaskPromptUTF16Units = 4
        let service = makeService(recorder: recorder, configuration: configuration)
        do {
            try await service.openNewTask(application: .codex, projectURL: projectURL, prompt: "😀😀x")
            XCTFail("Overlong draft must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .promptTooLong)
        }
        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies an existing Codex chat uses navigation instead of a new-chat URL.
    ///
    /// Raises:
    ///   Error: The existing chat link could not be created.
    func testCodexSessionNavigationTakesPrecedenceOverProject() throws {
        let url = try AgentDesktopLauncherService.destinationURL(
            for: .codex, projectURL: URL(fileURLWithPath: "/tmp/project"), sessionID: "thread-abc_123"
        )

        XCTAssertEqual(url?.absoluteString, "codex://threads/thread-abc_123")
    }

    /// Verifies an existing native Claude chat keeps its identifier as query data.
    ///
    /// Raises:
    ///   Error: The native chat link could not be created.
    func testClaudeNativeSessionLinkContainsOnlyEncodedSessionQuery() throws {
        for sessionID in ["local_ABC-123", "local_550e8400-e29b-41d4-a716-446655440000", "local_" + String(repeating: "A", count: 64)] {
            let url = try XCTUnwrap(AgentDesktopLauncherService.destinationURL(
                for: .claudeCode, projectURL: URL(fileURLWithPath: "/tmp/unrelated + project"), sessionID: sessionID
            ))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            XCTAssertEqual(components.scheme, "claude")
            XCTAssertEqual(components.host, "code")
            XCTAssertEqual(components.path, "/continue")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "session", value: sessionID)])
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.percentEncodedQuery, "session=\(sessionID)")
        }
    }

    /// Verifies injected, CLI, or non-native identifiers cannot alter URL routing.
    func testRejectsInvalidSessionIdentifiers() {
        for invalid in ["", "../new", "abc?prompt=send", "abc#fragment", "abc/def", "abc def"] {
            XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(for: .codex, sessionID: invalid)) { error in
                XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidSessionIdentifier)
            }
        }
        for invalid in [
            "", "abc", "last", "550e8400-e29b-41d4-a716-446655440000", "local_",
            "local_a_b", "local_../new", "local_abc?prompt=send", "local_abc&folder=/tmp",
            "local_abc#fragment", "local_abc/def", "local_abc def", "local_abc%3Fprompt=send",
            "local_é", "local_中文", "local_" + String(repeating: "a", count: 65),
        ] {
            XCTAssertThrowsError(try AgentDesktopLauncherService.destinationURL(for: .claudeCode, sessionID: invalid)) { error in
                XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidSessionIdentifier)
            }
        }
    }

    /// Verifies native navigation never probes or runs a CLI to create another chat.
    ///
    /// Raises:
    ///   Error: The fixture or opening request failed.
    func testClaudeNativeSessionOpensExistingChatEvenWithProjectWithoutCLI() async throws {
        let appURL = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = rootURL.appendingPathComponent("unavailable-workspace", isDirectory: true)
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let sessionID = "local_550e8400-e29b-41d4-a716-446655440000"
        let recorder = Recorder()
        let service = makeService(recorder: recorder, executableValidator: { $0 == commandURL })

        try await service.open(application: .claudeCode, projectURL: projectURL, sessionID: sessionID)

        XCTAssertEqual(recorder.opens.count, 1)
        XCTAssertEqual(recorder.opens.first?.0, appURL)
        XCTAssertEqual(recorder.opens.first?.1?.absoluteString, "claude://code/continue?session=\(sessionID)")
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies native capability reads each bundle version without cached metadata.
    ///
    /// Raises:
    ///   Error: The versioned bundle fixtures could not be written.
    func testClaudeNativeCapabilityReadsCurrentBundleVersionWithoutSideEffects() throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        XCTAssertFalse(service.supportsClaudeNativeSessionNavigation())
        for version in ["2.26454.2", "2.26455.0", "3.0.0"] {
            _ = try makeApplication(named: "Claude.app", application: .claudeCode, version: version)
            XCTAssertTrue(service.supportsClaudeNativeSessionNavigation(), version)
        }
        _ = try makeApplication(named: "Claude.app", bundleIdentifier: "example.other-app")
        XCTAssertFalse(service.supportsClaudeNativeSessionNavigation())
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies older or unknown app versions cannot fall back to a new Code chat.
    ///
    /// Raises:
    ///   Error: The versioned bundle fixtures could not be written.
    func testUnsupportedClaudeNativeVersionsNeverOpenOrRunCLI() async throws {
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let versions: [String?] = ["2.26454.1", "2.26453.99", "2.9.99999", nil, "2.26454.2-beta", "2.26454.2\n9.0.0"]
        for version in versions {
            _ = try makeApplication(named: "Claude.app", application: .claudeCode, version: version)
            let recorder = Recorder()
            let service = makeService(recorder: recorder, executableValidator: { $0 == commandURL })
            XCTAssertFalse(service.supportsClaudeNativeSessionNavigation())

            do {
                try await service.open(application: .claudeCode, projectURL: projectURL, sessionID: "local_existing")
                XCTFail("Unsupported native navigation must fail")
            } catch {
                XCTAssertEqual(error as? AgentDesktopLauncherError, .unsupportedSession(.claudeCode))
            }
            XCTAssertTrue(recorder.commands.isEmpty)
            XCTAssertTrue(recorder.opens.isEmpty)
        }
    }

    /// Verifies opening rechecks support after a previously successful catalog query.
    ///
    /// Raises:
    ///   Error: The updated bundle fixtures could not be written.
    func testClaudeNativeOpeningRechecksBundleAfterCapabilityDetection() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        XCTAssertTrue(service.supportsClaudeNativeSessionNavigation())
        _ = try makeApplication(named: "Claude.app", application: .claudeCode, version: "2.26454.1")

        do {
            try await service.open(application: .claudeCode, sessionID: "local_existing")
            XCTFail("Changed app support must be rechecked")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .unsupportedSession(.claudeCode))
        }
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies missing project directories prevent all opening side effects.
    ///
    /// Raises:
    ///   Error: The app fixture could not be written.
    func testUnavailableProjectDoesNotLaunch() async throws {
        _ = try makeApplication(named: "ChatGPT.app", application: .codex)
        let recorder = Recorder()
        let projectURL = rootURL.appendingPathComponent("missing-project")

        do {
            try await makeService(recorder: recorder).open(application: .codex, projectURL: projectURL)
            XCTFail("Missing project must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .invalidProject(projectURL.path))
        }
        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies recognized releases must meet the exact documented CLI minimum.
    func testClaudeDesktopVersionGate() {
        XCTAssertFalse(AgentDesktopLauncherService.supportsClaudeDesktopVersion("2.1.284 (Claude Code)"))
        XCTAssertTrue(AgentDesktopLauncherService.supportsClaudeDesktopVersion("2.1.285 (Claude Code)\n"))
        XCTAssertTrue(AgentDesktopLauncherService.supportsClaudeDesktopVersion("2.2.0 (Claude Code)"))
        XCTAssertFalse(AgentDesktopLauncherService.supportsClaudeDesktopVersion("2.1.285-beta (Claude Code)"))
        XCTAssertFalse(AgentDesktopLauncherService.supportsClaudeDesktopVersion("latest available version: 2.1.999"))
        XCTAssertFalse(AgentDesktopLauncherService.supportsClaudeDesktopVersion("unrecognized"))
    }

    /// Verifies newer CLI project handoff stays in the background and targets Code.
    ///
    /// Raises:
    ///   Error: Fixtures or opening failed.
    func testCompatibleClaudeCLIUsesDesktopFlagAndProjectWorkingDirectory() async throws {
        let appURL = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let service = makeService(
            recorder: recorder, executableValidator: { $0 == commandURL },
            commandRunner: { executable, arguments, directory, timeout in
                recorder.recordCommand(CommandInvocation(
                    executable: executable, arguments: arguments, projectURL: directory, timeout: timeout
                ))
                return .init(status: 0, output: arguments == ["--version"] ? "2.1.285 (Claude Code)" : "", timedOut: false)
            }
        )

        try await service.open(application: .claudeCode, projectURL: projectURL)

        XCTAssertEqual(recorder.commands.map(\.arguments), [["--version"], ["--desktop"]])
        XCTAssertEqual(recorder.commands.last?.projectURL, projectURL)
        XCTAssertTrue(recorder.commands.allSatisfy { $0.timeout > 0 && $0.timeout <= 15 })
        XCTAssertEqual(recorder.opens.first?.0, appURL)
        XCTAssertNil(recorder.opens.first?.1, "Activation must not create a second Code chat")
    }

    /// Verifies unavailable or older CLI support uses the documented Code deep link.
    ///
    /// Raises:
    ///   Error: Fixtures or opening failed.
    func testOldOrTimedOutClaudeProbeFallsBackToCodeDeepLink() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        for result in [
            AgentDesktopLauncherService.CommandResult(status: 0, output: "2.1.284 (Claude Code)", timedOut: false),
            .init(status: -1, output: "2.1.999 (Claude Code)", timedOut: true),
            .init(status: 1, output: "2.1.999 (Claude Code)", timedOut: false),
        ] {
            let recorder = Recorder()
            let service = makeService(
                recorder: recorder, executableValidator: { $0 == commandURL },
                commandRunner: { executable, arguments, directory, timeout in
                    recorder.recordCommand(.init(executable: executable, arguments: arguments, projectURL: directory, timeout: timeout))
                    return result
                }
            )

            try await service.open(application: .claudeCode, projectURL: projectURL)

            XCTAssertEqual(recorder.commands.map(\.arguments), [["--version"]])
            XCTAssertEqual(recorder.opens.first?.1?.host, "code")
            XCTAssertEqual(recorder.opens.first?.1?.path, "/new")
        }
    }

    /// Verifies an absent Claude command uses the folder link without invoking a shell.
    ///
    /// Raises:
    ///   Error: Fixtures or opening failed.
    func testClaudeProjectWithoutCommandUsesAppTargetedFolderLink() async throws {
        let appURL = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let recorder = Recorder()

        try await makeService(recorder: recorder).open(application: .claudeCode, projectURL: projectURL)

        let url = try XCTUnwrap(recorder.opens.first?.1)
        XCTAssertEqual(recorder.opens.first?.0, appURL)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "folder", value: projectURL.path),
        ])
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies real handoff failure is surfaced without creating a duplicate chat.
    ///
    /// Raises:
    ///   Error: Fixtures could not be written.
    func testClaudeDesktopCommandFailureDoesNotFallBackToTerminalOrSecondChat() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let service = makeService(
            recorder: recorder, executableValidator: { $0 == commandURL },
            commandRunner: { _, arguments, _, _ in
                .init(status: arguments == ["--version"] ? 0 : 1, output: "2.1.285 (Claude Code)", timedOut: false)
            }
        )

        do {
            try await service.open(application: .claudeCode, projectURL: projectURL)
            XCTFail("Rejected desktop handoff must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .launchFailed(.claudeCode))
        }
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies removal during an asynchronous probe cannot open a stale app.
    ///
    /// Raises:
    ///   Error: Fixtures could not be written.
    func testRemovedAppAfterVersionProbePreventsLaunch() async throws {
        let appURL = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let service = makeService(
            recorder: recorder, executableValidator: { $0 == commandURL },
            commandRunner: { _, _, _, _ in
                try FileManager.default.removeItem(at: appURL)
                return .init(status: 0, output: "2.1.285 (Claude Code)", timedOut: false)
            }
        )

        do {
            try await service.open(application: .claudeCode, projectURL: projectURL)
            XCTFail("Removed app must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .applicationRemoved(.claudeCode))
        }
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies macOS opening failures remain explicit and do not trigger fallback.
    ///
    /// Raises:
    ///   Error: The app fixture could not be written.
    func testApplicationOpenerFailureIsReported() async throws {
        _ = try makeApplication(named: "ChatGPT.app", application: .codex)
        let recorder = Recorder()
        let service = makeService(recorder: recorder, applicationOpener: { _, _ in throw StubError.rejected })

        do {
            try await service.open(application: .codex)
            XCTFail("Rejected app opening must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .launchFailed(.codex))
        }
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies a cancelled version probe never proceeds to app or command dispatch.
    ///
    /// Raises:
    ///   Error: Fixtures could not be written.
    func testCancellationDuringVersionProbePreventsOpening() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let probeStarted = expectation(description: "Version probe started")
        let service = makeService(
            recorder: recorder, executableValidator: { $0 == commandURL },
            commandRunner: { _, _, _, _ in
                probeStarted.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return .init(status: 0, output: "2.1.285 (Claude Code)", timedOut: false)
            }
        )
        let opening = Task { try await service.open(application: .claudeCode, projectURL: projectURL) }
        await fulfillment(of: [probeStarted], timeout: 1)

        opening.cancel()
        do {
            try await opening.value
            XCTFail("Cancelled opening must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(recorder.opens.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    /// Verifies helper handoff timeout is surfaced without app or terminal fallback.
    ///
    /// Raises:
    ///   Error: Fixtures could not be written.
    func testClaudeDesktopCommandTimeoutDoesNotOpenFallback() async throws {
        _ = try makeApplication(named: "Claude.app", application: .claudeCode)
        let projectURL = try makeProject()
        let commandURL = homeURL.appendingPathComponent(".local/bin/claude")
        let recorder = Recorder()
        let service = makeService(
            recorder: recorder, executableValidator: { $0 == commandURL },
            commandRunner: { _, arguments, _, _ in
                .init(status: 0, output: "2.1.285 (Claude Code)", timedOut: arguments == ["--desktop"])
            }
        )

        do {
            try await service.open(application: .claudeCode, projectURL: projectURL)
            XCTFail("Timed out handoff must fail")
        } catch {
            XCTAssertEqual(error as? AgentDesktopLauncherError, .launchTimedOut(.claudeCode))
        }
        XCTAssertTrue(recorder.opens.isEmpty)
    }

    /// Verifies every failure carries Chinese and English copy at display time.
    func testErrorsHaveChineseAndEnglishMessages() {
        let errors: [AgentDesktopLauncherError] = [
            .applicationNotInstalled(.codex), .applicationRemoved(.claudeCode),
            .invalidProject("/example/project"), .invalidSessionIdentifier,
            .unsupportedSession(.claudeCode), .invalidDestination,
            .invalidPrompt, .promptTooLong,
            .launchFailed(.codex), .launchTimedOut(.claudeCode),
        ]
        for error in errors {
            XCTAssertNotEqual(error.message(language: .zh), error.message(language: .en))
            XCTAssertFalse(error.message(language: .zh).isEmpty)
            XCTAssertFalse(error.message(language: .en).isEmpty)
        }
        XCTAssertTrue(AgentDesktopLauncherError.applicationNotInstalled(.codex).message(language: .zh).contains("桌面应用"))
        XCTAssertTrue(AgentDesktopLauncherError.applicationNotInstalled(.codex).message(language: .en).contains("desktop app"))
    }

    /// Creates an isolated service whose defaults never open UI or execute commands.
    ///
    /// Args:
    ///   recorder: Captures mocked side effects.
    ///   configuration: Optional bounds for isolated failure and timeout tests.
    ///   applicationLookup: Optional Launch Services result provider.
    ///   executableValidator: Optional command presence provider.
    ///   applicationOpener: Optional opener override for failure tests.
    ///   nativeNoFolderOpener: Folderless route override, isolated from installed apps.
    ///   commandRunner: Optional helper override for version and handoff tests.
    ///
    /// Returns:
    ///   Launcher restricted to this test's fixture directories.
    private func makeService(
        recorder: Recorder = Recorder(),
        configuration: AgentDesktopLauncherService.Configuration = .init(),
        applicationLookup: @escaping AgentDesktopLauncherService.ApplicationLookup = { _ in nil },
        executableValidator: @escaping AgentDesktopLauncherService.ExecutableValidator = { _ in false },
        applicationOpener: AgentDesktopLauncherService.ApplicationOpener? = nil,
        nativeNoFolderOpener: AgentDesktopLauncherService.NativeNoFolderOpener? = nil,
        commandRunner: AgentDesktopLauncherService.CommandRunner? = nil
    ) -> AgentDesktopLauncherService {
        AgentDesktopLauncherService(
            homeDirectory: homeURL,
            applicationDirectories: [appsURL, homeURL.appendingPathComponent("Applications", isDirectory: true)],
            configuration: configuration,
            applicationLookup: applicationLookup,
            executableValidator: executableValidator,
            applicationOpener: applicationOpener ?? { appURL, destinationURL in
                recorder.recordOpen(appURL, destinationURL: destinationURL)
            },
            nativeNoFolderOpener: nativeNoFolderOpener ?? { _, _ in
                XCTFail("Native No Folder opening was not expected")
                throw StubError.rejected
            },
            commandRunner: commandRunner ?? { executable, arguments, projectURL, timeout in
                recorder.recordCommand(.init(executable: executable, arguments: arguments, projectURL: projectURL, timeout: timeout))
                throw StubError.rejected
            }
        )
    }

    /// Writes a minimal identity-bearing app fixture.
    ///
    /// Args:
    ///   name: Bundle filename.
    ///   application: Expected supported app identity.
    ///   version: Actual short app version, or nil for absent metadata.
    ///   directory: Optional user-local app directory.
    ///
    /// Returns:
    ///   Fixture application URL.
    ///
    /// Raises:
    ///   Error: The fixture could not be created.
    private func makeApplication(
        named name: String,
        application: AgentDesktopApplication,
        version: String? = "2.26454.2",
        directory: URL? = nil
    ) throws -> URL {
        try makeApplication(named: name, bundleIdentifier: application.bundleIdentifier, version: version, directory: directory)
    }

    /// Writes a bundle with an explicit identifier, including impersonation fixtures.
    ///
    /// Args:
    ///   name: Bundle filename.
    ///   bundleIdentifier: Identity stored in the actual Info.plist.
    ///   version: Actual short app version, or nil for absent metadata.
    ///   directory: Optional user-local app directory.
    ///
    /// Returns:
    ///   Fixture application URL.
    ///
    /// Raises:
    ///   Error: The fixture could not be created.
    private func makeApplication(
        named name: String,
        bundleIdentifier: String,
        version: String? = "2.26454.2",
        directory: URL? = nil
    ) throws -> URL {
        let appURL = (directory ?? appsURL).appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var plist = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "Agent"]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        let executableURL = contentsURL.appendingPathComponent("MacOS/Agent")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return appURL
    }

    /// Creates a real readable project directory for opening validation.
    ///
    /// Returns:
    ///   Standardized fixture project URL.
    ///
    /// Raises:
    ///   Error: The fixture directory could not be created.
    private func makeProject() throws -> URL {
        let url = rootURL.appendingPathComponent("中文 + Project", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
