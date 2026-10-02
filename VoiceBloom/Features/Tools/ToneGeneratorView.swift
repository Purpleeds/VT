import Foundation
import SwiftUI

/// Reference tone generator and two-octave mini piano (SPEC section 8):
/// hear any note as a steady tone, or tap keys to hear notes.
struct ToneGeneratorView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var tones = TonePlayer()
    @State private var frequency = 200.0
    @State private var sliderValue = ToneGeneratorMath.sliderValue(for: 200)
    @State private var timbre: ToneTimbre = .pure
    @State private var headphonesConnected = false
    @State private var didLoad = false
    @State private var pausedListening = false

    private var target: PitchTargetZone { monitor.targetZone }
    private var isDroneOn: Bool { tones.droneFrequency != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toneCard
                pianoCard
                if tones.isHeadphonesOnly {
                    NoticeBanner(
                        title: "Discreet Mode is on",
                        message: headphonesConnected
                            ? "Tones play through your headphones only."
                            : "Connect headphones to hear tones. They won’t play through the speaker.",
                        systemImage: "headphones",
                        tint: headphonesConnected ? Theme.targetZone : Theme.warning
                    )
                }
                if let message = tones.errorMessage, !tones.isHeadphonesOnly || headphonesConnected {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                }
                if pausedListening {
                    Label("Listening is paused so the microphone doesn’t mistake the tone for your voice. Resume on the Practice tab.", systemImage: "pause.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Tone Generator")
        .navigationBarTitleDisplayMode(.inline)
        .tracksHeadphones($headphonesConnected)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            setFrequency(ToneGeneratorMath.clamp(target.center))
        }
        .onDisappear {
            tones.stop()
        }
        .onChange(of: sliderValue) { _, newValue in
            let newFrequency = ToneGeneratorMath.frequency(forSliderValue: newValue)
            guard abs(newFrequency - frequency) > 0.01 else { return }
            frequency = newFrequency
            retuneDrone()
        }
        .onChange(of: timbre) { _, _ in
            retuneDrone()
        }
    }

    // MARK: Steady tone

    private var toneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(frequency.rounded())) Hz")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    Text(noteDescription)
                        .font(.headline)
                    Text(target.contains(frequency) ? "In your target" : "Target \(target.formatted)")
                        .font(.caption)
                        .foregroundStyle(target.contains(frequency) ? Theme.targetZone : Color.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tone")
            .accessibilityValue("\(Int(frequency.rounded())) hertz, \(PitchMath.spokenNoteName(for: frequency) ?? "")\(target.contains(frequency) ? ", in your target" : "")")

            Slider(value: $sliderValue, in: 0...1) {
                Text("Frequency")
            } minimumValueLabel: {
                Text("\(Int(ToneGeneratorMath.range.lowerBound))")
                    .font(.caption2)
            } maximumValueLabel: {
                Text("\(Int(ToneGeneratorMath.range.upperBound))")
                    .font(.caption2)
            }
            .accessibilityValue("\(Int(frequency.rounded())) hertz")

            HStack(spacing: 10) {
                Button {
                    setFrequency(ToneGeneratorMath.step(frequency, semitones: -1))
                    retuneDrone()
                } label: {
                    Label("Lower", systemImage: "chevron.down")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("One semitone lower")
                Button {
                    setFrequency(ToneGeneratorMath.step(frequency, semitones: 1))
                    retuneDrone()
                } label: {
                    Label("Higher", systemImage: "chevron.up")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("One semitone higher")
            }
            .buttonStyle(.glass)

            VStack(alignment: .leading, spacing: 6) {
                Text("Your target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(ToneGeneratorMath.presets(for: target)) { preset in
                            FilterChip(
                                title: "\(preset.title) \(Int(preset.frequency.rounded()))",
                                systemImage: "scope",
                                isSelected: abs(frequency - preset.frequency) < 0.5
                            ) {
                                setFrequency(preset.frequency)
                                retuneDrone()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Picker("Sound", selection: $timbre) {
                ForEach(ToneTimbre.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button {
                    Task { await toggleDrone() }
                } label: {
                    Label(isDroneOn ? "Stop" : "Play steady tone", systemImage: isDroneOn ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button {
                    Task { await playNote(frequency) }
                } label: {
                    Label("Note", systemImage: "music.note")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Play once as a note")
            }
            .controlSize(.large)

            Text("Hum or say “mmm” on the tone, then speak a word starting from it. Matching a note gets easier with practice.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var noteDescription: String {
        guard let name = PitchMath.noteName(for: frequency),
              let cents = PitchMath.centsFromNearestNote(for: frequency)
        else { return "" }
        let rounded = Int(cents.rounded())
        return rounded == 0 ? name : "\(name) \(rounded > 0 ? "+" : "−")\(abs(rounded))¢"
    }

    // MARK: Piano

    private var pianoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mini piano")
                    .font(.headline)
                Spacer()
                if let note = tones.lastNote, let name = PitchMath.noteName(for: note) {
                    Text("\(name) · \(Int(note.rounded())) Hz")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            MiniPianoView(target: target, highlighted: tones.lastNote) { key in
                Task { await playNote(key.frequency, updatesTone: true) }
            }
            Label("Keys with a dot are inside your target range.", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(PianoLegendLabelStyle())
        }
        .cardStyle()
    }

    // MARK: Actions

    private func setFrequency(_ value: Double) {
        frequency = ToneGeneratorMath.clamp(value)
        sliderValue = ToneGeneratorMath.sliderValue(for: frequency)
    }

    /// Keeps a playing drone on the chosen frequency and sound.
    private func retuneDrone() {
        guard isDroneOn else { return }
        tones.startDrone(frequency, timbre: timbre)
    }

    private func toggleDrone() async {
        if isDroneOn {
            tones.stopDrone()
        } else {
            await pauseListeningIfNeeded()
            tones.startDrone(frequency, timbre: timbre)
        }
    }

    private func playNote(_ value: Double, updatesTone: Bool = false) async {
        await pauseListeningIfNeeded()
        if updatesTone {
            setFrequency(value)
        }
        tones.playNote(value, timbre: .warm)
    }

    /// The microphone would hear the tone through the speaker and count it
    /// as practice, so listening pauses first.
    private func pauseListeningIfNeeded() async {
        guard monitor.status.isRunning else { return }
        await monitor.pause(.user)
        pausedListening = true
    }
}

/// Two octaves of piano keys, C3 to C5, scrolled to middle C.
struct MiniPianoView: View {
    let target: PitchTargetZone
    /// The note playing (or last played), to light its key.
    let highlighted: Double?
    let onPlay: (PianoKey) -> Void

    @ScaledMetric(relativeTo: .body) private var whiteWidth: CGFloat = 42
    private let layout = PianoLayout(keys: PianoKey.range)
    private let height: CGFloat = 150

    private var blackWidth: CGFloat { whiteWidth * 0.62 }

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(layout.whiteKeys) { key in
                        whiteKey(key)
                    }
                }
                ForEach(layout.blackKeys) { key in
                    blackKey(key)
                        .offset(x: CGFloat(layout.offset(of: key)) * whiteWidth - blackWidth / 2)
                }
            }
            .frame(width: CGFloat(layout.whiteKeys.count) * whiteWidth, height: height, alignment: .topLeading)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini piano")
    }

    private func isLit(_ key: PianoKey) -> Bool {
        guard let highlighted else { return false }
        return abs(PitchMath.midiNote(for: highlighted) - Double(key.midiNote)) < 0.5
    }

    private func whiteKey(_ key: PianoKey) -> some View {
        Button {
            onPlay(key)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isLit(key) ? Theme.pitchLine.opacity(0.35) : Color(white: 0.97))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                VStack(spacing: 4) {
                    if target.contains(key.frequency) {
                        Circle()
                            .fill(Theme.targetZone)
                            .frame(width: 8, height: 8)
                    }
                    Text(key.midiNote % 12 == 0 ? key.name : " ")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.6))
                }
                .padding(.bottom, 8)
            }
            .frame(width: whiteWidth, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key.spokenName), \(Int(key.frequency.rounded())) hertz")
        .accessibilityValue(target.contains(key.frequency) ? "In your target range" : "")
        .accessibilityAddTraits(.playsSound)
    }

    private func blackKey(_ key: PianoKey) -> some View {
        Button {
            onPlay(key)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isLit(key) ? Theme.pitchLine : Color(white: 0.12))
                if target.contains(key.frequency) {
                    Circle()
                        .fill(Theme.targetZone)
                        .frame(width: 7, height: 7)
                        .padding(.bottom, 8)
                }
            }
            .frame(width: blackWidth, height: height * 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key.spokenName), \(Int(key.frequency.rounded())) hertz")
        .accessibilityValue(target.contains(key.frequency) ? "In your target range" : "")
        .accessibilityAddTraits(.playsSound)
    }
}

/// A small green dot before the legend text.
private struct PianoLegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(Theme.targetZone)
            configuration.title
        }
    }
}
