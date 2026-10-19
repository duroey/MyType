import Foundation
import XCTest
@testable import Type4Me

final class CodexNativeNoFolderServiceTests: XCTestCase {
    private var fixture: Fixture!

    /// Creates isolated native-state, log, and attachment fixtures.
    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    /// Removes only files created for this test.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixture.root)
        fixture = nil
    }

    /// Confirms both native receipts before reporting a folderless draft ready.
    func testOpensExactNativeDraftAndRetainsPrivateTaskAttachment() async throws {
        let fixture = fixture!
        let prompt = "请整理 A+B 的研究思路\n然后给我三个建议。"
        fixture.onOpen = { url in
            if url.isFileURL {
                try fixture.appendReceipt()
                try fixture.writeState(project: NSNull(), prompt: "旧任务")
            } else {
                try fixture.writeState(project: NSNull(), prompt: prompt)
            }
        }
        try await makeService().open(applicationURL: fixture.app, prompt: prompt)

        let opens = fixture.opens
        XCTAssertEqual(opens.count, 2)
        let attachment = try XCTUnwrap(opens.first)
        XCTAssertEqual(try String(contentsOf: attachment, encoding: .utf8), prompt)
        XCTAssertTrue(attachment.path.hasPrefix(fixture.requests.path + "/"))
        XCTAssertFalse(attachment.path.contains("AgentTasks"))
        let attributes = try FileManager.default.attributesOfItem(atPath: attachment.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: attachment.deletingLastPathComponent().path)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let components = try XCTUnwrap(URLComponents(url: opens[1], resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "prompt" }?.value, prompt)
        XCTAssertEqual(components.queryItems?.first { $0.name == "mode" }?.value, "codex")
        XCTAssertFalse(components.queryItems?.contains { $0.name == "path" || $0.name == "projectId" } ?? true)
    }

    /// Rejects an old file-open receipt even when the old draft already matches.
    func testOldReceiptCannotAuthorizePrefill() async throws {
        try fixture.appendReceipt()
        try fixture.writeState(project: NSNull(), prompt: "任务")

        await assertUnavailable(makeService(), prompt: "任务")
        XCTAssertEqual(fixture.opens.count, 1)
    }

    /// Rejects an appended record whose native timestamp predates this opening.
    func testAppendedOldTimestampDoesNotCountAsNewReceipt() async throws {
        let fixture = fixture!
        fixture.onOpen = { _ in
            try fixture.appendReceipt(at: Date().addingTimeInterval(-60))
            try fixture.writeState(project: NSNull(), prompt: "任务")
        }

        await assertUnavailable(makeService(), prompt: "任务")
        XCTAssertEqual(fixture.opens.count, 1)
    }

    /// Requires an explicit native null instead of an absent project field.
    func testMissingProjectStateFailsClosed() async throws {
        let fixture = fixture!
        fixture.onOpen = { _ in
            try fixture.appendReceipt()
            try fixture.writeState(project: nil, prompt: "任务")
        }

        await assertUnavailable(makeService(), prompt: "任务")
        XCTAssertEqual(fixture.opens.count, 1)
    }

    /// Refuses to prefill a composer still attached to a saved project.
    func testSelectedProjectDoesNotCountAsNoFolder() async throws {
        let fixture = fixture!
        fixture.onOpen = { _ in try fixture.appendReceipt() }

        await assertUnavailable(makeService(), prompt: "任务")
        XCTAssertEqual(fixture.opens.count, 1)
    }

    /// Rejects an older or truncated prompt despite a fresh state-file write.
    func testOldPromptDoesNotConfirmDelivery() async throws {
        let fixture = fixture!
        fixture.onOpen = { url in
            if url.isFileURL { try fixture.appendReceipt() }
            try fixture.writeState(project: NSNull(), prompt: "旧任务")
        }

        await assertUnavailable(makeService(), prompt: "新任务")
        XCTAssertEqual(fixture.opens.count, 2)
    }

    /// Accepts an idempotent exact draft after a fresh event and both native open requests.
    func testUnchangedExactDraftConfirmsTargetStateAfterFreshNativeOpen() async throws {
        let fixture = fixture!
        fixture.onOpen = { url in
            if url.isFileURL {
                try fixture.appendReceipt()
                try fixture.writeState(project: NSNull(), prompt: "相同任务")
            }
        }

        try await makeService().open(applicationURL: fixture.app, prompt: "相同任务")
        XCTAssertEqual(fixture.opens.count, 2)
        XCTAssertFalse(fixture.opens[1].isFileURL)
    }

    /// Unrelated native settings writes cannot turn the wrong draft into a successful result.
    func testUnrelatedStateWriteCannotConfirmDifferentPrompt() async throws {
        let fixture = fixture!
        fixture.onOpen = { url in
            if url.isFileURL {
                try fixture.appendReceipt()
                try fixture.writeState(project: NSNull(), prompt: "旧任务")
            } else {
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.state)) as? [String: Any])
                value["unrelated-window-preference"] = "changed"
                try JSONSerialization.data(withJSONObject: value).write(to: fixture.state, options: .atomic)
            }
        }

        await assertUnavailable(makeService(), prompt: "新任务")
        XCTAssertEqual(fixture.opens.count, 2)
    }

    /// Preserves cancellation without opening another composer or deleting its attachment.
    func testCancellationDoesNotRetryOrDeleteExposedAttachment() async throws {
        let fixture = fixture!
        let service = makeService(sleep: { _ in throw CancellationError() })
        do {
            try await service.open(applicationURL: fixture.app, prompt: "取消测试")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(fixture.opens.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.opens[0].path))
        }
    }

    /// Invalid task text cannot create files or trigger a native open.
    func testInvalidPromptHasNoSideEffects() async throws {
        do {
            try await makeService().open(applicationURL: fixture.app, prompt: " \n ")
            XCTFail("Expected invalid prompt")
        } catch let error as AgentDesktopLauncherError {
            XCTAssertEqual(error, .invalidPrompt)
        }
        XCTAssertTrue(fixture.opens.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.requests.path))
    }

    /// Bounds retention without deleting files that existing native drafts may reference.
    func testRetentionCapacityFailsBeforeNativeOpen() async throws {
        try FileManager.default.createDirectory(at: fixture.requests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.requests.appendingPathComponent("existing"), withIntermediateDirectories: true)
        var configuration = Self.configuration
        configuration.maximumRetainedRequests = 1

        do {
            try await makeService(configuration: configuration).open(applicationURL: fixture.app, prompt: "新任务")
            XCTFail("Expected retention capacity error")
        } catch let error as CodexNativeNoFolderService.ServiceError {
            XCTAssertEqual(error, .retentionLimit)
        }
        XCTAssertTrue(fixture.opens.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.requests.appendingPathComponent("existing").path))
    }

    /// Prevents a linked attachment container from redirecting task text elsewhere.
    func testSymlinkRequestDirectoryIsRejected() async throws {
        let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.requests, withDestinationURL: elsewhere)

        await assertUnavailable(makeService(), prompt: "新任务")
        XCTAssertTrue(fixture.opens.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    /// Keeps a second request from interleaving with the first native composer opening.
    func testConcurrentOpeningIsRejectedWithoutAnotherNativeAction() async throws {
        let fixture = fixture!
        var configuration = Self.configuration
        configuration.timeoutSeconds = 1
        let service = makeService(configuration: configuration)
        let first = Task { try await service.open(applicationURL: fixture.app, prompt: "第一个任务") }
        defer { first.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + configuration.timeoutSeconds
        while fixture.opens.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !fixture.opens.isEmpty else {
            XCTFail("First native opening did not arrive before the test deadline")
            return
        }
        await assertUnavailable(service, prompt: "第二个任务")
        XCTAssertEqual(fixture.opens.count, 1)
        first.cancel()
        do {
            try await first.value
            XCTFail("Expected first request cancellation")
        } catch is CancellationError {}
    }

    /// Confirms the production function against a real native draft only with explicit opt-in.
    ///
    /// Raises:
    ///   Error: Native receipt verification or packaged configuration fails.
    func testLiveNativeCodexDraftWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MYTYPE_CODEX_NO_FOLDER_LIVE"] == "1" else {
            throw XCTSkip("Requires explicit opt-in; opens a native draft without submitting it")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(CodexNativeNoFolderService.Configuration.self,
            from: Data(contentsOf: project.appendingPathComponent("Type4Me/Resources/CodexNativeNoFolderConfig.json")))
        let application = try XCTUnwrap(AgentDesktopLauncherService.shared.detectInstallation(for: .codex).applicationURL)
        let marker = "MYTYPE-NATIVE-NOFOLDER-" + UUID().uuidString.lowercased()
        let prompt = "\(marker)\n请核对 A+B & C 的任务草稿。\n不要执行工具，不要发送任何消息。"
        // Live attachments outlive the fixture because the native draft may retain them.
        let requests = project.appendingPathComponent(".build/codex-native-projectless-v2/swift-live-requests")
        let startedAt = Date()
        try await CodexNativeNoFolderService(requestRootDirectory: requests, configuration: configuration)
            .open(applicationURL: application, prompt: prompt)
        let receipt: [String: Any] = ["marker": marker, "startedAt": startedAt.timeIntervalSince1970,
                                     "finishedAt": Date().timeIntervalSince1970, "selectedProject": NSNull(),
                                     "draftTextVerified": true, "nativeFileReceiptVerified": true,
                                     "attachmentRoot": requests.path,
                                     "mode": "codex", "submitted": false, "computerUse": false]
        if let output = environment["MYTYPE_CODEX_NO_FOLDER_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("Native Codex draft verified; marker=\(marker); no task submitted")
    }

    /// Applies small deterministic deadlines while retaining production validation bounds.
    private static var configuration: CodexNativeNoFolderService.Configuration {
        var configuration = CodexNativeNoFolderService.Configuration()
        configuration.timeoutSeconds = 0.06
        configuration.pollIntervalSeconds = 0.002
        return configuration
    }

    /// Creates a service whose only side effects target this test's fixtures.
    ///
    /// Args:
    ///   configuration: Optional bounded settings for the tested failure mode.
    ///   sleep: Optional deterministic cancellation injection.
    ///
    /// Returns:
    ///   A service with a fake native opener and isolated native state.
    private func makeService(
        configuration: CodexNativeNoFolderService.Configuration = CodexNativeNoFolderServiceTests.configuration,
        sleep: CodexNativeNoFolderService.Sleep? = nil
    ) -> CodexNativeNoFolderService {
        let fixture = fixture!
        return CodexNativeNoFolderService(
            homeDirectory: fixture.root,
            requestRootDirectory: fixture.requests,
            configuration: configuration,
            applicationValidator: { _ in true },
            applicationOpener: { _, url, _ in try fixture.open(url) },
            logFilesProvider: { _, _ in [fixture.log] },
            sleep: sleep
        )
    }

    /// Verifies a failed native proof remains an explicit failure.
    ///
    /// Args:
    ///   service: Isolated service under test.
    ///   prompt: Exact task used for the attempt.
    private func assertUnavailable(_ service: CodexNativeNoFolderService, prompt: String) async {
        do {
            try await service.open(applicationURL: fixture.app, prompt: prompt)
            XCTFail("Unverified native No Folder must fail closed")
        } catch let error as AgentDesktopLauncherError {
            XCTAssertEqual(error, .nativeNoFolderUnavailable(.codex))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let app: URL
        let requests: URL
        let log: URL
        let state: URL
        private let lock = NSLock()
        private var recorded: [URL] = []
        var onOpen: (@Sendable (URL) throws -> Void)?

        /// Creates minimal native files without touching the real user profile.
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-no-folder-test-\(UUID().uuidString)")
            app = root.appendingPathComponent("ChatGPT.app")
            requests = root.appendingPathComponent("LaunchRequests")
            log = root.appendingPathComponent("codex.log")
            state = root.appendingPathComponent(".codex/.codex-global-state.json")
            try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: log)
            try writeState(project: ["type": "local", "projectId": "saved-project"], prompt: "旧任务")
        }

        /// Returns a synchronized copy of native opening requests.
        var opens: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        /// Records one native open before applying the configured native response.
        func open(_ url: URL) throws {
            lock.lock()
            recorded.append(url)
            lock.unlock()
            try onOpen?(url)
        }

        /// Appends one native file receipt with a controllable timestamp.
        func appendReceipt(at date: Date = Date()) throws {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: date)) info Opened desktop files in projectless task fileCount=1 fileExtensions=[\"txt\"]\n"
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        }

        /// Atomically publishes a native state revision containing only fixture data.
        func writeState(project: Any?, prompt: String) throws {
            var value: [String: Any] = [
                "electron-persisted-atom-state": [
                    "composer-prompt-drafts-v2": [
                        "new-conversation": ["prompt": ["document": [
                            "type": "doc",
                            "content": prompt.components(separatedBy: "\n").map { line in
                                ["type": "paragraph", "content": [["type": "text", "text": line]]] as [String: Any]
                            },
                        ]]],
                    ],
                ],
            ]
            if let project { value["selected-project"] = project }
            try JSONSerialization.data(withJSONObject: value).write(to: state, options: .atomic)
        }
    }
}
