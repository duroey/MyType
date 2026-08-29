import Foundation

enum StepFunBatchAccessMode: String, Sendable, CaseIterable {
    case stepPlan
    case standard

    var displayName: String {
        switch self {
        case .stepPlan:
            return "Step Plan"
        case .standard:
            return L("标准按量付费", "Standard pay-as-you-go")
        }
    }

    var endpoint: String {
        switch self {
        case .stepPlan:
            return StepFunBatchASRConfig.stepPlanEndpoint
        case .standard:
            return StepFunBatchASRConfig.standardEndpoint
        }
    }
}

struct StepFunBatchASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.stepfunBatch
    static let displayName = L("阶跃星辰", "StepFun")
    static let defaultModel = "stepaudio-2.5-asr"
    static let stepPlanEndpoint = "https://api.stepfun.com/step_plan/v1/audio/asr/sse"
    static let standardEndpoint = "https://api.stepfun.com/v1/audio/asr/sse"

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "accessMode",
            label: L("接入方式", "Access Mode"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: StepFunBatchAccessMode.stepPlan.rawValue,
            options: StepFunBatchAccessMode.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            }
        ),
    ]}

    let apiKey: String
    let accessMode: StepFunBatchAccessMode

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return nil
        }
        self.apiKey = apiKey
        self.accessMode = StepFunBatchAccessMode(rawValue: credentials["accessMode"] ?? "") ?? .stepPlan
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "accessMode": accessMode.rawValue,
        ]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
