import Foundation
import Observation
import SwiftData
import SwiftUI

/// Ask the Coach (SPEC section 10): short, safe, general voice-training
/// advice. Conversations stay in memory only.
@MainActor
@Observable
final class CoachChatModel {
    private(set) var messages: [CoachChatMessage] = []
    private(set) var isThinking = false
    private(set) var note: String?
    var draft = ""

    static let starters = [
        "How do I make my voice brighter?",
        "How long should I practice each day?",
        "My voice feels tired after practice. What should I do?",
        "How do I sound more natural on the phone?",
    ]

    func send(_ text: String, enabled: Bool) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        draft = ""
        note = nil
        messages.append(CoachChatMessage(role: .user, text: question))
        isThinking = true
        defer { isThinking = false }

        let history = messages
        let fallback = RuleBasedCoach().reply(to: question)
        let outcome = await CoachRouter.run(enabled: enabled, { service in
            try await service.chatReply(history)
        })
        let reply = CoachSafety.checkedReply(outcome?.value ?? fallback, question: question, fallback: fallback)
        note = outcome?.fallbackNote
        messages.append(CoachChatMessage(role: .coach, text: reply))
    }

    func clear() {
        messages = []
        note = nil
    }
}

struct CoachChatView: View {
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var model = CoachChatModel()
    @FocusState private var isInputFocused: Bool

    private var enabled: Bool { profiles.first?.aiCoachEnabled ?? false }
    private var engine: CoachEngine { CoachRouter.engine(enabled: enabled) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    disclaimer
                    if model.messages.isEmpty {
                        starters
                    }
                    ForEach(model.messages) { message in
                        CoachChatBubble(message: message)
                            .id(message.id)
                    }
                    if model.isThinking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Coach is thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                    if let note = model.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background { AppBackground() }
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .navigationTitle("Ask the Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    model.clear()
                }
                .disabled(model.messages.isEmpty)
            }
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoachEngineLabel(engine: engine)
            Text("General voice-training advice, not medical advice. If anything hurts, stop and talk to a speech-language pathologist.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if engine.sendsTextOffDevice {
                Label("Your messages are sent to Google Gemini as text with your own key. No audio is ever sent.", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("This conversation stays on your iPhone and isn’t saved.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.subheadline.weight(.semibold))
            ForEach(CoachChatModel.starters, id: \.self) { starter in
                Button {
                    Task { await model.send(starter, enabled: enabled) }
                } label: {
                    Text(starter)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inputBar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            TextField("Ask about your voice practice", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = model.draft
        Task { await model.send(text, enabled: enabled) }
    }
}

private struct CoachChatBubble: View {
    let message: CoachChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }
            Text(message.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    message.role == .user ? Theme.pitchLine.opacity(0.18) : Theme.cardBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if message.role == .coach {
                Spacer(minLength: 40)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "You said" : "Coach said")
        .accessibilityValue(message.text)
    }
}
