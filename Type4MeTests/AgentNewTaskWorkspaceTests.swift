import Foundation
import XCTest
@testable import Type4Me

final class AgentNewTaskWorkspaceTests: XCTestCase {
    /// Checks preparation creates nothing and confirmation gives each task a stable private directory.
    ///
    /// Raises:
    ///   Error: The isolated fixture cannot be created or inspected.
    func testIndependentTasksAreLazyDistinctAndStable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentNewTaskWorkspace(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let firstID = UUID()
        let first = try store.resolve(projectID: "independent", draftID: firstID)
        let repeated = try store.resolve(projectID: "independent", draftID: firstID)
        let second = try store.resolve(projectID: "independent", draftID: UUID())
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().path, root.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// Checks an existing project is reused without creating a replacement or changing its files.
    ///
    /// Raises:
    ///   Error: The isolated project cannot be created.
    func testMissingProjectIsNeverCreatedAndExistingProjectIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentNewTaskWorkspace(root: root.appendingPathComponent("tasks"))
        let project = root.appendingPathComponent("project")
        XCTAssertThrowsError(try store.resolve(projectID: project.path, draftID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(try store.resolve(projectID: project.path, draftID: UUID()), project.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks").path))
        for invalid in ["", "relative/project", "/", "/missing\0/project"] {
            XCTAssertThrowsError(try store.resolve(projectID: invalid, draftID: UUID()))
        }
    }

    /// Checks a managed-directory symlink cannot redirect creation into another project.
    ///
    /// Raises:
    ///   Error: The isolated symlink fixture cannot be created.
    func testManagedRootAndTaskSymlinksAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try AgentNewTaskWorkspace(root: link).resolve(projectID: "independent", draftID: UUID()))
        let taskID = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(taskID.uuidString), withDestinationURL: destination)
        XCTAssertThrowsError(try AgentNewTaskWorkspace(root: root).resolve(projectID: "independent", draftID: taskID))
    }
}
