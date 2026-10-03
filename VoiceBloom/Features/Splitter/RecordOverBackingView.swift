import AVFoundation
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Records the user over a split song's backing (SPEC section 23.4: no
/// bars, no scoring), then plays the take with the backing, saves or
/// discards it, and exports the mix.
@MainActor
@Observable
final class OverBackingSession {
    nonisolated enum Phase: Equatable, Sendable {
        case ready
        case recording
        case mixing
        case recorded
        case failed(String)
    }

    let backingURL: URL
    private(set) var phase = Phase.ready
    private(set) var elapsed = 0.0
    private(set) var isPlayingMix = false
    private(set) var savedMessage: String?
    /// Seconds the take is shifted to line up with the backing.
    private(set) var latency = 0.0

    @ObservationIgnored private let playback = StemPlaybackEngine()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var mixPlayer: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private(set) var takeURL: URL?
    @ObservationIgnored private(set) var mixURL: URL?
    @ObservationIgnored private var duration = 0.0

    init(backingURL: URL) {
        self.backingURL = backingURL
    }

    var isRecording: Bool { phase == .recording }

    func start(monitor: LiveVoiceMonitor) async {
        guard phase != .recording else { return }
        discardFiles()
        if monitor.status.isRunning {
            await monitor.pause(.user)
        }
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            phase = .failed("Discreet Mode plays the backing through headphones only. Connect headphones to record.")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // .measurement keeps automatic gain control off, so the take's
            // loudness is real (SPEC section 24.1).
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            phase = .failed("The microphone can’t start right now. Another app may be using audio.")
            return
        }

        let take = FileManager.default.temporaryDirectory.appending(path: "take-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: StereoAssetReader.decodeRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let newRecorder = try AVAudioRecorder(url: take, settings: settings)
            guard newRecorder.prepareToRecord() else { throw SeparationError.writeFailed }
            try playback.load(vocals: nil, backing: backingURL)
            playback.setGains(vocals: 0, backing: 1)
            duration = playback.duration
            try playback.play(from: 0)
            guard newRecorder.record() else { throw SeparationError.writeFailed }
            recorder = newRecorder
            takeURL = take
        } catch {
            playback.stop()
            phase = .failed(playback.errorMessage ?? "Recording couldn’t start. Check that Chirp can use the microphone in Settings.")
            return
        }
        // Input plus output delay: how late the take is relative to the backing.
        latency = session.inputLatency + session.outputLatency
        elapsed = 0
        phase = .recording
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.elapsed = self.recorder?.currentTime ?? self.elapsed
                // Stop at the end of the song.
                if self.elapsed >= self.duration, self.duration > 0 {
                    await self.stop()
                    return
                }
            }
        }
    }

    func stop() async {
        guard phase == .recording else { return }
        ticker?.cancel()
        recorder?.stop()
        recorder = nil
        playback.stop()
        guard let takeURL else {
            phase = .failed("The recording didn’t come through.")
            return
        }
        phase = .mixing
        let backing = backingURL
        let offset = -Int((latency * StereoAssetReader.decodeRate).rounded())
        let mix = FileManager.default.temporaryDirectory.appending(path: "mix-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let succeeded = await Task.detached(priority: .userInitiated) {
            do {
                try StemMixdown.render(
                    [MixInput(url: backing, gain: 1), MixInput(url: takeURL, gain: 1, offsetFrames: offset)],
                    to: mix,
                    format: .m4a
                )
                return true
            } catch {
                return false
            }
        }.value
        if succeeded {
            mixURL = mix
            phase = .recorded
        } else {
            phase = .failed("The take couldn’t be mixed with the backing.")
        }
    }

    func toggleMixPlayback() {
        if let mixPlayer, mixPlayer.isPlaying {
            mixPlayer.stop()
            isPlayingMix = false
            return
        }
        guard let mixURL else { return }
        if DiscreetMode.isEnabled, !TonePlayer.headphonesConnected {
            phase = .failed("Discreet Mode plays audio through headphones only. Connect headphones to listen.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: mixURL)
            player.play()
            mixPlayer = player
            isPlayingMix = true
            let length = player.duration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(length + 0.2))
                self?.isPlayingMix = self?.mixPlayer?.isPlaying ?? false
            }
        } catch {
            isPlayingMix = false
        }
    }

    /// Keeps the take (the voice only) as a recording.
    func save(context: ModelContext) {
        guard let takeURL else { return }
        let id = UUID()
        let fileName = RecordingFileStore.makeFileName(id: id)
        do {
            let destination = try RecordingFileStore.url(for: fileName)
            try FileManager.default.moveItem(at: takeURL, to: destination)
            self.takeURL = nil
            let reader = try? AudioFileStereoReader(url: destination)
            let recording = Recording(id: id, fileName: fileName, duration: reader?.duration ?? elapsed, kind: .overBacking)
            context.insert(recording)
            do {
                try context.save()
                savedMessage = "Your take is saved with your recordings."
            } catch {
                context.rollback()
                RecordingFileStore.delete(fileName: fileName)
                savedMessage = "The take couldn’t be saved."
            }
        } catch {
            savedMessage = "The take couldn’t be saved."
        }
    }

    func discardFiles() {
        mixPlayer?.stop()
        isPlayingMix = false
        for url in [takeURL, mixURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        takeURL = nil
        mixURL = nil
        savedMessage = nil
        if phase != .recording {
            phase = .ready
        }
    }

    func shutDown() {
        ticker?.cancel()
        recorder?.stop()
        recorder = nil
        playback.shutDown()
        mixPlayer?.stop()
        if let takeURL {
            try? FileManager.default.removeItem(at: takeURL)
        }
        if let mixURL {
            try? FileManager.default.removeItem(at: mixURL)
        }
    }
}

