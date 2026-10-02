import Foundation
import SwiftData
import SwiftUI
import UIKit

/// First-launch setup (SPEC section 1), in nine steps. Choices are saved to
/// the profile as the user goes; the flow ends by marking onboarding complete.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case health
        case permissions
        case calibration
        case goal
        case experience
        case dailyGoal
        case baseline
        case extras

        var number: Int { rawValue + 1 }
    }

    let profile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(AppLock.self) private var appLock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StepIndicator(current: step.number, total: Step.allCases.count)
                    content
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { AppBackground() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .welcome {
                        Button("Back", systemImage: "chevron.left") {
                            go(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep { next() }
        case .health:
            OnboardingHealthStep { next() }
        case .permissions:
            OnboardingPermissionsStep { next() }
        case .calibration:
            OnboardingCalibrationStep { next() }
        case .goal:
            OnboardingGoalStep(profile: profile) {
                monitor.targetZone = profile.targetZone
                save()
                next()
            }
        case .experience:
            OnboardingExperienceStep(profile: profile) {
                save()
                next()
            }
        case .dailyGoal:
            OnboardingDailyGoalStep(profile: profile) {
                save()
                next()
            }
        case .baseline:
            VStack(alignment: .leading, spacing: 16) {
                BaselineRecordingView(purpose: .dayOne, profile: profile, monitor: monitor) { _ in
                    next()
                }
                Button("Skip for Now") {
                    next()
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                Text("You can record your baseline later in More › Settings. Until then, scores use typical starting values.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .extras:
            OnboardingExtrasStep(profile: profile) {
                finish()
            }
        }
    }

    private func next() {
        go(to: Step(rawValue: step.rawValue + 1) ?? .extras)
    }

    private func go(to newStep: Step) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            step = newStep
        }
    }

    private func save() {
        try? modelContext.save()
    }

    private func finish() {
        monitor.targetZone = profile.targetZone
        monitor.applyReferences(profile.personalReferences)
        appLock.isEnabled = profile.faceIDLockEnabled
        profile.hasCompletedOnboarding = true
        save()
    }
}

// MARK: - 1. Welcome

private struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to VoiceBloom")
                .font(.largeTitle.weight(.bold))
            Text("Voice training is like learning an instrument: small, regular practice changes four things your ear hears as feminine or masculine.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OnboardingConceptRow(symbol: "music.note", title: "Pitch", detail: "How high or low your voice is. It matters, but less than most people think.")
            OnboardingConceptRow(symbol: "speaker.wave.2", title: "Resonance", detail: "How bright or dark your voice sounds, shaped by your throat and mouth. The biggest factor of all.")
            OnboardingConceptRow(symbol: "leaf", title: "Vocal weight", detail: "How heavy or light your voice feels, from how firmly your vocal folds meet.")
            OnboardingConceptRow(symbol: "waveform.path", title: "Intonation", detail: "The melody of your speech: how your pitch moves up and down.")
            Label("Everything is analyzed on this iPhone. Your recordings never leave it.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
            OnboardingContinueButton(title: "Get started", action: onContinue)
        }
    }
}

private struct OnboardingConceptRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingContinueButton: View {
    var title = "Continue"
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
        .padding(.top, 8)
    }
}

// MARK: - 2. Health notice

private struct OnboardingHealthStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text("Training should never hurt")
                .font(.title.weight(.bold))
            bullet("Stop right away if you feel pain, tightness, burning or hoarseness.")
            bullet("Short sessions, several times a day, are better than one long one. VoiceBloom suggests a soft limit of 45 minutes a day.")
            bullet("Drink water, and rest your voice when it feels tired.")
            bullet("If problems last more than a couple of weeks, see a doctor or a speech-language pathologist (SLP).")
            Text("VoiceBloom’s strain and comfort readings are rough indicators from a phone microphone, not a medical diagnosis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OnboardingContinueButton(title: "I understand", action: onContinue)
        }
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.targetZone)
        }
    }
}

// MARK: - 3. Permissions

private struct OnboardingPermissionsStep: View {
    let onContinue: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var microphone = MicrophonePermission.current
    @State private var speechAllowed = SpeechAuthorization.isAuthorized
    @State private var speechAsked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Microphone and speech")
                .font(.title.weight(.bold))
            Text("VoiceBloom needs the microphone to hear your voice. Speech recognition is optional: it shows a live transcript while you read.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                symbol: "mic.fill",
                title: "Microphone",
                detail: "Required. Audio is analyzed on this iPhone and never leaves it.",
                status: microphoneStatus,
                isGranted: microphone == .granted
            ) {
                Task {
                    if microphone == .denied {
                        openSettings()
                    } else {
                        _ = await MicrophonePermission.request()
                        microphone = MicrophonePermission.current
                    }
                }
            }

