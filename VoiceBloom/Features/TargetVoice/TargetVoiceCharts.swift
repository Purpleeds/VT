import Charts
import Foundation
import SwiftUI

/// One voice's pitch histogram for `PitchHistogramChart`.
struct HistogramSeries: Identifiable {
    let name: String
    let histogram: [Double]
    let color: Color

    var id: String { name }
}

private struct HistogramPoint: Identifiable {
    let series: String
    let frequency: Double
    let percent: Double

    var id: String { "\(series)-\(frequency)" }
}

/// Pitch histograms (share of voiced time per semitone), one line per voice.
struct PitchHistogramChart: View {
    let series: [HistogramSeries]

    private var visibleBins: ClosedRange<Int>? {
        var used: [Int] = []
        for item in series {
            for (bin, share) in item.histogram.enumerated() where share > 0.002 {
                used.append(bin)
            }
        }
        guard let low = used.min(), let high = used.max() else { return nil }
        return max(0, low - 2)...min(TakeResult.histogramBinCount - 1, high + 2)
    }

    private var points: [HistogramPoint] {
        guard let bins = visibleBins else { return [] }
        return series.flatMap { item in
            bins.map { bin in
                let share = bin < item.histogram.count ? item.histogram[bin] : 0
                // The middle of the 1-semitone bin.
                let frequency = TakeResult.histogramFrequency(forBin: bin) * pow(2, 0.5 / 12)
                return HistogramPoint(series: item.name, frequency: frequency, percent: share * 100)
            }
        }
    }

    var body: some View {
        let points = points
        if points.isEmpty {
            Text("No pitch measured.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Chart(points) { point in
                LineMark(
                    x: .value("Pitch", point.frequency),
                    y: .value("Share of time", point.percent),
                    series: .value("Voice", point.series)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .foregroundStyle(by: .value("Voice", point.series))
                .accessibilityLabel("\(point.series), \(point.frequency.roundedInt) hertz")
                .accessibilityValue("\(point.percent.roundedInt) percent of the time")
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartXAxisLabel("Hz")
            .chartYAxisLabel("% of time")
            .chartLegend(series.count > 1 ? .visible : .hidden)
        }
    }
}

/// The main numbers of a voice: pitch, formants, weight and melody.
struct TargetStatsGrid: View {
    let snapshot: VoiceSnapshot
    let low: Double?
    let high: Double?
    let tilt: Double?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Average pitch", value: pitchText)
                StatTile(title: "Range", value: SessionFormat.range(low: low, high: high))
            }
            HStack(spacing: 12) {
                StatTile(title: "F1", value: hertz(snapshot.f1))
                StatTile(title: "F2", value: hertz(snapshot.f2))
                StatTile(title: "F3", value: hertz(snapshot.f3))
            }
            HStack(spacing: 12) {
                StatTile(title: "Weight", value: weightText)
                StatTile(title: "Intonation", value: intonationText)
            }
        }
    }

    private var pitchText: String {
        guard let pitch = snapshot.medianPitch else { return "—" }
        let note = PitchMath.noteName(for: pitch).map { " (\($0))" } ?? ""
        return "\(pitch.roundedInt) Hz\(note)"
    }

    private func hertz(_ value: Double?) -> String {
        value.map { "\($0.roundedInt) Hz" } ?? "—"
    }

    private var weightText: String {
        guard let h1MinusH2 = snapshot.h1MinusH2 else { return "—" }
        let score = WeightReference.standard.score(h1MinusH2: h1MinusH2, spectralTilt: tilt)
        let word = switch MeterZone(score: score) {
        case .high: "Light"
        case .middle: "Moderate"
        case .low: "Full"
        }
        return "\(word) (\(h1MinusH2.formatted(.number.precision(.fractionLength(1)))) dB)"
    }

    private var intonationText: String {
        guard let deviation = snapshot.intonationSD else { return "—" }
        let score = IntonationReference.standard.score(standardDeviationSemitones: deviation)
        let word = switch MeterZone(score: score) {
        case .high: "Melodic"
        case .middle: "Moderate"
        case .low: "Even"
        }
        return "\(word) (\(deviation.formatted(.number.precision(.fractionLength(1)))) st)"
    }
}
