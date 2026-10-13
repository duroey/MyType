import Foundation
import Security

enum KeychainService {

    private struct StorageConfiguration {
        let scalarService: String
        let groupedService: String
        let legacyScalarService: String
        let legacyGroupedService: String
        let credentialsURL: URL?
        let usesKeychain: Bool

        static let production = StorageConfiguration(
            scalarService: "com.mytype.scalar",
            groupedService: "com.mytype.grouped",
            legacyScalarService: "com.type4me.scalar",
            legacyGroupedService: "com.type4me.grouped",
            credentialsURL: nil,
            usesKeychain: true
        )

        /// Default for XCTest runs that do not request their own isolated namespace.
        /// `credentialsURL` stays nil so it resolves inside the test profile directory.
        static let xctestDefault = StorageConfiguration(
            scalarService: "com.mytype.tests.scalar",
            groupedService: "com.mytype.tests.grouped",
            legacyScalarService: "com.mytype.tests.legacy.scalar",
            legacyGroupedService: "com.mytype.tests.legacy.grouped",
            credentialsURL: nil,
            usesKeychain: false
        )
    }

    private static let lock = NSLock()
    private static var cachedCredentials: [String: Any]?

    #if DEBUG
    private static let runningUnderXCTest: Bool = {
        let process = ProcessInfo.processInfo
        let processName = process.processName.lowercased()
        return process.environment["XCTestConfigurationFilePath"] != nil
            || processName == "xctest"
            || processName.hasSuffix("packagetests")
            || (CommandLine.arguments.first?.contains(".xctest") == true)
    }()
    #else
    /// Release builds contain no XCTest routing and always use production storage.
    private static let runningUnderXCTest = false
    #endif

    private static var testingStorageConfiguration: StorageConfiguration?

    /// Explicit per-test isolation wins; any other XCTest run falls back to a
    /// file-backed namespace so a test can never reach production credentials.
    private static var activeStorageConfiguration: StorageConfiguration {
        testingStorageConfiguration ?? (runningUnderXCTest ? .xctestDefault : .production)
    }

    private static var keychainScalarService: String {
        activeStorageConfiguration.scalarService
    }

    private static var keychainGroupedService: String {
        activeStorageConfiguration.groupedService
    }

    private static var legacyKeychainScalarService: String {
        activeStorageConfiguration.legacyScalarService
    }

    private static var legacyKeychainGroupedService: String {
        activeStorageConfiguration.legacyGroupedService
    }

    static var credentialsFileURL: URL {
        activeStorageConfiguration.credentialsURL
            ?? AppIdentity.appSupportDirectory().appendingPathComponent("credentials.json")
    }

    private static var credentialsURL: URL {
        credentialsFileURL
    }

    /// Indicates whether credential operations are redirected away from production storage.
    static var isUsingTestStorage: Bool {
        testingStorageConfiguration != nil || runningUnderXCTest
    }

    /// Redirects credential reads and writes to an isolated namespace for tests.
    ///
    /// Args:
    ///   directory: Temporary directory that should contain the test credentials file.
    ///   namespace: Unique keychain service prefix reserved for the current test.
    static func useIsolatedStorageForTesting(directory: URL, namespace: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedCredentials = nil
        #if DEBUG
        failNextCredentialsFileSaveForTesting = false
        secureReadErrorsForTesting = [:]
        failNextSecureSaveAccountForTesting = nil
        failNextSecureDeleteAccountForTesting = nil
        #endif
        testingStorageConfiguration = StorageConfiguration(
            scalarService: "\(namespace).scalar",
            groupedService: "\(namespace).grouped",
            legacyScalarService: "\(namespace).legacy.scalar",
            legacyGroupedService: "\(namespace).legacy.grouped",
            credentialsURL: directory.appendingPathComponent("credentials.json"),
            usesKeychain: false
        )
    }

    /// Restores production credential storage after an isolated test finishes.
    static func resetStorageAfterTesting() {
        lock.lock()
        defer { lock.unlock() }
        cachedCredentials = nil
        #if DEBUG
        failNextCredentialsFileSaveForTesting = false
        secureReadErrorsForTesting = [:]
        failNextSecureSaveAccountForTesting = nil
        failNextSecureDeleteAccountForTesting = nil
        #endif
        testingStorageConfiguration = nil
    }

    // MARK: - Core read/write (now supports nested objects)

    /// Load without acquiring lock — caller must hold `lock`.
    private static func _loadAllUnlocked() -> [String: Any] {
        if let cached = cachedCredentials { return cached }
        guard let data = try? Data(contentsOf: credentialsFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        cachedCredentials = dict
        return dict
    }

    /// Thread-safe load.
    private static func loadAll() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return _loadAllUnlocked()
    }

    #if DEBUG
    /// Test seam: makes the next credentials-file write fail.
    nonisolated(unsafe) static var failNextCredentialsFileSaveForTesting = false
    /// Isolated credential tests can model a locked or unavailable item without using Security.
    nonisolated(unsafe) static var secureReadErrorsForTesting: [String: KeychainReadError] = [:]
    nonisolated(unsafe) static var failNextSecureSaveAccountForTesting: String?
    nonisolated(unsafe) static var failNextSecureDeleteAccountForTesting: String?
    #endif

