import AVFoundation
import Foundation

/// Format of the audio being captured.
nonisolated struct CaptureFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    /// Hardware I/O buffer duration in seconds (how often the mic delivers audio).
    let ioBufferDuration: Double
    /// iOS voice processing is on (Clear Mic System mode).
    var isVoiceProcessing = false
    /// Why voice processing was asked for but isn't on, if it isn't.
    var voiceProcessingNote: String?
    /// A Bluetooth mic is recording in iOS 26's high-quality mode, which
    /// needs the .default session mode instead of .measurement.
    var isBluetoothHighQuality = false

    init(sampleRate: Double, channelCount: Int, ioBufferDuration: Double, isVoiceProcessing: Bool = false, voiceProcessingNote: String? = nil, isBluetoothHighQuality: Bool = false) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.ioBufferDuration = ioBufferDuration
        self.isVoiceProcessing = isVoiceProcessing
        self.voiceProcessingNote = voiceProcessingNote
        self.isBluetoothHighQuality = isBluetoothHighQuality
    }
}

/// How to set up the microphone (Clear Mic, SPEC section 24).
nonisolated struct CaptureOptions: Sendable, Equatable {
    /// iOS voice processing with automatic gain control off (System mode).
    var voiceProcessing = false
    /// Lets Bluetooth headset microphones be used for input.
    var allowsBluetoothInput = false
    /// The preferred input port (`AVAudioSessionPortDescription.uid`).
    var preferredInputUID: String?

    init(voiceProcessing: Bool = false, allowsBluetoothInput: Bool = false, preferredInputUID: String? = nil) {
        self.voiceProcessing = voiceProcessing
        self.allowsBluetoothInput = allowsBluetoothInput
        self.preferredInputUID = preferredInputUID
    }
}

/// A microphone the user can pick in Mic Check.
nonisolated struct MicInput: Sendable, Equatable, Identifiable {
    let uid: String
    let name: String
    let kind: AudioInputKind
    /// iOS 26 high-quality Bluetooth recording is supported.
    let supportsHighQualityBluetooth: Bool

    var id: String { uid }
}

/// Things the capture service reports back to its owner.
nonisolated enum CaptureEvent: Sendable, Equatable {
    /// The microphone/speaker route changed (or was read for the first time).
    case routeChanged(AudioRouteInfo)
    /// A phone call, Siri, or another app took over audio. Capture has stopped.
    case interruptionBegan
    /// The interruption is over. `shouldResume` is the system's hint.
    case interruptionEnded(shouldResume: Bool)
    /// The hardware format changed (e.g. headphones plugged in) and capture
    /// restarted automatically. Analysis must restart with the new format.
    case restarted(CaptureFormat)
    /// Capture stopped and could not restart by itself.
    case stopped(message: String)
}

nonisolated enum AudioCaptureError: LocalizedError, Sendable, Equatable {
    case noInputAvailable
    case unsupportedFormat
    case sessionUnavailable(String)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            "No microphone is available. If another app is recording, close it and try again."
        case .unsupportedFormat:
            "This microphone uses an audio format Chirp can’t read. Try the iPhone’s built-in mic."
        case .sessionUnavailable:
            "Chirp couldn’t access the microphone. If you’re on a call or another app is using audio, finish that first and try again."
        case .engineFailed:
            "The microphone couldn’t start. Please try again."
        }
    }
}

