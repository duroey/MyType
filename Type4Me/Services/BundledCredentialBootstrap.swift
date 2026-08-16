import Foundation

struct BundledCredentialPayload: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payloadID: String
    let asrProvider: ASRProvider
    let asrCredentials: [String: String]
    let llmProvider: LLMProvider
    let llmCredentials: [String: String]
}

enum BundledCredentialImportOutcome: Equatable {
    case notBundled
    case alreadyImported
    case completed(asrImported: Bool, llmImported: Bool)
}

enum BundledCredentialBootstrapError: Error, Equatable, LocalizedError {
    case unreadablePayload
    case invalidPayload
    case invalidPayloadID
    case unsupportedSchema(Int)
    case invalidASRConfiguration
    case invalidLLMConfiguration

    var errorDescription: String? {
        switch self {
        case .unreadablePayload:
            return "Unable to read bundled credential payload"
        case .invalidPayload:
            return "Bundled credential payload is invalid"
        case .invalidPayloadID:
            return "Bundled credential payload identifier is empty"
        case .unsupportedSchema(let version):
            return "Unsupported bundled credential schema: \(version)"
        case .invalidASRConfiguration:
            return "Bundled ASR configuration is invalid"
        case .invalidLLMConfiguration:
            return "Bundled LLM configuration is invalid"
        }
    }
}

enum BundledCredentialBootstrap {
    static let importMarkerKey = "tf_bundledCredentialPayloadID"
    private static let asrSelectionKey = "tf_selectedASRProvider"
    private static let llmSelectionKey = "tf_selectedLLMProvider"
    private static let resourceName = "MyTypeCredentials"
    private static let resourceExtension = "json"

    /// Imports the optional credential payload sealed into the application bundle.
    ///
    /// Args:
    ///   bundle: Application bundle that may contain the credential resource.
    ///   defaults: Preference store used for import markers and provider selections.
    ///
    /// Returns:
    ///   The import outcome, including whether each provider was initialized.
    ///
    /// Throws:
    ///   `BundledCredentialBootstrapError` when the resource cannot be read or validated.
    static func importIfAvailable(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) throws -> BundledCredentialImportOutcome {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            return .notBundled
        }
        return try importPayload(at: url, defaults: defaults)
    }

    /// Decodes and imports a credential payload from a local file.
    ///
    /// Args:
    ///   url: File URL containing the JSON payload.
    ///   defaults: Preference store used for import markers and provider selections.
    ///
    /// Returns:
    ///   The import outcome after decoding and validation.
    ///
    /// Throws:
    ///   `BundledCredentialBootstrapError` when the file is unreadable or malformed.
    static func importPayload(
        at url: URL,
        defaults: UserDefaults = .standard
    ) throws -> BundledCredentialImportOutcome {
        guard let data = try? Data(contentsOf: url) else {
            throw BundledCredentialBootstrapError.unreadablePayload
        }
        guard let payload = try? JSONDecoder().decode(BundledCredentialPayload.self, from: data) else {
            throw BundledCredentialBootstrapError.invalidPayload
        }
        return try importPayload(payload, defaults: defaults)
    }

    /// Validates and installs bundled provider credentials without replacing user configuration.
    ///
    /// Args:
    ///   payload: Decoded provider configuration and credentials.
    ///   defaults: Preference store used for import markers and provider selections.
    ///
    /// Returns:
    ///   The import outcome, or `alreadyImported` for a repeated payload.
    ///
    /// Throws:
    ///   `BundledCredentialBootstrapError` when the payload cannot initialize both providers.
    static func importPayload(
        _ payload: BundledCredentialPayload,
        defaults: UserDefaults = .standard
    ) throws -> BundledCredentialImportOutcome {
        guard payload.schemaVersion == BundledCredentialPayload.currentSchemaVersion else {
            throw BundledCredentialBootstrapError.unsupportedSchema(payload.schemaVersion)
        }
        guard !payload.payloadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BundledCredentialBootstrapError.invalidPayloadID
        }
        guard let asrConfigType = ASRProviderRegistry.configType(for: payload.asrProvider),
              asrConfigType.init(credentials: payload.asrCredentials) != nil
        else {
            throw BundledCredentialBootstrapError.invalidASRConfiguration
        }
        guard let llmConfigType = LLMProviderRegistry.configType(for: payload.llmProvider),
              llmConfigType.init(credentials: payload.llmCredentials) != nil
        else {
            throw BundledCredentialBootstrapError.invalidLLMConfiguration
        }
        if defaults.string(forKey: importMarkerKey) == payload.payloadID {
            return .alreadyImported
        }

        let hasExistingASRSelection = defaults.object(forKey: asrSelectionKey) != nil
        let hasExistingASRCredentials = KeychainService.loadASRCredentials(
            for: payload.asrProvider
        ) != nil
        let shouldImportASR = !hasExistingASRSelection && !hasExistingASRCredentials

        let hasExistingLLMSelection = defaults.object(forKey: llmSelectionKey) != nil
        let hasExistingLLMCredentials = KeychainService.loadLLMCredentials(
            for: payload.llmProvider
        ) != nil
        let shouldImportLLM = !hasExistingLLMSelection && !hasExistingLLMCredentials

        if shouldImportASR {
            try KeychainService.saveASRCredentials(
                for: payload.asrProvider,
                values: payload.asrCredentials
            )
            KeychainService.selectedASRProvider = payload.asrProvider
        }
        if shouldImportLLM {
            try KeychainService.saveLLMCredentials(
                for: payload.llmProvider,
                values: payload.llmCredentials
            )
            KeychainService.selectedLLMProvider = payload.llmProvider
        }

        defaults.set(payload.payloadID, forKey: importMarkerKey)
        return .completed(asrImported: shouldImportASR, llmImported: shouldImportLLM)
    }
}
