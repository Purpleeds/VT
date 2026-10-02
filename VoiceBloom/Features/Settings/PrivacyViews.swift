import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Manual backup to a file and restore from one (SPEC section 13).
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(AppLock.self) private var appLock

    @State private var includesRecordings = true
    @State private var exportDocument: BackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var pendingArchive: BackupArchive?
    @State private var isWorking = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Form {
            if let message {
                Section {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.subheadline)
                }
            }

            if let archive = pendingArchive {
                restoreConfirmation(archive)
            }

            Section {
                Toggle("Include recordings", isOn: $includesRecordings)
                Button {
                    Task { await makeBackup() }
                } label: {
                    Label("Back Up to a File", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)
            } header: {
                Text("Back up")
            } footer: {
                Text("Saves your sessions, check-ins, lesson progress, target voices, scenario results, journal entries, achievements and settings in one file. You choose where it goes (On My iPhone, iCloud Drive, a USB drive). With recordings included, your audio is in the file too, so keep it somewhere private. Your Gemini key and microphone calibration are never included.")
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Restore from a Backup", systemImage: "square.and.arrow.down")
                }
                .disabled(isWorking)
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring replaces everything on this iPhone with the backup. You’ll see what’s in the file before anything changes.")
            }

            if isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Working…")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: BackupService.fileName()
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                show("Backup saved.", isError: false)
            case .failure:
                show("The backup wasn’t saved.", isError: true)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .sensoryFeedback(.success, trigger: message) { _, newValue in
            newValue != nil && !messageIsError
        }
    }

    private func restoreConfirmation(_ archive: BackupArchive) -> some View {
        Section {
            LabeledContent("Made", value: archive.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Sessions", value: "\(archive.sessions.count)")
            LabeledContent("Recordings", value: "\(archive.recordings.count)")
            if archive.files.isEmpty, !archive.recordings.isEmpty {
                Text("This backup doesn’t include the audio, so recordings will show without sound.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Replace All Data with This Backup", role: .destructive) {
                Task { await restore(archive) }
            }
            .disabled(isWorking)
            Button("Cancel") {
                pendingArchive = nil
            }
        } header: {
            Text("Restore this backup?")
        } footer: {
            Text("Everything currently on this iPhone will be replaced. This can’t be undone.")
        }
    }

    // MARK: Actions

    private func makeBackup() async {
        isWorking = true
        defer { isWorking = false }
        // Let the progress row appear before the work starts.
        await Task.yield()
        do {
            let archive = try BackupService.makeArchive(context: modelContext, includeFiles: includesRecordings)
            exportDocument = BackupDocument(data: try BackupService.encode(archive))
            isExporting = true
        } catch {
            show("The backup couldn’t be made. Please try again.", isError: true)
        }
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                pendingArchive = try BackupService.decode(data)
                message = nil
            } catch let error as BackupError {
                show(error.localizedDescription, isError: true)
            } catch {
                show("That file couldn’t be opened.", isError: true)
            }
        case .failure:
            show("That file couldn’t be opened.", isError: true)
        }
    }

    private func restore(_ archive: BackupArchive) async {
        isWorking = true
        defer { isWorking = false }
        await monitor.pause(.user)
        do {
            try BackupService.restore(archive, context: modelContext)
        } catch {
            show("The backup couldn’t be restored. Please try again.", isError: true)
            return
        }
        pendingArchive = nil

        let profile = ProfileStore(context: modelContext).profile()
        try? modelContext.save()
        monitor.resetSession()
        monitor.targetZone = profile.targetZone
        monitor.applyReferences(profile.personalReferences)
        appLock.isEnabled = profile.faceIDLockEnabled
        sessionController.dismissCheckInReminder()
        sessionController.refreshRestDay()
        if let time = profile.reminderTime {
            await NotificationService.scheduleDailyReminder(at: time)
        } else {
            NotificationService.cancelDailyReminder()
        }
        _ = MotivationCenter.refresh(context: modelContext)
        show("Backup restored: \(archive.sessions.count) sessions and \(archive.recordings.count) recordings.", isError: false)
    }

    private func show(_ text: String, isError: Bool) {
        messageIsError = isError
        message = text
    }
}

/// Standard or neutral home-screen icon (SPEC section 13).
struct AppIconPickerView: View {
    @State private var current = AppIconService.current
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        Task { await select(choice) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(choice.previewImageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                                .accessibilityHidden(true)
                            Text(choice.title)
                            Spacer()
                            if choice == current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                    .disabled(!AppIconService.isSupported)
                }
            } footer: {
                Text("The neutral icon is a plain grey list with nothing about voice on it.")
            }

            if failed || !AppIconService.isSupported {
                Section {
                    Label("The icon couldn’t be changed on this iPhone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                }
            }

            Section {
                Text("iOS doesn’t let apps rename themselves on the Home Screen. To hide the name as well:")
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open the Shortcuts app and tap +.")
                    Text("2. Add the action Open App and choose Chirp.")
                    Text("3. Tap the share button › Add to Home Screen, and pick any name and icon.")
                    Text("4. Long-press Chirp’s own icon › Remove App › Remove from Home Screen. It stays in the App Library.")
                }
                .font(.subheadline)
            } header: {
                Text("A neutral name")
            }
        }
        .navigationTitle("App Icon")
        .sensoryFeedback(.selection, trigger: current)
    }

    private func select(_ choice: AppIconChoice) async {
        failed = false
        if await AppIconService.set(choice) {
            current = choice
        } else {
            failed = true
        }
    }
}
