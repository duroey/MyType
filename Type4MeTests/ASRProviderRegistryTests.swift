import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .stepfun, .mimo, .baidu, .bailian, .deepgram, .gemini, .assemblyai, .soniox, .metaMuse, .openai] {
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
        XCTAssertTrue(ASRProviderDetailView.hasValidASRCredentials(
            provider: .volcano,
            values: ["apiKey": "new-console-api-key"]
        ))
    }

    func testSettingsCredentialValidationAcceptsVolcanoLegacyPair() {
        XCTAssertTrue(ASRProviderDetailView.hasValidASRCredentials(
            provider: .volcano,
            values: ["appKey": "app-id", "accessKey": "access-token"]
        ))
    }

    func testSettingsCredentialValidationRejectsEmptyVolcanoCredentials() {
        XCTAssertFalse(ASRProviderDetailView.hasValidASRCredentials(provider: .volcano, values: [:]))
    }

    func testRegistry_exposesGeminiProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .gemini)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .gemini) == GeminiASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .gemini))

        let caps = ASRProviderRegistry.capabilities(for: .gemini)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.isStreaming)
        XCTAssertTrue(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
    }
    func testRegistry_exposesMetaMuseProviderConfiguration() {
        let entry = ASRProviderRegistry.entry(for: .metaMuse)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.isAvailable ?? false)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .metaMuse) == MetaMuseASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .metaMuse))

        let caps = ASRProviderRegistry.capabilities(for: .metaMuse)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.isStreaming)
        XCTAssertTrue(caps.supportsRealtimeRecognition)
        XCTAssertEqual(caps.audioInput, .pcmData)
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
        for nonRealtime in [ASRProvider.openai, .mimo] {
            let caps = ASRProviderRegistry.capabilities(for: nonRealtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertFalse(caps.isStreaming)
            XCTAssertFalse(caps.supportsRealtimeRecognition)
        }

        // Realtime streaming providers
        for realtime in [
            ASRProvider.apple, .volcano, .deepgram, .cartesia,
            .assemblyai, .elevenlabs, .gemini, .grok, .soniox, .metaMuse, .stepfun, .bailian, .baidu
        ] {
            let caps = ASRProviderRegistry.capabilities(for: realtime)
            XCTAssertTrue(caps.isAvailable)
            XCTAssertTrue(caps.isStreaming)
            XCTAssertTrue(caps.supportsRealtimeRecognition)
        }
    }

    func testProviderDisplayNames_areCleanWithoutBatchSuffix() {
        XCTAssertEqual(ASRProvider.stepfun.displayName, L("阶跃星辰", "StepFun"))
        XCTAssertEqual(ASRProvider.mimo.displayName, L("小米 MiMo", "Xiaomi MiMo"))
        XCTAssertEqual(ASRProvider.openai.displayName, "OpenAI")
    }

    func testRecognitionModeSelection_isOfferedByProvidersWithBatchVariant() {
        for provider in [ASRProvider.stepfun, .bailian, .gemini, .elevenlabs, .grok, .azure] {
            XCTAssertTrue(ASRProviderRegistry.supportsRecognitionModeSelection(for: provider), "\(provider)")
            let fields = ASRProviderRegistry.configType(for: provider)?.credentialFields ?? []
            XCTAssertEqual(fields.first?.key, ASRRecognitionMode.credentialKey, "\(provider)")
            XCTAssertEqual(fields.first?.defaultValue, ASRRecognitionMode.streaming.rawValue, "\(provider)")
        }
        for provider in [ASRProvider.volcano, .deepgram, .soniox, .openai, .mimo, .baidu] {
            XCTAssertFalse(ASRProviderRegistry.supportsRecognitionModeSelection(for: provider), "\(provider)")
        }
    }

    func testCapabilities_followRequestedRecognitionMode() {
        for provider in [ASRProvider.stepfun, .bailian, .gemini, .elevenlabs, .grok, .azure] {
            let streaming = ASRProviderRegistry.capabilities(for: provider, mode: .streaming)
            XCTAssertTrue(streaming.isStreaming, "\(provider)")
            XCTAssertTrue(streaming.supportsRealtimeRecognition, "\(provider)")

            let batch = ASRProviderRegistry.capabilities(for: provider, mode: .batch)
            XCTAssertTrue(batch.isAvailable, "\(provider)")
            XCTAssertFalse(batch.isStreaming, "\(provider)")
            XCTAssertFalse(batch.supportsRealtimeRecognition, "\(provider)")
        }
        // Providers without a batch variant ignore the requested mode.
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .volcano, mode: .batch).isStreaming)
    }

    func testCreateClient_usesBatchClientWhenConfigSelectsBatch() throws {
        let streaming = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai-test"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: streaming) is GrokASRClient)

        let batch = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "xai-test", "recognitionMode": "batch"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: batch) is BufferedBatchASRClient)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .grok, config: batch).isStreaming)

        let stepFunBatch = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "sk", "recognitionMode": "batch"]))
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .stepfun, config: stepFunBatch) is StepFunBatchASRClient)
    }

    /// Verifies an active recording keeps its captured mode after settings change.
    func testCapturedConfigKeepsModeWhenSavedSettingsChange() throws {
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Requires isolated credential storage")
        }
        let original = KeychainService.loadASRCredentials(for: .grok)
        defer { try? KeychainService.saveASRCredentials(for: .grok, values: original ?? [:]) }

        let streaming = try XCTUnwrap(GrokASRConfig(credentials: ["apiKey": "test-not-used"]))
        let batch = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "test-not-used", "recognitionMode": "batch",
        ]))
        try KeychainService.saveASRCredentials(for: .grok, values: batch.toCredentials())
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .grok).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .grok, config: streaming).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: streaming) is GrokASRClient)

        try KeychainService.saveASRCredentials(for: .grok, values: streaming.toCredentials())
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .grok).isStreaming)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .grok, config: batch).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .grok, config: batch) is BufferedBatchASRClient)
    }

    /// Keeps the existing Volcano setup and Agent mode available after upstream integration.
    func testLegacyVolcanoConfigRetainsStreamingAndAgentMode() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "apiKey": "test-not-used", "resourceId": "auto",
        ]))
        XCTAssertTrue(config.isValid)
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .volcano, config: config).isStreaming)
        XCTAssertTrue(ASRProviderRegistry.createClient(for: .volcano, config: config) is VolcASRClient)
        XCTAssertFalse(ASRProviderRegistry.supportsRecognitionModeSelection(for: .volcano))
        XCTAssertEqual(config.resourceId, VolcanoASRConfig.resourceIdSeedASR)
        XCTAssertTrue(ASRProviderRegistry.supports(.agentRouterMode, for: .volcano))
        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(for: .agentRouterMode, provider: .volcano).id,
            ProcessingMode.agentRouterModeId
        )
    }

    /// Stops bounded batch recordings before their upload caps, including startup audio.
    func testBatchRecordingLimitsIncludeCaptureAndStopHeadroom() throws {
        let bailian = try XCTUnwrap(BailianASRConfig(credentials: ["apiKey": "test", "recognitionMode": "batch"]))
        let gemini = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "test", "recognitionMode": "batch"]))
        for (provider, config, requestLimit) in [
            (ASRProvider.bailian, bailian as any ASRProviderConfig, try XCTUnwrap(BailianBatchTranscriber().maxDuration)),
            (ASRProvider.gemini, gemini as any ASRProviderConfig, try XCTUnwrap(GeminiBatchTranscriber().maxDuration)),
        ] {
            let limit = ASRProviderRegistry.recordingDurationLimit(for: provider, config: config)
            XCTAssertGreaterThan(limit, 0)
            XCTAssertLessThan(limit, requestLimit)
            XCTAssertEqual(ASRProviderRegistry.recordingStopDelay(for: provider, config: config, elapsed: 10), limit - 10)
            XCTAssertEqual(ASRProviderRegistry.recordingStopDelay(for: provider, config: config, elapsed: limit), 0)
            XCTAssertEqual(ASRProviderRegistry.recordingStopDelay(for: provider, config: config, elapsed: limit + 1), 0)
            XCTAssertEqual(ASRProviderRegistry.recordingStopDelay(for: provider, config: config, elapsed: -1), limit)
        }
    }

    /// Keeps the pre-existing streaming time limits and ignores later saved mode changes.
    func testStreamingRecordingLimitsStayUnchanged() throws {
        let volcano = try XCTUnwrap(VolcanoASRConfig(credentials: ["apiKey": "test"]))
        let gemini = try XCTUnwrap(GeminiASRConfig(credentials: ["apiKey": "test"]))
        let bailian = try XCTUnwrap(BailianASRConfig(credentials: ["apiKey": "test"]))
        XCTAssertEqual(ASRProviderRegistry.recordingDurationLimit(for: .volcano, config: volcano), 600)
        XCTAssertEqual(ASRProviderRegistry.recordingDurationLimit(for: .gemini, config: gemini), 570)
        XCTAssertEqual(ASRProviderRegistry.recordingDurationLimit(for: .bailian, config: bailian), 600)
        XCTAssertEqual(ASRProviderRegistry.recordingStopDelay(for: .volcano, config: volcano, elapsed: 10), 600)
    }

    func testCapabilities_followSavedRecognitionMode() throws {
        guard KeychainService.isUsingTestStorage else {
            throw XCTSkip("Requires isolated credential storage")
        }
        let original = KeychainService.loadASRCredentials(for: .elevenlabs)
        defer { try? KeychainService.saveASRCredentials(for: .elevenlabs, values: original ?? [:]) }

        try KeychainService.saveASRCredentials(for: .elevenlabs, values: ["apiKey": "k", "recognitionMode": "batch"])
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .elevenlabs), .batch)
        XCTAssertFalse(ASRProviderRegistry.capabilities(for: .elevenlabs).supportsRealtimeRecognition)
        XCTAssertEqual(
            MenuBarASRProviderItem(provider: .elevenlabs).title,
            "ElevenLabs (\(L("非实时", "Batch")))"
        )

        try KeychainService.saveASRCredentials(for: .elevenlabs, values: ["apiKey": "k", "recognitionMode": "streaming"])
        XCTAssertEqual(ASRProviderRegistry.recognitionMode(for: .elevenlabs), .streaming)
        XCTAssertTrue(ASRProviderRegistry.capabilities(for: .elevenlabs).supportsRealtimeRecognition)
        XCTAssertEqual(MenuBarASRProviderItem(provider: .elevenlabs).title, "ElevenLabs")
    }
}
