import XCTest
import Security
@testable import Type4Me

final class KeychainServiceTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private var testStorageDirectory: URL!
    private var testStorageNamespace: String!
    private var originalMigrationMarker: Any?
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
        originalMigrationMarker = UserDefaults.standard.object(forKey: "tf_migratedFromTypeFlow")
    }

    override func tearDown() {
        KeychainService.delete(key: "test_key")
        try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
        try? KeychainService.saveLLMCredentials(for: .doubao, values: [:])
        KeychainService.resetStorageAfterTesting()
        if let testStorageDirectory {
            try? FileManager.default.removeItem(at: testStorageDirectory)
        }
        KeychainService.selectedASRProvider = originalProvider
        restoreUserDefault(key: "tf_migratedFromTypeFlow", value: originalMigrationMarker)
        originalMigrationMarker = nil
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
            "apiKey": "myApiKey",
            "resourceId": "myResource",
        ])

        let config = KeychainService.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.apiKey, "myApiKey")
        XCTAssertEqual(config?.authMode, VolcanoASRConfig.authModeAPIKey)
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testCompatibleASRCredentials_backfillsVolcanoResourceIdForOldValues() throws {
        let values = KeychainService.compatibleASRCredentials(
            for: .volcano,
            stored: [
                "apiKey": "myApiKey",
            ]
        )

        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(VolcanoASRConfig(credentials: values))
    }

    func testCompatibleASRCredentials_preservesLegacyVolcanoAuthFields() throws {
        let values = KeychainService.compatibleASRCredentials(
            for: .volcano,
            stored: [
                "appKey": "legacyAppID",
                "accessKey": "legacyAccessToken",
            ]
        )

        XCTAssertEqual(values["authMode"], VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(values["appKey"], "legacyAppID")
        XCTAssertEqual(values["accessKey"], "legacyAccessToken")
        XCTAssertNotNil(VolcanoASRConfig(credentials: values))
    }

    func testCompatibleLLMCredentials_backfillsModelAndBaseURLForOldValues() throws {
        let values = KeychainService.compatibleLLMCredentials(
            for: .doubao,
            stored: ["apiKey": "myApiKey"]
        )

        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(OpenAICompatibleLLMConfig<DoubaoLLMTag>(credentials: values))
    }

    func testCompatibleCredentialsPreferStoredValuesOverLegacyFallbacks() throws {
        let values = KeychainService.compatibleASRCredentials(
            for: .volcano,
            stored: ["apiKey": "newApiKey"],
            legacy: [
                "apiKey": "oldApiKey",
                "resourceId": "oldResourceId",
            ]
        )

        XCTAssertEqual(values["apiKey"], "newApiKey")
        XCTAssertEqual(values["resourceId"], "oldResourceId")
    }

    func testLoadASRCredentials_backfillsDefaultsWhenSecureFieldIsStoredAlone() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "apiKey": "myApiKey",
        ])

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(KeychainService.loadASRConfig(for: .volcano))
    }

    func testLoadLLMCredentials_backfillsDefaultsWhenOnlyAPIKeyIsStored() throws {
        let original = KeychainService.loadLLMCredentials(for: .doubao)
        defer {
            if let original {
                try? KeychainService.saveLLMCredentials(for: .doubao, values: original)
            } else {
                try? KeychainService.saveLLMCredentials(for: .doubao, values: [:])
            }
        }

        try KeychainService.saveLLMCredentials(for: .doubao, values: [
            "apiKey": "myApiKey",
        ])

        let values = try XCTUnwrap(KeychainService.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(KeychainService.loadLLMProviderConfig(for: .doubao))
    }

    func testMigrateStoredCredentialsCleansLegacyFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_appKey", "tf_accessKey", "tf_resourceId"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, KeychainService.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? KeychainService.save(key: key, value: value)
                } else {
                    KeychainService.delete(key: key)
                }
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [:])
        UserDefaults.standard.set("legacyAppKey", forKey: "tf_appKey")
        try KeychainService.save(key: "tf_accessKey", value: "legacyAccessKey")
        UserDefaults.standard.set("legacyResource", forKey: "tf_resourceId")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["resourceId"], "legacyResource")
        XCTAssertEqual(values["authMode"], VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(values["appKey"], "legacyAppKey")
        XCTAssertEqual(values["accessKey"], "legacyAccessKey")
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_appKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_resourceId"))
        XCTAssertNil(KeychainService.load(key: "tf_accessKey"))
    }

    func testMigrateStoredCredentialsCleansLegacyLLMFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_llmApiKey", "tf_llmModel", "tf_llmEndpointId", "tf_llmBaseURL"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, KeychainService.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? KeychainService.save(key: key, value: value)
                } else {
                    KeychainService.delete(key: key)
                }
            }
        }

        try KeychainService.saveLLMCredentials(for: .doubao, values: [:])
        try KeychainService.save(key: "tf_llmApiKey", value: "legacyLLMKey")
        UserDefaults.standard.set("legacy-model", forKey: "tf_llmEndpointId")
        UserDefaults.standard.set("https://legacy.example/v1", forKey: "tf_llmBaseURL")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "legacyLLMKey")
        XCTAssertEqual(values["model"], "legacy-model")
        XCTAssertEqual(values["baseURL"], "https://legacy.example/v1")
        XCTAssertNil(KeychainService.load(key: "tf_llmApiKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmEndpointId"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmBaseURL"))
    }

    func testSaveASRCredentials_storesSecureFieldsOutsideCredentialsFile() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "apiKey": "myApiKey",
            "resourceId": "myResource",
        ])

        let fileData = try Data(contentsOf: credentialsURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let stored = try XCTUnwrap(json["tf_asr_volcano"] as? [String: String])

        XCTAssertEqual(stored["resourceId"], "myResource")
        XCTAssertNil(stored["apiKey"])
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["apiKey"], "myApiKey")
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

    private func restoreUserDefault(key: String, value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
