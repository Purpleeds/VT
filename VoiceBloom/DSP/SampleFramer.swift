import Foundation

/// Cuts a continuous stream of samples into overlapping analysis frames.
///
/// Audio arrives in arbitrary chunk sizes (often 256 samples). The framer
/// buffers it and hands out one `frameSize` window every `hopSize` samples,
/// so with 2048/512 each sample is analyzed in four overlapping frames.
nonisolated struct SampleFramer: Sendable {
    let frameSize: Int
    let hopSize: Int

    private var buffer: [Float] = []
    /// Total frames handed out since creation. Used to timestamp frames.
    private(set) var framesProduced = 0

    init(frameSize: Int, hopSize: Int) {
        self.frameSize = max(1, frameSize)
        self.hopSize = min(max(1, hopSize), self.frameSize)
        buffer.reserveCapacity(self.frameSize * 4)
    }

    /// Samples waiting for the next frame.
    var bufferedSampleCount: Int { buffer.count }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        buffer.append(contentsOf: samples)
    }

    mutating func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
    }

    /// Calls `body` for every complete frame now available, in order, with the
    /// frame's index since the framer was created. Consumed samples are dropped.
    mutating func forEachFrame(_ body: (UnsafeBufferPointer<Float>, Int) -> Void) {
        let size = frameSize
        let hop = hopSize
        guard buffer.count >= size else { return }

        var offset = 0
        var index = framesProduced
        buffer.withUnsafeBufferPointer { all in
            while offset + size <= all.count {
                body(UnsafeBufferPointer(rebasing: all[offset ..< offset + size]), index)
                offset += hop
                index += 1
            }
        }
        framesProduced = index
        // Keep only the samples the next frame still needs.
        buffer.removeFirst(offset)
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        framesProduced = 0
    }
}
