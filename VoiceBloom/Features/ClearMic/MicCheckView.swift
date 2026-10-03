import Foundation
import Observation
import SwiftUI

/// Runs Mic Check's tests (SPEC section 24.5): the 5-second A/B test, room
/// noise sampling and the System Mode Check. While the screen is open the
/// microphone listens, and nothing it hears counts toward practice.
@MainActor
@Observable
final class MicCheckModel {
    nonisolated enum ABPhase: Equatable, Sendable {
        case idle
        case recording
        case processing
        case ready
        case failed(String)
    }

    nonisolated enum SystemCheckPhase: Equatable, Sendable {
        case idle
        /// Switching the microphone setup before take `step` (1 or 2).
        case preparing(step: Int)
        case recording(step: Int)
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .preparing, .recording: true
            case .idle, .finished, .failed: false
            }
        }
    }

    static let abDuration = 5.0
    static let systemTakeDuration = 4.0
    static let rawID = 1
    static let enhancedID = 2

    let monitor: LiveVoiceMonitor
    let recorder: VoiceTakeRecorder
    let player = SamplePlayer()

    private(set) var inputs: [MicInput] = []
    private(set) var abPhase: ABPhase = .idle
    private(set) var comparison: MicABComparison?
    /// The Clear Mic version the A/B test plays against the raw take.
    var abStrength: ClearMicStrength
    private(set) var systemPhase: SystemCheckPhase = .idle
    private(set) var isSamplingNoise = false
    private(set) var noiseMessage: String?

    @ObservationIgnored private var rawClip: AudioClip?
    @ObservationIgnored private var enhancedClip: AudioClip?
    @ObservationIgnored private var wasListening = false
    @ObservationIgnored private var abTask: Task<Void, Never>?
    @ObservationIgnored private var systemTask: Task<Void, Never>?
    @ObservationIgnored private var noiseTask: Task<Void, Never>?
    /// The settings to put back after (or if leaving during) the System Mode Check.
    @ObservationIgnored private var settingsBeforeCheck: ClearMicSettings?
    @ObservationIgnored private var processToken = UUID()

    init(monitor: LiveVoiceMonitor) {
        self.monitor = monitor
        recorder = VoiceTakeRecorder(monitor: monitor)
        let strength = monitor.clearMicSettings.effectiveStrength
        abStrength = strength == .strong ? .strong : .light
    }

    /// A test is recording or processing.
    var isBusy: Bool {
        recorder.isRecording || abPhase == .processing || systemPhase.isRunning
    }

    // MARK: Screen

    /// Starts listening (if needed) so the meters move.
    func open() async {
        monitor.isCheckingMic = true
        wasListening = monitor.status.isRunning
        if !monitor.status.isRunning {
            await monitor.start()
        }
        await refreshInputs()
    }

    /// Stops the tests, puts the settings back and restores listening.
    func close() async {
        abTask?.cancel()
        systemTask?.cancel()
        noiseTask?.cancel()
        recorder.cancel()
        player.shutDown()
        // Let a running System Mode Check stop before its settings go back.
        await systemTask?.value
        await abTask?.value
        if var original = settingsBeforeCheck {
            settingsBeforeCheck = nil
            original.isTestingSystemMode = false
            await monitor.updateClearMicSettings(original)
        }
        monitor.isCheckingMic = false
        if !wasListening, monitor.status.isRunning {
            await monitor.stop()
            monitor.clearLiveReadings()
        }
    }

    func resumeListening() async {
        player.stop()
        await monitor.start()
    }

    // MARK: Settings

    func refreshInputs() async {
        let available = await monitor.availableInputs()
        if inputs != available {
            inputs = available
        }
    }

    func setStrength(_ strength: ClearMicStrength) async {
        await monitor.setClearMicStrength(strength)
    }

    func setAnalyzesEnhanced(_ analyzesEnhanced: Bool) async {
        var settings = monitor.clearMicSettings
        settings.analyzesEnhancedAudio = analyzesEnhanced
        await monitor.updateClearMicSettings(settings)
    }

    func setAllowsBluetooth(_ allows: Bool) async {
        var settings = monitor.clearMicSettings
        settings.allowsBluetoothInput = allows
        if !allows, let uid = settings.preferredInputUID,
           inputs.first(where: { $0.uid == uid })?.kind == .bluetooth {
            settings.preferredInputUID = nil
        }
        await monitor.updateClearMicSettings(settings)
        await refreshInputs()
    }

    func setPreferredInput(_ uid: String?) async {
        var settings = monitor.clearMicSettings
        settings.preferredInputUID = uid
        await monitor.updateClearMicSettings(settings)
        await refreshInputs()
    }

    // MARK: Room noise

    /// "Sample Room Noise": the next 2 seconds become Clear Mic's noise profile.
    func sampleRoomNoise() async {
        guard !isSamplingNoise else { return }
        noiseMessage = nil
        player.stop()
        if !monitor.status.isRunning {
            await monitor.start()
        }
        guard monitor.status.isRunning else {
            noiseMessage = VoiceTakeRecorder.message(for: monitor.status)
            return
        }
        isSamplingNoise = true
        let previous = monitor.noiseSampledAt
        monitor.sampleRoomNoise(seconds: 2)
        noiseTask = Task { [weak self] in
            await self?.waitForNoiseSample(previous: previous)
        }
    }

    private func waitForNoiseSample(previous: Date?) async {
        // Two seconds of sampling plus a moment to start.
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled {
                isSamplingNoise = false
                return
            }
            if monitor.noiseSampledAt != previous {
                isSamplingNoise = false
                noiseMessage = "Room noise saved. Clear Mic now knows what to remove here."
                return
            }
            if !monitor.status.isRunning {
                break
            }
        }
        isSamplingNoise = false
        noiseMessage = "Room noise wasn’t saved. Keep listening on and stay quiet for 2 seconds."
    }

    // MARK: A/B test

    func runABTest() {
        guard !isBusy else { return }
        player.stop()
        abTask = Task { [weak self] in
            await self?.performABTest()
        }
    }

    private func performABTest() async {
        comparison = nil
        rawClip = nil
        enhancedClip = nil
        abPhase = .recording
        let recorded = await recordTake(duration: Self.abDuration)
        guard !Task.isCancelled else {
            abPhase = .idle
            return
        }
        guard recorded else {
            abPhase = .failed(recorderFailure)
            return
        }
        guard let audio = recorder.audio else {
            abPhase = .failed("The recording didn’t come through. Please try again.")
            return
        }
        await process(audio)
    }

    /// Makes the Clear Mic version again after the strength picker changes.
    func reprocess() {
        guard let rawClip, abPhase == .ready, !isBusy else { return }
        player.stop()
        abTask = Task { [weak self] in
            await self?.process(rawClip)
        }
    }

    private func process(_ audio: AudioClip) async {
        abPhase = .processing
        let strength = abStrength
        // The room's live noise profile, when Clear Mic has learned one;
        // otherwise it's estimated from the take's own pauses.
        let profile = monitor.clearMic.latestProfile
        let token = UUID()
        processToken = token
        let result = await Task.detached(priority: .userInitiated) {
            ClearMicComparison.compare(raw: audio, strength: strength, knownProfile: profile)
        }.value
        guard token == processToken else { return }
        rawClip = audio
        enhancedClip = result.enhanced
        comparison = result.comparison
        abPhase = .ready
    }

    func togglePlayback(enhanced: Bool) async {
        let id = enhanced ? Self.enhancedID : Self.rawID
        if player.playingID == id {
            player.stop()
            return
        }
        guard !isBusy, let clip = enhanced ? enhancedClip : rawClip else { return }
        player.stop()
        if monitor.status.isRunning {
            // The microphone mustn't hear the playback.
            await monitor.pause(.user)
        }
        player.play(clip, range: 0...clip.duration, id: id)
    }

    // MARK: System Mode Check

    func runSystemCheck() {
        guard !isBusy else { return }
        player.stop()
        systemTask = Task { [weak self] in
            await self?.performSystemCheck()
        }
    }

    /// Records the same steady hum with iOS voice processing and with the
    /// plain microphone, and compares the pitch readings (SPEC section 24.4).
    private func performSystemCheck() async {
        let original = monitor.clearMicSettings
        settingsBeforeCheck = original

        // Take 1: iOS voice processing (automatic gain off).
        systemPhase = .preparing(step: 1)
        var system = original
        system.strength = .system
        system.isTestingSystemMode = true
        await monitor.updateClearMicSettings(system, persist: false)
        if !monitor.status.isRunning {
            await monitor.start()
        }
        guard !Task.isCancelled else { return }
        guard monitor.status.isRunning, let systemFormat = monitor.captureFormat else {
            await finishSystemCheck(nil, failure: VoiceTakeRecorder.message(for: monitor.status))
            return
        }
        guard systemFormat.isVoiceProcessing else {
            let result = SystemModeCheckResult(
                date: Date(),
                passed: false,
                systemSampleRate: systemFormat.sampleRate,
                normalSampleRate: systemFormat.sampleRate,
                pitchDifferenceCents: nil,
                voicedRatio: nil,
                reason: systemFormat.voiceProcessingNote ?? "iOS voice processing couldn’t start on this microphone."
            )
            await finishSystemCheck(result, failure: nil)
            return
        }
        systemPhase = .recording(step: 1)
        let systemRecorded = await recordTake(duration: Self.systemTakeDuration)
        guard !Task.isCancelled else { return }
        guard systemRecorded, let systemTake = recorder.result else {
            await finishSystemCheck(nil, failure: recorderFailure)
            return
        }
        let systemMeasure = PitchTakeMeasure(take: systemTake, sampleRate: systemFormat.sampleRate)

        // Take 2: the plain microphone, for reference.
        systemPhase = .preparing(step: 2)
        var plain = original
        plain.strength = .off
        plain.isTestingSystemMode = false
        await monitor.updateClearMicSettings(plain, persist: false)
        guard !Task.isCancelled else { return }
        guard monitor.status.isRunning, let plainFormat = monitor.captureFormat else {
            await finishSystemCheck(nil, failure: VoiceTakeRecorder.message(for: monitor.status))
            return
        }
        systemPhase = .recording(step: 2)
        let plainRecorded = await recordTake(duration: Self.systemTakeDuration)
        guard !Task.isCancelled else { return }
        guard plainRecorded, let plainTake = recorder.result else {
            await finishSystemCheck(nil, failure: recorderFailure)
            return
        }
        let plainMeasure = PitchTakeMeasure(take: plainTake, sampleRate: plainFormat.sampleRate)
        let result = SystemModeCheck.evaluate(system: systemMeasure, normal: plainMeasure, voiceProcessingWorked: true)
        await finishSystemCheck(result, failure: nil)
    }

    /// Puts the user's settings back, with the new result.
    private func finishSystemCheck(_ result: SystemModeCheckResult?, failure: String?) async {
        var restored = settingsBeforeCheck ?? monitor.clearMicSettings
        settingsBeforeCheck = nil
        restored.isTestingSystemMode = false
        if let result {
            restored.systemCheck = result
            if !result.passed, restored.strength == .system {
                restored.strength = .light
            }
        }
        await monitor.updateClearMicSettings(restored)
        if let failure {
            systemPhase = .failed(failure)
        } else {
            systemPhase = .finished
        }
    }

    // MARK: Takes

    /// Records one take with the shared recorder.
    /// - Returns: False when it failed or was cancelled.
    private func recordTake(duration: Double) async -> Bool {
        await recorder.start(duration: duration, target: monitor.targetZone)
        while recorder.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled {
                recorder.cancel()
                return false
            }
        }
        return recorder.phase == .finished
    }

    private var recorderFailure: String {
        if case .failed(let message) = recorder.phase {
            return message
        }
        return "The recording didn’t finish. Please try again."
    }
}

