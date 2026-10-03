import AVFoundation

nonisolated enum AudioInputKind: String, Sendable, Equatable, Codable {
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

    /// Short name for Mic Check.
    var title: String {
        switch self {
        case .builtInMicrophone: "Built-in mic"
        case .wiredHeadset: "Wired"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .carAudio: "Car"
        case .other: "Other"
        case .unavailable: "None"
        }
    }

    var systemImage: String {
        switch self {
        case .builtInMicrophone: "iphone"
        case .wiredHeadset: "headphones"
        case .bluetooth: "airpods"
        case .usb: "cable.connector"
        case .carAudio: "car"
        case .other: "mic"
        case .unavailable: "mic.slash"
        }
    }
}

/// A Sendable snapshot of where audio is coming from and going to.
nonisolated struct AudioRouteInfo: Sendable, Equatable {
    let inputName: String
    let inputKind: AudioInputKind
    let outputName: String
    /// The Bluetooth mic records in iOS 26's high-quality (full-bandwidth) mode.
    let isHighQualityBluetooth: Bool

    init(inputName: String, inputKind: AudioInputKind, outputName: String, isHighQualityBluetooth: Bool = false) {
        self.inputName = inputName
        self.inputKind = inputKind
        self.outputName = outputName
        self.isHighQualityBluetooth = isHighQualityBluetooth
    }

    init(route: AVAudioSessionRouteDescription) {
        let input = route.inputs.first
        inputName = input?.portName ?? "No microphone"
        inputKind = AudioInputKind(port: input?.portType)
        outputName = route.outputs.first?.portName ?? "None"
        isHighQualityBluetooth = input?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled ?? false
    }

    /// Bluetooth and car microphones use narrow-band, compressed audio that
    /// smears the upper harmonics resonance analysis depends on.
    var hasLowQualityInput: Bool {
        inputKind == .bluetooth || inputKind == .carAudio
    }

    /// A user-facing warning about the current microphone, if any.
    var warningMessage: String? {
        switch inputKind {
        case .bluetooth where isHighQualityBluetooth:
            "You’re using \(inputName) in high-quality mode. That’s much better than a call mic, but the earbuds still process your voice, so resonance and weight are less precise than with the iPhone’s mic or wired headphones."
        case .bluetooth, .carAudio:
            "You’re using \(inputName) as the microphone. Bluetooth and car mics record at low quality, so resonance readings will be unreliable. For best results, use the iPhone’s built-in mic or wired headphones."
        case .unavailable:
            "No microphone is available right now."
        case .builtInMicrophone, .wiredHeadset, .usb, .other:
            nil
        }
    }
}
