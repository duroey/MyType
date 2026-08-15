import Foundation

struct AzureASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.azure
    static let displayName = "Azure Speech"

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "subscriptionKey", label: L("订阅密钥", "Subscription Key"), placeholder: L("密钥", "Secret"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "region", label: L("区域", "Region"), placeholder: "eastasia", isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "customEndpoint", label: L("自定义端点", "Custom Endpoint"), placeholder: L("可选", "Optional"), isSecure: false, isOptional: true, defaultValue: ""),
    ]}

    let subscriptionKey: String
    let region: String
    let customEndpoint: String?

    init?(credentials: [String: String]) {
        guard let key = credentials["subscriptionKey"], !key.isEmpty,
              let region = credentials["region"], !region.isEmpty
        else { return nil }
        self.subscriptionKey = key
        self.region = region
        self.customEndpoint = credentials["customEndpoint"]
    }

    func toCredentials() -> [String: String] {
        var result = ["subscriptionKey": subscriptionKey, "region": region]
        if let v = customEndpoint, !v.isEmpty { result["customEndpoint"] = v }
        return result
    }

    var isValid: Bool { !subscriptionKey.isEmpty && !region.isEmpty }
}
