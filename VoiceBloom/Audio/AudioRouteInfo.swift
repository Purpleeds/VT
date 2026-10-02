import AVFoundation

nonisolated enum AudioInputKind: Sendable, Equatable {
    case builtInMicrophone
    case wiredHeadset
    case bluetooth
    case usb
    case carAudio
    case other
    case unavailable

    init(port: AVAudioSession.Port?) {
        guard let port else {
            self = .unavailable
            return
        }
        switch port {
        case .builtInMic: self = .builtInMicrophone
        case .headsetMic, .lineIn: self = .wiredHeadset
        case .bluetoothHFP, .bluetoothLE: self = .bluetooth
        case .usbAudio: self = .usb
        case .carAudio: self = .carAudio
        default: self = .other
        }
    }
}

/// A Sendable snapshot of where audio is coming from and going to.
nonisolated struct AudioRouteInfo: Sendable, Equatable {
    let inputName: String
    let inputKind: AudioInputKind
    let outputName: String

    init(inputName: String, inputKind: AudioInputKind, outputName: String) {
        self.inputName = inputName
        self.inputKind = inputKind
        self.outputName = outputName
    }

    init(route: AVAudioSessionRouteDescription) {
        let input = route.inputs.first
        inputName = input?.portName ?? "No microphone"
        inputKind = AudioInputKind(port: input?.portType)
        outputName = route.outputs.first?.portName ?? "None"
    }

    /// Bluetooth and car microphones use narrow-band, compressed audio that
    /// smears the upper harmonics resonance analysis depends on.
    var hasLowQualityInput: Bool {
        inputKind == .bluetooth || inputKind == .carAudio
    }

    /// A user-facing warning about the current microphone, if any.
    var warningMessage: String? {
        switch inputKind {
        case .bluetooth, .carAudio:
            "You’re using \(inputName) as the microphone. Bluetooth and car mics record at low quality, so resonance readings will be unreliable. For best results, use the iPhone’s built-in mic or wired headphones."
        case .unavailable:
            "No microphone is available right now."
        case .builtInMicrophone, .wiredHeadset, .usb, .other:
            nil
        }
    }
}
