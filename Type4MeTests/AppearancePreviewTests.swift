import XCTest
@testable import Type4Me

@MainActor
final class AppearancePreviewTests: XCTestCase {

    // MARK: - FloatingBarPresentation Override & Fallback Tests

    func testFloatingBarPresentationInit() {
        let presentation = FloatingBarPresentation(
            indicatorStyle: .regular,
            visualStyle: .voiceWave,
            showsLiveTranscript: false,
            enablesHoverTranscriptPreview: false,
            showsTooltips: false,
            showsCancelButton: false
        )

        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .voiceWave)
        XCTAssertFalse(presentation.showsLiveTranscript)
        XCTAssertFalse(presentation.enablesHoverTranscriptPreview)
        XCTAssertFalse(presentation.showsTooltips)
        XCTAssertFalse(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testFloatingBarPresentation_defaults() {
        let presentation = FloatingBarPresentation()
        XCTAssertEqual(presentation.indicatorStyle, .regular)
        XCTAssertEqual(presentation.visualStyle, .siri)
        XCTAssertTrue(presentation.showsLiveTranscript)
        XCTAssertTrue(presentation.enablesHoverTranscriptPreview)
        XCTAssertTrue(presentation.showsTooltips)
        XCTAssertTrue(presentation.showsCancelButton)
        XCTAssertTrue(presentation.showsRecordingIndicator)
    }

    func testAppearancePreferenceDefaults() {
        XCTAssertEqual(AppearancePreferenceDefaults.showTooltipsKey, "tf_showTooltips")
        XCTAssertTrue(AppearancePreferenceDefaults.showTooltipsDefault)
        XCTAssertEqual(AppearancePreferenceDefaults.showCancelButtonKey, "tf_showCancelButton")
        XCTAssertTrue(AppearancePreferenceDefaults.showCancelButtonDefault)
    }

    func testRecordingChromeWidthDesignTokens() {
        // Dual-button chrome: Finish(45) + Cancel(35) + LeadingInset(5) + TrailingInset(10) + Gap*2(16) + Safety(16) = 127
        XCTAssertEqual(TF.recordingChromeWidth, 127)
        // Single-button chrome: Finish(45) + LeadingInset(5) + TrailingInset(10) + Gap(8) + Safety(16) = 84
        XCTAssertEqual(TF.recordingSingleButtonChromeWidth, 84)
        // Difference is exactly one cancel control size (35) plus one control gap (8)
        XCTAssertEqual(
            TF.recordingChromeWidth - TF.recordingSingleButtonChromeWidth,
            TF.recordingCancelControlSize + TF.recordingControlGap
        )
    }

    func testFloatingBarPresentation_showsRecordingIndicatorAlwaysTrueWhenConfigured() {
        let compact = FloatingBarPresentation(
            indicatorStyle: .compact,
            visualStyle: .staticGlass,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertTrue(compact.showsRecordingIndicator)

        let regular = FloatingBarPresentation(
            indicatorStyle: .regular,
            visualStyle: .staticGlass,
            showsLiveTranscript: true,
            enablesHoverTranscriptPreview: true
        )
        XCTAssertTrue(regular.showsRecordingIndicator)
    }

    func testPreviewPhase_allCases() {
        XCTAssertEqual(PreviewPhase.allCases.count, 2)
        XCTAssertEqual(PreviewPhase.recording.displayName, L("录音中", "Recording"))
        XCTAssertEqual(PreviewPhase.processing.displayName, L("处理中", "Processing"))
    }

    func testRecordingVisualStyle_allCases() {
        XCTAssertEqual(RecordingVisualStyle.siri.displayName, L("Siri 波澜", "Siri Ripple"))
        XCTAssertEqual(RecordingVisualStyle.blueDrop.displayName, L("蓝晶液滴", "Blue Crystal Drop"))
        XCTAssertEqual(RecordingVisualStyle.chromaticMetal.displayName, L("色差液态金属", "Chromatic Liquid Metal"))
        XCTAssertEqual(RecordingVisualStyle.frost.displayName, L("冰霜流体", "Frost Fluid"))
        XCTAssertEqual(RecordingVisualStyle.opal.displayName, L("虹彩欧泊", "Iridescent Opal"))
        XCTAssertEqual(RecordingVisualStyle.voiceWave.displayName, L("声纹薄膜", "Voiceprint Membrane"))
        XCTAssertEqual(RecordingVisualStyle.violetEmber.displayName, L("紫焰流核", "Violet Flame Core"))
        XCTAssertEqual(RecordingVisualStyle.aurora.displayName, L("极光帷幕", "Aurora Veil"))
        XCTAssertEqual(RecordingVisualStyle.chrome.displayName, L("液态铬", "Liquid Chrome"))
        XCTAssertEqual(RecordingVisualStyle.spectrum.displayName, L("彩色声场", "Color Soundfield"))
        XCTAssertEqual(RecordingVisualStyle.staticSiri.displayName, L("静态 Siri (低能耗)", "Static Siri (Power-saving)"))

        XCTAssertTrue(RecordingVisualStyle.siri.isAnimated)
        XCTAssertFalse(RecordingVisualStyle.staticSiri.isAnimated)
    }

    // MARK: - Text Formatting Options Preview Tests

    func testAppearanceFormattingSample_panguEnabled() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)

        // Should contain spacing between CJK and Latin / Numbers
        XCTAssertTrue(
            formattedZh.contains("MacBook 上测试 \(AppIdentity.displayName) 2.3")
        )
        // Quotes remain curly
        XCTAssertTrue(formattedZh.contains("“这个效果很好”。"))
    }