    private static func saveAll(_ dict: [String: Any]) throws {
        #if DEBUG
        if isUsingTestStorage && failNextCredentialsFileSaveForTesting {
            failNextCredentialsFileSaveForTesting = false
            throw CocoaError(.fileWriteUnknown)
        }
        #endif
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: credentialsFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsFileURL.path
        )
    }

    // MARK: - Scalar key-value (for LLM keys and misc)

    static func save(key: String, value: String) throws {
        try saveSecureString(value, service: keychainScalarService, account: key)
    }

    /// Loads a scalar secret from the current keychain service.
    ///
    /// Args:
    ///   key: Secret account name.
    ///
    /// Returns:
    ///   The secret value, falling back to the legacy Type4Me keychain service when needed.
    static func load(key: String) -> String? {
        if let value = loadSecureString(service: keychainScalarService, account: key) {
            return value
        }
        guard let legacy = loadSecureString(service: legacyKeychainScalarService, account: key) else {
            return nil
        }
        try? saveSecureString(legacy, service: keychainScalarService, account: key)
        return legacy
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        deleteSecureValue(service: keychainScalarService, account: key)
    }

    // MARK: - Selected ASR Provider (UserDefaults)

    private static let selectedProviderKey = "tf_selectedASRProvider"

    static var selectedASRProvider: ASRProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: selectedProviderKey)
            // Retain provider identity for display. Starting recognition must validate migration
            // separately so this compatibility alias can never imply a switch to streaming.
            if raw == legacyStepFunBatchRawValue { return .stepfun }
            guard let raw, let provider = ASRProvider(rawValue: raw) else { return .volcano }
            return provider
        }
        set {
            let previous = selectedASRProvider
            let hadPendingMigration = UserDefaults.standard.string(forKey: selectedProviderKey) == legacyStepFunBatchRawValue
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
            guard previous != newValue || hadPendingMigration else { return }
            NotificationCenter.default.post(name: .asrProviderDidChange, object: newValue)
            NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
        }
    }

    /// Resolves the user's provider selection without falling back after a failed migration.
    ///
    /// Returns:
    ///   The provider whose configuration may be used to start recognition.
    ///
    /// Throws:
    ///   ASRProviderSelectionError when the selected legacy batch setup is not yet committed.
    static func validatedSelectedASRProvider() throws -> ASRProvider {
        guard UserDefaults.standard.string(forKey: selectedProviderKey) != legacyStepFunBatchRawValue else {
            throw ASRProviderSelectionError.pendingStepFunBatchMigration
        }
        return selectedASRProvider
    }

    #if HAS_CLOUD_SUBSCRIPTION
    // MARK: - Last BYOK Provider (for edition switching)

    private static let lastBYOKProviderKey = "tf_lastBYOKProvider"

    static var lastBYOKProvider: ASRProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: lastBYOKProviderKey),
                  let provider = ASRProvider(rawValue: raw)
            else { return .volcano }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: lastBYOKProviderKey)
        }
    }
    #endif

    // MARK: - ASR Credentials (provider-aware)

    private static func asrStorageKey(for provider: ASRProvider) -> String {
        "tf_asr_\(provider.rawValue)"
    }

    static func saveASRCredentials(for provider: ASRProvider, values: [String: String]) throws {
        lock.lock()
        do {
            var dict = _loadAllUnlocked()
            let storageKey = asrStorageKey(for: provider)
            let split = splitCredentials(values, using: ASRProviderRegistry.configType(for: provider)?.credentialFields ?? [])
            if split.secure.isEmpty {
                try deleteSecureValueCheckingKeychain(service: keychainGroupedService, account: storageKey)
            } else {
                try saveSecureValues(split.secure, account: storageKey)
            }
            if split.plaintext.isEmpty {
                dict.removeValue(forKey: storageKey)
            } else {
                dict[storageKey] = split.plaintext
            }
            try saveAll(dict)
            cachedCredentials = dict
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
    }

    static func loadASRCredentials(for provider: ASRProvider) -> [String: String]? {
        do {
            return try loadASRCredentialsCheckingKeychain(for: provider)
        } catch {
            NSLog(
                "[KeychainService] Failed to load ASR credentials provider=%@: %@",
                provider.rawValue,
                String(describing: error)
            )
            return nil
        }
    }

    /// Loads ASR credentials while preserving keychain read failures.
    ///
    /// Args:
    ///   provider: ASR provider whose credential group should be loaded.
    ///
    /// Returns:
    ///   Merged plaintext and secure credentials, or `nil` when no credentials exist.
    ///
    /// Throws:
    ///   `KeychainReadError` when the secure credential item cannot be read.
    static func loadASRCredentialsCheckingKeychain(
        for provider: ASRProvider
    ) throws -> [String: String]? {
        let dict = loadAll()
        let storageKey = asrStorageKey(for: provider)
        let plaintext = stringDictionary(dict[storageKey])
        let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let secure = fields.contains(where: \.isSecure)
            ? try loadSecureValuesCheckingKeychain(account: storageKey)
            : [:]
        let merged = plaintext.merging(secure) { _, secure in secure }
        let legacy = provider == .volcano ? legacyVolcanoASRCredentials(in: dict) : [:]
        let compatible = compatibleASRCredentials(for: provider, stored: merged, legacy: legacy)
        return compatible.isEmpty ? nil : compatible
    }

    /// Reads one non-secure value from the cached credentials file without touching the Keychain.
    /// Safe to call while rendering lists.
    static func loadASRPlaintextValue(for provider: ASRProvider, key: String) -> String? {
        let value = stringDictionary(loadAll()[asrStorageKey(for: provider)])[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func loadASRConfig(for provider: ASRProvider) -> (any ASRProviderConfig)? {
        do {
            return try loadASRConfigCheckingKeychain(for: provider)
        } catch {
            NSLog(
                "[KeychainService] Failed to load ASR config provider=%@: %@",
                provider.rawValue,
                String(describing: error)
            )
            return nil
        }
    }

    /// Loads an ASR configuration without collapsing keychain failures into missing credentials.
    ///
    /// Args:
    ///   provider: ASR provider whose configuration should be created.
    ///
    /// Returns:
    ///   A provider configuration, or `nil` when required credentials are genuinely absent.
    ///
    /// Throws:
    ///   `KeychainReadError` when secure credentials exist but are not currently readable,
    ///   or `ASRProviderSelectionError` while the selected legacy provider is unresolved.
    static func loadASRConfigCheckingKeychain(
        for provider: ASRProvider
    ) throws -> (any ASRProviderConfig)? {
        if provider == .stepfun {
            // Covers callers that load the selected config through the non-throwing wrapper.
            _ = try validatedSelectedASRProvider()
        }
        guard let configType = ASRProviderRegistry.configType(for: provider) else {
            return nil
        }

        if let values = try loadASRCredentialsCheckingKeychain(for: provider) {
            return configType.init(credentials: values)
        }

        // Fallback: build config from default field values (e.g. Apple ASR needs no API key)
        let defaultValues: [String: String] = Dictionary(
            uniqueKeysWithValues: configType.credentialFields.compactMap { field in
                guard !field.defaultValue.isEmpty else { return nil }
                return (field.key, field.defaultValue)
            }
        )

        if defaultValues.isEmpty && configType.credentialFields.isEmpty {
            return configType.init(credentials: [:])
        }

        return configType.init(credentials: defaultValues)
    }

    /// Load config for the currently selected provider.
    static func loadSelectedASRConfig() -> (any ASRProviderConfig)? {
        loadASRConfig(for: selectedASRProvider)
    }

    // MARK: - Legacy ASR convenience (volcano-specific, kept for migration)

    static func loadASRConfig() -> VolcanoASRConfig? {
        loadASRConfig(for: .volcano) as? VolcanoASRConfig
    }

    // MARK: - Selected LLM Provider (UserDefaults)

    private static let selectedLLMProviderKey = "tf_selectedLLMProvider"

    static var selectedLLMProvider: LLMProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedLLMProviderKey),
                  let provider = LLMProvider(rawValue: raw)
            else { return .doubao }
            return provider
        }
        set {
            let previous = selectedLLMProvider
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedLLMProviderKey)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
        }
    }

    // MARK: - LLM Credentials (provider-aware)

    private static func llmStorageKey(for provider: LLMProvider) -> String {
        "tf_llm_\(provider.rawValue)"
    }

    static func saveLLMCredentials(for provider: LLMProvider, values: [String: String]) throws {
        lock.lock()
        do {
            var dict = _loadAllUnlocked()
            let storageKey = llmStorageKey(for: provider)
            let split = splitCredentials(values, using: LLMProviderRegistry.configType(for: provider)?.credentialFields ?? [])
            if split.secure.isEmpty {
                try deleteSecureValueCheckingKeychain(service: keychainGroupedService, account: storageKey)
            } else {
                try saveSecureValues(split.secure, account: storageKey)
            }
            if split.plaintext.isEmpty {
                dict.removeValue(forKey: storageKey)
            } else {
                dict[storageKey] = split.plaintext
            }
            try saveAll(dict)
            cachedCredentials = dict
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
    }

    static func loadLLMCredentials(for provider: LLMProvider) -> [String: String]? {
        do {
            return try loadLLMCredentialsCheckingKeychain(for: provider)
        } catch {
            NSLog(
                "[KeychainService] Failed to load LLM credentials provider=%@: %@",
                provider.rawValue,
                String(describing: error)
            )
            return nil
        }
    }

    /// Loads LLM credentials while preserving keychain read failures.
    ///
    /// Args:
    ///   provider: LLM provider whose credential group should be loaded.
    ///
    /// Returns:
    ///   Merged plaintext and secure credentials, or `nil` when no credentials exist.
    ///
    /// Throws:
    ///   `KeychainReadError` when the secure credential item cannot be read.
    static func loadLLMCredentialsCheckingKeychain(
        for provider: LLMProvider
    ) throws -> [String: String]? {
        let dict = loadAll()
        let storageKey = llmStorageKey(for: provider)
        let plaintext = stringDictionary(dict[storageKey])
        let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let secure = fields.contains(where: \.isSecure)
            ? try loadSecureValuesCheckingKeychain(account: storageKey)
            : [:]
        let merged = plaintext.merging(secure) { _, secure in secure }
        let legacy = provider == .doubao ? legacyDoubaoLLMCredentials(in: dict) : [:]
        let compatible = compatibleLLMCredentials(for: provider, stored: merged, legacy: legacy)
        return compatible.isEmpty ? nil : compatible
    }

    static func loadLLMProviderConfig(for provider: LLMProvider) -> (any LLMProviderConfig)? {
        guard let configType = LLMProviderRegistry.configType(for: provider) else { return nil }
        if let values = loadLLMCredentials(for: provider) {
            return configType.init(credentials: values)
        }
        if provider == .codexCLI {
            return configType.init(credentials: ["model": "gpt-5.6-luna"])
        }
        return nil
    }

    /// Load config for the currently selected LLM provider.
    static func loadSelectedLLMConfig() -> (any LLMProviderConfig)? {
        loadLLMProviderConfig(for: selectedLLMProvider)
    }

    // MARK: - LLM Config convenience (backward compat)

    static func saveLLMCredentials(apiKey: String, model: String, baseURL: String = "") throws {
        try saveLLMCredentials(for: .doubao, values: [
            "apiKey": apiKey, "model": model, "baseURL": baseURL,
        ])
    }

    /// Load LLMConfig for the currently selected provider.
    static func loadLLMConfig() -> LLMConfig? {
        guard let config = loadSelectedLLMConfig() else { return nil }
        return config.toLLMConfig()
    }

    // MARK: - ASR Usage Tracking (local)

    private static let asrUsageKey = "tf_asrUsageSeconds"

    /// Total ASR usage in seconds (local estimate).
    static var asrUsageSeconds: Double {
        get { UserDefaults.standard.double(forKey: asrUsageKey) }
        set { UserDefaults.standard.set(newValue, forKey: asrUsageKey) }
    }

    /// Add seconds from a completed ASR session.
    static func addASRUsage(seconds: Double) {
        asrUsageSeconds += seconds
    }

    // MARK: - Migration (call once at app launch)

    /// Migrate legacy flat keys to provider-grouped format,
    /// move Application Support directory, and migrate UserDefaults from old bundle ID.
    static func migrateIfNeeded() {
        migrateSettingsIfNeeded()
        migrateStoredCredentials()
    }

    /// Migrates non-Keychain state needed before `AppState` is constructed.
    ///
    /// This method intentionally excludes credential reads so startup can restore
    /// legacy modes and selections before creating UI state without prompting for
    /// Keychain access earlier than the normal launch lifecycle.
    static func migrateSettingsIfNeeded() {
        migrateAppSupportDirectory()
        migrateUserDefaults()
    }

    static func migrateStoredCredentials() {
        lock.lock()
        defer { lock.unlock() }
        let dict = _loadAllUnlocked()

        var migrated = false
        var mutableDict = dict
        var legacyExternalKeysToClean = Set<String>()

        // Migrate ASR: tf_appKey/tf_accessKey/tf_resourceId → tf_asr_volcano
        let legacyASRKeys = ["tf_appKey", "tf_accessKey", "tf_resourceId"]
        let legacyASR = legacyVolcanoASRCredentials(in: dict)
        if !legacyASR.isEmpty {
            let storageKey = asrStorageKey(for: .volcano)
            let current = stringDictionary(mutableDict[storageKey])
            let repaired = compatibleASRCredentials(for: .volcano, stored: current, legacy: legacyASR)
            if repaired != current {
                mutableDict[storageKey] = repaired
                migrated = true
                NSLog("[KeychainService] Migrated legacy ASR credentials to tf_asr_volcano")
            }
            migrated = removeLegacyFileKeys(legacyASRKeys, from: &mutableDict) || migrated
            legacyExternalKeysToClean.formUnion(legacyASRKeys)
        }

        // Migrate mistakenly stored Bailian ASR credentials from tf_asr_aliyun → tf_asr_bailian
        if let aliyunValues = dict[asrStorageKey(for: .aliyun)] as? [String: String],
           let apiKey = aliyunValues["apiKey"], !apiKey.isEmpty,
           dict[asrStorageKey(for: .bailian)] == nil {
            mutableDict[asrStorageKey(for: .bailian)] = aliyunValues
            mutableDict.removeValue(forKey: asrStorageKey(for: .aliyun))
            if selectedASRProvider == .aliyun {
                selectedASRProvider = .bailian
            }
            migrated = true
            NSLog("[KeychainService] Migrated Bailian ASR credentials from tf_asr_aliyun → tf_asr_bailian")
        }

        let finishStepFunMigration = migrateStepFunBatchProvider(in: &mutableDict)
        migrated = finishStepFunMigration != nil || migrated

        // Migrate LLM: tf_llmApiKey/tf_llmModel/tf_llmEndpointId/tf_llmBaseURL → tf_llm_doubao
        let legacyLLMKeys = ["tf_llmApiKey", "tf_llmModel", "tf_llmEndpointId", "tf_llmBaseURL"]
        let legacyLLM = legacyDoubaoLLMCredentials(in: dict)
        if !legacyLLM.isEmpty {
            let storageKey = llmStorageKey(for: .doubao)
            let current = stringDictionary(mutableDict[storageKey])
            let repaired = compatibleLLMCredentials(for: .doubao, stored: current, legacy: legacyLLM)
            if repaired != current {
                mutableDict[storageKey] = repaired
                migrated = true
                NSLog("[KeychainService] Migrated flat LLM keys to tf_llm_doubao")
            }
            migrated = removeLegacyFileKeys(legacyLLMKeys, from: &mutableDict) || migrated
            legacyExternalKeysToClean.formUnion(legacyLLMKeys)
        }

        // Migrate MiniMax CN: api.minimax.chat → api.minimaxi.com (old domain was incorrect)
        let minimaxCNKey = llmStorageKey(for: .minimaxCN)
        if var minimaxCreds = mutableDict[minimaxCNKey] as? [String: String],
           let baseURL = minimaxCreds["baseURL"],
           baseURL.contains("api.minimax.chat") {
            minimaxCreds["baseURL"] = baseURL.replacingOccurrences(
                of: "api.minimax.chat", with: "api.minimaxi.com"
            )
            mutableDict[minimaxCNKey] = minimaxCreds
            migrated = true
            NSLog("[KeychainService] Migrated MiniMax CN base URL: api.minimax.chat → api.minimaxi.com")
        }

        let defaultsRepaired = repairCredentialDefaults(in: &mutableDict)
        let secureFieldsMigrated = migrateSecureCredentialGroups(in: &mutableDict)

        if migrated || defaultsRepaired || secureFieldsMigrated {
            do {
                try saveAll(mutableDict)
                cachedCredentials = mutableDict
                cleanLegacyExternalCredentialSources(legacyExternalKeysToClean)
                finishStepFunMigration?()
            } catch {
                NSLog("[KeychainService] Failed to persist credential migration: %@", error.localizedDescription)
            }
        } else {
            cleanLegacyExternalCredentialSources(legacyExternalKeysToClean)
        }
    }

    /// StepFun used to be two providers (`stepfun` realtime, `stepfunBatch` batch). Fold the batch
    /// credentials into `stepfun` as its batch recognition mode. A Step Plan key moves to
    /// `stepPlanApiKey` so it never overwrites the standard realtime key.
    static let legacyStepFunBatchRawValue = "stepfunBatch"
    /// Backup for the standard key not chosen when realtime and batch used different keys.
    /// Nothing reads it automatically; it only prevents silently deleting a credential.
    static let stepFunUnusedStandardKeyAccount = "tf_asr_stepfun_unusedStandardKey"

    private static let stepFunBatchMigrationCompletedKey = "tf_stepFunBatchMigrationCompleted"

    /// Prepares a retryable migration while preserving the active recognition mode and keys.
    ///
    /// Args:
    ///   dict: Working copy of plaintext credentials, saved by the caller after secure writes.
    ///
    /// Returns:
    ///   A cleanup action to run after the file commit, or nil if no work can be committed.
    private static func migrateStepFunBatchProvider(in dict: inout [String: Any]) -> (() -> Void)? {
        let legacyStorageKey = "tf_asr_\(legacyStepFunBatchRawValue)"
        let defaults = UserDefaults.standard
        let selectedRawValue = defaults.string(forKey: selectedProviderKey)
        let wasSelected = selectedRawValue == legacyStepFunBatchRawValue
        let wasLastBYOK = defaults.string(forKey: "tf_lastBYOKProvider") == legacyStepFunBatchRawValue
        let legacyPlaintext = stringDictionary(dict[legacyStorageKey])
        let legacySecure: [String: String]
        do {
            legacySecure = try loadSecureValuesCheckingKeychain(account: legacyStorageKey)
        } catch {
            NSLog("[KeychainService] StepFun batch migration deferred; source credential read failed: %@", error.localizedDescription)
            return nil
        }

        // Notifications while the migration lock is held could re-enter KeychainService.
        let finishMigration = {
            if wasSelected { defaults.set(ASRProvider.stepfun.rawValue, forKey: selectedProviderKey) }
            if wasLastBYOK { defaults.set(ASRProvider.stepfun.rawValue, forKey: "tf_lastBYOKProvider") }
            _ = deleteSecureValue(service: keychainGroupedService, account: legacyStorageKey)
        }
        // A committed migration can still have a legacy item if deletion was denied. Retry only
        // cleanup: re-merging could overwrite a recognition-mode choice made since the commit.
        if dict[stepFunBatchMigrationCompletedKey] as? Bool == true {
            guard !legacyPlaintext.isEmpty || !legacySecure.isEmpty || wasSelected || wasLastBYOK else { return nil }
            dict.removeValue(forKey: legacyStorageKey)
            return finishMigration
        }
        guard !legacyPlaintext.isEmpty || !legacySecure.isEmpty || wasSelected || wasLastBYOK else { return nil }

        let storageKey = asrStorageKey(for: .stepfun)
        var plaintext = stringDictionary(dict[storageKey])
        var secure: [String: String]
        do {
            secure = try loadSecureValuesCheckingKeychain(account: storageKey)
        } catch {
            NSLog("[KeychainService] StepFun batch migration deferred; destination credential read failed: %@", error.localizedDescription)
            return nil
        }
        let existingAPIKey = secure["apiKey"] ?? plaintext["apiKey"] ?? ""
        let legacyAPIKey = (legacySecure["apiKey"] ?? legacyPlaintext["apiKey"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accessMode = legacyPlaintext["accessMode"].flatMap(StepFunBatchAccessMode.init(rawValue:)) ?? .stepPlan
        for key in ["apiKey", "stepPlanApiKey"] {
            if (secure[key] ?? "").isEmpty, let plainKey = plaintext[key], !plainKey.isEmpty {
                secure[key] = plainKey
            }
            plaintext.removeValue(forKey: key)
        }
        var unusedStandardKey: String?
        if !legacyAPIKey.isEmpty {
            switch accessMode {
            case .stepPlan:
                if (secure["stepPlanApiKey"] ?? "").isEmpty { secure["stepPlanApiKey"] = legacyAPIKey }
            case .standard:
                if existingAPIKey.isEmpty {
                    secure["apiKey"] = legacyAPIKey
                } else if existingAPIKey != legacyAPIKey {
                    unusedStandardKey = wasSelected ? existingAPIKey : legacyAPIKey
                    if wasSelected { secure["apiKey"] = legacyAPIKey }
                }
            }
        }
        plaintext["accessMode"] = accessMode.rawValue
        let hasRealtimeSelection = selectedRawValue == ASRProvider.stepfun.rawValue
        let hasModePreference = plaintext[ASRRecognitionMode.credentialKey] != nil
        if wasSelected || (!hasRealtimeSelection && !hasModePreference && existingAPIKey.isEmpty) {
            plaintext[ASRRecognitionMode.credentialKey] = ASRRecognitionMode.batch.rawValue
        }

        do {
            if let unusedStandardKey {
                try saveSecureValues(["apiKey": unusedStandardKey], account: stepFunUnusedStandardKeyAccount)
            }
            if !secure.isEmpty { try saveSecureValues(secure, account: storageKey) }
        } catch {
            NSLog("[KeychainService] StepFun batch migration deferred; Keychain write failed: %@", error.localizedDescription)
            return nil
        }
        dict[storageKey] = plaintext
        dict.removeValue(forKey: legacyStorageKey)
        dict[stepFunBatchMigrationCompletedKey] = true
        return finishMigration
    }

    #if DEBUG
    /// Test seam: stores credentials under a storage key that no longer maps to an `ASRProvider`.
    static func seedLegacyASRCredentialsForTesting(
        storageKey: String,
        plaintext: [String: String],
        secure: [String: String]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = _loadAllUnlocked()
        if plaintext.isEmpty {
            dict.removeValue(forKey: storageKey)
        } else {
            dict[storageKey] = plaintext
        }
        if secure.isEmpty {
            _ = deleteSecureValue(service: keychainGroupedService, account: storageKey)
        } else {
            try saveSecureValues(secure, account: storageKey)
        }
        try saveAll(dict)
        cachedCredentials = dict
    }

    /// Seeds only the isolated legacy namespace to verify MyType's Type4Me fallback.
    ///
    /// Args:
    ///   account: Credential group name.
    ///   values: Synthetic secure values for the test.
    ///
    /// Throws:
    ///   A storage error if isolated storage is not active or the fixture cannot be saved.
    static func seedLegacyGroupedValuesForTesting(account: String, values: [String: String]) throws {
        guard isUsingTestStorage else { throw KeychainError.saveFailed(errSecNotAvailable) }
        let data = try JSONSerialization.data(withJSONObject: values)
        try saveSecureData(data, service: legacyKeychainGroupedService, account: account)
    }

    static func loadSecureValuesForTesting(account: String) -> [String: String] {
        loadSecureValues(account: account)
    }

    static func deleteSecureValuesForTesting(account: String) {
        _ = deleteSecureValue(service: keychainGroupedService, account: account)
    }

    static func hasStoredCredentialsForTesting(storageKey: String) -> Bool {
        loadAll()[storageKey] != nil || !loadSecureValues(account: storageKey).isEmpty
    }
    #endif

    private static func removeLegacyFileKeys(_ keys: [String], from dict: inout [String: Any]) -> Bool {
        var changed = false
        for key in keys {
            if dict.removeValue(forKey: key) != nil {
                changed = true
            }
        }
        return changed
    }

    private static func cleanLegacyExternalCredentialSources(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            _ = deleteSecureValue(service: keychainScalarService, account: key)
        }
    }

    // MARK: - Keychain helpers

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func saveSecureString(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidEncoding
        }
        try saveSecureData(data, service: service, account: account)
    }

    private static func loadSecureString(service: String, account: String) -> String? {
        guard let data = loadSecureData(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveSecureValues(_ values: [String: String], account: String) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try saveSecureData(data, service: keychainGroupedService, account: account)
    }

    /// Loads grouped secure values from the current keychain service.
    ///
    /// Args:
    ///   account: Grouped credential account name.
    ///
    /// Returns:
    ///   Secure values, copied from the legacy Type4Me keychain service when the new service is empty.
    private static func loadSecureValues(account: String) -> [String: String] {
        do {
            return try loadSecureValuesCheckingKeychain(account: account)
        } catch {
            NSLog(
                "[KeychainService] Failed to load grouped credentials account=%@: %@",
                account,
                String(describing: error)
            )
            return [:]
        }
    }

    /// Loads grouped secure values while retaining keychain availability errors.
    ///
    /// Args:
    ///   account: Grouped credential account name.
    ///
    /// Returns:
    ///   Secure values, including a migrated legacy value when available.
    ///
    /// Throws:
    ///   `KeychainReadError` when the keychain is locked, unavailable, or contains invalid data.
    private static func loadSecureValuesCheckingKeychain(
        account: String
    ) throws -> [String: String] {
        if let data = try loadSecureDataCheckingKeychain(
            service: keychainGroupedService,
            account: account
        ) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw KeychainReadError.invalidData
            }
            return object
        }
        guard let legacyData = try loadSecureDataCheckingKeychain(
            service: legacyKeychainGroupedService,
            account: account
        ) else {
            return [:]
        }
        guard let legacyObject = try? JSONSerialization.jsonObject(with: legacyData) as? [String: String] else {
            throw KeychainReadError.invalidData
        }
        try? saveSecureData(legacyData, service: keychainGroupedService, account: account)
        return legacyObject
    }

    private static func saveSecureData(_ data: Data, service: String, account: String) throws {
        #if DEBUG
        if isUsingTestStorage && failNextSecureSaveAccountForTesting == account {
            failNextSecureSaveAccountForTesting = nil
            throw KeychainError.saveFailed(errSecNotAvailable)
        }
        #endif
        guard activeStorageConfiguration.usesKeychain else {
            try saveTestingSecureData(data, service: service, account: account)
            return
        }
        let query = keychainQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        default:
            throw KeychainError.saveFailed(status)
        }
    }

    private static func loadSecureData(service: String, account: String) -> Data? {
        do {
            return try loadSecureDataCheckingKeychain(service: service, account: account)
        } catch {
            NSLog(
                "[KeychainService] Failed to load secure item service=%@ account=%@: %@",
                service,
                account,
                String(describing: error)
            )
            return nil
        }
    }

    /// Loads one secure item from the login keychain.
    ///
    /// Args:
    ///   service: Keychain service name.
    ///   account: Keychain account name.
    ///
    /// Returns:
    ///   Secret data, or `nil` when the item does not exist.
    ///
    /// Throws:
    ///   `KeychainReadError` when the item cannot be read or decoded.
    private static func loadSecureDataCheckingKeychain(
        service: String,
        account: String
    ) throws -> Data? {
        #if DEBUG
        if isUsingTestStorage, let error = secureReadErrorsForTesting[account] { throw error }
        #endif
        guard activeStorageConfiguration.usesKeychain else {
            return loadTestingSecureData(service: service, account: account)
        }
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainReadError.invalidData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            NSLog(
                "[KeychainService] Keychain read status service=%@ account=%@ status=%d",
                service,
                account,
                status
            )
            throw KeychainReadError(status: status)
        }
    }

    /// Deletes one keychain value and its matching legacy fallback.
    ///
    /// Args:
    ///   service: Keychain service name.
    ///   account: Keychain account name.
    ///
    /// Returns:
    ///   `true` when the current-service deletion succeeds or the item is already absent.
    @discardableResult
    private static func deleteSecureValue(service: String, account: String) -> Bool {
        do {
            try deleteSecureValueCheckingKeychain(service: service, account: account)
            return true
        } catch {
            NSLog(
                "[KeychainService] Failed to delete secure item service=%@ account=%@: %@",
                service,
                account,
                String(describing: error)
            )
            return false
        }
    }

    /// Deletes one secure item and fails when the keychain rejects the operation.
    ///
    /// Args:
    ///   service: Keychain service name.
    ///   account: Keychain account name.
    ///
    /// Throws:
    ///   `KeychainError.deleteFailed` when either current or legacy deletion fails.
    private static func deleteSecureValueCheckingKeychain(
        service: String,
        account: String
    ) throws {
        #if DEBUG
        if isUsingTestStorage && failNextSecureDeleteAccountForTesting == account {
            failNextSecureDeleteAccountForTesting = nil
            throw KeychainError.deleteFailed(errSecNotAvailable)
        }
        #endif
        try deleteSecureItem(service: service, account: account)

        let legacyService: String?
        if service == keychainScalarService {
            legacyService = legacyKeychainScalarService
        } else if service == keychainGroupedService {
            legacyService = legacyKeychainGroupedService
        } else {
            legacyService = nil
        }
        if let legacyService {
            try deleteSecureItem(service: legacyService, account: account)
        }
    }

    /// Deletes one storage item using the same fallback sequence in production and tests.
    ///
    /// Args:
    ///   service: Current or legacy service name.
    ///   account: Credential item name.
    ///
    /// Throws:
    ///   A deletion error when the backing store rejects the operation.
    private static func deleteSecureItem(service: String, account: String) throws {
        guard activeStorageConfiguration.usesKeychain else {
            let url = testingSecureDataURL(service: service, account: account)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let status = SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Saves test-only secret bytes without touching the user's login keychain.
    ///
    /// Args:
    ///   data: Secret bytes to store in the isolated test file.
    ///   service: Test service name.
    ///   account: Test account name.
    private static func saveTestingSecureData(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let directory = credentialsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: testingSecureDataURL(service: service, account: account), options: .atomic)
    }

    /// Loads test-only secret bytes from the isolated test file.
    ///
    /// Args:
    ///   service: Test service name.
    ///   account: Test account name.
    ///
    /// Returns:
    ///   Stored secret bytes, or `nil` when no test item exists.
    private static func loadTestingSecureData(service: String, account: String) -> Data? {
        try? Data(contentsOf: testingSecureDataURL(service: service, account: account))
    }

    /// Resolves the file URL for a test-only secret item.
    ///
    /// Args:
    ///   service: Test service name.
    ///   account: Test account name.
    ///
    /// Returns:
    ///   URL inside the current isolated test directory.
    private static func testingSecureDataURL(service: String, account: String) -> URL {
        let identifier = Data("\(service)|\(account)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return credentialsURL.deletingLastPathComponent()
            .appendingPathComponent("secret-\(identifier)")
    }

    // MARK: - Secure field splitting

    private static func splitCredentials(
        _ values: [String: String],
        using fields: [CredentialField]
    ) -> (plaintext: [String: String], secure: [String: String]) {
        let secureKeys = Set(fields.filter(\.isSecure).map(\.key))
        guard !secureKeys.isEmpty else {
            return (values, [:])
        }

        var plaintext: [String: String] = [:]
        var secure: [String: String] = [:]

        for (key, value) in values {
            if secureKeys.contains(key) {
                if !value.isEmpty {
                    secure[key] = value
                }
            } else if !value.isEmpty {
                plaintext[key] = value
            }
        }
        return (plaintext, secure)
    }

    static func compatibleASRCredentials(
        for provider: ASRProvider,
        stored: [String: String],
        legacy: [String: String] = [:]
    ) -> [String: String] {
        let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
        var values = compatibleCredentialValues(
            stored: stored,
            legacy: legacy,
            fields: fields
        )
        if provider == .volcano, !values.isEmpty {
            if let explicitMode = stored["authMode"] ?? legacy["authMode"],
               explicitMode == VolcanoASRConfig.authModeAPIKey
                || explicitMode == VolcanoASRConfig.authModeLegacy {
                values["authMode"] = explicitMode
            } else {
                values.removeValue(forKey: "authMode")
                values["authMode"] = VolcanoASRConfig.inferredAuthMode(in: values)
            }
        }
        return values
    }

    static func compatibleLLMCredentials(
        for provider: LLMProvider,
        stored: [String: String],
        legacy: [String: String] = [:]
    ) -> [String: String] {
        let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
        return compatibleCredentialValues(stored: stored, legacy: legacy, fields: fields)
    }

    private static func compatibleCredentialValues(
        stored: [String: String],
        legacy: [String: String],
        fields: [CredentialField]
    ) -> [String: String] {
        var result: [String: String] = [:]
        mergeNonEmpty(legacy, into: &result)
        mergeNonEmpty(stored, into: &result)

        guard !result.isEmpty else { return [:] }
        for field in fields where !field.defaultValue.isEmpty {
            if result[field.key]?.isEmpty != false {
                result[field.key] = field.defaultValue
            }
        }
        return result
    }

    private static func mergeNonEmpty(_ values: [String: String], into result: inout [String: String]) {
        for (key, value) in values where !value.isEmpty {
            result[key] = value
        }
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else {
            return value as? [String: String] ?? [:]
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            }
        }
        return result
    }

    private static func legacyVolcanoASRCredentials(in dict: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        setLegacyValue("tf_appKey", as: "appKey", in: dict, values: &values)
        setLegacyValue("tf_accessKey", as: "accessKey", in: dict, values: &values)
        setLegacyValue("tf_resourceId", as: "resourceId", in: dict, values: &values)
        return values
    }

    private static func legacyDoubaoLLMCredentials(in dict: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        setLegacyValue("tf_llmApiKey", as: "apiKey", in: dict, values: &values)
        if let model = legacyString("tf_llmModel", in: dict)
            ?? legacyString("tf_llmEndpointId", in: dict) {
            values["model"] = model
        }
        setLegacyValue("tf_llmBaseURL", as: "baseURL", in: dict, values: &values)
        return values
    }

    private static func setLegacyValue(
        _ legacyKey: String,
        as targetKey: String,
        in dict: [String: Any],
        values: inout [String: String]
    ) {
        if let value = legacyString(legacyKey, in: dict) {
            values[targetKey] = value
        }
    }

    private static func legacyString(_ key: String, in dict: [String: Any]) -> String? {
        let candidates = [
            dict[key] as? String,
            UserDefaults.standard.string(forKey: key),
            loadSecureString(service: keychainScalarService, account: key),
        ]
        return candidates.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    @discardableResult
    private static func repairCredentialDefaults(in dict: inout [String: Any]) -> Bool {
        var changed = false
        for provider in ASRProvider.allCases {
            let storageKey = asrStorageKey(for: provider)
            let current = stringDictionary(dict[storageKey])
            guard !current.isEmpty else { continue }
            let repaired = compatibleASRCredentials(for: provider, stored: current)
            if repaired != current {
                dict[storageKey] = repaired
                changed = true
            }
        }

        for provider in LLMProvider.allCases {
            let storageKey = llmStorageKey(for: provider)
            let current = stringDictionary(dict[storageKey])
            guard !current.isEmpty else { continue }
            let repaired = compatibleLLMCredentials(for: provider, stored: current)
            if repaired != current {
                dict[storageKey] = repaired
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    private static func migrateSecureCredentialGroups(in dict: inout [String: Any]) -> Bool {
        var changed = false
        for provider in ASRProvider.allCases {
            changed = migrateSecureFields(
                in: &dict,
                storageKey: asrStorageKey(for: provider),
                fields: ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            ) || changed
        }

        for provider in LLMProvider.allCases {
            changed = migrateSecureFields(
                in: &dict,
                storageKey: llmStorageKey(for: provider),
                fields: LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            ) || changed
        }
        return changed
    }

    /// Moves plaintext secrets only after the merged secure group has been persisted.
    ///
    /// Args:
    ///   dict: Pending credentials-file contents.
    ///   storageKey: Group whose secure fields should move to Keychain.
    ///   fields: Provider schema identifying secrets.
    ///
    /// Returns:
    ///   True when the plaintext group changed; false on no work or a retryable storage failure.
    @discardableResult
    private static func migrateSecureFields(
        in dict: inout [String: Any],
        storageKey: String,
        fields: [CredentialField]
    ) -> Bool {
        guard let values = dict[storageKey] as? [String: String] else { return false }
        let split = splitCredentials(values, using: fields)
        guard split.plaintext.count != values.count || !split.secure.isEmpty else { return false }
        if !split.secure.isEmpty {
            do {
                let existing = try loadSecureValuesCheckingKeychain(account: storageKey)
                let merged = split.secure.merging(existing) { _, current in current }
                try saveSecureValues(merged, account: storageKey)
            } catch {
                NSLog("[KeychainService] Secure field migration deferred account=%@: %@", storageKey, error.localizedDescription)
                return false
            }
        }
        if split.plaintext.isEmpty {
            dict.removeValue(forKey: storageKey)
        } else {
            dict[storageKey] = split.plaintext
        }
        return true
    }

    // MARK: - Application Support Directory Migration

    /// Merge legacy app support files into mytype.
    ///
    /// This preserves current files and leaves old directories in place for rollback builds.
    private static func migrateAppSupportDirectory() {
        AppIdentity.migrateLegacySupportDirectories()
        migrateTypeFlowSupportDirectory()
    }

    /// Merge ~/Library/Application Support/TypeFlow/ files into mytype/ (one-time, from old project name).
    /// Uses file-level merge instead of directory rename, because other init code may create
    /// the new directory before this migration runs.
    private static func migrateTypeFlowSupportDirectory() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDir = appSupport.appendingPathComponent("TypeFlow", isDirectory: true)
        let newDir = appSupport.appendingPathComponent(AppDataLocation.profileDirectoryName, isDirectory: true)

        // Old directory must exist and contain real data (credentials.json is the marker)
        guard fm.fileExists(atPath: oldDir.appendingPathComponent("credentials.json").path) else { return }

        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // Move each file from old → new, skipping files that already exist in new
        guard let contents = try? fm.contentsOfDirectory(atPath: oldDir.path) else { return }
        var movedCount = 0
        for item in contents {
            let src = oldDir.appendingPathComponent(item)
            let dst = newDir.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                    movedCount += 1
                } catch {
                    NSLog("[KeychainService] Failed to migrate %@: %@", item, error.localizedDescription)
                }
            }
        }

        if movedCount > 0 {
            NSLog("[KeychainService] Migrated %d files from TypeFlow → mytype", movedCount)
        }

        // Clean up old directory if empty
        if let remaining = try? fm.contentsOfDirectory(atPath: oldDir.path), remaining.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
    }

    // MARK: - UserDefaults Migration (old bundle ID)

    /// Copies `tf_` keys from legacy bundle identifiers into the current domain.
    private static func migrateUserDefaults() {
        migrateUserDefaults(from: "com.typeflow.app", marker: "tf_migratedFromTypeFlow")
        migrateUserDefaults(from: "com.type4me.app", marker: "tf_migratedFromType4Me")
    }

    /// Copies missing `tf_` keys from one legacy UserDefaults suite.
    ///
    /// Args:
    ///   suiteName: Legacy bundle identifier to read from.
    ///   marker: Current-domain marker used to avoid repeated migration.
    private static func migrateUserDefaults(from suiteName: String, marker: String) {
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        guard let oldDefaults = UserDefaults(suiteName: suiteName) else { return }
        let oldDict = oldDefaults.dictionaryRepresentation()
        let tfKeys = oldDict.keys.filter { $0.hasPrefix("tf_") }

        guard !tfKeys.isEmpty else {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }

        var count = 0
        for key in tfKeys {
            // Don't overwrite if the new domain already has a value
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(oldDict[key], forKey: key)
                count += 1
            }
        }

        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            NSLog("[KeychainService] Migrated %d UserDefaults keys from %@", count, suiteName)
        }
    }
}

