import Foundation

struct VolcanoASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.volcano
    static var displayName: String { L("火山引擎 (Doubao)", "Volcano (Doubao)") }

    /// 豆包流式语音识别模型 2.0
    static let resourceIdSeedASR = "volc.seedasr.sauc.duration"
    /// 豆包流式语音识别模型 1.0
    static let resourceIdBigASR = "volc.bigasr.sauc.duration"
    /// Auto: prefer 2.0, fall back to 1.0
    static let resourceIdAuto = "auto"

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: "API Key", placeholder: L("新版控制台 API Key", "New console API Key"), isSecure: true, isOptional: true, defaultValue: ""),
        CredentialField(key: "appKey", label: "App ID", placeholder: "APPID", isSecure: false, isOptional: true, defaultValue: ""),
        CredentialField(key: "accessKey", label: "Access Token", placeholder: L("访问令牌", "Access token"), isSecure: true, isOptional: true, defaultValue: ""),
        CredentialField(
            key: "resourceId",
            label: L("识别模型", "Model"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: resourceIdAuto,
            options: [
                FieldOption(value: resourceIdAuto, label: L("自动（优先 2.0，额度用完切 1.0）", "Auto (prefer 2.0, fallback to 1.0)")),
                FieldOption(value: resourceIdSeedASR, label: L("流式语音识别模型 2.0", "Streaming ASR Model 2.0")),
                FieldOption(value: resourceIdBigASR, label: L("流式语音识别大模型", "Streaming ASR Large Model")),
            ]
        ),
    ]}

    let apiKey: String?
    let appKey: String
    let accessKey: String
    let resourceId: String
    let uid: String

    init?(credentials: [String: String]) {
        let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appKey = credentials["appKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accessKey = credentials["accessKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || (!appKey.isEmpty && !accessKey.isEmpty) else { return nil }
        self.apiKey = apiKey.isEmpty ? nil : apiKey
        self.appKey = appKey
        self.accessKey = accessKey
        let raw = credentials["resourceId"] ?? Self.resourceIdAuto
        if raw == Self.resourceIdAuto || raw.isEmpty {
            // Use resolved value from auto-detect, or default to seed
            self.resourceId = credentials["resolvedResourceId"]?.isEmpty == false
                ? credentials["resolvedResourceId"]!
                : Self.resourceIdSeedASR
        } else {
            self.resourceId = raw
        }
        self.uid = ASRIdentityStore.loadOrCreateUID()
    }

    func toCredentials() -> [String: String] {
        var values = ["appKey": appKey, "accessKey": accessKey, "resourceId": resourceId]
        if let apiKey {
            values["apiKey"] = apiKey
        }
        return values
    }

    var isValid: Bool {
        apiKey?.isEmpty == false || (!appKey.isEmpty && !accessKey.isEmpty)
    }
}
