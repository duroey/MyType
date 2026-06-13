import Foundation

/// Thread-safe PCM frame coalescer for externally owned capture streams.
final class ExternalAudioFrameBuffer: @unchecked Sendable {
    private let chunkByteSize: Int
    private let lock = NSLock()
    private var pending = Data()
    private var recorded = Data()

    /// Creates a buffer that converts small PCM frames into ASR chunks.
    ///
    /// Args:
    ///   chunkByteSize: Byte length for each full chunk emitted to ASR.
    init(chunkByteSize: Int = AudioCaptureEngine.chunkByteSize) {
        self.chunkByteSize = max(1, chunkByteSize)
    }

    /// Appends one PCM frame and returns all newly completed chunks.
    ///
    /// Args:
    ///   frame: PCM16 little-endian audio bytes from a live capture callback.
    ///
    /// Returns:
    ///   Full ASR chunks completed by this append. A trailing partial chunk is
    ///   retained until more frames arrive or `flushPartialChunk()` is called.
    func appendFrame(_ frame: Data) -> [Data] {
        lock.withLock {
            guard !frame.isEmpty else { return [] }
            recorded.append(frame)
            pending.append(frame)
            var chunks: [Data] = []
            while pending.count >= chunkByteSize {
                chunks.append(Data(pending.prefix(chunkByteSize)))
                pending.removeFirst(chunkByteSize)
            }
            return chunks
        }
    }

    /// Adds already chunked seed audio to the recorded-audio fallback buffer.
    ///
    /// Args:
    ///   chunk: PCM16 bytes that have already been queued for ASR separately.
    func appendRecordedChunk(_ chunk: Data) {
        lock.withLock {
            recorded.append(chunk)
        }
    }

    /// Emits and clears the current partial chunk.
    ///
    /// Returns:
    ///   The pending partial chunk, or nil when no pending audio exists.
    func flushPartialChunk() -> Data? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            let chunk = pending
            pending = Data()
            return chunk
        }
    }

    /// Returns all PCM audio observed by this buffer.
    ///
    /// Returns:
    ///   Recorded PCM16 bytes, including seed chunks and live frames.
    func recordedAudio() -> Data {
        lock.withLock { recorded }
    }

    /// Clears pending chunks and recorded fallback audio.
    func reset() {
        lock.withLock {
            pending = Data()
            recorded = Data()
        }
    }
}
