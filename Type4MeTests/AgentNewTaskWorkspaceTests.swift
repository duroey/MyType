import Foundation
import XCTest
@testable import Type4Me

final class AgentNewTaskWorkspaceTests: XCTestCase {
    /// Verifies a folderless request never allocates substitute storage owned by MyType.
    ///
    /// Raises:
    ///   Error: Resolving the independent-task choice unexpectedly fails.
    func testIndependentChoiceDoesNotAllocateMyTypeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentNewTaskWorkspace(root: root)
        _ = try store.resolve(projectID: AgentNewTaskService.independentProjectID, draftID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "No Folder must not create a MyType-managed workspace")
    }

    /// Checks repeated folderless choices remain native requests without creating storage.
    ///
    /// Raises:
    ///   Error: The isolated fixture cannot be created or inspected.
    func testIndependentTasksAlwaysResolveToNativeNoFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentNewTaskWorkspace(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let firstID = UUID()
        let first = try store.resolve(projectID: "independent", draftID: firstID)
        let repeated = try store.resolve(projectID: "independent", draftID: firstID)
        let second = try store.resolve(projectID: "independent", draftID: UUID())
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, .nativeNoFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
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
        XCTAssertEqual(try store.resolve(projectID: project.path, draftID: UUID()), .project(project.standardizedFileURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks").path))
        for invalid in ["", "relative/project", "/", "/missing\0/project"] {
            XCTAssertThrowsError(try store.resolve(projectID: invalid, draftID: UUID()))
        }
    }

    /// Checks folderless requests do not inspect or follow legacy task-directory links.
    ///
    /// Raises:
    ///   Error: The isolated symlink fixture cannot be created.
    func testLegacyManagedSymlinksRemainUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertEqual(try AgentNewTaskWorkspace(root: link).resolve(projectID: "independent", draftID: UUID()), .nativeNoFolder)
        let taskID = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(taskID.uuidString), withDestinationURL: destination)
        XCTAssertEqual(try AgentNewTaskWorkspace(root: root).resolve(projectID: "independent", draftID: taskID), .nativeNoFolder)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
