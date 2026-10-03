import Foundation
import SwiftData
import SwiftUI

/// A game to present full screen.
struct PitchTrackGameLaunch: Identifiable {
    let id = UUID()
    let setup: PitchTrackGameSetup
    let isSimulated: Bool
}

/// A track's settings and the Play button (SPEC section 22.1: track settings
/// editable before playing).
struct PitchTrackDetailView: View {
    let reference: PitchTrackReference

    var body: some View {
        switch reference {
        case .saved(let id):
            SavedPitchTrackDetail(id: id)
        case .builtIn(let track):
            BuiltInPitchTrackDetail(track: track)
        }
    }
}

private struct SavedPitchTrackDetail: View {
    let id: UUID
    @Environment(\.modelContext) private var modelContext
    @Query private var tracks: [PitchTrack]

    init(id: UUID) {
        self.id = id
        let wanted = id
        _tracks = Query(filter: #Predicate<PitchTrack> { $0.id == wanted })
    }

    var body: some View {
        if let track = tracks.first {
            PitchTrackSettingsScreen(
                trackID: track.id,
                title: track.name,
                content: PitchTrackStore.content(of: track),
                initialSettings: PitchTrackStore.settings(of: track),
                sources: PitchTrackStore(context: modelContext).audioSources(for: track),
                savedTrack: track,
                builtIn: nil
            )
        } else {
            ContentUnavailableView("Track not found", systemImage: "questionmark.circle", description: Text("It may have been deleted."))
        }
    }
}

private struct BuiltInPitchTrackDetail: View {
    let track: BuiltInTrack
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    var body: some View {
        let target = profiles.first?.targetZone ?? monitor.targetZone
        let references = profiles.first?.personalReferences ?? monitor.personalReferences
        PitchTrackSettingsScreen(
            trackID: track.trackID,
            title: track.title,
            content: track.content(target: target, references: references),
            initialSettings: BuiltInTrackSettingsStore.load(track),
            sources: .none,
            savedTrack: nil,
            builtIn: track
        )
        .id("\(target.lowerBound)-\(target.upperBound)")
    }
}

private struct PitchTrackSettingsScreen: View {
    let trackID: UUID
    let title: String
    let content: PitchTrackContent
    let sources: TrackAudioSources
    let savedTrack: PitchTrack?
    let builtIn: BuiltInTrack?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @AppStorage(PitchTrackGameModel.perfectHapticKey) private var perfectHaptic = true

    @State private var settings: TrackSettings
    @State private var loopEnabled: Bool
    @State private var loopSelection: TrimSelection
    @State private var name: String
    @State private var comfort: ClosedRange<Double>?
    @State private var launch: PitchTrackGameLaunch?
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    init(
        trackID: UUID,
        title: String,
        content: PitchTrackContent,
        initialSettings: TrackSettings,
        sources: TrackAudioSources,
        savedTrack: PitchTrack?,
        builtIn: BuiltInTrack?
    ) {
        self.trackID = trackID
        self.title = title
        self.content = content
        self.sources = sources
        self.savedTrack = savedTrack
        self.builtIn = builtIn
        var settings = initialSettings
        // A mode whose files are gone falls back to guide tones.
        let available = sources.availableModes
        if !available.contains(settings.audioMode) {
            settings.audioMode = available.contains(.original) ? .original : .guideTones
        }
        _settings = State(initialValue: settings)
        _loopEnabled = State(initialValue: settings.loop != nil)
        let duration = max(content.duration, 0.1)
        _loopSelection = State(initialValue: TrimSelection(
            clipDuration: duration,
            start: settings.loop?.start ?? 0,
            end: settings.loop?.end ?? min(duration, 8)
        ))
        _name = State(initialValue: title)
    }

