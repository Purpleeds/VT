import Foundation
import SwiftData
import SwiftUI

/// Every saved practice session, newest first. Charts arrive in Stage 5;
/// for now this is the list of sessions with their details and recordings.
struct SessionHistoryView: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Query(sort: \PracticeSession.startDate, order: .reverse) private var sessions: [PracticeSession]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "waveform",
                        description: Text("Practice for a few seconds and your session will appear here with its stats, check-in, and recordings.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(sessions) { session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRow(session: session, isCurrent: session.id == sessionController.monitor.sessionID)
                                }
                                .deleteDisabled(!sessionController.canDelete(session))
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("Sessions")
                        } footer: {
                            Text("Swipe left on a session to delete it with its recordings. Charts of your progress are coming soon.")
                        }
                    }
                }
            }
            .navigationTitle("Progress")
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { sessions[$0] }
        for session in doomed {
            sessionController.delete(session)
        }
    }
}

private struct SessionRow: View {
    let session: PracticeSession
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.startDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.headline)
                Spacer(minLength: 8)
                if isCurrent {
                    Label("Now", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.targetZone)
                } else if let comfort = session.comfort {
                    Label(comfort.title, systemImage: comfort.systemImage)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(comfort == .fine ? Color.secondary : Theme.warning)
                        .accessibilityLabel("Throat felt \(comfort.title.lowercased())")
                }
            }
            HStack(spacing: 14) {
                Label(SessionFormat.duration(session.duration), systemImage: "clock")
                    .accessibilityLabel(SessionFormat.spokenDuration(session.duration))
                if let pitch = session.averagePitch {
                    Label(SessionFormat.hertz(pitch), systemImage: "waveform")
                        .accessibilityLabel("average \(Int(pitch.rounded())) hertz")
                }
                if let percent = session.percentInTarget {
                    Label(SessionFormat.percent(percent), systemImage: "target")
                        .accessibilityLabel("\(SessionFormat.percent(percent)) in target")
                }
                if let count = session.recordings?.count, count > 0 {
                    Label("\(count)", systemImage: "record.circle")
                        .accessibilityLabel(count == 1 ? "1 recording" : "\(count) recordings")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