            permissionRow(
                symbol: "captions.bubble.fill",
                title: "Speech recognition",
                detail: "Optional. Runs on the device; nothing is sent to Apple.",
                status: speechAllowed ? "Allowed" : (speechAsked ? "Off" : "Not set"),
                isGranted: speechAllowed
            ) {
                Task {
                    speechAllowed = await SpeechAuthorization.request()
                    speechAsked = true
                }
            }

            OnboardingContinueButton(title: microphone == .granted ? "Continue" : "Continue without the microphone", action: onContinue)
            if microphone != .granted {
                Text("You can allow the microphone later in the Settings app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var microphoneStatus: String {
        switch microphone {
        case .granted: "Allowed"
        case .denied: "Off: open Settings"
        case .undetermined: "Not set"
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String, status: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isGranted {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.targetZone)
                } else {
                    Button("Allow", action: action)
                        .buttonStyle(.glass)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

// MARK: - 4. Calibration

private struct OnboardingCalibrationStep: View {
    let onContinue: () -> Void
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var isShowingCalibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate your microphone")
                .font(.title.weight(.bold))
            Text("Fifteen seconds: stay quiet for 5 seconds so VoiceBloom can measure your room, then say “aah” to set your input level. It makes every meter more accurate, and warns you if the room is too noisy.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let calibration = monitor.calibration {
                Label("Calibrated (room noise \(calibration.noiseFloorDb.roundedInt) dB)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.targetZone)
                OnboardingContinueButton(action: onContinue)
                Button("Calibrate Again") {
                    isShowingCalibration = true
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            } else {
                OnboardingContinueButton(title: "Start calibration") {
                    isShowingCalibration = true
                }
                Button("Skip for Now", action: onContinue)
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $isShowingCalibration) {
            MicCalibrationView(monitor: monitor)
        }
    }
}

// MARK: - 5. Goal

private struct OnboardingGoalStep: View {
    @Bindable var profile: UserProfile
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What’s your goal?")
                .font(.title.weight(.bold))
            Text("This sets your pitch target zone. You can change it any time in Settings, or set it from a voice you like in the Target Voice tab.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(GoalType.allCases) { goal in
                SelectableCard(
                    title: goal.title,
                    detail: detail(for: goal),
                    isSelected: profile.goalType == goal
                ) {
                    profile.setGoal(goal)
                }
            }

            if profile.goalType == .custom {
                PitchRangeEditor(profile: profile)
                    .cardStyle()
            }

            OnboardingContinueButton(action: onContinue)
        }
    }

    private func detail(for goal: GoalType) -> String {
        switch goal {
        case .feminine: "Target \(GoalType.feminine.defaultTarget.formatted), a typical feminine speaking range."
        case .androgynous: "Target \(GoalType.androgynous.defaultTarget.formatted), between typical ranges."
        case .custom: "Choose your own range."
        }
    }
}

/// Two steppers for the pitch target range.
struct PitchRangeEditor: View {
    @Bindable var profile: UserProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $profile.targetPitchLow, in: 90...max(90, profile.targetPitchHigh - 10), step: 5) {
                LabeledContent("Lowest", value: "\(Int(profile.targetPitchLow)) Hz")
            }
            Stepper(value: $profile.targetPitchHigh, in: min(350, profile.targetPitchLow + 10)...350, step: 5) {
                LabeledContent("Highest", value: "\(Int(profile.targetPitchHigh)) Hz")
            }
        }
    }
}

/// A large tappable option with a checkmark (selection isn't shown by color alone).
struct SelectableCard: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.targetZone : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.targetZone : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 6. Experience

private struct OnboardingExperienceStep: View {
    @Bindable var profile: UserProfile
    let onContinue: () -> Void
    @Environment(LiveVoiceMonitor.self) private var monitor
    @State private var isShowingPlacement = false
    @State private var placementWeek = AppPreferences.placementWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your experience")
                .font(.title.weight(.bold))
            Text("Everyone starts somewhere. If you’ve trained before, a 5-minute placement test can skip the parts you already know.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ExperienceLevel.allCases) { level in
                SelectableCard(title: level.title, detail: detail(for: level), isSelected: profile.experienceLevel == level) {
                    profile.experienceLevel = level
                }
            }

