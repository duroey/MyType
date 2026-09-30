import Foundation

enum AppIdentity {
    static let displayName = "MyType"
    static let urlScheme = "mytype"
    static let supportDirectoryName = "mytype"
    static let legacySupportDirectoryNames = ["Type4Me", "MyType"]

    /// Returns the current app support directory, creating it if needed.
    ///
    /// Delegates to `AppDataLocation` so fork code and upstream code resolve the
    /// same profile directory (and the same isolated directory under tests).
    ///
    /// Returns:
    ///   The `~/Library/Application Support/mytype` directory URL.
    static func appSupportDirectory() -> URL {
        AppDataLocation.profileDirectory
    }

    /// Migrates files from old app support directories into the mytype directory.
    ///
    /// Existing files in the current directory are preserved. Legacy directories
    /// are left in place so rollback builds can still read their data.
    static func migrateLegacySupportDirectories() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let target = appSupportDirectory()
        // Only the real profile receives legacy data; an isolated test profile must
        // never be seeded with the user's files.
        guard target.lastPathComponent == supportDirectoryName else { return }

        for name in legacySupportDirectoryNames {
            let source = appSupport.appendingPathComponent(name, isDirectory: true)
            guard source.path != target.path,
                  fm.fileExists(atPath: source.path) else {
                continue
            }
            copyMissingItems(from: source, to: target, fileManager: fm)
        }
    }

    /// Recursively copies missing files from a legacy directory.
    ///
    /// Args:
    ///   source: Legacy directory URL.
    ///   target: Current mytype directory URL.
    ///   fileManager: File manager used for filesystem operations.
    private static func copyMissingItems(from source: URL, to target: URL, fileManager: FileManager) {
        guard let items = try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)
            guard exists else { continue }

            if isDirectory.boolValue {
                try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                copyMissingItems(from: item, to: destination, fileManager: fileManager)
            } else if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.copyItem(at: item, to: destination)
            }
        }
    }
}
