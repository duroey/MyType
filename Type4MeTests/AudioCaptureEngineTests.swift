import XCTest
import AVFoundation
@testable import Type4Me

final class AudioCaptureEngineTests: XCTestCase {

    func testAudioChunkSize() {
        XCTAssertEqual(AudioCaptureEngine.chunkByteSize, 6400)
    }

    func testSamplesPerChunk() {
        XCTAssertEqual(AudioCaptureEngine.samplesPerChunk, 3200)
    }

    func testTargetAudioFormat() {
        let format = AudioCaptureEngine.targetFormat
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }

    func testPCM16FrameStatsReportsAmplitudeAndZeroRatio() {
        let samples: [Int16] = [0, 100, -200, 0]
        let data = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }

        let stats = AudioCaptureEngine.pcm16FrameStats(from: data)

        XCTAssertEqual(stats.sampleCount, 4)
        XCTAssertEqual(stats.minSample, -200)
        XCTAssertEqual(stats.maxSample, 100)
        XCTAssertEqual(stats.zeroRatio, 0.5, accuracy: 0.001)
        let expectedRMS = sqrt(Float(50_000) / 4)
        XCTAssertEqual(stats.rms, expectedRMS, accuracy: 0.001)
    }
}