/// Mic Check (SPEC section 24.5): input level and clipping, background
/// noise, Clear Mic's strength, the microphone in use, an A/B test and the
/// System Mode Check.
struct MicCheckView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor

    var body: some View {
        MicCheckContent(monitor: monitor)
    }
}

private struct MicCheckContent: View {
    @State private var model: MicCheckModel
    @State private var strength: ClearMicStrength = .off
    @State private var analyzesEnhanced = true
    @State private var allowsBluetooth = false
    @State private var preferredInputUID = ""

    init(monitor: LiveVoiceMonitor) {
        _model = State(initialValue: MicCheckModel(monitor: monitor))
    }

    private var monitor: LiveVoiceMonitor { model.monitor }
    private var settings: ClearMicSettings { monitor.clearMicSettings }
    private var mic: ClearMicLiveStatus { monitor.micStatus }
    private var isListening: Bool { monitor.status.isRunning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                levelCard
                noiseCard
                clearMicCard
                inputCard
                MicABTestCard(model: model)
                MicSystemCheckCard(model: model)
                Label("Everything here happens on this iPhone. Test recordings aren’t saved.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle("Mic Check")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadSettings()
            await model.open()
        }
        .onDisappear {
            Task { await model.close() }
        }
        .onChange(of: monitor.clearMicSettings) { _, _ in loadSettings() }
        .onChange(of: model.systemPhase) { _, _ in loadSettings() }
        .onChange(of: monitor.route) { _, _ in
            Task { await model.refreshInputs() }
        }
        .onChange(of: strength) { _, newValue in
            guard newValue != settings.displayedStrength, !model.systemPhase.isRunning else { return }
            Task { await model.setStrength(newValue) }
        }
        .onChange(of: analyzesEnhanced) { _, newValue in
            guard newValue != settings.analyzesEnhancedAudio, !model.systemPhase.isRunning else { return }
            Task { await model.setAnalyzesEnhanced(newValue) }
        }
        .onChange(of: allowsBluetooth) { _, newValue in
            guard newValue != settings.allowsBluetoothInput, !model.systemPhase.isRunning else { return }
            Task { await model.setAllowsBluetooth(newValue) }
        }
        .onChange(of: preferredInputUID) { _, newValue in
            let uid: String? = newValue.isEmpty ? nil : newValue
            guard uid != settings.preferredInputUID, !model.systemPhase.isRunning else { return }
            Task { await model.setPreferredInput(uid) }
        }
        .onChange(of: model.abStrength) { _, _ in model.reprocess() }
    }

