import XCTest
import Security
@testable import Type4Me

final class KeychainServiceTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private var testStorageDirectory: URL!
    private var testStorageNamespace: String!

    private var credentialsURL: URL {
        testStorageDirectory.appendingPathComponent("credentials.json")
    }

    override func setUp() {
        super.setUp()
        let testID = UUID().uuidString.lowercased()
        testStorageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mytype-keychain-tests-\(testID)", isDirectory: true)
        testStorageNamespace = "com.mytype.tests.\(testID)"
        try? FileManager.default.createDirectory(
            at: testStorageDirectory,
            withIntermediateDirectories: true
        )
        KeychainService.useIsolatedStorageForTesting(
            directory: testStorageDirectory,
            namespace: testStorageNamespace
        )
        originalProvider = KeychainService.selectedASRProvider
    }

    override func tearDown() {
        KeychainService.delete(key: "test_key")
        try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
        KeychainService.resetStorageAfterTesting()
        if let testStorageDirectory {
            try? FileManager.default.removeItem(at: testStorageDirectory)
        }
        KeychainService.selectedASRProvider = originalProvider
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        try KeychainService.save(key: "test_key", value: "secret123")
        let loaded = KeychainService.load(key: "test_key")
        XCTAssertEqual(loaded, "secret123")
    }

    func testOverwrite() throws {
        try KeychainService.save(key: "test_key", value: "old")
        try KeychainService.save(key: "test_key", value: "new")
        XCTAssertEqual(KeychainService.load(key: "test_key"), "new")
    }

    func testLoadMissing() {
        let result = KeychainService.load(key: "nonexistent_key_xyz")
        XCTAssertNil(result)
    }

    func testDelete() throws {
        try KeychainService.save(key: "test_key", value: "value")
        KeychainService.delete(key: "test_key")
        XCTAssertNil(KeychainService.load(key: "test_key"))
    }

    func testLoadCredentials_fromKeychain() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let config = KeychainService.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.appKey, "myAppKey")
        XCTAssertEqual(config?.accessKey, "myAccessKey")
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testSaveASRCredentials_storesSecureFieldsOutsideCredentialsFile() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let fileData = try Data(contentsOf: credentialsURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let stored = try XCTUnwrap(json["tf_asr_volcano"] as? [String: String])

        XCTAssertEqual(stored["appKey"], "myAppKey")
        XCTAssertEqual(stored["resourceId"], "myResource")
        XCTAssertNil(stored["accessKey"])
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["accessKey"], "myAccessKey")
    }

    func testSelectedASRProviderPostsNotificationOnChange() {
        let targetProvider: ASRProvider = originalProvider == .bailian ? .volcano : .bailian
        let expectation = expectation(description: "provider change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.object as? ASRProvider, targetProvider)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeychainService.selectedASRProvider = targetProvider

        wait(for: [expectation], timeout: 1.0)
    }

    func testInteractionNotAllowedIsReportedAsLockedKeychain() {
        let error = KeychainReadError(status: errSecInteractionNotAllowed)

        XCTAssertEqual(error, .locked(errSecInteractionNotAllowed))
    }

    func testInteractionRequiredIsReportedAsLockedKeychain() {
        let error = KeychainReadError(status: errSecInteractionRequired)

        XCTAssertEqual(error, .locked(errSecInteractionRequired))
    }

    func testUnexpectedReadStatusRemainsDiagnosable() {
        let status = errSecDecode
        let error = KeychainReadError(status: status)

        XCTAssertEqual(error, .unavailable(status))
    }

    func testUnavailableKeychainIsNotMisreportedAsLocked() {
        let error = KeychainReadError(status: errSecNotAvailable)

        XCTAssertEqual(error, .unavailable(errSecNotAvailable))
    }

}
