import Foundation
import XCTest
@testable import Type4Me

final class ClaudeSessionViewingTests: XCTestCase {
    private let sessionID = "local_913c6df8-7b12-45d7-b895-84037752e99b"

    /// Fresh selection must remain eligible for a complete dwell before acknowledgement.
    func testStableSelectionAndBackgroundReturn() {
        var gate = ClaudeSessionViewingGate(stableSeconds: 1, maximumGapSeconds: 1)
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 0))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 0.75))
        XCTAssertEqual(gate.observe(selection: sessionID, eligible: true, now: 1), sessionID)
        XCTAssertNil(gate.observe(selection: sessionID, eligible: false, now: 1.25))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 1.5))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 2))
        XCTAssertEqual(gate.observe(selection: sessionID, eligible: true, now: 2.5), sessionID)
    }

    /// Null selection, uncertainty, switching, and a suspended observer invalidate its dwell.
    func testUncertainSelectionAndSamplingGapsFailClosed() {
        var gate = ClaudeSessionViewingGate(stableSeconds: 1, maximumGapSeconds: 1)
        _ = gate.observe(selection: sessionID, eligible: true, now: 0)
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 5))
        XCTAssertNil(gate.observe(selection: nil, eligible: true, now: 5.5))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 6))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: false, now: 6.5))
        XCTAssertNil(gate.observe(selection: sessionID, eligible: true, now: 7))
        XCTAssertNil(gate.observe(selection: "another", eligible: true, now: 7.5))
    }

    /// Old log contents, partial lines, rotations and truncations never restore old selection.
    func testFreshBoundedLogCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("main.log")
        let line = "2026-10-13 15:48:31 [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(sessionID)\n"
        try Data(line.utf8).write(to: log)
        var cursor = ClaudeFocusLogCursor(maximumBytes: 1024)
        XCTAssertFalse(try cursor.read(log).continuous)
        XCTAssertTrue(try cursor.read(log).selections.isEmpty)
        try append(Data(line.dropLast().utf8), to: log)
        XCTAssertTrue(try cursor.read(log).selections.isEmpty)
        try append(Data("\n".utf8), to: log)
        XCTAssertEqual(try cursor.read(log).selections, [sessionID])
        try Data(line.utf8).write(to: log, options: .atomic)
        XCTAssertFalse(try cursor.read(log).continuous)
        XCTAssertTrue(try cursor.read(log).selections.isEmpty)
        try Data().write(to: log)
        XCTAssertFalse(try cursor.read(log).continuous)
    }

    /// Malformed focus lines invalidate identity; unrelated log text cannot impersonate selection.
    func testLogSchemaValidationAndBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("main.log")
        try Data().write(to: log)
        var cursor = ClaudeFocusLogCursor(maximumBytes: 256)
        _ = try cursor.read(log)
        try append(Data("unrelated payload sessionId=\(sessionID)\n".utf8), to: log)
        XCTAssertTrue(try cursor.read(log).selections.isEmpty)
        try append(Data("2026-10-13 15:48:31 [info] [CCD] LocalSessions.setFocusedSession: sessionId=bad\n".utf8), to: log)
        XCTAssertEqual(try cursor.read(log).selections, ["null"])
        try append(Data(repeating: 65, count: 300), to: log)
        XCTAssertFalse(try cursor.read(log).continuous)
    }

    /// An observer restart can restore current-process focus without requiring another navigation.
    func testCursorRestoresOnlyCurrentProcessFocusWhenExplicitlyEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("main.log")
        let focusedAt = Date(timeIntervalSinceNow: -60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: focusedAt)) [info] [CCD] LocalSessions.setFocusedSession: sessionId=\(sessionID)\n"
        try Data(line.utf8).write(to: log)
        var cursor = ClaudeFocusLogCursor(maximumBytes: 1024, processStartedAt: focusedAt.addingTimeInterval(-60))
        let restored = try cursor.read(log)
        XCTAssertFalse(restored.continuous)
        XCTAssertEqual(restored.selections, [sessionID])
        XCTAssertNotNil(restored.restoredFocusAt)
        XCTAssertTrue(try cursor.read(log).selections.isEmpty)

        var laterProcess = ClaudeFocusLogCursor(maximumBytes: 1024, processStartedAt: focusedAt.addingTimeInterval(1))
        XCTAssertTrue(try laterProcess.read(log).selections.isEmpty)
    }

    /// Null, schema drift and incomplete tails must never recover an older valid identity.
    func testTailRecoveryFailsClosedAfterAmbiguousFocus() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = Date()
        let prefix = "\(formatter.string(from: now.addingTimeInterval(-60))) [info] [CCD] LocalSessions.setFocusedSession: sessionId="
        let good = prefix + sessionID + "\n"
        for tail in [good + prefix + "null\n", good + prefix + "invalid\n", good + "LocalSessions.setFocusedSession: unknown-schema\n", good + "unfinished"] {
            XCTAssertNil(ClaudeFocusLogCursor.restoreSelection(
                from: Data(tail.utf8), skipsFirstLine: false,
                processStartedAt: now.addingTimeInterval(-120), now: now
            ))
        }
        XCTAssertNil(ClaudeFocusLogCursor.restoreSelection(
            from: Data(good.utf8), skipsFirstLine: true,
            processStartedAt: now.addingTimeInterval(-120), now: now
        ))
    }

    /// Appends fixture bytes without replacing the inode used by the native log reader.
    ///
    /// Args:
    ///   data: New complete or partial log bytes.
    ///   url: Isolated test log.
    private func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }
}
