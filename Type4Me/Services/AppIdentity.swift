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

    // MARK: - Stores that stayed in the upstream directory

    /// Directory fork builds before 2.10 still wrote a few stores to.
    static let legacySplitStoreDirectoryName = "Type4Me"
    /// Holds profile copies replaced by a newer legacy file, so nothing is destroyed.
    static let supersededStoresDirectoryName = "superseded-by-legacy-stores"
    static let legacySplitStoresReconciledKey = "tf_legacySplitStoresReconciled"

    /// Stores the pre-2.10 fork kept in `Type4Me/` while the rest of the profile
    /// already lived in `mytype/`. Each entry is adopted as one unit, because a
    /// SQLite database and its sidecars are only consistent together.
    static let legacySplitStoreUnits: [[String]] = [
        ["ask-anything.db", "ask-anything.db-wal", "ask-anything.db-shm"],
        ["revise-settings.json"],
        ["intelli-sense-settings.json"],
        ["intelli-sense-expression-profile.json"],
        ["batch-correction-suggestions-v1.json"],
        ["jieba-user-dictionary-v1.utf8"],
    ]

    /// Runs the one-time reconciliation against the real directories.
    ///
    /// Must run before any of the affected stores opens its file.
    static func reconcileLegacyProfileStoresIfNeeded() {
        let fm = FileManager.default
        let profile = appSupportDirectory()
        // An isolated test profile must never be seeded with the user's files.
        guard profile.lastPathComponent == supportDirectoryName else { return }
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(legacySplitStoreDirectoryName, isDirectory: true)
        reconcileLegacyProfileStores(
            legacyDirectory: legacy,
            profileDirectory: profile,
            defaults: .standard,
            fileManager: fm
        )
    }

    /// Adopts, once, the newer copy of every store that used to live in `Type4Me/`.
    ///
    /// The profile already holds a snapshot of these files from the earlier
    /// copy-if-missing migration, but the app kept writing the legacy ones. Moving
    /// the stores into the profile without this step would silently revert them
    /// to that stale snapshot. Replaced files are kept, and legacy files stay in
    /// place so a rollback build keeps working.
    ///
    /// Args:
    ///   legacyDirectory: Directory the old builds wrote these stores to.
    ///   profileDirectory: Profile directory the stores live in from now on.
    ///   defaults: Defaults domain that records the one-time completion.
    ///   fileManager: File manager used for filesystem operations.
    static func reconcileLegacyProfileStores(
        legacyDirectory: URL,
        profileDirectory: URL,
        defaults: UserDefaults,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: legacySplitStoresReconciledKey) else { return }
        guard legacyDirectory.standardizedFileURL != profileDirectory.standardizedFileURL else { return }

        var succeeded = true
        for unit in legacySplitStoreUnits {
            let legacyDate = latestModificationDate(of: unit, in: legacyDirectory, fileManager: fileManager)
            guard let legacyDate else { continue }
            let profileDate = latestModificationDate(of: unit, in: profileDirectory, fileManager: fileManager)
            if let profileDate, profileDate >= legacyDate { continue }
            do {
                try adoptLegacyUnit(
                    unit,
                    from: legacyDirectory,
                    into: profileDirectory,
                    fileManager: fileManager
                )
                NSLog("[AppIdentity] Adopted newer legacy store %@", unit[0])
            } catch {
                succeeded = false
                NSLog(
                    "[AppIdentity] Failed to adopt legacy store %@: %@",
                    unit[0],
                    String(describing: error)
                )
            }
        }
        // A failed unit is retried on the next launch rather than left half-moved.
        if succeeded {
            defaults.set(true, forKey: legacySplitStoresReconciledKey)
        }
    }

    /// Returns the newest modification date among a unit's existing files.
    ///
    /// Args:
    ///   unit: File names that belong together.
    ///   directory: Directory to look in.
    ///   fileManager: File manager used for filesystem operations.
    ///
    /// Returns:
    ///   The newest date, or `nil` when none of the files exist.
    private static func latestModificationDate(
        of unit: [String],
        in directory: URL,
        fileManager: FileManager
    ) -> Date? {
        unit.compactMap { name -> Date? in
            let path = directory.appendingPathComponent(name).path
            return (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }

    /// Replaces a profile store with its legacy copy, keeping what it replaces.
    ///
    /// Args:
    ///   unit: File names that belong together.
    ///   legacyDirectory: Directory holding the newer copy.
    ///   profileDirectory: Directory that receives it.
    ///   fileManager: File manager used for filesystem operations.
    ///
    /// Throws:
    ///   Any filesystem error; the caller retries on the next launch.
    private static func adoptLegacyUnit(
        _ unit: [String],
        from legacyDirectory: URL,
        into profileDirectory: URL,
        fileManager: FileManager
    ) throws {
        let superseded = profileDirectory
            .appendingPathComponent(supersededStoresDirectoryName, isDirectory: true)
        // Set every current file aside first, including sidecars the legacy copy
        // does not have: a stale sidecar next to a newer database corrupts it.
        for name in unit {
            let current = profileDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            try fileManager.createDirectory(at: superseded, withIntermediateDirectories: true)
            let kept = superseded.appendingPathComponent(name)
            if fileManager.fileExists(atPath: kept.path) {
                try fileManager.removeItem(at: kept)
            }
            try fileManager.moveItem(at: current, to: kept)
        }
        for name in unit {
            let source = legacyDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: profileDirectory.appendingPathComponent(name))
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
