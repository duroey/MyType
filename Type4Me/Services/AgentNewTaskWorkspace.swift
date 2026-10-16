import Foundation

/// Allocates independent-task storage only after the user confirms a new-task draft.
struct AgentNewTaskWorkspace: Sendable {
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

    /// Reuses a selected project or creates one stable directory for this independent draft.
    ///
    /// Args:
    ///   projectID: A catalog path or the explicit independent-task choice.
    ///   draftID: Stable identity retained across an opening retry.
    ///
    /// Returns:
    ///   Existing workspace URL; no previous conversation history is copied.
    ///
    /// Raises:
    ///   Error: A selected directory disappeared, or managed storage is unsafe/unavailable.
    func resolve(projectID: String, draftID: UUID) throws -> URL {
        let fm = FileManager.default
        if projectID != AgentNewTaskService.independentProjectID {
            guard projectID.hasPrefix("/"), projectID != "/", !projectID.contains("\0"),
                  projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw AgentDesktopLauncherError.invalidProject(projectID)
            }
            let url = URL(fileURLWithPath: projectID, isDirectory: true).standardizedFileURL
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw AgentDesktopLauncherError.invalidProject(projectID)
            }
            return url
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateManagedDirectory(root)
        let directory = root.appendingPathComponent(draftID.uuidString, isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try validateManagedDirectory(directory)
        return directory
    }

    /// Rejects managed paths that are links or non-directories before returning them to an agent.
    ///
    /// Args:
    ///   url: Managed container or individual task directory.
    ///
    /// Raises:
    ///   Error: Resource identity or directory type cannot be verified.
    private func validateManagedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw AgentDesktopLauncherError.invalidProject(url.path)
        }
    }
}
