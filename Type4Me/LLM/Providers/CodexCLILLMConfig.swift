import Foundation

struct CodexCLILLMConfig: LLMProviderConfig, Sendable {

    static let provider = LLMProvider.codexCLI

    static var credentialFields: [CredentialField] {
        let models = provider.modelOptions
        return [
            CredentialField(
                key: "model",
                label: L("模型（固定使用低推理）", "Model (Low Reasoning)"),
                placeholder: "gpt-5.6-luna",
                isSecure: false,
                isOptional: false,
                defaultValue: models.first?.value ?? "gpt-5.6-luna",
                options: models
            ),
        ]
    }

    let model: String

    init?(credentials: [String: String]) {
        let model = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return nil }
        self.model = model
    }

    func toCredentials() -> [String: String] {
        ["model": model]
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(apiKey: "", model: model, baseURL: "codex-cli")
    }
}
