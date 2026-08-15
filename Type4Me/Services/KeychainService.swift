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
    }

    private static let lock = NSLock()
    private static var cachedCredentials: [String: Any]?

    private static var testingStorageConfiguration: StorageConfiguration?

    private static var activeStorageConfiguration: StorageConfiguration {
        testingStorageConfiguration ?? .production
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

    private static var credentialsURL: URL {
        activeStorageConfiguration.credentialsURL
            ?? AppIdentity.appSupportDirectory().appendingPathComponent("credentials.json")
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
        testingStorageConfiguration = nil
    }

    // MARK: - Core read/write (now supports nested objects)

    /// Load without acquiring lock — caller must hold `lock`.
    private static func _loadAllUnlocked() -> [String: Any] {
        if let cached = cachedCredentials { return cached }
        guard let data = try? Data(contentsOf: credentialsURL),
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

    private static func saveAll(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsURL.path
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
            guard let raw = UserDefaults.standard.string(forKey: selectedProviderKey),
                  let provider = ASRProvider(rawValue: raw)
            else { return .volcano }
            return provider
        }
        set {
            let previous = selectedASRProvider
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .asrProviderDidChange, object: newValue)
        }
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
        defer { lock.unlock() }
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
        let plaintext = dict[storageKey] as? [String: String] ?? [:]
        let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let secure = fields.contains(where: \.isSecure)
            ? try loadSecureValuesCheckingKeychain(account: storageKey)
            : [:]
        let merged = plaintext.merging(secure) { _, secure in secure }
        return merged.isEmpty ? nil : merged
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
    ///   `KeychainReadError` when secure credentials exist but are not currently readable.
    static func loadASRConfigCheckingKeychain(
        for provider: ASRProvider
    ) throws -> (any ASRProviderConfig)? {
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

    static func saveASRCredentials(appKey: String, accessKey: String, resourceId: String) throws {
        try saveASRCredentials(for: .volcano, values: [
            "appKey": appKey,
            "accessKey": accessKey,
            "resourceId": resourceId,
        ])
    }

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
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedLLMProviderKey)
        }
    }

    // MARK: - LLM Credentials (provider-aware)

    private static func llmStorageKey(for provider: LLMProvider) -> String {
        "tf_llm_\(provider.rawValue)"
    }

    static func saveLLMCredentials(for provider: LLMProvider, values: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
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
        let plaintext = dict[storageKey] as? [String: String] ?? [:]
        let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
        let secure = fields.contains(where: \.isSecure)
            ? try loadSecureValuesCheckingKeychain(account: storageKey)
            : [:]
        let merged = plaintext.merging(secure) { _, secure in secure }
        return merged.isEmpty ? nil : merged
    }

    static func loadLLMProviderConfig(for provider: LLMProvider) -> (any LLMProviderConfig)? {
        guard let values = loadLLMCredentials(for: provider),
              let configType = LLMProviderRegistry.configType(for: provider)
        else { return nil }
        return configType.init(credentials: values)
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

    // MARK: - Migration (call once at app launch)

    /// Migrate legacy flat keys to provider-grouped format,
    /// move Application Support directory, and migrate UserDefaults from old bundle ID.
    static func migrateIfNeeded() {
        migrateAppSupportDirectory()
        migrateUserDefaults()
        lock.lock()
        defer { lock.unlock() }
        let dict = _loadAllUnlocked()

        var migrated = false
        var mutableDict = dict

        // Migrate ASR: tf_appKey/tf_accessKey/tf_resourceId → tf_asr_volcano
        if let appKey = dict["tf_appKey"] as? String, !appKey.isEmpty,
           dict[asrStorageKey(for: .volcano)] == nil {
            let accessKey = dict["tf_accessKey"] as? String ?? ""
            let resourceId = dict["tf_resourceId"] as? String ?? "volc.bigasr.sauc.duration"
            mutableDict[asrStorageKey(for: .volcano)] = [
                "appKey": appKey,
                "accessKey": accessKey,
                "resourceId": resourceId,
            ]
            mutableDict.removeValue(forKey: "tf_appKey")
            mutableDict.removeValue(forKey: "tf_accessKey")
            mutableDict.removeValue(forKey: "tf_resourceId")
            migrated = true
            NSLog("[KeychainService] Migrated legacy ASR credentials to tf_asr_volcano")
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

        // Migrate LLM: tf_llmEndpointId → tf_llmModel
        if let endpointId = dict["tf_llmEndpointId"] as? String, !endpointId.isEmpty,
           dict["tf_llmModel"] == nil {
            mutableDict["tf_llmModel"] = endpointId
            mutableDict.removeValue(forKey: "tf_llmEndpointId")
            migrated = true
            NSLog("[KeychainService] Migrated tf_llmEndpointId → tf_llmModel")
        }

        // Migrate LLM: flat keys → tf_llm_doubao (provider-grouped)
        if let apiKey = dict["tf_llmApiKey"] as? String, !apiKey.isEmpty,
           dict[llmStorageKey(for: .doubao)] == nil {
            let model = (dict["tf_llmModel"] as? String) ?? ""
            let baseURL = (dict["tf_llmBaseURL"] as? String) ?? ""
            mutableDict[llmStorageKey(for: .doubao)] = [
                "apiKey": apiKey,
                "model": model,
                "baseURL": baseURL.isEmpty ? LLMProvider.doubao.defaultBaseURL : baseURL,
            ]
            mutableDict.removeValue(forKey: "tf_llmApiKey")
            mutableDict.removeValue(forKey: "tf_llmModel")
            mutableDict.removeValue(forKey: "tf_llmBaseURL")
            migrated = true
            NSLog("[KeychainService] Migrated flat LLM keys to tf_llm_doubao")
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

        let secureFieldsMigrated = migrateSecureCredentialGroups(in: &mutableDict)

        if migrated || secureFieldsMigrated {
            try? saveAll(mutableDict)
            cachedCredentials = mutableDict
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
        guard activeStorageConfiguration.usesKeychain else {
            deleteTestingSecureData(service: service, account: account)
            return
        }
        let status = SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }

        let legacyService: String?
        if service == keychainScalarService {
            legacyService = legacyKeychainScalarService
        } else if service == keychainGroupedService {
            legacyService = legacyKeychainGroupedService
        } else {
            legacyService = nil
        }
        if let legacyService {
            let legacyStatus = SecItemDelete(
                keychainQuery(service: legacyService, account: account) as CFDictionary
            )
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw KeychainError.deleteFailed(legacyStatus)
            }
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

    /// Deletes one test-only secret file.
    ///
    /// Args:
    ///   service: Test service name.
    ///   account: Test account name.
    private static func deleteTestingSecureData(service: String, account: String) {
        try? FileManager.default.removeItem(at: testingSecureDataURL(service: service, account: account))
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
            try? saveSecureValues(split.secure, account: storageKey)
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
        let newDir = AppIdentity.appSupportDirectory()

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
