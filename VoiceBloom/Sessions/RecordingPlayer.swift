import AVFoundation
import Foundation
import Observation

/// Plays saved recordings, one at a time.
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

    var isPlaying: Bool { playingID != nil }

    func play(url: URL, id: UUID) {
        stop()
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                errorMessage = "This recording couldn’t be played."
                deactivateSession()
                return
            }
            player = newPlayer
            playingID = id
            progress = 0
            progressTask = Task { [weak self] in
                await self?.trackProgress()
            }
        } catch {
            errorMessage = "This recording couldn’t be played."
            deactivateSession()
        }
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        guard let current = player else { return }
        current.stop()
        player = nil
        playingID = nil
        progress = 0
        deactivateSession()
    }

    /// Updates progress ten times a second and notices when playback ends.
    private func trackProgress() async {
        while !Task.isCancelled {
            guard let current = player else { return }
            if !current.isPlaying {
                stop()
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
