import Charts
import Foundation
import SwiftData
import SwiftUI

/// Daily Sentence Journal (SPEC section 8): the same sentence recorded every
/// day, with a timeline to scrub through and hear progress.
struct JournalView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        JournalContent(monitor: monitor)
    }
}

private struct JournalContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \DailyJournalEntry.date) private var entries: [DailyJournalEntry]

    @State private var recorder: VoiceTakeRecorder
    @State private var sentence = ReadingPassages.journalSentence
    @State private var scrubPosition = 0.0
    @State private var isEditingSentence = false
    @State private var isSaving = false
    @State private var lastTake: TakeResult?
    @State private var errorMessage: String?
    @State private var entryToDelete: DailyJournalEntry?
    @State private var isConfirmingDelete = false
    @State private var didLoad = false

    init(monitor: LiveVoiceMonitor) {
        _recorder = State(initialValue: VoiceTakeRecorder(monitor: monitor))
    }

    private var profile: UserProfile? { profiles.first }
    private var target: PitchTargetZone { profile?.targetZone ?? recorder.monitor.targetZone }

    private var todaysEntry: DailyJournalEntry? {
        let calendar = Calendar.current
        return entries.last { calendar.isDateInToday($0.date) }
    }

    private var selectedIndex: Int? {
        guard !entries.isEmpty else { return nil }
        return min(max(Int(scrubPosition.rounded()), 0), entries.count - 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sentenceCard
                todayCard
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Your timeline starts today",
                        systemImage: "calendar.badge.plus",
                        description: Text("Record the sentence once a day. After a few weeks you can scrub back and hear how far you’ve come.")
                    )
                } else {
                    timelineCard
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Daily Journal")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingSentence) {
            JournalSentenceEditor(sentence: sentence) { newSentence in
                JournalStore.sentence = newSentence
                sentence = JournalStore.sentence
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: entryToDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                delete(entry)
            }
        } message: { entry in
            Text("The recording from \(entry.date.formatted(date: .long, time: .omitted)) will be removed from this iPhone.")
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            sentence = JournalStore.sentence
            scrubPosition = Double(max(entries.count - 1, 0))
        }
        .onChange(of: entries.count) { _, count in
            // Jump to the newest entry when one is added.
            scrubPosition = Double(max(count - 1, 0))
        }
        .onChange(of: recorder.phase) { _, phase in
            if phase == .finished {
                Task { await saveTake() }
            } else if case .failed(let message) = phase {
                errorMessage = message
            }
        }
        .onDisappear {
            recorder.cancel()
            Task { await recorder.restoreMicrophone() }
        }
    }

    // MARK: Sentence and today's recording

    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your sentence")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change") {
                    isEditingSentence = true
                }
                .font(.subheadline)
                .disabled(recorder.isRecording)
            }
            Text(sentence)
                .font(.title3.weight(.medium))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch recorder.phase {
            case .starting, .recording:
                TakeProgressView(recorder: recorder)
            case .finished where isSaving:
                ProgressView("Saving…")
                    .frame(maxWidth: .infinity)
            default:
                if let lastTake, recorder.phase == .finished {
                    TakeResultSummary(result: lastTake)
                }
                if todaysEntry != nil {
                    Label("Today’s entry is saved.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.targetZone)
                        .font(.subheadline.weight(.semibold))
                }
                if todaysEntry == nil {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label("Record today’s entry", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label("Record again (replaces today’s)", systemImage: "mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                let streak = JournalTimeline.streak(dates: entries.map(\.date))
                if streak > 1 {
                    Label("\(streak) days in a row", systemImage: "flame")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Timeline

    private var timelineCard: some View {
        let points = entries.map { $0.timelinePoint }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Timeline")
                    .font(.headline)
                Spacer()
                Text("\(entries.count) \(entries.count == 1 ? "day" : "days")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            JournalPitchChart(points: points, target: target, selectedIndex: selectedIndex)

            if entries.count > 1 {
                Slider(value: $scrubPosition, in: 0...Double(entries.count - 1), step: 1) {
                    Text("Timeline")
                } minimumValueLabel: {
                    Text("First")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text("Today")
                        .font(.caption2)
                }
                .accessibilityValue(selectedIndex.map { "Entry \($0 + 1) of \(entries.count), \(entries[$0].date.formatted(date: .long, time: .omitted))" } ?? "")
            }

            if let index = selectedIndex {
                JournalEntryDetail(
                    entry: entries[index],
                    number: index + 1,
                    change: JournalTimeline.pitchChange(in: points, to: points[index]),
                    onDelete: {
                        entryToDelete = entries[index]
                        isConfirmingDelete = true
                    }
                )
            }

            if entries.count > 2 {
                Button {
                    playHighlights()
                } label: {
                    Label("Play my progress", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityHint("Plays up to eight days, from your first entry to your latest")
            }
        }
        .cardStyle()
    }

    // MARK: Actions

    private func startRecording() async {
        errorMessage = nil
        lastTake = nil
        await recorder.start(
            duration: JournalStore.recordingDuration,
            target: target,
            resonanceMode: .speech,
            references: profile?.personalReferences ?? .none
        )
    }

    private func saveTake() async {
        guard let result = recorder.result else { return }
        lastTake = result
        guard result.hasVoice else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await JournalStore(context: modelContext).save(
                take: result,
                audio: recorder.audio,
                sentence: sentence,
                target: target
            )
        } catch {
            errorMessage = "Today’s entry couldn’t be saved. Please try again."
        }
    }

    private func playHighlights() {
        let recordings = JournalTimeline.highlights(count: entries.count, maximum: 8).compactMap { entries[$0].recording }
        guard !recordings.isEmpty else { return }
        Task { await sessionController.playInSequence(recordings) }
    }

    private func delete(_ entry: DailyJournalEntry) {
        if let recording = entry.recording, sessionController.player.playingID == recording.id {
            sessionController.player.stop()
        }
        do {
            try JournalStore(context: modelContext).delete(entry)
        } catch {
            errorMessage = "The entry couldn’t be deleted. Please try again."
        }
    }
}

/// Pitch for each day, with the target band and the selected day marked.
private struct JournalPitchChart: View {
    let points: [JournalPoint]
    let target: PitchTargetZone
    let selectedIndex: Int?

    private var yDomain: ClosedRange<Double> {
        let values = points.compactMap(\.pitch)
        let low = min(values.min() ?? target.lowerBound, target.lowerBound) - 15
        let high = max(values.max() ?? target.upperBound, target.upperBound) + 15
        return max(50, low)...high
    }

    private var xUpperBound: Double { Double(max(points.count - 1, 1)) }

    var body: some View {
        Chart {
            RectangleMark(
                xStart: .value("Start", 0.0),
                xEnd: .value("End", xUpperBound),
                yStart: .value("Target low", target.lowerBound),
                yEnd: .value("Target high", target.upperBound)
            )
            .foregroundStyle(Theme.targetZone.opacity(0.16))
            .accessibilityHidden(true)

            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if let pitch = point.pitch {
                    LineMark(x: .value("Day", Double(index)), y: .value("Pitch", pitch))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.pitchLine)
                        .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(Int(pitch.rounded())) hertz")
                    PointMark(x: .value("Day", Double(index)), y: .value("Pitch", pitch))
                        .symbolSize(index == selectedIndex ? 90 : 24)
                        .foregroundStyle(Theme.pitchLine)
                        .accessibilityHidden(true)
                }
            }

            if let selectedIndex {
                RuleMark(x: .value("Selected", Double(selectedIndex)))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: 0...xUpperBound)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxisLabel("Hz")
        .frame(height: 170)
    }
}

/// The selected day: date, numbers, playback and delete.
private struct JournalEntryDetail: View {
    let entry: DailyJournalEntry
    let number: Int
    let change: Double?
    let onDelete: () -> Void
    @Environment(PracticeSessionController.self) private var sessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Delete entry", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("More for this entry")
            }

            HStack(spacing: 12) {
                StatTile(title: "Pitch", value: entry.averagePitch.map(SessionFormat.hertz) ?? "—")
                StatTile(title: "Resonance", value: SessionFormat.score(entry.resonanceScore))
                StatTile(title: "Weight", value: SessionFormat.score(entry.weightScore))
                StatTile(title: "Intonation", value: SessionFormat.score(entry.intonationScore))
            }

            if let recording = entry.recording {
                let isPlaying = sessionController.player.playingID == recording.id
                Button {
                    Task { await sessionController.togglePlayback(of: recording) }
                } label: {
                    Label(isPlaying ? "Stop" : "Listen to this day", systemImage: isPlaying ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                if isPlaying {
                    ProgressView(value: sessionController.player.progress)
                        .tint(Theme.pitchLine)
                        .accessibilityLabel("Playback progress")
                }
            }
        }
    }

    private var subtitle: String {
        var text = "Day \(number)"
        if let change, number > 1 {
            let amount = Int(abs(change).rounded())
            text += amount == 0 ? " · same pitch as day 1" : " · \(change > 0 ? "+" : "−")\(amount) Hz since day 1"
        }
        return text
    }
}

/// Edits the journal sentence.
private struct JournalSentenceEditor: View {
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(sentence: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: sentence)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sentence", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Pick something you can say comfortably in about 5–10 seconds. Keeping the same sentence makes days easy to compare; earlier entries keep the sentence they were recorded with.")
                }
                Section {
                    Button("Use the default sentence") {
                        text = ReadingPassages.journalSentence
                    }
                }
            }
            .navigationTitle("Journal Sentence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
