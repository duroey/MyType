import XCTest
@testable import Type4Me

final class BundledCredentialBootstrapTests: XCTestCase {
    private let defaultsKeys = [
        "tf_selectedASRProvider",
        "tf_selectedLLMProvider",
        BundledCredentialBootstrap.importMarkerKey,
    ]
    private var originalDefaults: [String: Any] = [:]
    private var storageDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                originalDefaults[key] = value
            }
            UserDefaults.standard.removeObject(forKey: key)
        }

        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mytype-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        KeychainService.useIsolatedStorageForTesting(
            directory: storageDirectory,
            namespace: "com.mytype.bootstrap-tests.\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        KeychainService.resetStorageAfterTesting()
        if let storageDirectory {
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        for key in defaultsKeys {
            if let value = originalDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        originalDefaults.removeAll()

        try super.tearDownWithError()
    }

    func testImportsCredentialsIntoEmptyStorage() throws {
        let payload = makePayload(id: "payload-a")

        let outcome = try BundledCredentialBootstrap.importPayload(payload)

        XCTAssertEqual(outcome, .completed(asrImported: true, llmImported: true))
        XCTAssertEqual(KeychainService.selectedASRProvider, .volcano)
        XCTAssertEqual(KeychainService.selectedLLMProvider, .doubao)
        XCTAssertEqual(
            KeychainService.loadASRCredentials(for: .volcano)?["apiKey"],
            "test-asr-key"
        )
        XCTAssertEqual(
            KeychainService.loadLLMCredentials(for: .doubao)?["apiKey"],
            "test-llm-key"
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: BundledCredentialBootstrap.importMarkerKey),
            "payload-a"
        )
    }

    func testPreservesExistingCredentialsAndSelections() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "apiKey": "existing-asr-key",
            "resourceId": VolcanoASRConfig.resourceIdSeedASR,
        ])
        try KeychainService.saveLLMCredentials(for: .doubao, values: [
            "apiKey": "existing-llm-key",
            "model": "existing-model",
            "baseURL": LLMProvider.doubao.defaultBaseURL,
        ])
        KeychainService.selectedASRProvider = .volcano
        KeychainService.selectedLLMProvider = .doubao

        let outcome = try BundledCredentialBootstrap.importPayload(makePayload(id: "payload-b"))

        XCTAssertEqual(outcome, .completed(asrImported: false, llmImported: false))
        XCTAssertEqual(
            KeychainService.loadASRCredentials(for: .volcano)?["apiKey"],
            "existing-asr-key"
        )
        XCTAssertEqual(
            KeychainService.loadLLMCredentials(for: .doubao)?["apiKey"],
            "existing-llm-key"
        )
    }

    func testSkipsPreviouslyImportedPayload() throws {
        let payload = makePayload(id: "payload-c")
        _ = try BundledCredentialBootstrap.importPayload(payload)

        let outcome = try BundledCredentialBootstrap.importPayload(payload)

        XCTAssertEqual(outcome, .alreadyImported)
    }

    func testRejectsUnsupportedSchemaBeforeWritingCredentials() throws {
        let payload = makePayload(id: "payload-d", schemaVersion: 99)

        XCTAssertThrowsError(try BundledCredentialBootstrap.importPayload(payload)) { error in
            XCTAssertEqual(
                error as? BundledCredentialBootstrapError,
                .unsupportedSchema(99)
            )
        }
        XCTAssertNil(KeychainService.loadASRCredentials(for: .volcano))
        XCTAssertNil(KeychainService.loadLLMCredentials(for: .doubao))
    }

    func testImportsExternalPayloadWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "MYTYPE_BUNDLED_CREDENTIALS_TEST_FILE"
        ] else {
            throw XCTSkip("No external bundled credential payload supplied")
        }

        let outcome = try BundledCredentialBootstrap.importPayload(
            at: URL(fileURLWithPath: path)
        )

        XCTAssertEqual(outcome, .completed(asrImported: true, llmImported: true))
        XCTAssertNotNil(KeychainService.loadASRConfig(for: .volcano))
        XCTAssertNotNil(KeychainService.loadLLMProviderConfig(for: .doubao))
    }

    /// Creates a valid payload containing test-only credentials.
    ///
    /// Args:
    ///   id: Stable identifier used to make imports idempotent.
    ///   schemaVersion: Payload schema version to exercise.
    ///
    /// Returns:
    ///   A credential payload that can initialize the default ASR and LLM providers.
    private func makePayload(
        id: String,
        schemaVersion: Int = BundledCredentialPayload.currentSchemaVersion
    ) -> BundledCredentialPayload {
        BundledCredentialPayload(
            schemaVersion: schemaVersion,
            payloadID: id,
            asrProvider: .volcano,
            asrCredentials: [
                "apiKey": "test-asr-key",
                "resourceId": VolcanoASRConfig.resourceIdSeedASR,
            ],
            llmProvider: .doubao,
            llmCredentials: [
                "apiKey": "test-llm-key",
                "model": "test-model",
                "baseURL": LLMProvider.doubao.defaultBaseURL,
            ]
        )
    }
}
