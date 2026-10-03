import Foundation
import SwiftData
import SwiftUI

/// Settings (SPEC section 16).
struct SettingsView: View {
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(AppLock.self) private var appLock
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    var body: some View {
        Group {
            if let profile = profiles.first {
                // A new profile (after restoring a backup or deleting all
                // data) gets a fresh form, so no change handlers fire on it.
                SettingsForm(profile: profile)
                    .id(profile.persistentModelID)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "gearshape", description: Text("Please restart Chirp."))
            }
        }
        .navigationTitle("Settings")
    }
}

private struct SettingsForm: View {
    @Bindable var profile: UserProfile
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(AppLock.self) private var appLock
    @Environment(\.modelContext) private var modelContext

    @State private var isShowingCalibration = false
    @State private var isShowingPlacement = false
    @State private var isShowingFeedbackSettings = false
    @State private var isShowingBaseline = false
    @State private var isConfirmingDelete = false
    @State private var remindersOn = false
    @AppStorage(MotivationCenter.nudgeKey) private var eveningNudge = true
    @AppStorage(PrivacyPreferences.appSwitcherCoverKey) private var coversAppSwitcher = true
    @AppStorage(PrivacyPreferences.notificationStyleKey) private var notificationStyleRawValue = NotificationWordingStyle.neutral.rawValue
    @State private var reminderTime = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var lockOn = false
    @State private var message: String?
    @State private var aiProvider = AppPreferences.aiProvider
    @State private var geminiKey = ""
    @State private var hasGeminiKey = KeychainStore.string(account: KeychainStore.geminiAPIKeyAccount) != nil

