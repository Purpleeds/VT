import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer queue of audio samples.
///
/// The producer is the real-time audio thread (inside `AVAudioSinkNode`), which
/// must never lock, allocate, or wait. The consumer is the analysis task.
/// Indices only ever grow; `index & mask` maps them into the storage. Acquire/
/// release ordering on the indices makes each side see the other's writes.
///
/// Thread-safety contract (why `@unchecked Sendable` is sound): exactly one
/// thread calls `write` and exactly one thread at a time calls `read`/`discardAll`.
nonisolated final class SampleRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    init(minimumCapacity: Int) {
        var size = 2
        while size < minimumCapacity {
            size <<= 1
        }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Producer (real-time safe)

    /// Copies `count` samples into the queue, reading every `stride`-th value
    /// from `source` (stride 2 takes the left channel of interleaved stereo).
    /// If the consumer has fallen behind, the newest samples that don't fit are
    /// dropped and counted rather than overwriting unread audio.
    /// - Returns: The number of samples stored.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int, stride: Int = 1) -> Int {
        guard count > 0 else { return 0 }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacity - (write - read)
        let accepted = min(count, free)
        if accepted < count {
            _ = droppedSamples.wrappingAdd(count - accepted, ordering: .relaxed)
        }
        let step = max(1, stride)
        var sourceIndex = 0
        for offset in 0..<accepted {
            storage[(write + offset) & mask] = source[sourceIndex]
            sourceIndex += step
        }
        writeIndex.store(write + accepted, ordering: .releasing)
        return accepted
    }

    /// Convenience for tests and non-real-time callers.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return write(base, count: buffer.count)
        }
    }

    // MARK: Consumer

    /// Moves up to `destination.count` samples out of the queue.
    /// - Returns: The number of samples copied.
    func read(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = destination.baseAddress, !destination.isEmpty else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let count = min(write - read, destination.count)
        guard count > 0 else { return 0 }
        for offset in 0..<count {
            base[offset] = storage[(read + offset) & mask]
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }

    /// Drops everything currently queued (consumer side).
    func discardAll() {
        let write = writeIndex.load(ordering: .acquiring)
        readIndex.store(write, ordering: .releasing)
    }

    /// Samples waiting to be read.
    var availableCount: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    /// Total samples dropped because the consumer fell behind.
    var droppedSampleCount: Int {
        droppedSamples.load(ordering: .relaxed)
    }
}
