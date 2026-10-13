import AppKit
import Foundation
import XCTest
@testable import Type4Me

/// Opt-in native observation test: no prompts, UI automation, persistent inbox, or app installation.
@MainActor
final class ClaudeSessionViewingLiveTests: XCTestCase {
    /// Exercises the production observer against existing fixture sessions and an in-memory inbox.
    ///
    /// Raises:
    ///   Error: Explicit fixtures, restoration state, or a bounded native open is unavailable.
    func testExistingClaudeSessionsAgainstMemoryOnlyInbox() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MYTYPE_CLAUDE_VIEWING_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires explicit opt-in and existing native fixture IDs")
        }
        let targets = (env["MYTYPE_CLAUDE_VIEWING_TARGETS"] ?? "").split(separator: ",").map(String.init)
        XCTAssertEqual(targets.count, 2)
        guard targets.count == 2 else { return }
        let original = try lastSelection()
        let orderedTargets = targets[0] == original ? Array(targets.reversed()) : targets
        let a = try fixtureSession(orderedTargets[0])
        let b = try fixtureSession(orderedTargets[1])
        let foreground = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let background = foreground == AgentDesktopApplication.claudeCode.bundleIdentifier
            ? AgentDesktopApplication.codex.bundleIdentifier : foreground
        let configuration = AgentNotificationConfiguration()
        let inbox = AgentInboxStore(configuration: configuration)
        var popups: [String] = []
        inbox.onCompletion = { popups.append($0.id) }
        var latest: ClaudeSessionViewingObservation?
        var observations: [ClaudeSessionViewingObservation] = []
        let worker = Task {
            await ClaudeSessionViewingSource(configuration: configuration).run { observation in
                await MainActor.run {
                    latest = observation
                    observations.append(observation)
                    inbox.applyViewedSession(observation)
                }
            }
        }
        var failure: Error?
        var viewedCompletionRemoved = false
        var backgroundRetained = false
        var visitedCompletionRemoved = false
        var originalRestored = false
        var start = Date()
        do {
            try await Task.sleep(for: .milliseconds(750))
            start = Date()
            try nativeOpen(session: a.sessionID)
            let sawA = await waitUntil { latest?.sessionID == a.sessionID && latest!.observedAt >= start }
            XCTAssertTrue(sawA, "Production observer must see fixture A from real native evidence")
            inbox.apply(.init(session: a, status: .completed, completionID: "memory-only-completion-a"))
            viewedCompletionRemoved = await waitUntil { inbox.items.isEmpty }
            XCTAssertTrue(viewedCompletionRemoved)
            XCTAssertTrue(popups.isEmpty)

            try nativeOpen(bundle: background)
            try await Task.sleep(for: .milliseconds(750))
            let backgroundAt = Date()
            inbox.apply(.init(session: b, status: .completed, completionID: "memory-only-completion-b"))
            try await Task.sleep(for: .seconds(configuration.completionAlertDelaySeconds + 0.5))
            backgroundRetained = inbox.items.contains { $0.id == b.id } && popups == [b.id]
            XCTAssertTrue(backgroundRetained)
            XCTAssertFalse(observations.contains { $0.observedAt >= backgroundAt }, "Background app cannot emit viewing acknowledgements")

            let switchedAt = Date()
            try nativeOpen(session: b.sessionID)
            visitedCompletionRemoved = await waitUntil {
                latest?.sessionID == b.sessionID && latest!.observedAt >= switchedAt && inbox.items.isEmpty
            }
            XCTAssertTrue(visitedCompletionRemoved)
            XCTAssertEqual(popups, [b.id], "Viewing must not replay a completed notification")
        } catch { failure = error }

        // Restore both identities even after a failed assertion or thrown open/read operation.
        do {
            let restoringAt = Date()
            try nativeOpen(session: original)
            originalRestored = await waitUntil { latest?.sessionID == original && latest!.observedAt >= restoringAt }
            XCTAssertTrue(originalRestored)
        } catch { if failure == nil { failure = error } }
        do { try nativeOpen(bundle: foreground) }
        catch { if failure == nil { failure = error } }
        worker.cancel()
        await worker.value
        inbox.cancelCompletionAlerts()
        if let output = env["MYTYPE_CLAUDE_VIEWING_RECEIPT"] {
            let receipt: [String: Any] = [
                "computerUse": false, "promptsSent": 0, "installedAppChanged": false,
                "completionInput": "synthetic updates in a memory-only store; native viewing evidence from production Swift observer",
                "viewedCompletionRemovedWithoutPopup": viewedCompletionRemoved,
                "backgroundCompletionRetainedAndAlerted": backgroundRetained,
                "visitedCompletionRemoved": visitedCompletionRemoved,
                "originalSessionRestored": originalRestored,
                "foregroundRestored": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == foreground,
                "observedSessionIDs": Array(Set(observations.map(\.sessionID))).sorted(),
                "durationSeconds": Date().timeIntervalSince(start),
                "error": failure.map { String(describing: $0) } ?? ""
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        if let failure { throw failure }
    }

    /// Waits a bounded time while allowing the observer and main actor to run.
    ///
    /// Args:
    ///   condition: Exact state transition expected from native evidence.
    ///
    /// Returns:
    ///   Whether the condition became true before the deadline.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Opens only registered native URLs/apps, without scripting their user interface.
    ///
    /// Args:
    ///   session: Existing native Code session to select.
    ///   bundle: Original foreground application to restore.
    private func nativeOpen(session: String? = nil, bundle: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let session {
            guard AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(session) else { throw CocoaError(.validationMissingMandatoryProperty) }
            process.arguments = ["claude://code/continue?session=" + session]
        } else if let bundle { process.arguments = ["-b", bundle] }
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { process.terminate(); throw CocoaError(.executableRuntimeMismatch) }
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }

    /// Reads a bounded native log tail solely to establish the restoration destination.
    ///
    /// Returns:
    ///   Last exact native session ID; never used to infer current viewing for the inbox.
    private func lastSelection() throws -> String {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")
        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let bound: UInt64 = 1_048_576
        try handle.seek(toOffset: size > bound ? size - bound : 0)
        let data = try handle.read(upToCount: Int(bound)) ?? Data()
        let marker = "[CCD] LocalSessions.setFocusedSession: sessionId="
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let range = line.range(of: marker) else { continue }
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(value) else { break }
            return value
        }
        throw CocoaError(.fileReadUnknown)
    }

    /// Loads an explicitly supplied fixture even when the native test conversation has no title.
    ///
    /// Args:
    ///   id: Exact existing desktop session ID supplied by the opt-in runner.
    ///
    /// Returns:
    ///   Whitelisted native/engine identity, without modifying the original metadata.
    private func fixtureSession(_ id: String) throws -> AgentSessionDescriptor {
        let configuration = AgentNotificationConfiguration()
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard AgentSessionMetadataValidation.isValidClaudeNativeIdentifier(id),
              let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var count = 0
        var matches: [AgentSessionDescriptor] = []
        for case let url as URL in entries {
            count += 1
            guard count <= configuration.maximumClaudeFocusMetadataEntries else { throw CocoaError(.fileReadTooLarge) }
            if entries.level >= 3 { entries.skipDescendants() }
            guard entries.level == 3, url.lastPathComponent == id + ".json" else { continue }
            let (handle, info) = try ClaudeFocusLogCursor.openOwnedFile(url)
            defer { try? handle.close() }
            guard info.st_size <= configuration.maximumClaudeFocusMetadataBytes,
                  let data = try handle.read(upToCount: configuration.maximumClaudeFocusMetadataBytes),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["sessionId"] as? String == id, value["isArchived"] as? Bool == false,
                  let engine = value["cliSessionId"] as? String, UUID(uuidString: engine) != nil else { throw CocoaError(.fileReadCorruptFile) }
            matches.append(.init(sessionID: id, application: .claudeCode, title: "Native viewing fixture",
                                 workspacePath: nil, updatedAt: 1, matchTexts: [], openCapability: .claudeNativeDeepLink,
                                 engineSessionID: engine.lowercased()))
        }
        guard matches.count == 1, let result = matches.first else { throw CocoaError(.fileReadUnknown) }
        return result
    }
}