    var body: some View {
        Form {
            if let message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.subheadline)
                }
            }

            targetsSection
            displaySection
            feedbackSection
            microphoneSection
            practiceSection
            aiSection
            privacySection
            appearanceSection

            Section {
                LabeledContent("Version", value: Self.versionText)
            } footer: {
                Text("Chirp analyzes your voice on this iPhone. No analytics, no tracking, no ads.")
            }
        }
        .onAppear(perform: loadState)
        .onChange(of: profile.goalTypeRawValue) { _, _ in
            profile.setGoal(profile.goalType)
            applyTargets()
        }
        .onChange(of: profile.targetPitchLow) { _, _ in applyTargets() }
        .onChange(of: profile.targetPitchHigh) { _, _ in applyTargets() }
        .onChange(of: remindersOn) { _, _ in Task { await updateReminder() } }
        .onChange(of: eveningNudge) { _, _ in _ = MotivationCenter.refresh(context: modelContext) }
        .onChange(of: reminderTime) { _, _ in Task { await updateReminder() } }
        .onChange(of: notificationStyleRawValue) { _, _ in
            // Reschedule so pending reminders use the new wording.
            if remindersOn {
                Task { await updateReminder() }
            }
            _ = MotivationCenter.refresh(context: modelContext)
        }
        .onChange(of: lockOn) { _, newValue in
            guard newValue != profile.faceIDLockEnabled else { return }
            Task { await setLock(newValue) }
        }
        .onChange(of: aiProvider) { _, newValue in AppPreferences.aiProvider = newValue }
        .sheet(isPresented: $isShowingCalibration) {
            MicCalibrationView(monitor: monitor)
        }
        .sheet(isPresented: $isShowingPlacement) {
            PlacementTestView(profile: profile, monitor: monitor) { week in
                if let week {
                    message = "Placement saved: start at week \(week)."
                }
            }
        }
        .sheet(isPresented: $isShowingFeedbackSettings) {
            FeedbackSettingsView()
        }
        .sheet(isPresented: $isShowingBaseline) {
            NavigationStack {
                ScrollView {
                    BaselineRecordingView(purpose: profile.hasBaseline ? .reRecord : .dayOne, profile: profile, monitor: monitor) { saved in
                        isShowingBaseline = false
                        if saved {
                            message = profile.hasBaseline ? "Baseline saved." : nil
                        }
                    }
                    .padding()
                }
                .background { AppBackground() }
                .navigationTitle("Baseline Recording")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingBaseline = false }
                    }
                }
            }
        }
        .confirmationDialog("Delete all data?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) {
                Task { await deleteEverything() }
            }
        } message: {
            Text("This permanently deletes every session, recording, check-in, lesson progress, target voice and setting on this iPhone. It can’t be undone.")
        }
    }

    // MARK: Sections

    private var targetsSection: some View {
        Section {
            Picker("Goal", selection: $profile.goalTypeRawValue) {
                ForEach(GoalType.allCases) { goal in
                    Text(goal.title).tag(goal.rawValue)
                }
            }
            PitchRangeEditor(profile: profile)
            NavigationLink {
                VoiceTargetsView(profile: profile)
            } label: {
                LabeledContent("Resonance, weight & intonation", value: hasCustomTargets ? "Custom" : "Default")
            }
        } header: {
            Text("Targets")
        } footer: {
            Text("Current pitch target: \(profile.targetZone.formatted). You can also set targets from a voice you like in the Target Voice tab.")
        }
    }

    private var hasCustomTargets: Bool {
        profile.targetF2 != nil || profile.targetF3 != nil || profile.targetH1MinusH2 != nil || profile.targetIntonationSD != nil
    }

    private var displaySection: some View {
        Section("Display") {
            Picker("Pitch shown as", selection: $profile.displayUnitsRawValue) {
                ForEach(DisplayUnits.allCases) { units in
                    Text(units.title).tag(units.rawValue)
                }
            }
        }
    }

    private var feedbackSection: some View {
        Section("Alerts") {
            Button {
                isShowingFeedbackSettings = true
            } label: {
                LabeledContent("Slip alerts & feedback", value: monitor.feedbackSettings.sensitivity.title)
            }
            .foregroundStyle(.primary)
        }
    }

    private var microphoneSection: some View {
        Section {
            NavigationLink {
                MicCheckView()
            } label: {
                LabeledContent("Mic Check & Clear Mic", value: "Clear Mic \(monitor.clearMicSettings.effectiveStrength.title)")
            }
            Button("Re-run Mic Calibration") { isShowingCalibration = true }
            Button("Re-run Placement Test") { isShowingPlacement = true }
            Button(profile.hasBaseline ? "Re-record Baseline" : "Record Baseline") { isShowingBaseline = true }
        } header: {
            Text("Microphone & tests")
        } footer: {
            if let placement = AppPreferences.placementWeek {
                Text("Placement test recommended starting at week \(placement).")
            }
        }
    }

    private var practiceSection: some View {
        Section("Practice") {
            Picker("Daily goal", selection: $profile.dailyGoalMinutes) {
                ForEach([10, 15, 20, 30], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            Picker("Session length", selection: $profile.defaultSessionLengthRawValue) {
                ForEach(SessionLength.allCases) { length in
                    Text("\(length.title) (\(length.minutes) min)").tag(length.rawValue)
                }
            }
            Toggle("Daily reminder", isOn: $remindersOn)
            if remindersOn {
                DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                Toggle("Evening nudge if I haven’t practiced", isOn: $eveningNudge)
            }
        }
    }

    private var aiSection: some View {
        Section {
            Toggle("AI Coach", isOn: $profile.aiCoachEnabled)
            if profile.aiCoachEnabled {
                Picker("Coach", selection: $aiProvider) {
                    ForEach(AICoachProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                LabeledContent("Coach in use", value: activeEngine.title)
                if aiProvider != .ruleBased, let reason = FoundationModelsCoach.unavailableReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if aiProvider == .automatic {
                    SecureField(hasGeminiKey ? "Gemini key saved (enter to replace)" : "Optional Gemini API key", text: $geminiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(saveGeminiKey)
                    if !geminiKey.isEmpty {
                        Button("Save Key", action: saveGeminiKey)
                    }
                    if hasGeminiKey {
                        Button("Remove Gemini Key", role: .destructive) {
                            KeychainStore.set(nil, account: KeychainStore.geminiAPIKeyAccount)
                            hasGeminiKey = false
                        }
                    }
                }
            }
        } header: {
            Text("AI Coach")
        } footer: {
            Text(aiFooter)
        }
    }

    private var activeEngine: CoachEngine {
        // Read `hasGeminiKey` so the row updates when the key changes.
        _ = hasGeminiKey
        return CoachEngine.choose(
            enabled: profile.aiCoachEnabled,
            provider: aiProvider,
            onDeviceAvailable: FoundationModelsCoach.isAvailable,
            hasGeminiKey: hasGeminiKey
        )
    }

    private var aiFooter: String {
        guard profile.aiCoachEnabled else {
            return "With the AI Coach off you still get simple built-in tips."
        }
        switch aiProvider {
        case .automatic:
            return "Uses Apple’s on-device model when your iPhone supports it. Only if it doesn’t, and you add your own free Gemini key (from aistudio.google.com), are text stats, transcripts and chat messages sent to Google; audio never is. The key is kept in the Keychain on this iPhone. Turn the AI Coach off to stop all AI features."
        case .onDeviceOnly:
            return "Only Apple’s on-device model is used. Nothing leaves your iPhone."
        case .ruleBased:
            return "Preset tips based on your stats. Nothing leaves your iPhone."
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Lock with \(AppLock.methodName)", isOn: $lockOn)
            Toggle("Hide in app switcher", isOn: $coversAppSwitcher)
            Picker("Notification wording", selection: $notificationStyleRawValue) {
                ForEach(NotificationWordingStyle.allCases) { style in
                    Text(style.title).tag(style.rawValue)
                }
            }
            NavigationLink {
                AppIconPickerView()
            } label: {
                Text("App icon")
            }
            NavigationLink {
                SplitStorageView()
            } label: {
                Text("Split Tracks Storage")
            }
            NavigationLink {
                PitchTrackLatencyView()
            } label: {
                Text("Pitch Track timing")
            }
            NavigationLink {
                BackupRestoreView()
            } label: {
                Text("Backup & restore")
            }
            LabeledContent("iCloud sync", value: "Not available")
            Button("Delete All Data", role: .destructive) {
                isConfirmingDelete = true
            }
        } header: {
            Text("Privacy & data")
        } footer: {
            Text("All data is stored on this iPhone only. Recordings are excluded from iCloud and computer backups; use Backup & restore to keep a copy. iCloud sync needs a paid Apple Developer account, so it’s off in this build. Neutral notifications just say “Time for practice”. No analytics, no tracking, no ads.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $profile.themeRawValue) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    static var versionText: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: Actions

    private func loadState() {
        if let time = profile.reminderTime {
            remindersOn = true
            reminderTime = time
        }
        lockOn = profile.faceIDLockEnabled
    }

    private func applyTargets() {
        monitor.targetZone = profile.targetZone
        try? modelContext.save()
    }

    private func updateReminder() async {
        if remindersOn {
            if await NotificationService.scheduleDailyReminder(at: reminderTime) {
                profile.reminderTime = reminderTime
            } else {
                remindersOn = false
                profile.reminderTime = nil
                message = "Notifications are off for Chirp. Turn them on in the Settings app to get reminders."
            }
        } else {
            profile.reminderTime = nil
            NotificationService.cancelDailyReminder()
        }
    }

    private func setLock(_ enabled: Bool) async {
        guard enabled else {
            profile.faceIDLockEnabled = false
            appLock.isEnabled = false
            return
        }
        guard AppLock.isAvailable else {
            message = "Set a passcode on your iPhone first to use the app lock."
            lockOn = false
            return
        }
        if await appLock.authenticate(reason: "Turn on the Chirp lock") {
            profile.faceIDLockEnabled = true
            appLock.isEnabled = true
        } else {
            lockOn = false
        }
    }

    private func saveGeminiKey() {
        let trimmed = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasGeminiKey = KeychainStore.set(trimmed, account: KeychainStore.geminiAPIKeyAccount)
        geminiKey = ""
        message = hasGeminiKey ? "Gemini key saved in the Keychain." : "The key couldn’t be saved."
    }

    private func deleteEverything() async {
        await monitor.pause(.user)
        do {
            try DataEraser.eraseEverything(context: modelContext)
            await monitor.clearCalibration()
            await monitor.resetClearMic()
            monitor.resetSession()
            monitor.applyReferences(.none)
            sessionController.dismissCheckInReminder()
            appLock.isEnabled = false
            // A fresh profile brings back onboarding.
            _ = ProfileStore(context: modelContext).profile()
            try? modelContext.save()
        } catch {
            message = "Some data couldn’t be deleted. Please try again."
        }
    }
}

/// Resonance, weight and intonation targets (defaults or custom values).
struct VoiceTargetsView: View {
    @Bindable var profile: UserProfile
    @Environment(LiveVoiceMonitor.self) private var monitor

    private let speechDefault = ResonanceMode.speech.defaultReference

    var body: some View {
        Form {
            Section {
                optionalStepper("F2 target", value: $profile.targetF2, defaultValue: speechDefault.targetF2, range: 1_400...2_400, step: 10, unit: "Hz")
                optionalStepper("F3 target", value: $profile.targetF3, defaultValue: speechDefault.targetF3, range: 2_400...3_400, step: 10, unit: "Hz")
            } header: {
                Text("Resonance")
            } footer: {
                Text("Average F2 and F3 in running speech. Higher sounds brighter. Default: typical adult female averages.")
            }
            Section {
                optionalStepper("H1–H2 target", value: $profile.targetH1MinusH2, defaultValue: WeightReference.standard.targetH1MinusH2, range: 4...16, step: 0.5, unit: "dB")
            } header: {
                Text("Vocal weight")
            } footer: {
                Text("A larger H1–H2 difference sounds lighter.")
            }
            Section {
                optionalStepper("Variability target", value: $profile.targetIntonationSD, defaultValue: IntonationReference.standard.targetStandardDeviation, range: 2...6, step: 0.25, unit: "st")
            } header: {
                Text("Intonation")
            } footer: {
                Text("Pitch variation in semitones (standard deviation). More variation sounds more melodic.")
            }
            Section {
                LabeledContent("Baseline", value: profile.hasBaseline ? "From your Day 1 recording" : "Typical starting values")
                Button("Reset to Defaults") {
                    profile.targetF2 = nil
                    profile.targetF3 = nil
                    profile.targetH1MinusH2 = nil
                    profile.targetIntonationSD = nil
                }
            } footer: {
                Text("Scores run from your baseline (0) to these targets (100).")
            }
        }
        .navigationTitle("Voice Targets")
        .onChange(of: profile.personalReferences) { _, newValue in
            monitor.applyReferences(newValue)
        }
    }

    /// A stepper for a value that is nil (use the default) until changed.
    private func optionalStepper(
        _ title: String,
        value: Binding<Double?>,
        defaultValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        let current = value.wrappedValue ?? defaultValue
        return Stepper {
            LabeledContent(title, value: "\(current.formatted(.number.precision(.fractionLength(step < 1 ? 1 : 0)))) \(unit)\(value.wrappedValue == nil ? " (default)" : "")")
        } onIncrement: {
            value.wrappedValue = min(current + step, range.upperBound)
        } onDecrement: {
            value.wrappedValue = max(current - step, range.lowerBound)
        }
    }
}
