import Foundation
import SwiftUI

/// Resonance, weight and intonation meters for the practice screen.
struct VoiceMetersCard: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Voice")
                    .font(.headline)
                Spacer()
                ResonanceModeMenu()
            }

            VoiceMeterRow(
                title: "Resonance",
                systemImage: "speaker.wave.2",
                lowLabel: "Dark",
                highLabel: "Bright",
                display: resonanceDisplay,
                emptyHint: monitor.resonanceMode.prompt
            )
            VoiceMeterRow(
                title: "Weight",
                systemImage: "scalemass",
                lowLabel: "Heavy",
                highLabel: "Light",
                display: weightDisplay,
                emptyHint: "Hold a vowel or talk"
            )
            VoiceMeterRow(
                title: "Intonation",
                systemImage: "music.note",
                lowLabel: "Flat",
                highLabel: "Melodic",
                display: intonationDisplay,
                emptyHint: "Say a sentence, then pause"
            )
        }
        .cardStyle()
    }

    private var resonanceDisplay: MeterDisplay? {
        guard let reading = monitor.resonance else { return nil }
        let f3Text = reading.f3.map { " · F3 \(Int($0.rounded())) Hz" } ?? ""
        let f3Spoken = reading.f3.map { ", F3 \(Int($0.rounded())) hertz" } ?? ""
        return MeterDisplay(
            score: reading.score,
            zone: MeterZone(score: reading.score).resonanceLabel,
            detail: "F2 \(Int(reading.f2.rounded())) Hz\(f3Text)",
            spokenDetail: "F2 \(Int(reading.f2.rounded())) hertz\(f3Spoken)",
            isLive: reading.isLive
        )
    }

    private var weightDisplay: MeterDisplay? {
        guard let reading = monitor.weight else { return nil }
        let h1h2 = reading.h1MinusH2.formatted(.number.precision(.fractionLength(1)))
        let tiltText = reading.spectralTilt.map {
            " · tilt \($0.formatted(.number.precision(.fractionLength(1)))) dB/oct"
        } ?? ""
        return MeterDisplay(
            score: reading.score,
            zone: MeterZone(score: reading.score).weightLabel,
            detail: "H1–H2 \(h1h2) dB\(tiltText)",
            spokenDetail: "H1 minus H2, \(h1h2) decibels",
            isLive: reading.isLive
        )
    }

    private var intonationDisplay: MeterDisplay? {
        guard let reading = monitor.intonation else { return nil }
        let phrase = reading.phrase
        let variability = phrase.standardDeviationSemitones.formatted(.number.precision(.fractionLength(1)))
        let rises = phrase.rises == 1 ? "1 rise" : "\(phrase.rises) rises"
        let falls = phrase.falls == 1 ? "1 fall" : "\(phrase.falls) falls"
        return MeterDisplay(
            score: reading.score,
            zone: MeterZone(score: reading.score).intonationLabel,
            detail: "Last phrase: ±\(variability) semitones · \(rises), \(falls)",
            spokenDetail: "Last phrase varied by \(variability) semitones, with \(rises) and \(falls)",
            isLive: reading.isRecent
        )
    }
}

/// Picks which vowel the resonance meter compares against.
private struct ResonanceModeMenu: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Menu {
            Picker("Resonance reference", selection: $monitor.resonanceMode) {
                ForEach(ResonanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } label: {
            Label(monitor.resonanceMode.shortTitle, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel("Resonance reference")
        .accessibilityValue(monitor.resonanceMode.title)
        .accessibilityHint("Choose speech, or the vowel you are holding, so resonance is judged fairly")
    }
}

/// What a meter row shows.
struct MeterDisplay: Equatable {
    let score: Double
    let zone: String
    let detail: String
    let spokenDetail: String
    let isLive: Bool
}

/// One labelled 0–100 meter with words at both ends, so meaning never
/// depends on color.
struct VoiceMeterRow: View {
    let title: String
    let systemImage: String
    let lowLabel: String
    let highLabel: String
    let display: MeterDisplay?
    let emptyHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let display {
                    Text(display.zone)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(Int(display.score.rounded()))")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            MeterBar(fraction: (display?.score ?? 0) / 100)
                .frame(height: 12)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(display?.detail ?? emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .opacity(display?.isLive == false ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let display else { return "No reading yet. \(emptyHint)." }
        let freshness = display.isLive ? "" : " Last reading."
        return "\(Int(display.score.rounded())) out of 100, \(display.zone).\(freshness) \(display.spokenDetail)."
    }
}

extension MeterZone {
    var resonanceLabel: String {
        switch self {
        case .low: "Dark"
        case .middle: "Medium"
        case .high: "Bright"
        }
    }

    var weightLabel: String {
        switch self {
        case .low: "Heavy"
        case .middle: "Medium"
        case .high: "Light"
        }
    }

    var intonationLabel: String {
        switch self {
        case .low: "Flat"
        case .middle: "Some melody"
        case .high: "Melodic"
        }
    }
}