/// Owns the audio session and engine, and streams microphone samples into a
/// lock-free ring buffer.
///
/// Audio is captured with an `AVAudioSinkNode`, which receives samples directly
/// on the real-time I/O thread in small (~5 ms) chunks, so the pitch display
/// can follow the voice with very little delay. The sink block only copies
/// samples into `samples`; all analysis happens elsewhere.
actor AudioCaptureService {
    /// Microphone samples (mono, first channel) at `CaptureFormat.sampleRate`.
    nonisolated let samples: SampleRingBuffer
    /// Route changes, interruptions, and restarts.
    nonisolated let events: AsyncStream<CaptureEvent>

    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private var engine: AVAudioEngine?
    private var format: CaptureFormat?
    /// Plays the soft feedback chimes through the same engine.
    private var cuePlayer: AVAudioPlayerNode?
    private var bluetoothHighQuality = false
    private var cueFormat: AVAudioFormat?
    private var observers: [any NSObjectProtocol] = []
    private var isCapturing = false
    private var wasInterruptedWhileCapturing = false
    private var options = CaptureOptions()

    init() {
        // ~2.7 s at 48 kHz: plenty of slack if analysis briefly falls behind.
        samples = SampleRingBuffer(minimumCapacity: 1 << 17)
        let (stream, continuation) = AsyncStream.makeStream(
            of: CaptureEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = stream
        eventContinuation = continuation
    }

    // MARK: Public API

    var isRunning: Bool { isCapturing }

    func currentRoute() -> AudioRouteInfo {
        AudioRouteInfo(route: AVAudioSession.sharedInstance().currentRoute)
    }

    /// The microphones available right now (Mic Check's picker). Bluetooth
    /// mics only appear while `allowsBluetoothInput` is on.
    func availableInputs() -> [MicInput] {
        let ports = AVAudioSession.sharedInstance().availableInputs ?? []
        return ports.map { port in
            MicInput(
                uid: port.uid,
                name: port.portName,
                kind: AudioInputKind(port: port.portType),
                supportsHighQualityBluetooth: port.bluetoothMicrophoneExtension?.highQualityRecording.isSupported ?? false
            )
        }
    }

    /// The options capture was last started with.
    var currentOptions: CaptureOptions { options }

    nonisolated private static func categoryOptions(for options: CaptureOptions, highQuality: Bool) -> AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if options.allowsBluetoothInput {
            result.insert(.allowBluetoothHFP)
            if highQuality {
                result.insert(.bluetoothHighQualityRecording)
            }
        }
        return result
    }

    nonisolated private static func applyPreferredInput(_ uid: String?, session: AVAudioSession) {
        guard let uid else {
            try? session.setPreferredInput(nil)
            return
        }
        if let port = session.availableInputs?.first(where: { $0.uid == uid }) {
            try? session.setPreferredInput(port)
        }
    }

    nonisolated private static func currentInputSupportsHighQualityBluetooth(_ session: AVAudioSession) -> Bool {
        session.currentRoute.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording.isSupported ?? false
    }

    nonisolated private static func currentInputHasHighQualityBluetooth(_ session: AVAudioSession) -> Bool {
        session.currentRoute.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled ?? false
    }

    /// Configures the audio session for accurate measurement and starts capture.
    func start(options newOptions: CaptureOptions = CaptureOptions()) throws -> CaptureFormat {
        beginObservingSystemEvents()
        if isCapturing, let format, newOptions == options {
            return format
        }
        if isCapturing {
            tearDownEngine()
            isCapturing = false
        }
        options = newOptions

        let session = AVAudioSession.sharedInstance()
        var highQualityBluetooth = false
        do {
            // .measurement turns off automatic gain control and voice processing
            // (echo cancellation, noise suppression), which would distort pitch
            // and resonance readings.
            try session.setCategory(.playAndRecord, mode: .measurement, options: Self.categoryOptions(for: newOptions, highQuality: false))
            try session.setPreferredSampleRate(48_000)
            // Small hardware buffers mean fresh audio arrives every ~5 ms.
            try session.setPreferredIOBufferDuration(0.005)
            // iOS silences haptics while the mic records unless this is set.
            // Slip alerts rely on gentle haptics during practice.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            Self.applyPreferredInput(newOptions.preferredInputUID, session: session)
            // iOS 26: a Bluetooth mic that supports it records full-bandwidth
            // audio instead of the call profile. Apple only allows that in the
            // .default mode, so this one case leaves .measurement.
            if newOptions.allowsBluetoothInput, Self.currentInputSupportsHighQualityBluetooth(session) {
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions(for: newOptions, highQuality: true))
                    highQualityBluetooth = Self.currentInputHasHighQualityBluetooth(session)
                } catch {
                    try? session.setCategory(.playAndRecord, mode: .measurement, options: Self.categoryOptions(for: newOptions, highQuality: false))
                }
            }
        } catch {
            throw AudioCaptureError.sessionUnavailable(error.localizedDescription)
        }

        guard session.isInputAvailable else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioCaptureError.noInputAvailable
        }
        bluetoothHighQuality = highQualityBluetooth

        do {
            let format = try startEngine(session: session)
            isCapturing = true
            eventContinuation.yield(.routeChanged(AudioRouteInfo(route: session.currentRoute)))
            return format
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// Stops capture and releases the audio session so other apps can resume.
    func stop() {
        tearDownEngine()
        isCapturing = false
        wasInterruptedWhileCapturing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plays a soft feedback chime while listening (no-op when not capturing).
    func playTone(_ tone: ToneSequence) {
        // A player node raises an exception if its engine has stopped (for
        // example right after an interruption, before the restart).
        guard isCapturing, engine?.isRunning == true, let player = cuePlayer, let format = cueFormat else { return }
        let samples = tone.render(sampleRate: format.sampleRate)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    /// Starts listening for interruptions, route changes, and engine resets.
    /// Safe to call more than once.
    func beginObservingSystemEvents() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Extract plain values here: Notification itself isn't Sendable.
            guard let self, let change = InterruptionChange(notification) else { return }
            Task { await self.handleInterruption(change) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleRouteChange() }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleMediaServicesReset() }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let object = notification.object else { return }
            let engineID = ObjectIdentifier(object as AnyObject)
            Task { await self.handleEngineConfigurationChange(engineID: engineID) }
        })
    }

    // MARK: Engine

    /// Starts the engine with the chime player; if that combination fails on
    /// some route, falls back to listening only (chimes are optional).
    private func startEngine(session: AVAudioSession) throws -> CaptureFormat {
        do {
            return try startEngine(session: session, withChimes: true)
        } catch {
            return try startEngine(session: session, withChimes: false)
        }
    }

    private func startEngine(session: AVAudioSession, withChimes: Bool) throws -> CaptureFormat {
        tearDownEngine()

        // A fresh engine each time avoids stale graph state after route changes.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let voiceProcessing = Self.configureVoiceProcessing(input, requested: options.voiceProcessing)
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }
        guard hardwareFormat.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError.unsupportedFormat
        }

        // Non-interleaved audio keeps each channel in its own buffer; interleaved
        // audio alternates channels, so step over the others to stay mono.
        let stride = hardwareFormat.isInterleaved ? Int(hardwareFormat.channelCount) : 1
        let sink = Self.makeSinkNode(writingTo: samples, stride: stride)
        engine.attach(sink)
        // The sink node can't convert formats, so it must use the input's format.
        engine.connect(input, to: sink, format: hardwareFormat)

        // A player for feedback chimes (mono, at the output's rate).
        var player: AVAudioPlayerNode?
        var toneFormat: AVAudioFormat?
        let outputRate = withChimes ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 0
        if outputRate > 0, let monoFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1) {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
            player = node
            toneFormat = monoFormat
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        player?.play()

        self.engine = engine
        cuePlayer = player
        cueFormat = toneFormat
        let format = CaptureFormat(
            sampleRate: hardwareFormat.sampleRate,
            channelCount: Int(hardwareFormat.channelCount),
            ioBufferDuration: session.ioBufferDuration,
            isVoiceProcessing: voiceProcessing.isOn,
            voiceProcessingNote: voiceProcessing.note,
            isBluetoothHighQuality: bluetoothHighQuality
        )
        self.format = format
        return format
    }

    /// Turns on iOS voice processing with automatic gain control off, and
    /// turns it off again if it can't start or lowers the format too far.
    /// Must run before the engine starts.
    nonisolated private static func configureVoiceProcessing(_ input: AVAudioInputNode, requested: Bool) -> (isOn: Bool, note: String?) {
        guard requested else { return (false, nil) }
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            return (false, "iOS voice processing couldn’t start, so Clear Mic Light is used instead.")
        }
        // Automatic gain would make loudness and strain readings meaningless.
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate >= SystemModeCheck.minimumSampleRate, format.commonFormat == .pcmFormatFloat32 else {
            try? input.setVoiceProcessingEnabled(false)
            return (false, "iOS voice processing would lower the audio to \(format.sampleRate.roundedInt) Hz, so Clear Mic Light is used instead.")
        }
        return (true, nil)
    }

    private func tearDownEngine() {
        engine?.stop()
        engine = nil
        format = nil
        cuePlayer = nil
        cueFormat = nil
    }

    /// Builds the real-time sink. This is `nonisolated` so the block is not tied
    /// to this actor: it runs on Core Audio's I/O thread and must never lock,
    /// allocate, or await. It only copies samples into the ring buffer.
    nonisolated private static func makeSinkNode(writingTo ring: SampleRingBuffer, stride: Int) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            let bytesPerFrame = MemoryLayout<Float>.size * stride
            let framesInBuffer = Int(buffers[0].mDataByteSize) / bytesPerFrame
            let frames = min(Int(frameCount), framesInBuffer)
            guard frames > 0 else { return noErr }
            ring.write(data.assumingMemoryBound(to: Float.self), count: frames, stride: stride)
            return noErr
        }
    }

    // MARK: System events

    private func handleInterruption(_ change: InterruptionChange) {
        switch change {
        case .began:
            guard isCapturing else { return }
            // The system has already stopped the engine; release it.
            tearDownEngine()
            isCapturing = false
            wasInterruptedWhileCapturing = true
            eventContinuation.yield(.interruptionBegan)
        case .ended(let shouldResume):
            guard wasInterruptedWhileCapturing else { return }
            wasInterruptedWhileCapturing = false
            eventContinuation.yield(.interruptionEnded(shouldResume: shouldResume))
        }
    }

    private func handleRouteChange() {
        eventContinuation.yield(.routeChanged(currentRoute()))
    }

    private func handleEngineConfigurationChange(engineID: ObjectIdentifier) {
        guard isCapturing, let engine, ObjectIdentifier(engine) == engineID, !engine.isRunning else { return }
        // The hardware format changed and the engine stopped itself. Rebuild it.
        do {
            let format = try startEngine(session: AVAudioSession.sharedInstance())
            eventContinuation.yield(.restarted(format))
        } catch {
            isCapturing = false
            let message = (error as? LocalizedError)?.errorDescription ?? "The microphone stopped unexpectedly."
            eventContinuation.yield(.stopped(message: message))
        }
    }

    private func handleMediaServicesReset() {
        // Every audio object is invalid after a media services reset. Drop them;
        // the next start() reconfigures the session from scratch.
        engine = nil
        format = nil
        cuePlayer = nil
        cueFormat = nil
        guard isCapturing || wasInterruptedWhileCapturing else { return }
        isCapturing = false
        wasInterruptedWhileCapturing = false
        eventContinuation.yield(.stopped(message: "iPhone audio restarted. Tap Resume to keep practicing."))
    }
}

/// Plain-value summary of an interruption notification.
nonisolated enum InterruptionChange: Sendable, Equatable {
    case began
    case ended(shouldResume: Bool)

    init?(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return nil }

        switch type {
        case .began:
            self = .began
        case .ended:
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            self = .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}
