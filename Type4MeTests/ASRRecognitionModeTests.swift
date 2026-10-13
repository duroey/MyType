import XCTest
import Security
@testable import Type4Me

final class ASRRecognitionModeTests: XCTestCase {

    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        super.tearDown()
    }

    func testUnknownOrMissingValueFallsBackToStreaming() {
        XCTAssertEqual(ASRRecognitionMode(credentialValue: nil), .streaming)
        XCTAssertEqual(ASRRecognitionMode(credentialValue: "weird"), .streaming)
        XCTAssertEqual(ASRRecognitionMode(credentialValue: " batch "), .batch)
    }

    func testLabelsSwitchWithAppLanguage() {
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(ASRRecognitionMode.streaming.displayName, "实时流式")
        XCTAssertEqual(ASRRecognitionMode.batch.displayName, "非实时")
        XCTAssertEqual(ASRRecognitionMode.credentialField.label, "识别方式")
        XCTAssertEqual(ASRRecognitionMode.batchRecordingPlaceholder, "录音中 · 结束后识别")
        XCTAssertTrue(ASRRecognitionMode.batch.summary.contains("结束录音后"))
        XCTAssertEqual(StepFunASRConfig.credentialFields.first { $0.key == "accessMode" }?.label, "接入方式")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(ASRRecognitionMode.streaming.displayName, "Real-time")
        XCTAssertEqual(ASRRecognitionMode.batch.displayName, "Batch")
        XCTAssertEqual(ASRRecognitionMode.credentialField.label, "Recognition")
        XCTAssertEqual(ASRRecognitionMode.batchRecordingPlaceholder, "Recording · text at end")
        XCTAssertTrue(ASRRecognitionMode.batch.summary.contains("when you stop recording"))
        XCTAssertEqual(StepFunASRConfig.credentialFields.first { $0.key == "accessMode" }?.label, "Access Mode")
        XCTAssertEqual(
            BatchASRError.recordingTooLong(provider: "Gemini", maxSeconds: 420).errorDescription,
            "The recording exceeds the 7-minute limit of Gemini batch recognition. Switch to real-time mode."
        )
    }

    func testModelFieldIsSwappedPerMode() {
        func keys(_ type: any ASRProviderConfig.Type, _ mode: ASRRecognitionMode) -> [String] {
            type.displayedCredentialFields(for: ["recognitionMode": mode.rawValue]).map(\.key)
        }
        for type in [BailianASRConfig.self, GeminiASRConfig.self, ElevenLabsASRConfig.self] as [any ASRProviderConfig.Type] {
            XCTAssertTrue(keys(type, .streaming).contains("model"))
            XCTAssertFalse(keys(type, .streaming).contains("batchModel"))
            XCTAssertTrue(keys(type, .batch).contains("batchModel"))
            XCTAssertFalse(keys(type, .batch).contains("model"))
        }
        XCTAssertEqual(keys(GrokASRConfig.self, .batch), keys(GrokASRConfig.self, .streaming))
    }

    func testHistoryModelLabelFollowsRecognitionMode() throws {
        func label(_ provider: ASRProvider, _ type: any ASRProviderConfig.Type, _ values: [String: String]) -> String? {
            RecognitionSession.asrModelLabel(for: provider, config: type.init(credentials: values))
        }
        let name = ASRProvider.bailian.displayName
        XCTAssertEqual(
            label(.bailian, BailianASRConfig.self, ["apiKey": "k"]),
            "\(name) · qwen-audio-3.1-asr-flash-streaming"
        )
        XCTAssertEqual(
            label(.bailian, BailianASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "\(name) · qwen-audio-3.1-asr-flash"
        )
        XCTAssertEqual(
            label(.elevenlabs, ElevenLabsASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "ElevenLabs · scribe_v2"
        )
        XCTAssertEqual(
            label(.gemini, GeminiASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "Gemini · gemini-3.5-transcribe"
        )
        XCTAssertEqual(
            label(.stepfun, StepFunASRConfig.self, ["apiKey": "k", "recognitionMode": "batch"]),
            "\(ASRProvider.stepfun.displayName) · stepaudio-2.5-asr"
        )
        XCTAssertEqual(
            label(.stepfun, StepFunASRConfig.self, ["apiKey": "k"]),
            "\(ASRProvider.stepfun.displayName) · stepaudio-2.5-asr-stream"
        )
    }

    func testConfigsRememberModelPerMode() throws {
        let config = try XCTUnwrap(ElevenLabsASRConfig(credentials: [
            "apiKey": "k",
            "recognitionMode": "batch",
            "model": "scribe_v2_realtime",
        ]))
        XCTAssertEqual(config.recognitionMode, .batch)
        XCTAssertEqual(config.model, "scribe_v2_realtime")
        XCTAssertEqual(config.batchModel, "scribe_v2")
        XCTAssertEqual(config.toCredentials()["recognitionMode"], "batch")
        XCTAssertTrue(config.isValid)
    }
}

final class StepFunBatchMigrationTests: XCTestCase {

    private let legacyStorageKey = "tf_asr_stepfunBatch"
    private var testStorageDirectory: URL!
    private var originalSelectedRaw: Any?
    private var originalLastBYOK: Any?

    /// Creates file-backed credentials so migration tests never access the login keychain.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let identifier = UUID().uuidString.lowercased()
        testStorageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mytype-stepfun-migration-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: testStorageDirectory, withIntermediateDirectories: true)
        KeychainService.useIsolatedStorageForTesting(
            directory: testStorageDirectory,
            namespace: "com.mytype.tests.\(identifier)"
        )
        originalSelectedRaw = UserDefaults.standard.object(forKey: "tf_selectedASRProvider")
        originalLastBYOK = UserDefaults.standard.object(forKey: "tf_lastBYOKProvider")
        UserDefaults.standard.set("volcano", forKey: "tf_selectedASRProvider")
        UserDefaults.standard.removeObject(forKey: "tf_lastBYOKProvider")
    }

    /// Restores only the defaults changed by the test and removes its isolated files.
    override func tearDown() {
        KeychainService.resetStorageAfterTesting()
        if let testStorageDirectory {
            try? FileManager.default.removeItem(at: testStorageDirectory)
        }
        for (key, value) in [
            ("tf_selectedASRProvider", originalSelectedRaw),
            ("tf_lastBYOKProvider", originalLastBYOK),
        ] {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testSelectedStepPlanSetupBecomesStepFunBatchModeWithoutTouchingRealtimeKey() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime", "region": "global"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "stepPlan"],
            secure: ["apiKey": "sk-plan"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["accessMode"], "stepPlan")
        XCTAssertEqual(values["apiKey"], "sk-realtime")
        XCTAssertEqual(values["stepPlanApiKey"], "sk-plan")
        XCTAssertEqual(values["region"], "global")
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))

        let config = try XCTUnwrap(KeychainService.loadASRConfig(for: .stepfun) as? StepFunASRConfig)
        XCTAssertEqual(config.batchAPIKey, "sk-plan")
    }

    func testMissingLegacyAccessModeMeansStepPlan() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: [:],
            secure: ["apiKey": "sk-plan"]
        )

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["accessMode"], "stepPlan")
        XCTAssertEqual(values["stepPlanApiKey"], "sk-plan")
        XCTAssertEqual(values["recognitionMode"], "batch", "No realtime key, so the batch setup stays active")
    }

    func testUnselectedStandardSetupKeepsExistingRealtimeMode() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-other-standard"]
        )
        UserDefaults.standard.set("volcano", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .volcano)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "streaming")
        XCTAssertEqual(values["apiKey"], "sk-realtime")
        XCTAssertEqual(values["accessMode"], "standard")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-other-standard",
            "The unused batch key must be backed up, not discarded"
        )
    }

    func testSelectedStandardBatchKeepsItsOwnKeyWhenKeysDiffer() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["apiKey"], "sk-batch", "The active batch setup keeps the key it was using")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-realtime"
        )
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))

        // A second launch must not migrate again.
        KeychainService.migrateStoredCredentials()
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["apiKey"], "sk-batch")
    }

    func testFailedFileSaveKeepsLegacyDataAndSelectionForRetry() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")

        KeychainService.failNextCredentialsFileSaveForTesting = true
        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "tf_selectedASRProvider"), "stepfunBatch")
        XCTAssertEqual(KeychainService.loadSecureValuesForTesting(account: legacyStorageKey)["apiKey"], "sk-batch")

        // The retry on the next launch completes the merge with the original selection intact.
        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["recognitionMode"], "batch")
        XCTAssertEqual(values["apiKey"], "sk-batch")
        XCTAssertEqual(
            KeychainService.loadSecureValuesForTesting(account: KeychainService.stepFunUnusedStandardKeyAccount)["apiKey"],
            "sk-realtime"
        )
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
    }

    func testLegacyConfigWithoutRecognitionModeStillCountsAsConfigured() throws {
        let original = KeychainService.loadASRCredentials(for: .bailian)
        defer { try? KeychainService.saveASRCredentials(for: .bailian, values: original ?? [:]) }

        // Saved by an older version: no recognitionMode or batchModel.
        try KeychainService.saveASRCredentials(for: .bailian, values: [
            "apiKey": "sk-old",
            "model": "qwen-audio-3.1-asr-flash-streaming",
        ])
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "sk-old", "region": "china"])

        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: ASRProvider.bailian))
        XCTAssertTrue(ModelSettingsHelpers.hasConfiguredCredentials(for: ASRProvider.stepfun))
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .bailian), .streaming)
    }

    func testStandardKeyFillsEmptyRealtimeKey() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey,
            plaintext: ["accessMode": "standard"],
            secure: ["apiKey": "sk-standard"]
        )

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["apiKey"], "sk-standard")
        XCTAssertEqual(values["recognitionMode"], "batch")
    }

    /// A denied source read must not be mistaken for an empty credential group.
    func testUnavailableLegacyKeychainDefersMigrationWithoutDeletingSource() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: ["accessMode": "standard"], secure: ["apiKey": "old-batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")
        KeychainService.secureReadErrorsForTesting[legacyStorageKey] = .locked(errSecInteractionNotAllowed)

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "tf_selectedASRProvider"), "stepfunBatch")
        KeychainService.secureReadErrorsForTesting = [:]
        XCTAssertEqual(KeychainService.loadSecureValuesForTesting(account: legacyStorageKey)["apiKey"], "old-batch")
        KeychainService.migrateStoredCredentials()
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["apiKey"], "old-batch")
        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
    }

    /// A denied destination read must not overwrite its existing realtime key.
    func testUnavailableDestinationKeychainDefersMigration() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: ["accessMode": "standard"], secure: ["apiKey": "batch"]
        )
        KeychainService.secureReadErrorsForTesting["tf_asr_stepfun"] = .locked(errSecInteractionNotAllowed)

        KeychainService.migrateStoredCredentials()

        KeychainService.secureReadErrorsForTesting = [:]
        XCTAssertEqual(KeychainService.loadSecureValuesForTesting(account: "tf_asr_stepfun")["apiKey"], "realtime")
        XCTAssertTrue(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
    }

    /// Keychain writes can fail independently from the credentials-file save.
    func testFailedSecureSaveKeepsLegacyDataAndSelectionForRetry() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: ["accessMode": "standard"], secure: ["apiKey": "batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")
        KeychainService.failNextSecureSaveAccountForTesting = "tf_asr_stepfun"

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "tf_selectedASRProvider"), "stepfunBatch")
        XCTAssertTrue(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
        KeychainService.migrateStoredCredentials()
        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["apiKey"], "batch")
    }

    /// Retrying cleanup must never reapply stale legacy values over subsequent user choices.
    func testFailedLegacyDeletionRetriesOnlyCleanup() throws {
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: ["accessMode": "standard"], secure: ["apiKey": "batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")
        KeychainService.failNextSecureDeleteAccountForTesting = legacyStorageKey
        KeychainService.migrateStoredCredentials()
        XCTAssertTrue(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
        try KeychainService.saveASRCredentials(for: .stepfun, values: [
            "apiKey": "new-realtime", "recognitionMode": "streaming", "accessMode": "standard",
        ])

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .stepfun))
        XCTAssertEqual(values["apiKey"], "new-realtime")
        XCTAssertEqual(values["recognitionMode"], "streaming")
        XCTAssertEqual(values["accessMode"], "standard")
        XCTAssertFalse(KeychainService.hasStoredCredentialsForTesting(storageKey: legacyStorageKey))
    }

    /// A realtime selection is meaningful even when its credentials are temporarily missing.
    func testSelectedRealtimeWithoutKeyDoesNotBecomeBatch() throws {
        UserDefaults.standard.set("stepfun", forKey: "tf_selectedASRProvider")
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: [:], secure: ["apiKey": "plan"]
        )

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun)
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["recognitionMode"], "streaming")
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["stepPlanApiKey"], "plan")
    }

    /// Explicit recognition-mode preferences take precedence over an unused legacy setup.
    func testExplicitRealtimePreferenceWithoutKeyDoesNotBecomeBatch() throws {
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["recognitionMode": "streaming"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: [:], secure: ["apiKey": "plan"]
        )

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .volcano)
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .stepfun)?["recognitionMode"], "streaming")
    }

    /// The user's current Volcano provider and streaming client survive the migration.
    func testMigrationPreservesVolcanoSelectionConfigurationAndStreaming() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "apiKey": "volcano-test", "resourceId": "auto",
        ])
        let before = try KeychainService.loadASRCredentialsCheckingKeychain(for: .volcano)
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: [:], secure: ["apiKey": "unused-plan"]
        )

        KeychainService.migrateStoredCredentials()

        let config = try XCTUnwrap(KeychainService.loadASRConfigCheckingKeychain(for: .volcano))
        XCTAssertEqual(KeychainService.selectedASRProvider, .volcano)
        XCTAssertEqual(try KeychainService.loadASRCredentialsCheckingKeychain(for: .volcano), before)
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .volcano, config: config).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .volcano, config: config) is VolcASRClient)
    }


    /// An unresolved legacy selection cannot silently route audio to another configured provider.
    func testPendingMigrationBlocksRecognitionInsteadOfFallingBackToVolcanoOrRealtime() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: ["apiKey": "configured-volcano"])
        try KeychainService.saveASRCredentials(for: .stepfun, values: ["apiKey": "configured-realtime"])
        try KeychainService.seedLegacyASRCredentialsForTesting(
            storageKey: legacyStorageKey, plaintext: ["accessMode": "standard"], secure: ["apiKey": "batch"]
        )
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")
        KeychainService.failNextCredentialsFileSaveForTesting = true
        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(KeychainService.selectedASRProvider, .stepfun, "The UI must retain the actual provider identity")
        XCTAssertThrowsError(try KeychainService.validatedSelectedASRProvider()) { error in
            XCTAssertEqual(error as? ASRProviderSelectionError, .pendingStepFunBatchMigration)
        }
        XCTAssertThrowsError(try KeychainService.loadASRConfigCheckingKeychain(for: .stepfun)) { error in
            XCTAssertEqual(error as? ASRProviderSelectionError, .pendingStepFunBatchMigration)
        }
        XCTAssertNil(KeychainService.loadSelectedASRConfig(), "No usable default streaming config may escape the blocked state")

        KeychainService.migrateStoredCredentials()

        XCTAssertEqual(try KeychainService.validatedSelectedASRProvider(), .stepfun)
        let config = try XCTUnwrap(KeychainService.loadASRConfigCheckingKeychain(for: .stepfun) as? StepFunASRConfig)
        XCTAssertEqual(config.recognitionMode, .batch)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .stepfun, config: config).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .stepfun, config: config) is StepFunBatchASRClient)
    }

    /// An explicit provider selection is the user's decision and can clear the migration gate.
    func testExplicitSelectionResolvesPendingProviderWithChangeNotification() throws {
        UserDefaults.standard.set("stepfunBatch", forKey: "tf_selectedASRProvider")
        let changed = expectation(description: "explicit StepFun selection")
        let token = NotificationCenter.default.addObserver(forName: .asrProviderDidChange, object: nil, queue: nil) { note in
            XCTAssertEqual(note.object as? ASRProvider, .stepfun)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeychainService.selectedASRProvider = .stepfun

        XCTAssertEqual(try KeychainService.validatedSelectedASRProvider(), .stepfun)
        wait(for: [changed], timeout: 1)
    }

    /// The startup failure explains the unresolved migration in either supported language.
    func testPendingMigrationErrorSwitchesBetweenChineseAndEnglish() {
        let originalLanguage = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        let error = ASRProviderSelectionError.pendingStepFunBatchMigration
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(error.errorDescription, "阶跃星辰旧版非实时配置尚未完成迁移，已暂停识别。请重新打开 MyType 重试，或在设置中重新选择识别服务。")
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(error.errorDescription, "The legacy StepFun batch configuration has not finished migrating, so recognition is paused. Restart MyType to retry, or explicitly select a recognition provider in Settings.")
    }

}
