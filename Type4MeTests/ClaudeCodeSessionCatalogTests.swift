import Foundation
import XCTest
@testable import Type4Me

final class ClaudeCodeSessionCatalogTests: XCTestCase {
    private var rootURL: URL!
    private var organizationURL: URL!

    /// Creates a native metadata directory shape isolated from actual Claude history.
    ///
    /// Raises:
    ///   Error: The fixture directory could not be created.
    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-native-catalog-\(UUID().uuidString)")
        organizationURL = rootURL.appendingPathComponent("account/organization")
        try FileManager.default.createDirectory(at: organizationURL, withIntermediateDirectories: true)
    }

    /// Removes only this test's isolated synthetic metadata.
    ///
    /// Raises:
    ///   Error: Fixture cleanup failed.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    /// Verifies native identity is preserved and cannot become a misleading CLI resume request.
    ///
    /// Raises:
    ///   Error: Fixture serialization or metadata reading failed.
    func testNativeMetadataPreservesTitleAndUnsupportedOpening() throws {
        try writeMetadata(id: "local_abc", fields: [
            "title": "模型训练", "cliSessionId": "different_cli_id", "cwd": "/worktree", "originCwd": "/project",
            "promptAppendSnapshot": ["append": "Ignored private field"],
        ])

        let session = try XCTUnwrap(ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { false }
        ).loadSessions().first)

        XCTAssertEqual(session.sessionID, "local_abc")
        XCTAssertEqual(session.title, "模型训练")
        XCTAssertEqual(session.workspacePath, "/worktree")
        XCTAssertEqual(session.updatedAt, 1_760_000_000)
        XCTAssertEqual(session.matchTexts, ["模型训练"])
        XCTAssertEqual(session.openCapability, .unsupported)
        XCTAssertFalse(session.canOpenExistingConversation)
    }

    /// Verifies available native opening retains Desktop identity rather than a CLI import ID.
    ///
    /// Raises:
    ///   Error: Synthetic fixture writing, reading, or unwrapping failed.
    func testSupportedNativeOpeningPreservesExactIDWithoutCLIImport() throws {
        let nativeID = "local_069abcde-1234-5678-9abc-0123456789ab"
        let cliID = "different-cli-session"
        try writeMetadata(id: nativeID, fields: ["title": "原生会话", "cliSessionId": cliID])

        let session = try XCTUnwrap(ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { true }
        ).loadSessions().first)

        XCTAssertEqual(session.sessionID, nativeID)
        XCTAssertEqual(session.id, "claudeCode:" + nativeID)
        XCTAssertNotEqual(session.sessionID, cliID)
        XCTAssertEqual(session.application, .claudeCode)
        XCTAssertEqual(session.title, "原生会话")
        XCTAssertEqual(session.matchTexts, ["原生会话"])
        XCTAssertEqual(session.openCapability, .claudeNativeDeepLink)
        XCTAssertTrue(session.canOpenExistingConversation)
    }

    /// Verifies malformed native IDs cannot be promoted into a session navigation target.
    ///
    /// Raises:
    ///   Error: Synthetic fixture metadata could not be written or read.
    func testMalformedNativeIDsAreRejectedEvenWhenOpeningIsAvailable() throws {
        let invalidIDs = [
            "local_", "last", "cli_id", "local_abc_", "local_a_b", "local_中文",
            "local_a%2Fb", "local_" + String(repeating: "a", count: 65),
        ]
        for id in invalidIDs {
            try writeMetadata(id: id, fields: ["title": "Malformed identity"])
        }

        let sessions = try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { true }
        ).loadSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    /// Verifies ASCII native suffixes accept both supported length boundaries unchanged.
    ///
    /// Raises:
    ///   Error: Synthetic fixture metadata could not be written or read.
    func testNativeIDLengthBoundariesAndASCIICharactersArePreserved() throws {
        let validIDs = ["local_a", "local_A9-Z", "local_" + String(repeating: "a", count: 64)]
        for id in validIDs {
            try writeMetadata(id: id, fields: ["title": "Valid native identity"])
        }

        let sessions = try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { true }
        ).loadSessions()

        XCTAssertEqual(Set(sessions.map(\.sessionID)), Set(validIDs))
        XCTAssertTrue(sessions.allSatisfy { $0.openCapability == .claudeNativeDeepLink })
        XCTAssertTrue(sessions.allSatisfy(\.canOpenExistingConversation))
    }

    /// Verifies untitled, archived and identity-mismatched metadata is not imported.
    ///
    /// Raises:
    ///   Error: Fixture metadata could not be written or read.
    func testInvalidNativeRecordsFailClosed() throws {
        try writeMetadata(id: "local_untitled", fields: [:])
        try writeMetadata(id: "local_archived", fields: ["title": "Archived", "isArchived": true])
        try writeMetadata(id: "local_mismatch", fields: ["title": "Mismatch", "sessionId": "local_other"])

        XCTAssertTrue(try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { false }
        ).loadSessions().isEmpty)
    }

    /// Verifies an absent archive field indicates an incompatible record rather than an active session.
    ///
    /// Raises:
    ///   Error: Fixture metadata could not be written or read.
    func testMissingArchiveFlagIsNotAssumedActive() throws {
        let record: [String: Any] = ["sessionId": "local_unknown", "title": "Unknown schema", "lastActivityAt": 1_760_000_000_000]
        try JSONSerialization.data(withJSONObject: record).write(to: organizationURL.appendingPathComponent("local_unknown.json"))

        XCTAssertTrue(try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { false }
        ).loadSessions().isEmpty)
    }

    /// Verifies large metadata files are rejected before decoding snapshots or other fields.
    ///
    /// Raises:
    ///   Error: Fixture metadata could not be written or read.
    func testMetadataByteBoundRejectsOversizedFiles() throws {
        try writeMetadata(id: "local_large", fields: ["title": "Large", "unused": String(repeating: "x", count: 1024)])
        var configuration = ClaudeCodeSessionCatalog.Configuration()
        configuration.maximumFileBytes = 128

        XCTAssertTrue(try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, configuration: configuration, openingAvailability: { false }
        ).loadSessions().isEmpty)
    }

    /// Verifies a symlink cannot redirect the metadata reader to another directory or transcript.
    ///
    /// Raises:
    ///   Error: Fixture symlink creation failed.
    func testSymlinkMetadataIsNotFollowed() throws {
        let targetURL = organizationURL.appendingPathComponent("other.json")
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "local_symlink", "title": "Do not follow", "isArchived": false,
            "lastActivityAt": 1_760_000_000_000,
        ]).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: organizationURL.appendingPathComponent("local_symlink.json"), withDestinationURL: targetURL)

        XCTAssertTrue(try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { false }
        ).loadSessions().isEmpty)
    }

    /// Verifies scheduled files and CLI-shaped history cannot masquerade as native Code sessions.
    ///
    /// Raises:
    ///   Error: Synthetic unrelated metadata could not be written or read.
    func testNoFallbackToCLIOrScheduledFiles() throws {
        let unrelated: [String: Any] = ["sessionId": "cli_id", "title": "CLI title", "cwd": "/project"]
        try JSONSerialization.data(withJSONObject: unrelated).write(to: organizationURL.appendingPathComponent("scheduled-tasks.json"))
        try JSONSerialization.data(withJSONObject: unrelated).write(to: organizationURL.appendingPathComponent("cli_id.jsonl"))

        XCTAssertTrue(try ClaudeCodeSessionCatalog(
            metadataDirectory: rootURL, openingAvailability: { false }
        ).loadSessions().isEmpty)
    }

    /// Writes a bounded synthetic native metadata record using Desktop's observed file shape.
    ///
    /// Args:
    ///   id: Native session identifier and fixture filename stem.
    ///   fields: Synthetic overrides for selected fields.
    ///
    /// Raises:
    ///   Error: Fixture serialization or writing failed.
    private func writeMetadata(id: String, fields: [String: Any]) throws {
        var record: [String: Any] = [
            "sessionId": id, "isArchived": false, "createdAt": 1_759_000_000_000,
            "lastActivityAt": 1_760_000_000_000,
        ]
        record.merge(fields) { _, override in override }
        try JSONSerialization.data(withJSONObject: record).write(to: organizationURL.appendingPathComponent(id + ".json"))
    }
}
