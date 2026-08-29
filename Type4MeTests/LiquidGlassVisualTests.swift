//
//  LiquidGlassVisualTests.swift
//  Type4MeTests
//

import XCTest
@testable import Type4Me

@MainActor
final class LiquidGlassVisualTests: XCTestCase {

    // MARK: - RecordingTextParts Tests

    func testRecordingTextParts_emptySegmentsYieldsListeningText() {
        let parts = RecordingTextParts.build(segments: [], defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "")
        XCTAssertEqual(parts.active, "倾听中")
    }

    func testRecordingTextParts_allConfirmedSegmentsYieldsEmptyActive() {
        let segments = [
            TranscriptionSegment(text: "今天天气", isConfirmed: true),
            TranscriptionSegment(text: "真不错", isConfirmed: true),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "今天天气真不错")
        XCTAssertEqual(parts.active, "")
    }

    func testRecordingTextParts_mixedSegmentsSplitsConfirmedAndLastUnconfirmed() {
        let segments = [
            TranscriptionSegment(text: "今天天气", isConfirmed: true),
            TranscriptionSegment(text: "很好，我们", isConfirmed: true),
            TranscriptionSegment(text: "出去玩吧", isConfirmed: false),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "今天天气很好，我们")
        XCTAssertEqual(parts.active, "出去玩吧")
    }

    func testRecordingTextParts_onlyUnconfirmedSegment() {
        let segments = [
            TranscriptionSegment(text: "正在说话", isConfirmed: false),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "")
        XCTAssertEqual(parts.active, "正在说话")
    }

    // MARK: - OrbPreset Mapping Tests

    func testOrbPresets_styleIDAndAnimation() {
        XCTAssertEqual(RecordingVisualStyle.siri.preset.styleID, 0)
        XCTAssertTrue(RecordingVisualStyle.siri.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.blueDrop.preset.styleID, 1)
        XCTAssertTrue(RecordingVisualStyle.blueDrop.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.chromaticMetal.preset.styleID, 2)
        XCTAssertTrue(RecordingVisualStyle.chromaticMetal.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.frost.preset.styleID, 3)
        XCTAssertTrue(RecordingVisualStyle.frost.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.opal.preset.styleID, 4)
        XCTAssertTrue(RecordingVisualStyle.opal.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.voiceWave.preset.styleID, 5)
        XCTAssertTrue(RecordingVisualStyle.voiceWave.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.violetEmber.preset.styleID, 6)
        XCTAssertTrue(RecordingVisualStyle.violetEmber.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.aurora.preset.styleID, 7)
        XCTAssertTrue(RecordingVisualStyle.aurora.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.chrome.preset.styleID, 8)
        XCTAssertTrue(RecordingVisualStyle.chrome.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.spectrum.preset.styleID, 9)
        XCTAssertTrue(RecordingVisualStyle.spectrum.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.staticGlass.preset.styleID, 10)
        XCTAssertFalse(RecordingVisualStyle.staticGlass.preset.isAnimated)
    }

    // MARK: - LiquidGlassMotion Policy Tests

    func testLiquidGlassMotion_activeClampsEnergy() {
        let motion = LiquidGlassMotion.active(time: 12.34, rawEnergy: 1.5, isAnimated: true, reduceMotion: false)
        XCTAssertTrue(motion.isAnimated)
        XCTAssertEqual(motion.time, 12.34)
        XCTAssertEqual(motion.energy, 1.0)

        let negativeMotion = LiquidGlassMotion.active(time: 5.0, rawEnergy: -0.5, isAnimated: true, reduceMotion: false)
        XCTAssertEqual(negativeMotion.energy, 0.0)
    }

    func testLiquidGlassMotion_staticOrReduceMotionYieldsStaticFallback() {
        let staticMotion = LiquidGlassMotion.active(time: 10.0, rawEnergy: 0.8, isAnimated: false, reduceMotion: false)
        XCTAssertEqual(staticMotion, LiquidGlassMotion.staticFallback)

        let reduceMotion = LiquidGlassMotion.active(time: 10.0, rawEnergy: 0.8, isAnimated: true, reduceMotion: true)
        XCTAssertEqual(reduceMotion, LiquidGlassMotion.staticFallback)
    }

    // MARK: - DemoState Preview Segment Tests

    func testDemoState_makePreviewSegments_splitsConfirmedAndActive() {
        let zhSegments = DemoState.makePreviewSegments(from: "我正在使用Type4Me测试一段足够长的实时识别文本，方便直接预览悬停窗口和录音动效。")
        XCTAssertEqual(zhSegments.count, 2)
        XCTAssertTrue(zhSegments[0].isConfirmed)
        XCTAssertFalse(zhSegments[1].isConfirmed)
        XCTAssertEqual(zhSegments[0].text, "我正在使用Type4Me测试一段足够长的实时识别文本，")
        XCTAssertEqual(zhSegments[1].text, "方便直接预览悬停窗口和录音动效。")

        let enSegments = DemoState.makePreviewSegments(from: "I am testing a sufficiently long live transcript in Type4Me, to preview the hover window and recording effects directly.")
        XCTAssertEqual(enSegments.count, 2)
        XCTAssertTrue(enSegments[0].isConfirmed)
        XCTAssertFalse(enSegments[1].isConfirmed)
    }
}