            if profile.experienceLevel != .beginner {
                VStack(alignment: .leading, spacing: 10) {
                    if let placementWeek {
                        Label("Placement test done: start at week \(placementWeek).", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.targetZone)
                    }
                    Button {
                        isShowingPlacement = true
                    } label: {
                        Label(placementWeek == nil ? "Take the placement test (5 min)" : "Retake the placement test", systemImage: "list.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }

            OnboardingContinueButton(action: onContinue)
        }
        .sheet(isPresented: $isShowingPlacement) {
            PlacementTestView(profile: profile, monitor: monitor) { week in
                if let week {
                    placementWeek = week
                }
            }
        }
    }

    private func detail(for level: ExperienceLevel) -> String {
        switch level {
        case .beginner: "New to voice training. Start with the foundations."
        case .someTraining: "You’ve practiced a bit, on your own or with videos."
        case .experienced: "You’ve trained for a while or worked with a coach."
        }
    }
}

// MARK: - 7. Daily goal

private struct OnboardingDailyGoalStep: View {
    @Bindable var profile: UserProfile
    let onContinue: () -> Void
    @State private var remindersOn = false
    @State private var reminderTime = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var notificationsDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Daily goal")
                .font(.title.weight(.bold))
            Text("Little and often works best. Pick a goal that feels easy to keep.")
                .foregroundStyle(.secondary)

            Picker("Minutes per day", selection: $profile.dailyGoalMinutes) {
                ForEach([10, 15, 20, 30], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)

            Picker("Usual session length", selection: $profile.defaultSessionLengthRawValue) {
                ForEach(SessionLength.allCases) { length in
                    Text("\(length.title) · \(length.minutes) min").tag(length.rawValue)
                }
            }

            Toggle("Daily reminder", isOn: $remindersOn)
            if remindersOn {
                DatePicker("Remind me at", selection: $reminderTime, displayedComponents: .hourAndMinute)
                Text("Reminders say only “Time for practice”, so nobody else can tell what the app is for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if notificationsDenied {
                Label("Notifications are off for VoiceBloom. You can turn them on in the Settings app.", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }

            OnboardingContinueButton {
                Task {
                    if remindersOn {
                        let scheduled = await NotificationService.scheduleDailyReminder(at: reminderTime)
                        profile.reminderTime = scheduled ? reminderTime : nil
                        notificationsDenied = !scheduled
                        if !scheduled { return }
                    } else {
                        profile.reminderTime = nil
                        NotificationService.cancelDailyReminder()
                    }
                    onContinue()
                }
            }
        }
        .onAppear {
            if let time = profile.reminderTime {
                remindersOn = true
                reminderTime = time
            }
        }
    }
}

// MARK: - 9. Extras

private struct OnboardingExtrasStep: View {
    @Bindable var profile: UserProfile
    let onFinish: () -> Void
    @Environment(AppLock.self) private var appLock
    @State private var lockMessage: String?
    @State private var lockOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Last touches")
                .font(.title.weight(.bold))
            Text("Both are optional and can be changed in Settings.")
                .foregroundStyle(.secondary)

            Toggle(isOn: $lockOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock with \(AppLock.methodName)")
                        .font(.headline)
                    Text("Ask for \(AppLock.methodName) when opening VoiceBloom, so your practice stays private.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .cardStyle()
            if let lockMessage {
                Text(lockMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }

            Toggle(isOn: $profile.aiCoachEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Coach")
                        .font(.headline)
                    Text("Personal tips after sessions, using Apple’s on-device model when your iPhone supports it. Without it you still get simple built-in tips.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .cardStyle()

            OnboardingContinueButton(title: "Start practicing", action: onFinish)
        }
        .onAppear {
            lockOn = profile.faceIDLockEnabled
        }
        .onChange(of: lockOn) { _, newValue in
            guard newValue != profile.faceIDLockEnabled else { return }
            Task { await setLock(newValue) }
        }
    }

    private func setLock(_ enabled: Bool) async {
        lockMessage = nil
        guard enabled else {
            profile.faceIDLockEnabled = false
            return
        }
        guard AppLock.isAvailable else {
            lockMessage = "Set a passcode on your iPhone first to use the app lock."
            lockOn = false
            return
        }
        if await appLock.authenticate(reason: "Turn on the VoiceBloom lock") {
            profile.faceIDLockEnabled = true
        } else {
            lockOn = false
        }
    }
}
