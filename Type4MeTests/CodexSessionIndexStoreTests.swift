import XCTest
@testable import Type4Me

final class CodexSessionIndexStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var sessionsRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-index-\(UUID().uuidString)", isDirectory: true)
        sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func testLoadsRecentMeaningfulUserMessagesFromCodexJsonl() throws {
        let projectURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: projectURL.path,
            messages: [
                "Go",
                "# AGENTS.md instructions for /tmp/project",
                "微信输入框现在可以识别了",
                "自动唤醒还是偶尔失败",
            ]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot)

        let entries = store.loadSessions()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "session-voice")
        XCTAssertEqual(entries.first?.cwd, projectURL.path)
        XCTAssertEqual(entries.first?.matchTexts, ["自动唤醒还是偶尔失败", "微信输入框现在可以识别了"])
    }

    func testFindsBestSessionByRecentUserMessages() throws {
        let voiceURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        let graphicsURL = tempRoot.appendingPathComponent("Graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: graphicsURL, withIntermediateDirectories: true)
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )
        try writeSession(
            fileName: "session-graphics.jsonl",
            id: "session-graphics",
            cwd: graphicsURL.path,
            messages: ["计算机图形学渲染问题"]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot)
        _ = store.reconcileSessionIndex()

        let match = store.bestMatch(for: "自动唤醒")

        XCTAssertEqual(match?.id, "session-voice")
        XCTAssertEqual(match?.cwd, voiceURL.path)
    }

    func testReconcileSessionIndexWritesCacheAndRemovesDeletedSessions() throws {
        let cacheURL = tempRoot.appendingPathComponent("codex-sessions-index.json")
        let voiceURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        let graphicsURL = tempRoot.appendingPathComponent("Graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: graphicsURL, withIntermediateDirectories: true)
        let voiceSessionURL = try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )
        let graphicsSessionURL = try writeSession(
            fileName: "session-graphics.jsonl",
            id: "session-graphics",
            cwd: graphicsURL.path,
            messages: ["计算机图形学渲染问题"]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot, cacheURL: cacheURL)

        XCTAssertEqual(Set(store.reconcileSessionIndex().map(\.id)), ["session-voice", "session-graphics"])
        try FileManager.default.removeItem(at: graphicsSessionURL)
        let reconciled = store.reconcileSessionIndex()
        let cached = try JSONDecoder().decode([CodexSessionIndexEntry].self, from: Data(contentsOf: cacheURL))

        XCTAssertEqual(reconciled.map(\.id), ["session-voice"])
        XCTAssertEqual(cached.map(\.id), ["session-voice"])
        XCTAssertEqual(cached.first?.sourceFilePath, voiceSessionURL.path)
    }

    func testBestMatchUsesCachedSessionIndexBeforeScanningJsonl() throws {
        let cacheURL = tempRoot.appendingPathComponent("codex-sessions-index.json")
        let voiceURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceURL, withIntermediateDirectories: true)
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot, cacheURL: cacheURL)
        _ = store.reconcileSessionIndex()
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["计算机图形学渲染问题"]
        )

        let match = store.bestMatch(for: "自动唤醒")

        XCTAssertEqual(match?.id, "session-voice")
    }

    func testBestMatchDoesNotScanJsonlWhenCacheIsMissing() throws {
        let cacheURL = tempRoot.appendingPathComponent("codex-sessions-index.json")
        let voiceURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceURL, withIntermediateDirectories: true)
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot, cacheURL: cacheURL)

        let match = store.bestMatch(for: "自动唤醒")

        XCTAssertNil(match)
    }

    func testBestMatchDoesNotRefreshDiskWhenCacheMisses() throws {
        let cacheURL = tempRoot.appendingPathComponent("codex-sessions-index.json")
        let voiceURL = tempRoot.appendingPathComponent("VoiceInterface", isDirectory: true)
        let graphicsURL = tempRoot.appendingPathComponent("Graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: graphicsURL, withIntermediateDirectories: true)
        try writeSession(
            fileName: "session-graphics.jsonl",
            id: "session-graphics",
            cwd: graphicsURL.path,
            messages: ["计算机图形学渲染问题"]
        )
        let store = CodexSessionIndexStore(sessionsRoot: sessionsRoot, cacheURL: cacheURL)
        _ = store.reconcileSessionIndex()
        try writeSession(
            fileName: "session-voice.jsonl",
            id: "session-voice",
            cwd: voiceURL.path,
            messages: ["自动唤醒还是偶尔失败"]
        )

        let match = store.bestMatch(for: "自动唤醒")

        XCTAssertNil(match)
    }

    /// Writes a minimal Codex session jsonl fixture.
    ///
    /// Args:
    ///   fileName: Fixture filename under the test session root.
    ///   id: Codex session identifier.
    ///   cwd: Working directory stored in `session_meta`.
    ///   messages: User messages written as `event_msg` payloads.
    @discardableResult
    private func writeSession(
        fileName: String,
        id: String,
        cwd: String,
        messages: [String]
    ) throws -> URL {
        let fileURL = sessionsRoot.appendingPathComponent(fileName)
        var lines = [
            #"{"timestamp":"2026-06-12T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-06-12T00:00:00Z","cwd":"\#(cwd)"}}"#,
        ]
        lines += messages.map { message in
            #"{"timestamp":"2026-06-12T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"\#(message)"}}"#
        }
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
