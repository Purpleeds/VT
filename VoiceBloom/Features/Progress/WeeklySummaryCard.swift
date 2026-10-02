import Foundation
import SwiftUI

/// "This week": time practiced, best day, biggest improvement and the area
/// to focus on next.
struct WeeklySummaryCard: View {
    let summary: WeeklySummary
    let dailyGoal: Int

    var body: some View {
        ChartCard(title: "This week", subtitle: "Last 7 days compared with the 7 before.") {
            if summary.isEmpty {
                Text("No practice in the last 7 days yet. A short session today is a great restart.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        StatTile(title: "Practice", value: "\(summary.minutes.roundedInt) min")
                        StatTile(title: "Sessions", value: "\(summary.sessionCount)")
                        StatTile(title: "Days", value: "\(summary.activeDays) of 7")
                    }
                    if let best = summary.bestDay {
                        row(
                            symbol: "star.fill",
                            title: "Best day",
                            detail: bestDayText(best)
                        )
                    }
                    if let change = summary.biggestImprovement {
                        row(
                            symbol: "arrow.up.right.circle.fill",
                            title: "Biggest improvement",
                            detail: "\(change.metric.title): +\(change.amount.roundedInt)\(change.metric == .inTarget ? " points" : "") on last week"
                        )
                    } else {
                        row(symbol: "arrow.left.arrow.right.circle", title: "Trend", detail: "Practice two weeks in a row to see what’s improving.")
                    }
                    if let focus = summary.focus {
                        row(
                            symbol: "scope",
                            title: "Area to focus on",
                            detail: "\(focus.metric.title) (average \(focus.average.roundedInt)\(focus.metric.unit)). \(Self.tip(for: focus.metric))"
                        )
                    }
                }
            }
        }
    }

    private func bestDayText(_ best: WeeklySummary.BestDay) -> String {
        let day = best.date.formatted(.dateTime.weekday(.wide))
        if let percent = best.percentInTarget {
            return "\(day): \(percent.roundedInt)% in target over \(best.minutes.roundedInt) min"
        }
        return "\(day): \(best.minutes.roundedInt) min of practice"
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func tip(for metric: ProgressMetric) -> String {
        switch metric {
        case .inTarget: "Try short pitch glides into your target before reading aloud."
        case .resonance: "Bright vowels (“ee”, “ih”) and the small-dog pant help."
        case .weight: "Gentle onsets and soft speaking lighten the voice."
        case .intonation: "Read with more ups and downs, as if telling a child a story."
        }
    }
}