    private var transposedRange: ClosedRange<Double>? {
        content.range.map { ($0.lowerBound + Double(settings.transpose))...($0.upperBound + Double(settings.transpose)) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    PitchTrackPreview(bars: content.playableBars(transpose: settings.transpose, range: settings.playRange(trackDuration: content.duration)))
                        .frame(height: 110)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        play()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(content.bars.isEmpty)
                    if PitchTrackDebug.simulatesPerfectVoice {
                        Label("Debug: a simulated perfect voice will play this track.", systemImage: "ladybug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let savedTrack {
                savedSection(savedTrack)
            }

            Section {
                Stepper(
                    "Transpose: \(transposeText)",
                    onIncrement: { settings.setTranspose(settings.transpose + 1) },
                    onDecrement: { settings.setTranspose(settings.transpose - 1) }
                )
                .accessibilityValue(transposeText)
                if let range = transposedRange {
                    LabeledContent("Range", value: TrackRange.label(range))
                }
                if let comfort, let range = content.range {
                    Button("Auto-Fit to My Range") {
                        settings.setTranspose(TrackRange.bestFit(range, comfort: comfort))
                    }
                    if let suggestion = TrackRange.suggestion(range, comfort: comfort, current: settings.transpose) {
                        Text(rangeAdvice(suggestion: suggestion, track: range, comfort: comfort))
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Pitch")
            } footer: {
                if let comfort {
                    Text("Your comfortable range from your practice history: \(TrackRange.label(comfort)).")
                }
            }

            Section {
                Stepper(
                    "Speed: \((settings.speed * 100).roundedInt)%",
                    onIncrement: { settings.setSpeed(settings.speed + TrackSettings.speedStep) },
                    onDecrement: { settings.setSpeed(settings.speed - TrackSettings.speedStep) }
                )
                Picker("Difficulty", selection: $settings.difficulty) {
                    ForEach(TrackDifficulty.allCases) { difficulty in
                        Text(difficulty.title).tag(difficulty)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Score resonance and weight", isOn: $settings.scoresResonanceAndWeight)
            } header: {
                Text("Play")
            } footer: {
                Text("\(settings.difficulty.detail): how close counts as on the note. Slower speeds keep the pitch the same.")
            }

            Section {
                Picker("Sound", selection: $settings.audioMode) {
                    ForEach(sources.availableModes) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Sound while playing")
            } footer: {
                Text("Use headphones for anything but Silent, so the microphone hears only you.")
            }

            Section {
                Toggle("Loop a section", isOn: $loopEnabled)
                if loopEnabled {
                    WaveformTrimView(peaks: barPeaks, selection: $loopSelection)
                        .frame(height: 80)
                    Text("\(SessionTime.clock(loopSelection.start)) – \(SessionTime.clock(loopSelection.end)) repeats until you stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Loop")
            }

            Section {
                Toggle("Tap on perfect notes", isOn: $perfectHaptic)
            } header: {
                Text("Feedback")
            } footer: {
                Text("A light vibration when you nail a note. Pitch Track never sounds slip alerts.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            comfort = loadComfortRange()
        }
        .onChange(of: settings) { _, newValue in
            persist(newValue)
        }
        .onChange(of: loopEnabled) { _, _ in
            updateLoop()
        }
        .onChange(of: loopSelection) { _, _ in
            updateLoop()
        }
        .fullScreenCover(item: $launch, onDismiss: {
            if !(PitchTrackDebug.simulatesPerfectVoice) {
                Task { _ = await sessionController.endGuidedSession() }
            }
        }) { launch in
            PitchTrackGameView(setup: launch.setup, simulated: launch.isSimulated)
        }
        .confirmationDialog("Delete this track?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Track", role: .destructive) {
                deleteTrack()
            }
        } message: {
            Text("The bars and the saved clip are deleted. The original file isn’t touched.")
        }
    }

    private var summary: String {
        var parts = [content.kind.title, SessionTime.clock(content.duration), "\(content.bars.count) bars"]
        if content.bars.contains(where: { $0.word != nil }) {
            parts.append("with words")
        }
        return parts.joined(separator: " · ")
    }

    private var transposeText: String {
        switch settings.transpose {
        case 0: "none"
        case 1: "+1 semitone"
        case -1: "−1 semitone"
        case let value where value > 0: "+\(value) semitones"
        default: "−\(abs(settings.transpose)) semitones"
        }
    }

    /// Where the bars are, shaped like the melody, for the loop selector.
    private var barPeaks: [Float] {
        let buckets = 120
        let duration = max(content.duration, 0.1)
        let window = PitchTrackGameModel.window(for: content.bars)
        var peaks = [Float](repeating: 0.05, count: buckets)
        for bar in content.bars {
            let first = max(0, Int(bar.start / duration * Double(buckets)))
            let last = min(buckets - 1, Int(bar.end / duration * Double(buckets)))
            guard first <= last else { continue }
            let height = (bar.midi - window.lowerBound) / max(window.upperBound - window.lowerBound, 1)
            for index in first...last {
                peaks[index] = max(peaks[index], Float(0.2 + 0.8 * min(max(height, 0), 1)))
            }
        }
        return peaks
    }

    @ViewBuilder
    private func savedSection(_ track: PitchTrack) -> some View {
        Section {
            TextField("Name", text: $name)
                .submitLabel(.done)
                .onSubmit {
                    rename(track)
                }
            if track.hasBackgroundMusic, track.separatedTrackID == nil {
                Label("This clip has background music, so some bars may be off.", systemImage: "music.note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if track.hasMultipleSpeakers {
                Label("More than one voice was heard, so the bars may jump between them.", systemImage: "person.2.wave.2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let detected = track.detectedKindRawValue.flatMap(PitchTrackKind.init(rawValue:)), detected != track.kind {
                Text("Detected as \(detected.title.lowercased()); you chose \(track.kind.title.lowercased()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Delete Track", role: .destructive) {
                isConfirmingDelete = true
            }
        } header: {
            Text("Track")
        }
    }

    private func rangeAdvice(suggestion: Int, track: ClosedRange<Double>, comfort: ClosedRange<Double>) -> String {
        let shifted = (track.lowerBound + Double(settings.transpose))...(track.upperBound + Double(settings.transpose))
        let direction = shifted.upperBound > comfort.upperBound ? "above" : "below"
        let move = suggestion > settings.transpose ? "up" : "down"
        let amount = abs(suggestion - settings.transpose)
        return "This track sits \(direction) your comfortable range. Try transposing \(move) \(amount) semitone\(amount == 1 ? "" : "s") (Auto-Fit does it for you). Never push for notes that hurt."
    }

    // MARK: Actions

    private func play() {
        let simulated = PitchTrackDebug.simulatesPerfectVoice
        let setup = PitchTrackGameSetup(trackID: trackID, title: name, content: content, settings: settings, sources: sources)
        Task {
            if !simulated {
                await sessionController.beginGuidedSession(kind: .pitchTrack, lessonID: trackID.uuidString)
            }
            if let savedTrack {
                PitchTrackStore(context: modelContext).markPlayed(savedTrack)
            }
            launch = PitchTrackGameLaunch(setup: setup, isSimulated: simulated)
        }
    }

    private func updateLoop() {
        let newLoop = loopEnabled
            ? TrackLoop(start: loopSelection.start, end: loopSelection.end, trackDuration: content.duration)
            : nil
        if settings.loop != newLoop {
            settings.loop = newLoop
        }
    }

    private func persist(_ newSettings: TrackSettings) {
        if let builtIn {
            BuiltInTrackSettingsStore.save(newSettings, for: builtIn)
        } else if let savedTrack {
            do {
                try PitchTrackStore(context: modelContext).update(savedTrack, settings: newSettings)
                errorMessage = nil
            } catch {
                errorMessage = "Your changes couldn’t be saved."
            }
        }
    }

    private func rename(_ track: PitchTrack) {
        do {
            try PitchTrackStore(context: modelContext).rename(track, to: name)
            name = track.name
        } catch {
            errorMessage = "The new name couldn’t be saved."
        }
    }

    /// Leaves the screen first, then deletes (reading a deleted model crashes).
    private func deleteTrack() {
        guard let savedTrack else { return }
        let store = PitchTrackStore(context: modelContext)
        let id = savedTrack.id
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if let doomed = store.track(id: id) {
                try? store.delete(doomed)
            }
        }
    }

    /// The comfortable range from recent sessions, the baseline and targets.
    private func loadComfortRange() -> ClosedRange<Double> {
        var descriptor = FetchDescriptor<PracticeSession>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 40
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let ranges = sessions.compactMap { session -> SessionPitchRange? in
            guard let low = session.minimumPitch, let high = session.maximumPitch else { return nil }
            return SessionPitchRange(low: low, high: high, voicedDuration: session.voicedDuration)
        }
        let profile = profiles.first
        return ComfortRange.estimate(
            sessions: ranges,
            baselineLow: profile?.baselinePitchLow,
            baselineHigh: profile?.baselinePitchHigh,
            target: profile?.targetZone ?? monitor.targetZone
        )
    }
}
