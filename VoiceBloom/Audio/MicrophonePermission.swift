import AVFoundation

nonisolated enum MicrophonePermission {
    nonisolated enum State: Sendable, Equatable {
        case undetermined
        case granted
        case denied
    }

    static var current: State {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }

    /// Asks for microphone access if needed (shows the system prompt once).
    /// - Returns: Whether the app may record.
    static func request() async -> Bool {
        switch current {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        }
    }
}
