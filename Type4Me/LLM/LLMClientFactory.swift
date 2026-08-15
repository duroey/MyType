import Foundation

enum LLMClientFactory {
    static func make(for provider: LLMProvider) -> any LLMClient {
        switch provider {
        case .claude:
            return ClaudeChatClient()
        case .codexCLI:
            return CodexCLIClient()
        default:
            return DoubaoChatClient(provider: provider)
        }
    }
}
