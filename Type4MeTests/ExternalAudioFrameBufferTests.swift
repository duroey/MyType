import XCTest
@testable import Type4Me

final class ExternalAudioFrameBufferTests: XCTestCase {
    func testAppendFrameEmitsOnlyFullChunksAndFlushesTail() {
        let buffer = ExternalAudioFrameBuffer(chunkByteSize: 4)

        XCTAssertEqual(buffer.appendFrame(Data([1, 2])), [])
        XCTAssertEqual(buffer.appendFrame(Data([3, 4, 5])), [Data([1, 2, 3, 4])])
        XCTAssertEqual(buffer.flushPartialChunk(), Data([5]))
        XCTAssertNil(buffer.flushPartialChunk())
    }

    func testRecordedAudioIncludesFramesAndSeedChunks() {
        let buffer = ExternalAudioFrameBuffer(chunkByteSize: 4)

        buffer.appendRecordedChunk(Data([9, 9]))
        _ = buffer.appendFrame(Data([1, 2, 3, 4]))
        _ = buffer.appendFrame(Data([5]))

        XCTAssertEqual(buffer.recordedAudio(), Data([9, 9, 1, 2, 3, 4, 5]))
    }

    func testResetClearsPendingAndRecordedAudio() {
        let buffer = ExternalAudioFrameBuffer(chunkByteSize: 4)
        _ = buffer.appendFrame(Data([1, 2, 3]))

        buffer.reset()

        XCTAssertNil(buffer.flushPartialChunk())
        XCTAssertEqual(buffer.recordedAudio(), Data())
    }
}
