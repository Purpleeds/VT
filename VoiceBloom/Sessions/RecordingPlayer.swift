import AVFoundation
import Foundation
import Observation

/// Plays saved recordings, one at a time or back to back ("Then vs Now").
///
/// Playback uses the `.playback` audio category so recordings are heard even
/// with the ring/silent switch on. Listening must be paused first, otherwise
/// the microphone would analyze the playback (the session controller does this).
@MainActor
@Observable
final class RecordingPlayer {
    /// The recording currently playing.
    private(set) var playingID: UUID?
    /// 0...1 through the current recording.
    private(set) var progress = 0.0
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    /// Recordings still to play after the current one.
    @ObservationIgnored private var queue: [(url: URL, id: UUID)] = []

    var isPlaying: Bool { playingID != nil }

    func play(url: URL, id: UUID) {
        playSequence([(url: url, id: id)])
    }

    /// Plays the recordings one after another.
    func playSequence(_ items: [(url: URL, id: UUID)]) {
        stop()
        errorMessage = nil
        queue = items
        advance()
    }

    func stop() {
        queue = []
        progressTask?.cancel()
        progressTask = nil
        guard let current = player else { return }
        current.stop()
        finish()
    }

    /// Starts the next queued recording, or finishes when none are left.
    private func advance() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        guard !queue.isEmpty else {
            finish()
            return
        }
        let next = queue.removeFirst()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: next.url)
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                errorMessage = "This recording couldn’t be played."
                queue = []
                finish()
                return
            }
            player = newPlayer
            playingID = next.id
            progress = 0
            progressTask = Task { [weak self] in
                await self?.trackProgress()
            }
        } catch {
            errorMessage = "This recording couldn’t be played."
            queue = []
            finish()
        }
    }

    private func finish() {
        player = nil
        playingID = nil
        progress = 0
        deactivateSession()
    }

    /// Updates progress ten times a second and moves on when a recording ends.
    private func trackProgress() async {
        while !Task.isCancelled {
            guard let current = player else { return }
            if !current.isPlaying {
                advance()
                return
            }
            progress = current.duration > 0 ? current.currentTime / current.duration : 0
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
