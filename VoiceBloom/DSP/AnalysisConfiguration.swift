import Foundation

/// Frame sizes and search limits shared by the live analysis pipeline.
///
/// The spec calls for 2048-sample frames with a 512-sample hop at 48 kHz
/// (~43 ms of audio per frame, a new result every ~10.7 ms). If the hardware
/// runs at a different rate (44.1 kHz on some routes, 16/24 kHz on Bluetooth),
/// the sizes are scaled so the frame and hop keep roughly the same duration.
nonisolated struct AnalysisConfiguration: Sendable, Equatable {
    static let referenceSampleRate: Double = 48_000
    static let referenceFrameSize = 2048
    static let referenceHopSize = 512

    /// Samples per second of the incoming audio.
    let sampleRate: Double
    /// Number of samples analyzed per frame (always a power of two).
    let frameSize: Int
    /// Number of samples between the starts of consecutive frames.
    let hopSize: Int
    /// Lowest fundamental frequency the pitch search will report (Hz).
    let minimumFrequency: Double
    /// Highest fundamental frequency the pitch search will report (Hz).
    let maximumFrequency: Double
    /// YIN absolute threshold: a lag is accepted as the period once its
    /// normalized difference drops below this value.
    let yinThreshold: Double

    init(
        sampleRate: Double = AnalysisConfiguration.referenceSampleRate,
        minimumFrequency: Double = 60,
        maximumFrequency: Double = 500,
        yinThreshold: Double = 0.12
    ) {
        let rate = max(sampleRate, 8_000)
        let lowest = max(minimumFrequency, 20)
        self.sampleRate = rate
        self.minimumFrequency = lowest
        self.maximumFrequency = max(maximumFrequency, lowest * 2)
        self.yinThreshold = yinThreshold

        // Keep the frame duration close to 2048 samples at 48 kHz, but make sure
        // half a frame (YIN's integration window) is longer than the longest
        // period we search for, plus a little headroom for interpolation.
        let scale = rate / Self.referenceSampleRate
        let scaledFrame = Int((Double(Self.referenceFrameSize) * scale).rounded())
        let longestPeriod = Int((rate / lowest).rounded(.up))
        let minimumFrame = 2 * (longestPeriod + 4)
        self.frameSize = Self.nextPowerOfTwo(max(scaledFrame, minimumFrame))

        let scaledHop = Int((Double(Self.referenceHopSize) * scale).rounded())
        self.hopSize = min(max(1, scaledHop), frameSize)
    }

    /// Seconds between consecutive analysis frames.
    var hopDuration: Double { Double(hopSize) / sampleRate }

    /// Seconds of audio covered by one analysis frame.
    var frameDuration: Double { Double(frameSize) / sampleRate }

    /// Number of analysis frames produced per second of audio.
    var framesPerSecond: Double { sampleRate / Double(hopSize) }

    static func nextPowerOfTwo(_ value: Int) -> Int {
        var power = 1
        while power < value {
            power <<= 1
        }
        return power
    }
}
