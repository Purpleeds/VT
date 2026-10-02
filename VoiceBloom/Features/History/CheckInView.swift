import Foundation
import SwiftUI

/// The post-session check-in: "How did your throat feel?" and "How natural
/// did your voice feel?" (SPEC section 4).
struct CheckInSheet: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(\.dismiss) private var dismiss
    let request: CheckInRequest

    var body: some View {
        NavigationStack {
            if let session = sessionController.session(id: request.id) {
                CheckInForm(session: session)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "questionmark.circle",
                    description: Text("This session may have been deleted.")
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct CheckInForm: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(\.dismiss) private var dismiss
    let session: PracticeSession

    @State private var comfort: ComfortRating?
    @State private var naturalness: Int?
    @State private var advice: CheckInAdvice?

    var body: some View {
        Group {
            if let advice, advice != .none {
                CheckInAdviceView(advice: advice) {
                    dismiss()
                }
            } else {
                form
            }
        }
        .navigationTitle("Quick Check-In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if advice == nil {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .onAppear {
            comfort = comfort ?? session.comfort
            naturalness = naturalness ?? session.naturalnessRating
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SessionSummaryLine(session: session)

                VStack(alignment: .leading, spacing: 12) {
                    Text("How did your throat feel?")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 10) {
                        ForEach(ComfortRating.allCases) { rating in
                            ChoiceButton(
                                title: rating.title,
                                systemImage: rating.systemImage,
                                isSelected: comfort == rating
                            ) {
                                comfort = rating
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("How natural did your voice feel?")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { value in
                            ChoiceButton(
                                title: "\(value)",
                                systemImage: nil,
                                isSelected: naturalness == value
                            ) {
                                naturalness = value
                            }
                            .accessibilityLabel("\(value) out of 5, \(Self.naturalnessDescription(value))")
                        }
                    }
                    HStack {
                        Text("1 = forced")
                        Spacer()
                        Text("5 = natural")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }

                Button {
                    save()
                } label: {
                    Text("Save Check-In")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(comfort == nil)

                Text("Training should never hurt. If your throat often feels sore or hoarse, rest your voice and talk to a doctor or speech-language pathologist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .background { AppBackground() }
    }

    private func save() {
        guard let comfort else { return }
        guard let result = sessionController.saveCheckIn(for: session, comfort: comfort, naturalness: naturalness) else {
            return
        }
        if result == .none {
            dismiss()
        } else {
            withAnimation {
                advice = result
            }
        }
    }

    private static func naturalnessDescription(_ value: Int) -> String {
        switch value {
        case 1: "very forced"
        case 2: "somewhat forced"
        case 3: "in between"
        case 4: "fairly natural"
        default: "very natural"
        }
    }
}

/// One line about the session being checked in on.
private struct SessionSummaryLine: View {
    let session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate, format: .dateTime.weekday(.wide).hour().minute())
                .font(.subheadline.weight(.semibold))
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [SessionFormat.duration(session.duration)]
        if let pitch = session.averagePitch {
            parts.append("average \(SessionFormat.hertz(pitch))")
        }
        if let percent = session.percentInTarget {
            parts.append("\(SessionFormat.percent(percent)) in target")
        }
        return parts.joined(separator: " · ")
    }
}

/// A large selectable answer. Selection is shown with a checkmark and a
/// border, not color alone.
private struct ChoiceButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(systemImage == nil ? Font.title3.weight(.semibold) : Font.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shown after a check-in that suggests resting the voice.
struct CheckInAdviceView: View {
    let advice: CheckInAdvice
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: advice == .seeSpecialist ? "stethoscope" : "bed.double.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(advice.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(advice.message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This suggestion is based on your own check-ins. It isn’t a medical diagnosis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onDone()
                } label: {
                    Text("OK")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
        .background { AppBackground() }
    }
}
