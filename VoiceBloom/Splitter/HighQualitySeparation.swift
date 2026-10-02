import CoreML
import Foundation

// MARK: - Model-agnostic engine

/// Something that estimates the vocal magnitude spectrogram of a stereo mix.
/// Arrays are channel-major: index = (channel × bins + bin) × frames + frame,
/// matching the model's (1, 2, bins, frames) input.
nonisolated protocol MagnitudePredictor: AnyObject {
    var bins: Int { get }
    var frames: Int { get }
    func predictVocals(_ magnitude: [Float]) throws -> [Float]
}

/// The High Quality engine (SPEC section 23.1): a source-separation network
/// predicts the vocals' magnitude spectrogram; we turn that into a soft
/// mask, apply it to the mix, and take the backing as mix − vocals (so the
/// parts always add back up to the original).
///
/// Works with any model that takes and returns (1, 2, 2049, frames)
/// magnitude spectrograms at 44.1 kHz with a 4096-point FFT and 1024 hop,
/// like Open-Unmix (see tools/convert_separator.py).
nonisolated final class SpectrogramMaskEngine: SeparationService {
    static let sampleRate = 44_100.0
    static let fftSize = 4096
    static let hopSize = 1024

    let kind = SeparationEngineKind.highQuality
    let overlapDuration = 1.0
    private let predictor: any MagnitudePredictor
    private let bestPredictor: (any MagnitudePredictor)?
    private let transform: SpectralTransform

    /// Samples per chunk: exactly the model's frame count.
    let chunkSamples: Int
    var chunkDuration: Double { Double(chunkSamples) / Self.sampleRate }

    init(predictor: any MagnitudePredictor, bestPredictor: (any MagnitudePredictor)? = nil) throws {
        guard let transform = SpectralTransform(fftSize: Self.fftSize, hopSize: Self.hopSize),
              predictor.bins == transform.binCount, predictor.frames > 1
        else { throw HighQualityEngineError.unexpectedModel }
        if let bestPredictor, bestPredictor.bins != predictor.bins || bestPredictor.frames != predictor.frames {
            throw HighQualityEngineError.unexpectedModel
        }
        self.predictor = predictor
        self.bestPredictor = bestPredictor
        self.transform = transform
        // A centred STFT of (frames − 1) × hop samples has exactly `frames` frames.
        chunkSamples = (predictor.frames - 1) * Self.hopSize
    }

    func separate(_ chunk: StereoBuffer, sampleRate: Double, quality: SeparationQuality) throws -> StemPair {
        guard !chunk.isEmpty else { return StemPair(vocals: .empty, backing: .empty) }
        guard abs(sampleRate - Self.sampleRate) < 1 else { throw HighQualityEngineError.wrongSampleRate }
        let length = min(chunk.count, chunkSamples)
        // The last chunk is padded with silence to the model's fixed size.
        var input = chunk.prefix(chunkSamples)
        if input.count < chunkSamples {
            let padding = [Float](repeating: 0, count: chunkSamples - input.count)
            input.append(StereoBuffer(left: padding, right: padding))
        }

        var left = transform.forward(input.left)
        var right = transform.forward(input.right)
        guard left.frames == predictor.frames else { throw HighQualityEngineError.unexpectedModel }
        let magnitude = Self.layout(left, right)

        var vocals = try predictor.predictVocals(magnitude)
        if quality == .best {
            if let bestPredictor {
                // A larger model, when one is installed.
                vocals = try bestPredictor.predictVocals(magnitude)
            } else {
                // A second pass with left and right swapped, averaged with
                // the first: the network sees the mix from both sides.
                let swapped = Self.swapChannels(magnitude, bins: predictor.bins, frames: predictor.frames)
                let second = Self.swapChannels(try predictor.predictVocals(swapped), bins: predictor.bins, frames: predictor.frames)
                vocals = zip(vocals, second).map { ($0 + $1) / 2 }
            }
        }
        guard vocals.count == magnitude.count else { throw HighQualityEngineError.unexpectedModel }

        Self.applyMask(to: &left, channel: 0, mixture: magnitude, vocals: vocals, frames: predictor.frames)
        Self.applyMask(to: &right, channel: 1, mixture: magnitude, vocals: vocals, frames: predictor.frames)
        let vocalsLeft = Array(transform.inverse(left, length: chunkSamples).prefix(length))
        let vocalsRight = Array(transform.inverse(right, length: chunkSamples).prefix(length))
        let original = chunk.prefix(length)
        return StemPair(
            vocals: StereoBuffer(left: vocalsLeft, right: vocalsRight),
            backing: StereoBuffer(
                left: zip(original.left, vocalsLeft).map { $0 - $1 },
                right: zip(original.right, vocalsRight).map { $0 - $1 }
            )
        )
    }

    // MARK: Pure helpers (tested)

    /// Magnitudes in the model's channel-major layout.
    static func layout(_ left: SpectralTransform.Spectrum, _ right: SpectralTransform.Spectrum) -> [Float] {
        let bins = left.bins
        let frames = left.frames
        var result = [Float](repeating: 0, count: 2 * bins * frames)
        for (channel, spectrum) in [left, right].enumerated() {
            for frame in 0..<frames {
                for bin in 0..<bins {
                    let source = frame * bins + bin
                    result[(channel * bins + bin) * frames + frame] = hypot(spectrum.real[source], spectrum.imag[source])
                }
            }
        }
        return result
    }

    static func swapChannels(_ values: [Float], bins: Int, frames: Int) -> [Float] {
        let half = bins * frames
        guard values.count == 2 * half else { return values }
        return Array(values[half...]) + Array(values[..<half])
    }

    /// Soft vocal mask v² / (v² + r²), where r = max(mix − v, 0) is what's left
    /// for the backing.
    static func vocalMask(mixture: Float, vocals: Float) -> Float {
        let voice = max(vocals, 0)
        let rest = max(mixture - voice, 0)
        let voicePower = voice * voice
        return voicePower / (voicePower + rest * rest + 1e-12)
    }

    static func applyMask(to spectrum: inout SpectralTransform.Spectrum, channel: Int, mixture: [Float], vocals: [Float], frames: Int) {
        let bins = spectrum.bins
        for frame in 0..<spectrum.frames {
            for bin in 0..<bins {
                let modelIndex = (channel * bins + bin) * frames + frame
                let mask = vocalMask(mixture: mixture[modelIndex], vocals: vocals[modelIndex])
                let index = frame * bins + bin
                spectrum.real[index] *= mask
                spectrum.imag[index] *= mask
            }
        }
    }
}

