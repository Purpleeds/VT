import Foundation

/// Tuning values for turning raw per-frame pitch estimates into a steady contour.
nonisolated struct PitchTrackerConfiguration: Sendable, Equatable {
    /// Number of recent frames the median filter looks at.
    var medianWindowSize = 5
    /// Time constant (seconds) of the exponential smoothing used for display.
    var smoothingTimeConstant = 0.03
    /// A frame-to-frame change larger than this (in semitones) is treated as a
    /// suspected octave error. A real voice can't move 9 semitones in ~10 ms,
    /// but YIN occasionally locks onto double or half the true pitch.
    var jumpThresholdSemitones = 9.0
    /// A suspected jump is only believed after this many consecutive frames agree.
    var jumpConfirmationFrames = 3
    /// How closely (semitones) consecutive jump frames must agree with each other.
    var jumpAgreementSemitones = 1.5
    /// After this many unvoiced frames in a row, the contour starts fresh
    /// (the next syllable is not compared against the previous one).
    var resetAfterUnvoicedFrames = 5
}

nonisolated enum TrackedPitchStatus: Sendable, Equatable {
    /// A pitch that passed all checks.
    case voiced
    /// No pitch this frame (silence, noise, or YIN found no period).
    case unvoiced
    /// A sudden doubling/halving that hasn't lasted long enough to be trusted.
    case octaveJumpHeld
}

nonisolated struct TrackedPitch: Sendable, Equatable {
    let status: TrackedPitchStatus
    /// Median-filtered pitch (Hz). Used for statistics. Nil unless `.voiced`.
    let filteredFrequency: Double?
    /// Median-filtered then exponentially smoothed pitch (Hz), for the UI.
    /// While a jump is being held, this repeats the last displayed value.
    let displayFrequency: Double?
}

/// Post-processes raw YIN estimates:
/// 1. rejects sudden octave jumps unless they last for 3+ frames,
/// 2. applies a 5-frame median filter to remove single-frame glitches,
/// 3. applies exponential smoothing so the display moves fluidly.
nonisolated struct PitchTracker: Sendable {
    let configuration: PitchTrackerConfiguration
    /// Per-frame weight of the newest value in the exponential smoother (0...1).
    let smoothingFactor: Double

    private var window: [Double] = []
    private var jumpCandidates: [Double] = []
    private var reference: Double?
    private var smoothed: Double?
    private var unvoicedRun = 0

    /// - Parameter frameInterval: Seconds between frames (the hop duration).
    init(frameInterval: Double, configuration: PitchTrackerConfiguration = PitchTrackerConfiguration()) {
        self.configuration = configuration
        // Convert the smoothing time constant into a per-frame factor so the
        // feel of the display doesn't depend on the sample rate or hop size.
        if configuration.smoothingTimeConstant > 0, frameInterval > 0 {
            smoothingFactor = 1 - exp(-frameInterval / configuration.smoothingTimeConstant)
        } else {
            smoothingFactor = 1
        }
    }

    /// Forgets all history, e.g. when the user restarts a session.
    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        jumpCandidates.removeAll(keepingCapacity: true)
        reference = nil
        smoothed = nil
        unvoicedRun = 0
    }

    /// Feeds one frame's raw estimate (nil when unvoiced) and returns the cleaned-up pitch.
    mutating func process(_ rawFrequency: Double?) -> TrackedPitch {
        guard let frequency = rawFrequency, frequency.isFinite, frequency > 0 else {
            return processUnvoicedFrame()
        }
        unvoicedRun = 0

        if let reference, abs(PitchMath.semitones(from: reference, to: frequency)) > configuration.jumpThresholdSemitones {
            // Suspected octave error: collect agreeing frames before believing it.
            if let last = jumpCandidates.last,
               abs(PitchMath.semitones(from: last, to: frequency)) <= configuration.jumpAgreementSemitones {
                jumpCandidates.append(frequency)
            } else {
                jumpCandidates = [frequency]
            }

            guard jumpCandidates.count >= configuration.jumpConfirmationFrames else {
                return TrackedPitch(status: .octaveJumpHeld, filteredFrequency: nil, displayFrequency: smoothed)
            }

            // The jump held for long enough, so the voice really moved (e.g. a
            // yodel or a flip into a new register). Restart the filters from the
            // confirmed frames so old values don't drag the median back.
            window = Array(jumpCandidates.suffix(max(1, configuration.medianWindowSize)))
            smoothed = nil
            jumpCandidates.removeAll(keepingCapacity: true)
        } else {
            jumpCandidates.removeAll(keepingCapacity: true)
            window.append(frequency)
            let overflow = window.count - max(1, configuration.medianWindowSize)
            if overflow > 0 {
                window.removeFirst(overflow)
            }
        }

        let median = PitchMath.median(of: window) ?? frequency
        reference = median

        let display: Double
        if let previous = smoothed {
            display = previous + smoothingFactor * (median - previous)
        } else {
            display = median
        }
        smoothed = display

        return TrackedPitch(status: .voiced, filteredFrequency: median, displayFrequency: display)
    }

    private mutating func processUnvoicedFrame() -> TrackedPitch {
        unvoicedRun += 1
        jumpCandidates.removeAll(keepingCapacity: true)
        if unvoicedRun >= configuration.resetAfterUnvoicedFrames {
            window.removeAll(keepingCapacity: true)
            reference = nil
            smoothed = nil
        }
        return TrackedPitch(status: .unvoiced, filteredFrequency: nil, displayFrequency: nil)
    }
}