struct RecordOverBackingView: View {
    let track: SeparatedTrack

    var body: some View {
        if let backing = track.backingURL {
            RecordOverBackingContent(title: track.title, backingURL: backing)
        } else {
            ContentUnavailableView("No backing", systemImage: "music.note", description: Text("This split doesn’t have a backing track."))
        }
    }
}

private struct RecordOverBackingContent: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var session: OverBackingSession
    @State private var isConfirmingDiscard = false
    @State private var headphones = TonePlayer.headphonesConnected

    init(title: String, backingURL: URL) {
        self.title = title
        _session = State(initialValue: OverBackingSession(backingURL: backingURL))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !headphones {
                        NoticeBanner(
                            title: "Use headphones",
                            message: "Without headphones the microphone records the backing too, which muddies your take.",
                            systemImage: "headphones"
                        )
                    }
                    recordCard
                    if session.phase == .recorded {
                        resultCard
                    }
                    if case .failed(let message) = session.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SplitRightsNote()
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Record Over Backing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        session.shutDown()
                        dismiss()
                    }
                }
            }
            .tracksHeadphones($headphones)
            .interactiveDismissDisabled(session.isRecording)
            .confirmationDialog("Discard this take?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard Take", role: .destructive) {
                    session.discardFiles()
                }
            }
        }
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text("The backing plays while you sing or speak along. There are no bars and no score: it’s just for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(session.isRecording ? Theme.warning : Color.secondary)
                    .accessibilityHidden(true)
                Text(SessionTime.clock(session.elapsed))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(session.isRecording ? "Recording" : "Ready")
            .accessibilityValue(SessionTime.clock(session.elapsed))

            if session.phase == .mixing {
                ProgressView("Mixing your take with the backing…")
            } else {
                Button {
                    Task {
                        if session.isRecording {
                            await session.stop()
                        } else {
                            await session.start(monitor: monitor)
                        }
                    }
                } label: {
                    Label(session.isRecording ? "Stop" : "Record", systemImage: session.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .cardStyle()
        .sensoryFeedback(.start, trigger: session.isRecording) { _, isRecording in isRecording }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                session.toggleMixPlayback()
            } label: {
                Label(session.isPlayingMix ? "Stop" : "Play My Take With the Backing", systemImage: session.isPlayingMix ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            if let mix = session.mixURL {
                ShareLink(item: mix) {
                    Label("Export the Mix", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if session.takeURL != nil {
                Button {
                    session.save(context: modelContext)
                } label: {
                    Label("Save My Take", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            Button(role: .destructive) {
                isConfirmingDiscard = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            if let message = session.savedMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Your take is lined up with the backing using the iPhone’s audio delay (\((session.latency * 1000).roundedInt) ms).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.large)
        .cardStyle()
    }
}