nonisolated enum HighQualityEngineError: LocalizedError, Equatable, Sendable {
    case modelMissing
    case unexpectedModel
    case cannotLoad
    case wrongSampleRate
    case predictionFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            "The High Quality model isn’t installed in this build, so the Basic engine was used. See README › Vocal splitter to add it."
        case .unexpectedModel:
            "The installed High Quality model has an unexpected shape, so the Basic engine was used. Convert it again with tools/convert_separator.py."
        case .cannotLoad:
            "This iPhone couldn’t load the High Quality model, so the Basic engine was used."
        case .wrongSampleRate:
            "The High Quality engine needs 44.1 kHz audio."
        case .predictionFailed:
            "The High Quality model stopped with an error."
        }
    }
}

// MARK: - Core ML

/// Runs the converted model with Core ML on the Neural Engine and GPU
/// (`MLComputeUnits.all`), dropping to the CPU if that fails.
nonisolated final class CoreMLMagnitudePredictor: MagnitudePredictor {
    static let inputName = "magnitude"
    static let outputName = "vocals"

    let bins: Int
    let frames: Int
    private let url: URL
    private var model: MLModel
    private var usesCPUOnly = false
    private let shape: [NSNumber]

    init(url: URL) throws {
        self.url = url
        let loaded = try Self.load(url, computeUnits: .all)
        guard let constraint = loaded.modelDescription.inputDescriptionsByName[Self.inputName]?.multiArrayConstraint,
              loaded.modelDescription.outputDescriptionsByName[Self.outputName] != nil
        else { throw HighQualityEngineError.unexpectedModel }
        let dimensions = constraint.shape.map { $0.intValue }
        guard let parsed = Self.parseShape(dimensions) else { throw HighQualityEngineError.unexpectedModel }
        bins = parsed.bins
        frames = parsed.frames
        shape = constraint.shape
        model = loaded
    }

    /// (1, 2, bins, frames) → bins and frames.
    static func parseShape(_ dimensions: [Int]) -> (bins: Int, frames: Int)? {
        guard dimensions.count == 4, dimensions[0] == 1, dimensions[1] == 2, dimensions[2] > 1, dimensions[3] > 1 else { return nil }
        return (dimensions[2], dimensions[3])
    }

    private static func load(_ url: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw HighQualityEngineError.cannotLoad
        }
    }

    func predictVocals(_ magnitude: [Float]) throws -> [Float] {
        do {
            return try predict(magnitude)
        } catch {
            // Some devices can't run every layer on the Neural Engine or GPU.
            guard !usesCPUOnly else { throw HighQualityEngineError.predictionFailed }
            model = try Self.load(url, computeUnits: .cpuOnly)
            usesCPUOnly = true
            do {
                return try predict(magnitude)
            } catch {
                throw HighQualityEngineError.predictionFailed
            }
        }
    }

    private func predict(_ magnitude: [Float]) throws -> [Float] {
        guard magnitude.count == 2 * bins * frames else { throw HighQualityEngineError.unexpectedModel }
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        let bins = bins
        let frames = frames
        magnitude.withUnsafeBufferPointer { source in
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { destination, strides in
                for channel in 0..<2 {
                    for bin in 0..<bins {
                        for frame in 0..<frames {
                            destination[channel * strides[1] + bin * strides[2] + frame * strides[3]] = source[(channel * bins + bin) * frames + frame]
                        }
                    }
                }
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: features)
        guard let output = result.featureValue(for: Self.outputName)?.multiArrayValue,
              output.shape.map({ $0.intValue }) == shape.map({ $0.intValue })
        else { throw HighQualityEngineError.unexpectedModel }

        let strides = output.strides.map { $0.intValue }
        var vocals = [Float](repeating: 0, count: magnitude.count)
        if output.dataType == .float32 {
            output.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for channel in 0..<2 {
                    for bin in 0..<bins {
                        for frame in 0..<frames {
                            vocals[(channel * bins + bin) * frames + frame] = buffer[channel * strides[1] + bin * strides[2] + frame * strides[3]]
                        }
                    }
                }
            }
        } else {
            // Other output types (e.g. float16): slower, but works everywhere.
            for channel in 0..<2 {
                for bin in 0..<bins {
                    for frame in 0..<frames {
                        let key = [0, channel, bin, frame].map { NSNumber(value: $0) }
                        vocals[(channel * bins + bin) * frames + frame] = output[key].floatValue
                    }
                }
            }
        }
        return vocals
    }
}

/// Finds and loads the bundled model.
nonisolated enum CoreMLSeparationEngine {
    /// `VocalSeparator.mlmodelc` in the app bundle (Xcode compiles a dropped-in
    /// .mlpackage to this; the GitHub build compiles Models/VocalSeparator.mlpackage).
    static let modelName = "VocalSeparator"
    /// An optional larger model used for Best quality.
    static let bestModelName = "VocalSeparatorBest"

    static func modelURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    static var isModelInstalled: Bool {
        modelURL(modelName) != nil
    }

    static func make() throws -> SpectrogramMaskEngine {
        guard let url = modelURL(modelName) else { throw HighQualityEngineError.modelMissing }
        let predictor = try CoreMLMagnitudePredictor(url: url)
        let best = modelURL(bestModelName).flatMap { try? CoreMLMagnitudePredictor(url: $0) }
        return try SpectrogramMaskEngine(predictor: predictor, bestPredictor: best)
    }
}
