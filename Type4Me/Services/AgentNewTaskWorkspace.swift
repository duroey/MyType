import Foundation

/// Keeps an explicit project separate from the native application's folderless mode.
enum AgentNewTaskDestination: Equatable, Sendable {
    case project(URL)
    case nativeNoFolder
}

/// Resolves a confirmed destination without allocating substitute task storage.
struct AgentNewTaskWorkspace: Sendable {
    /// Legacy task root, retained so project discovery can exclude old managed tasks.
    static var managedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.profileDirectoryName, isDirectory: true)
            .appendingPathComponent("AgentTasks", isDirectory: true)
    }

    let root: URL

    /// Keeps the location without creating it or inspecting user files.
    ///
    /// Args:
    ///   root: App-managed task container; tests use an isolated temporary location.
    init(root: URL = Self.managedRoot) { self.root = root.standardizedFileURL }

    /// Reuses a selected project or delegates folderless storage to the native application.
    ///
    /// Args:
    ///   projectID: A catalog path or the explicit independent-task choice.
    ///   draftID: Identity of the confirmed draft; folderless storage is never allocated here.
    ///
    /// Returns:
    ///   Explicit project or native No Folder; no directories or history are created.
    ///
    /// Raises:
    ///   Error: A selected directory is invalid or disappeared.
    func resolve(projectID: String, draftID: UUID) throws -> AgentNewTaskDestination {
        if projectID == AgentNewTaskService.independentProjectID { return .nativeNoFolder }
        let fm = FileManager.default
        guard projectID.hasPrefix("/"), projectID != "/", !projectID.contains("\0"),
              projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AgentDesktopLauncherError.invalidProject(projectID)
        }
        let url = URL(fileURLWithPath: projectID, isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw AgentDesktopLauncherError.invalidProject(projectID)
        }
        return .project(url)
    }
}
