import Foundation

/// How a provider that offers both APIs transcribes a recording.
/// Persisted as a plain credential value so it lives next to the provider's other settings.
enum ASRRecognitionMode: String, CaseIterable, Sendable {
    /// Audio is streamed while recording; text appears as the user speaks.
    case streaming
    /// The complete recording is uploaded after the hotkey is released.
    case batch

    static let credentialKey = "recognitionMode"
    static let `default` = ASRRecognitionMode.streaming

    init(credentialValue: String?) {
        let raw = credentialValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self = ASRRecognitionMode(rawValue: raw) ?? .default
    }

    init(credentials: [String: String]) {
        self.init(credentialValue: credentials[Self.credentialKey])
    }

    var displayName: String {
        switch self {
        case .streaming: return L("实时流式", "Real-time")
        case .batch:     return L("非实时", "Batch")
        }
    }

    var summary: String {
        switch self {
        case .streaming:
            return L(
                "录音时持续上传并识别，可显示中间文字；结束后等待最终结果。",
                "Audio is uploaded and transcribed while you speak, with interim text available. The final result follows when recording stops."
            )
        case .batch:
            return L(
                "结束录音后上传整段音频再识别；等待时间、费用和准确率取决于服务商、模型及录音长度。",
                "The whole recording is uploaded when you stop recording. Latency, cost, and accuracy depend on the provider, model, and recording length."
            )
        }
    }

    /// Indicator text while a batch provider records; no text arrives until recording ends
    /// (hold-to-talk or tap-to-toggle).
    static var batchRecordingPlaceholder: String {
        L("录音中 · 结束后识别", "Recording · text at end")
    }

    /// Credential field rendered as a segmented control at the top of the provider settings.
    static var credentialField: CredentialField {
        CredentialField(
            key: credentialKey,
            label: L("识别方式", "Recognition"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: ASRRecognitionMode.default.rawValue,
            options: allCases.map { FieldOption(value: $0.rawValue, label: $0.displayName) }
        )
    }
}

/// Implemented by configs whose provider can switch between streaming and batch recognition.
protocol ASRRecognitionModeConfigurable: ASRProviderConfig {
    var recognitionMode: ASRRecognitionMode { get }
}