enum ASRProviderSelectionError: Error, Equatable, LocalizedError {
    case pendingStepFunBatchMigration

    var errorDescription: String? {
        switch self {
        case .pendingStepFunBatchMigration:
            return L(
                "阶跃星辰旧版非实时配置尚未完成迁移，已暂停识别。请重新打开 MyType 重试，或在设置中重新选择识别服务。",
                "The legacy StepFun batch configuration has not finished migrating, so recognition is paused. Restart MyType to retry, or explicitly select a recognition provider in Settings."
            )
        }
    }
}

enum KeychainError: Error {
    case invalidEncoding
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}

enum KeychainReadError: Error, Equatable, LocalizedError {
    case locked(OSStatus)
    case unavailable(OSStatus)
    case invalidData

    /// Creates a diagnosable read error from a Security framework status code.
    ///
    /// Args:
    ///   status: Security framework status returned by `SecItemCopyMatching`.
    init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed,
             errSecInteractionRequired,
             errSecAuthFailed:
            self = .locked(status)
        default:
            self = .unavailable(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .locked:
            return L(
                "登录钥匙串当前不可用。请先解锁“登录”钥匙串，再重试。",
                "The login keychain is unavailable. Unlock it, then try again."
            )
        case .unavailable(let status):
            return L(
                "无法读取 API 凭证（钥匙串错误 \(status)）。请重新打开 MyType 后重试。",
                "Unable to read API credentials (Keychain error \(status)). Restart MyType and try again."
            )
        case .invalidData:
            return L(
                "钥匙串中的 API 凭证格式异常。请在设置中重新保存凭证。",
                "The API credentials in Keychain are invalid. Save them again in Settings."
            )
        }
    }
}