    /// Mirrors the saved settings into the controls (not the temporary ones
    /// the System Mode Check uses).
    private func loadSettings() {
        guard !model.systemPhase.isRunning else { return }
        let current = monitor.clearMicSettings
        if strength != current.displayedStrength {
            strength = current.displayedStrength
        }
        if analyzesEnhanced != current.analyzesEnhancedAudio {
            analyzesEnhanced = current.analyzesEnhancedAudio
        }
        if allowsBluetooth != current.allowsBluetoothInput {
            allowsBluetooth = current.allowsBluetoothInput
        }
        let uid = current.preferredInputUID ?? ""
        if preferredInputUID != uid {
            preferredInputUID = uid
        }
    }

    // MARK: Level

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Input Level")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                listeningControl
            }
            MicLevelBar(levelDb: mic.inputLevelDb, peakDb: mic.peakDb, isActive: isListening)
                .frame(height: 14)
            HStack {
                Text(isListening ? "\(mic.inputLevelDb.roundedInt) dBFS" : "—")
                Spacer()
                Text(isListening ? "Peak \(mic.peakDb.roundedInt) dBFS" : "")
            }
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            if isListening, mic.isClipping {
                Label("Too loud: the microphone is clipping, which distorts every reading. Hold the phone a little farther away or speak more softly.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Talk at your usual practice volume. The bar should move well past the middle without reaching the end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var listeningControl: some View {
        switch monitor.status {
        case .running:
            Label("Listening", systemImage: "mic.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.targetZone)
        case .starting:
            ProgressView()
                .accessibilityLabel("Starting microphone")
        case .idle, .paused, .failed:
            Button("Listen", systemImage: "mic.fill") {
                Task { await model.resumeListening() }
            }
            .buttonStyle(.glass)
            .disabled(model.isBusy)
        case .permissionDenied:
            Label("No mic access", systemImage: "mic.slash.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Noise

    private var noiseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Background Noise")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isListening, let floor = mic.noiseFloorDb {
                    let badge = MicNoiseBadge(noiseFloorDb: floor)
                    Label(badge.title, systemImage: badge.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(badge == .tooNoisy ? Theme.warning : Theme.targetZone)
                }
            }
            Text(noiseDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isSamplingNoise {
                ProgressView(value: mic.captureProgress ?? 0) {
                    Text("Stay quiet for 2 seconds…")
                        .font(.subheadline)
                }
            } else {
                Button {
                    Task { await model.sampleRoomNoise() }
                } label: {
                    Label("Sample Room Noise", systemImage: "waveform")
                }
                .buttonStyle(.glass)
                .disabled(model.isBusy || monitor.status == .permissionDenied)
            }
            if let message = model.noiseMessage {
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(sampledDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var noiseDescription: String {
        guard isListening, let floor = mic.noiseFloorDb else {
            return "Listening measures the room between your words."
        }
        let level = "\(floor.roundedInt) dBFS"
        switch MicNoiseBadge(noiseFloorDb: floor) {
        case .great:
            return "\(level): a quiet room, so readings will be accurate."
        case .ok:
            return "\(level): some background noise. Readings are fine; Clear Mic Light tidies it up."
        case .tooNoisy:
            return "\(level): loud background. Use Clear Mic Strong, or find a quieter spot for the most accurate readings."
        }
    }

    private var sampledDescription: String {
        let intro = "Stay quiet while it listens, so Clear Mic learns this room’s noise. It also keeps learning in your pauses."
        guard let date = monitor.noiseSampledAt else { return intro }
        return "\(intro) Last sampled \(date.formatted(.relative(presentation: .named)))."
    }

    // MARK: Clear Mic

    private var strengthOptions: [ClearMicStrength] {
        settings.isSystemModeAvailable ? [.off, .light, .strong, .system] : [.off, .light, .strong]
    }

    private var clearMicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear Mic")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Clear Mic strength", selection: $strength) {
                ForEach(strengthOptions) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.systemPhase.isRunning)

            Text(strength.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if strength == .strong {
                Label("Strong may make resonance readings slightly less precise.", systemImage: "info.circle")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if strength == .system, let note = monitor.captureFormat?.voiceProcessingNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Live readings from")
                    .font(.subheadline.weight(.semibold))
                Picker("Live readings from", selection: $analyzesEnhanced) {
                    Text("Clear Mic").tag(true)
                    Text("Raw Mic").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(strength == .off || model.systemPhase.isRunning)
                Text("Switch to Raw Mic to compare. Saved recordings always keep the raw sound; Clear Mic is applied when you play or share them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isListening, settings.isEnhancing {
                HStack(spacing: 16) {
                    Label(mic.isGateOpen ? "Voice heard" : "No voice", systemImage: mic.isGateOpen ? "waveform" : "waveform.slash")
                    Label(mic.isNoiseKnown ? "Room learned" : "Learning room", systemImage: mic.isNoiseKnown ? "checkmark.circle" : "hourglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .cardStyle()
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let route = monitor.route {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.inputName)
                            .font(.body.weight(.medium))
                        Text(inputDetail(route))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: route.inputKind.systemImage)
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Text("Use")
                Spacer()
                Picker("Microphone to use", selection: $preferredInputUID) {
                    Text("Automatic").tag("")
                    ForEach(model.inputs) { input in
                        Text("\(input.name) (\(input.kind.title))").tag(input.uid)
                    }
                    if !preferredInputUID.isEmpty, !model.inputs.contains(where: { $0.uid == preferredInputUID }) {
                        Text("Not connected").tag(preferredInputUID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isBusy)
            }

            Toggle("Use Bluetooth Microphones", isOn: $allowsBluetooth)
                .disabled(model.isBusy)
            Text(allowsBluetooth
                 ? "Bluetooth headsets can be picked as the microphone. Where the earbuds support it, Chirp asks for iOS’s high-quality recording mode."
                 : "Off: AirPods and other headsets only play sound, and the iPhone’s own mic records, which is more accurate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = monitor.route?.warningMessage {
                NoticeBanner(title: "Microphone quality", message: warning, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .cardStyle()
    }

    private func inputDetail(_ route: AudioRouteInfo) -> String {
        var parts = [route.inputKind.title]
        if let rate = monitor.captureFormat?.sampleRate, isListening {
            parts.append("\((rate / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
        }
        if route.inputKind == .bluetooth {
            parts.append(route.isHighQualityBluetooth ? "high-quality mode" : "call quality")
        }
        if monitor.captureFormat?.isVoiceProcessing == true, isListening {
            parts.append("iOS voice processing")
        }
        return parts.joined(separator: " · ")
    }
}

/// Record 5 seconds, then hear it raw and with Clear Mic, with the readings
/// for each.
private struct MicABTestCard: View {
    @Bindable var model: MicCheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A/B Test")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Record 5 seconds, then hear the raw microphone and Clear Mic, with the readings for each. Pitch should match; the background should drop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Compare with", selection: $model.abStrength) {
                Text("Light").tag(ClearMicStrength.light)
                Text("Strong").tag(ClearMicStrength.strong)
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)
            if model.monitor.captureFormat?.isVoiceProcessing == true {
                Label("System mode is on, so even the raw take has been through iOS voice processing.", systemImage: "info.circle")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch model.abPhase {
            case .recording:
                Text(ReadingPassages.quickCheck)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                TakeProgressView(recorder: model.recorder)
            case .processing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            case .ready:
                if let comparison = model.comparison {
                    MicABResultsView(model: model, comparison: comparison)
                }
                recordButton(title: "Record Again")
            case .idle:
                recordButton(title: "Record 5 Seconds")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                recordButton(title: "Try Again")
            }
            if let error = model.player.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private func recordButton(title: String) -> some View {
        Button {
            model.runABTest()
        } label: {
            Label(title, systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(model.isBusy || model.monitor.status == .permissionDenied)
    }
}

/// The two versions side by side.
private struct MicABResultsView: View {
    let model: MicCheckModel
    let comparison: MicABComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    playButton(title: "Raw", enhanced: false)
                    playButton(title: comparison.strength.title, enhanced: true)
                }
                row("Pitch", comparison.raw.medianPitch.map(hertz), comparison.enhanced.medianPitch.map(hertz))
                row("Steadiness", comparison.raw.pitchSpreadCents.map(cents), comparison.enhanced.pitchSpreadCents.map(cents))
                row("Voiced", seconds(comparison.raw.voicedSeconds), seconds(comparison.enhanced.voicedSeconds))
                row("Resonance (F2)", comparison.raw.f2.map(hertz), comparison.enhanced.f2.map(hertz))
                row("H1–H2", comparison.raw.h1MinusH2.map(decibels), comparison.enhanced.h1MinusH2.map(decibels))
                row("Background", comparison.raw.backgroundDb.map(level), comparison.enhanced.backgroundDb.map(level))
            }
            .font(.subheadline)
            .monospacedDigit()

            Text(comparison.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Steadiness is how far the pitch wandered (lower is steadier). H1–H2 is the vocal weight measure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func playButton(title: String, enhanced: Bool) -> some View {
        let id = enhanced ? MicCheckModel.enhancedID : MicCheckModel.rawID
        let isPlaying = model.player.playingID == id
        return Button {
            Task { await model.togglePlayback(enhanced: enhanced) }
        } label: {
            Label(title, systemImage: isPlaying ? "stop.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isPlaying ? "Stop \(title)" : "Play \(title)")
    }

    private func row(_ title: String, _ raw: String?, _ enhanced: String?) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(raw ?? "—")
                .accessibilityLabel("\(title), raw: \(raw ?? "none")")
            Text(enhanced ?? "—")
                .accessibilityLabel("\(title), \(comparison.strength.title): \(enhanced ?? "none")")
        }
    }

    private func hertz(_ value: Double) -> String { "\(value.roundedInt) Hz" }
    private func cents(_ value: Double) -> String { "±\(value.roundedInt)¢" }
    private func decibels(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(1)))) dB" }
    private func level(_ value: Double) -> String { "\(value.roundedInt) dBFS" }
    private func seconds(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(1)))) s" }
}

/// Tests iOS voice processing before offering it as "System" (SPEC section 24.4).
private struct MicSystemCheckCard: View {
    let model: MicCheckModel

    private var result: SystemModeCheckResult? { model.monitor.clearMicSettings.systemCheck }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iOS Voice Processing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("iOS can clean up the microphone itself (echo and noise suppression). It can change pitch readings, so Chirp tests it first: hum one steady, comfortable note for 4 seconds, twice. If it passes, “System” appears in Clear Mic. Automatic gain always stays off.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.systemPhase {
            case .preparing(let step):
                HStack(spacing: 10) {
                    ProgressView()
                    Text(step == 1 ? "Turning on voice processing…" : "Switching back to the plain microphone…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            case .recording(let step):
                Text("Take \(step) of 2: hum a steady note")
                    .font(.title3.weight(.medium))
                TakeProgressView(recorder: model.recorder)
            case .idle, .finished, .failed:
                if case .failed(let message) = model.systemPhase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.passed ? "Passed: System is available" : "Not recommended on this iPhone")
                                .font(.subheadline.weight(.semibold))
                            Text(result.reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Tested \(result.date.formatted(date: .abbreviated, time: .shortened)) at \((result.systemSampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(result.passed ? Theme.targetZone : Theme.warning)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    model.runSystemCheck()
                } label: {
                    Label(result == nil ? "Test System Mode" : "Test Again", systemImage: "waveform.badge.mic")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(model.isBusy || model.monitor.status == .permissionDenied)
            }
        }
        .cardStyle()
    }
}
