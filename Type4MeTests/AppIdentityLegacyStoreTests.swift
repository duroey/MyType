import XCTest
@testable import Type4Me

/// Fork builds before 2.10 kept a handful of stores in the upstream `Type4Me`
/// directory while the rest of the profile already lived in `mytype`. Unifying
/// the profile must adopt whichever copy the user actually used last.
final class AppIdentityLegacyStoreTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var profile: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-store-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("Type4Me", isDirectory: true)
        profile = root.appendingPathComponent("mytype-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        suiteName = "legacy-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testNewerLegacyFileReplacesStaleProfileCopyAndKeepsTheOldOne() throws {
        try write("{\"enabled\":false}", to: legacy, name: "revise-settings.json", age: 10)
        try write("{\"enabled\":true}", to: profile, name: "revise-settings.json", age: 1_000)

        reconcile()

        XCTAssertEqual(try read(profile, "revise-settings.json"), "{\"enabled\":false}")
        let superseded = profile
            .appendingPathComponent(AppIdentity.supersededStoresDirectoryName, isDirectory: true)
        XCTAssertEqual(try read(superseded, "revise-settings.json"), "{\"enabled\":true}")
    }

    func testOlderLegacyFileDoesNotReplaceProfileCopy() throws {
        try write("legacy", to: legacy, name: "intelli-sense-settings.json", age: 1_000)
        try write("current", to: profile, name: "intelli-sense-settings.json", age: 10)

        reconcile()

        XCTAssertEqual(try read(profile, "intelli-sense-settings.json"), "current")
    }

    func testMissingProfileFileIsCopiedFromLegacy() throws {
        try write("words", to: legacy, name: "jieba-user-dictionary-v1.utf8", age: 50)

        reconcile()

        XCTAssertEqual(try read(profile, "jieba-user-dictionary-v1.utf8"), "words")
        XCTAssertEqual(try read(legacy, "jieba-user-dictionary-v1.utf8"), "words",
                       "legacy files stay in place so a rollback build keeps working")
    }

    func testReconciliationRunsOnlyOnce() throws {
        try write("first", to: legacy, name: "revise-settings.json", age: 10)
        reconcile()
        try write("edited in the fork", to: profile, name: "revise-settings.json", age: 5)
        try write("upstream app wrote again", to: legacy, name: "revise-settings.json", age: 0)

        reconcile()

        XCTAssertEqual(try read(profile, "revise-settings.json"), "edited in the fork")
    }

    func testDatabaseSidecarsMoveTogetherWithTheDatabase() throws {
        // The legacy database is older than the profile copy, but its WAL holds
        // the most recent writes, so the whole set must be adopted as one unit.
        try write("legacy-db", to: legacy, name: "ask-anything.db", age: 1_000)
        try write("legacy-wal", to: legacy, name: "ask-anything.db-wal", age: 10)
        try write("stale-db", to: profile, name: "ask-anything.db", age: 500)
        try write("stale-shm", to: profile, name: "ask-anything.db-shm", age: 500)

        reconcile()

        XCTAssertEqual(try read(profile, "ask-anything.db"), "legacy-db")
        XCTAssertEqual(try read(profile, "ask-anything.db-wal"), "legacy-wal")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profile.appendingPathComponent("ask-anything.db-shm").path),
            "a stale sidecar must never be left next to a newer database"
        )
    }

    func testUnrelatedLegacyFilesAreIgnored() throws {
        try write("upstream history", to: legacy, name: "history.db", age: 0)
        try write("fork history", to: profile, name: "history.db", age: 1_000)

        reconcile()

        XCTAssertEqual(try read(profile, "history.db"), "fork history")
    }

    // MARK: - Helpers

    private func reconcile() {
        AppIdentity.reconcileLegacyProfileStores(
            legacyDirectory: legacy,
            profileDirectory: profile,
            defaults: defaults
        )
    }

    private func write(_ text: String, to directory: URL, name: String, age: TimeInterval) throws {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
    }

    private func read(_ directory: URL, _ name: String) throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
    }
}