    func testAppearanceFormattingSample_cornerQuotesEnabled() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: true,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let enSample = AppearancePreviewStage.formattingSamples[1]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)
        let formattedEn = TextOutputFormatter.format(enSample, options: options)

        // Chinese quotes are converted to corner quotes
        XCTAssertTrue(formattedZh.contains("「这个效果很好」"))
        XCTAssertFalse(formattedZh.contains("“"))
        XCTAssertFalse(formattedZh.contains("”"))

        // English quotes are converted and apostrophe preserved
        XCTAssertTrue(formattedEn.contains("「it’s fast and accurate」") || formattedEn.contains("「it's fast and accurate」"))
    }

    func testAppearanceFormattingSample_stripTrailingPeriods() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: false,
            trailingPunctuationMode: .period
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let enSample = AppearancePreviewStage.formattingSamples[1]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)
        let formattedEn = TextOutputFormatter.format(enSample, options: options)

        // Trailing periods removed from both Chinese and English lines
        XCTAssertTrue(formattedZh.hasSuffix("“这个效果很好”"))
        XCTAssertFalse(formattedZh.hasSuffix("。"))

        XCTAssertTrue(formattedEn.hasSuffix("“it's fast and accurate”") || formattedEn.hasSuffix("“it’s fast and accurate”"))
        XCTAssertFalse(formattedEn.hasSuffix("."))
    }

    func testAppearanceFormattingSample_removeSpaces() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .remove,
            usesCornerQuotes: false,
            trailingPunctuationMode: .off
        )
        let zhSample = AppearancePreviewStage.formattingSamples[0]
        let formattedZh = TextOutputFormatter.format(zhSample, options: options)

        // Spacing removed
        XCTAssertTrue(
            formattedZh.contains("在MacBook上测试\(AppIdentity.displayName) 2.3")
        )
    }

    func testAppearanceFormattingSample_combinedOptions() {
        let options = TextOutputFormattingOptions(
            cjkSpacingMode: .pangu,
            usesCornerQuotes: true,
            trailingPunctuationMode: .period
        )
        let formatted = AppearancePreviewStage.formattingSamples
            .map { TextOutputFormatter.format($0, options: options) }
            .joined(separator: "\n")

        XCTAssertTrue(
            formatted.contains("在 MacBook 上测试 \(AppIdentity.displayName) 2.3")
        )
        XCTAssertTrue(formatted.contains("「这个效果很好」"))
        XCTAssertTrue(formatted.contains("fast and accurate」"))
        XCTAssertFalse(formatted.contains("。"))
        XCTAssertFalse(formatted.hasSuffix("."))
    }

    // MARK: - DemoState Lifecycle & Isolation Tests

    func testDemoState_startAppearancePreview() {
        let demoState = DemoState()
        let sample = "Test Sample Text"

        demoState.startAppearancePreview(sampleText: sample)

        XCTAssertEqual(demoState.demoMode, .appearancePreview)
        XCTAssertEqual(demoState.barPhase, .recording)
        XCTAssertFalse(demoState.segments.isEmpty)
        XCTAssertEqual(demoState.transcriptionText, sample)
        XCTAssertNotNil(demoState.recordingStartDate)

        demoState.stop()
        XCTAssertEqual(demoState.demoMode, .quickLoop)
        XCTAssertEqual(demoState.barPhase, .hidden)
        XCTAssertTrue(demoState.segments.isEmpty)
        XCTAssertEqual(demoState.audioLevel.current, 0)
    }

    func testDemoState_updateAppearancePreviewSampleText() {
        let demoState = DemoState()
        demoState.startAppearancePreview(sampleText: "Initial Text")
        XCTAssertEqual(demoState.transcriptionText, "Initial Text")

        demoState.updateAppearancePreview(sampleText: "Updated Text")
        XCTAssertEqual(demoState.transcriptionText, "Updated Text")
        XCTAssertEqual(demoState.barPhase, .recording)
        XCTAssertEqual(demoState.demoMode, .appearancePreview)

        demoState.stop()
    }

    func testDemoState_actionIsolationInAppearancePreviewMode() {
        let demoState = DemoState()
        demoState.startAppearancePreview(sampleText: "Sample")

        // Clicking finish / cancel should not advance or disrupt preview state
        demoState.performRecordingControlAction(.finish)
        XCTAssertEqual(demoState.barPhase, .recording)

        demoState.performRecordingControlAction(.cancel)
        XCTAssertEqual(demoState.barPhase, .recording)

        demoState.stop()
    }

    func testDemoState_actionInQuickLoopMode() {
        let demoState = DemoState()
        demoState.startQuickModeDemo()
        // Wait briefly or simulate recording phase
        demoState.barPhase = .recording

        demoState.performRecordingControlAction(.finish)
        XCTAssertEqual(demoState.barPhase, .processing)

        demoState.stop()
    }

    // MARK: - SettingsTab Appearance Tests

    func testSettingsTab_appearanceProperties() {
        let tab = SettingsTab.appearance
        XCTAssertEqual(tab.rawValue, "appearance")
        XCTAssertEqual(tab.icon, "paintbrush")
        XCTAssertFalse(tab.displayName.isEmpty)
        XCTAssertFalse(tab.subtitle.isEmpty)
        XCTAssertTrue(SettingsTab.allCases.contains(.appearance))
    }
}
