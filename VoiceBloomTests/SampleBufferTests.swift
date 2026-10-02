import Foundation
import Testing
@testable import VoiceBloom

@Suite("SampleRingBuffer")
struct SampleRingBufferTests {
    private func readAll(_ ring: SampleRingBuffer, max: Int = 64) -> [Float] {
        var destination = [Float](repeating: 0, count: max)
        let count = destination.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        return Array(destination.prefix(count))
    }

    @Test("Capacity rounds up to a power of two")
    func capacity() {
        #expect(SampleRingBuffer(minimumCapacity: 5).capacity == 8)
        #expect(SampleRingBuffer(minimumCapacity: 8).capacity == 8)
        #expect(SampleRingBuffer(minimumCapacity: 0).capacity == 2)
    }

    @Test("Samples come out in order")
    func fifo() {
        let ring = SampleRingBuffer(minimumCapacity: 16)
        #expect(ring.write([1, 2, 3, 4]) == 4)
        #expect(ring.availableCount == 4)
        #expect(readAll(ring) == [1, 2, 3, 4])
        #expect(ring.availableCount == 0)
        #expect(readAll(ring).isEmpty)
    }

    @Test("Wraps around the end of storage")
    func wrapAround() {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        ring.write([1, 2, 3, 4, 5, 6])
        #expect(readAll(ring, max: 4) == [1, 2, 3, 4])
        #expect(ring.write([7, 8, 9, 10, 11, 12]) == 6)
        #expect(readAll(ring) == [5, 6, 7, 8, 9, 10, 11, 12])
    }

    @Test("When full, new samples are dropped and counted (unread audio is never overwritten)")
    func overflow() {
        let ring = SampleRingBuffer(minimumCapacity: 8)
        #expect(ring.write([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) == 8)
        #expect(ring.droppedSampleCount == 2)
        #expect(readAll(ring) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("Stride picks one channel out of interleaved audio")
    func interleaved() {
        let ring = SampleRingBuffer(minimumCapacity: 16)
        let stereo: [Float] = [1, -1, 2, -2, 3, -3]
        stereo.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                ring.write(base, count: 3, stride: 2)
            }
        }
        #expect(readAll(ring) == [1, 2, 3])
    }

    @Test("discardAll empties the queue")
    func discard() {
        let ring = SampleRingBuffer(minimumCapacity: 16)
        ring.write([1, 2, 3])
        ring.discardAll()
        #expect(ring.availableCount == 0)
        ring.write([4])
        #expect(readAll(ring) == [4])
    }
}

@Suite("SampleFramer")
struct SampleFramerTests {
    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { Float($0) }
    }

    @Test("Produces overlapping frames every hop")
    func overlappingFrames() {
        var framer = SampleFramer(frameSize: 2048, hopSize: 512)
        framer.append(ramp(2048 + 512 * 3))
        var starts: [Float] = []
        var indices: [Int] = []
        framer.forEachFrame { frame, index in
            #expect(frame.count == 2048)
            starts.append(frame[0])
            indices.append(index)
            // Frames are contiguous slices of the input.
            #expect(frame[2047] == frame[0] + 2047)
        }
        #expect(starts == [0, 512, 1024, 1536])
        #expect(indices == [0, 1, 2, 3])
        #expect(framer.framesProduced == 4)
        // The next frame starts at 2048 and needs samples up to 4095.
        #expect(framer.bufferedSampleCount == 1536)
    }

    @Test("Chunk size doesn't change the frames")
    func chunkingIsTransparent() {
        let input = ramp(5000)
        var whole = SampleFramer(frameSize: 1024, hopSize: 256)
        whole.append(input)
        var expected: [Float] = []
        whole.forEachFrame { frame, _ in expected.append(frame[0]) }

        var chunked = SampleFramer(frameSize: 1024, hopSize: 256)
        var actual: [Float] = []
        var position = 0
        let chunkSizes = [1, 7, 256, 300, 13, 999]
        var chunkIndex = 0
        while position < input.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], input.count - position)
            chunked.append(Array(input[position ..< position + size]))
            chunked.forEachFrame { frame, _ in actual.append(frame[0]) }
            position += size
            chunkIndex += 1
        }
        #expect(actual == expected)
        #expect(!actual.isEmpty)
    }

    @Test("Nothing is produced until a full frame is buffered")
    func waitsForFullFrame() {
        var framer = SampleFramer(frameSize: 1024, hopSize: 256)
        framer.append(ramp(1023))
        var count = 0
        framer.forEachFrame { _, _ in count += 1 }
        #expect(count == 0)
        #expect(framer.bufferedSampleCount == 1023)
    }
}
