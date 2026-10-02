import AppIntents
import Foundation
import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets (SPEC section 12): streak, today's
/// minutes against the goal, and a quick-start button. Wording is neutral.
@main
struct VoiceBloomWidgetBundle: WidgetBundle {
    var body: some Widget {
        PracticeWidget()
    }
}

nonisolated struct PracticeEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

nonisolated struct PracticeProvider: TimelineProvider {
    func placeholder(in context: Context) -> PracticeEntry {
        PracticeEntry(date: Date(), snapshot: WidgetSnapshot(
            streakDays: 5,
            practicedToday: false,
            freezeAvailable: true,
            todayMinutes: 6,
            goalMinutes: 15,
            challenge: "Five easy minutes",
            updated: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (PracticeEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : PracticeEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PracticeEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        var entries = [PracticeEntry(date: now, snapshot: snapshot)]
        // Refresh at midnight, when today's minutes start again.
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3_600)
        entries.append(PracticeEntry(date: midnight, snapshot: snapshot))
        let next = calendar.date(byAdding: .hour, value: 1, to: midnight) ?? midnight
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

struct PracticeWidget: Widget {
    let kind = "PracticeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PracticeProvider()) { entry in
            PracticeWidgetView(entry: entry)
        }
        .configurationDisplayName("Practice")
        .description("Your streak, today’s practice and a quick start.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PracticeWidgetView: View {
    let entry: PracticeEntry
    @Environment(\.widgetFamily) private var family

    private var streak: Int { entry.snapshot?.streak(on: entry.date) ?? 0 }
    private var minutes: Double { entry.snapshot?.minutes(on: entry.date) ?? 0 }
    private var goal: Int { max(entry.snapshot?.goalMinutes ?? 15, 1) }
    private var progress: Double { entry.snapshot?.goalProgress(on: entry.date) ?? 0 }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color.clear
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(minutes, Double(goal)), in: 0...Double(goal)) {
                Image(systemName: "waveform")
            } currentValueLabel: {
                Text("\(Int(minutes.rounded()))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("\(Int(minutes.rounded())) of \(goal) minutes today")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("\(streak)-day streak", systemImage: "flame.fill")
                    .font(.headline)
                Text("\(Int(minutes.rounded())) of \(goal) min today")
                    .font(.caption)
                ProgressView(value: progress)
            }
        case .accessoryInline:
            Label("\(streak)-day streak · \(Int(minutes.rounded()))/\(goal) min", systemImage: "flame")
        case .systemMedium:
            HStack(spacing: 16) {
                summary
                VStack(alignment: .leading, spacing: 8) {
                    if let challenge = entry.snapshot?.challenge {
                        Text("Today’s challenge")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(challenge)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button(intent: StartPracticeIntent()) {
                        Label("Start", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.pink)
                }
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(streak)", systemImage: "flame.fill")
                .font(.title.weight(.bold))
                .foregroundStyle(streak > 0 ? Color.orange : Color.secondary)
                .accessibilityLabel("\(streak)-day streak")
            Text(streak == 1 ? "day streak" : "days streak")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(Int(minutes.rounded())) of \(goal) min")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: progress)
                .tint(.green)
            if entry.snapshot == nil {
                Text("Open the app to start")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
