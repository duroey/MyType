import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .stepfunBatch, .mimo, .baidu, .bailian, .deepgram, .assemblyai, .soniox, .openai] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
        }
    }

    func testResolvedModeFallsBackToDirectForUnavailableProvider() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        // Custom/LLM modes should always be supported
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .bailian))
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .volcano))
    }

    func testSupportedModesFilterKeepsAllForAvailableProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, customMode]

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let bailianModes = ASRProviderRegistry.supportedModes(from: modes, for: .bailian)
        XCTAssertEqual(bailianModes.map(\.id), [ProcessingMode.directId, customMode.id])
    }

    func testSettingsCredentialValidationAcceptsVolcanoApiKeyOnly() {
        XCTAssertTrue(ASRSettingsCard.hasValidASRCredentials(
            provider: .volcano,
            values: ["apiKey": "new-console-api-key"]
        ))
    }

    func testSettingsCredentialValidationAcceptsVolcanoLegacyPair() {
        XCTAssertTrue(ASRSettingsCard.hasValidASRCredentials(
            provider: .volcano,
            values: ["appKey": "app-id", "accessKey": "access-token"]
        ))
    }

    func testSettingsCredentialValidationRejectsEmptyVolcanoCredentials() {
        XCTAssertFalse(ASRSettingsCard.hasValidASRCredentials(provider: .volcano, values: [:]))
    }

    func testRegistry_exposesMiMoProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .mimo)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .mimo) == MiMoASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .mimo))

        let caps = ASRProviderRegistry.capabilities(for: .mimo)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertFalse(caps.isStreaming)
        XCTAssertFalse(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
    }

    func testCapabilities_distinguishRealtimeAndNonRealtimeProviders() {
        // Non-realtime (batch audio submission after hotkey release)
        for nonRealtime in [ASRProvider.openai, .stepfunBatch, .mimo] {
            let caps = ASRProviderRegistry.capabilities(for: nonRealtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertFalse(caps.isStreaming)
            XCTAssertFalse(caps.supportsRealtimeRecognition)
        }

        // Realtime streaming providers
        for realtime in [
            ASRProvider.apple, .volcano, .deepgram, .cartesia,
            .assemblyai, .elevenlabs, .grok, .soniox, .bailian, .baidu
        ] {
            let caps = ASRProviderRegistry.capabilities(for: realtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertTrue(caps.isStreaming)
            XCTAssertTrue(caps.supportsRealtimeRecognition)
        }
    }

    func testProviderDisplayNames_areCleanWithoutBatchSuffix() {
        XCTAssertEqual(ASRProvider.stepfunBatch.displayName, L("阶跃星辰", "StepFun"))
        XCTAssertEqual(ASRProvider.mimo.displayName, L("小米 MiMo", "Xiaomi MiMo"))
        XCTAssertEqual(ASRProvider.openai.displayName, "OpenAI")
    }
}
