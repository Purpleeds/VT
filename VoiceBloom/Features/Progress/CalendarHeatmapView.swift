import Foundation
import SwiftUI

/// GitHub-style grid of practice days: one column per week, one row per
/// weekday. Shading shows minutes against the daily goal; every square also
/// has a spoken description, and the totals are written out below.
struct CalendarHeatmapView: View {
    let weeks: [HeatmapWeek]
    let dailyGoal: Double
    @Environment(\.calendar) private var calendar
    @ScaledMetric(relativeTo: .caption) private var cellSize: CGFloat = 15
    @State private var selectedDay: HeatmapDay?

    private var pastDays: [HeatmapDay] {
        weeks.flatMap(\.days).filter { !$0.isFuture }
    }

    private var practicedDays: Int { pastDays.filter { $0.minutes > 0 }.count }
    private var goalDays: Int { pastDays.filter { $0.level >= 3 }.count }

    /// Weekday initials in calendar order (starting with the first weekday).
    private var weekdayLabels: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % symbols.count] }
    }

    var body: some View {
        ChartCard(
            title: "Practice calendar",
            subtitle: "Practiced on \(practicedDays) of \(pastDays.count) days · goal met on \(goalDays)."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(spacing: 3) {
                        Color.clear.frame(height: cellSize)
                        ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { index, label in
                            Text(index.isMultiple(of: 2) ? label : "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                    .accessibilityHidden(true)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                                VStack(spacing: 3) {
                                    Text(monthLabel(for: week, at: index))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                        .frame(width: cellSize, height: cellSize, alignment: .leading)
                                        .accessibilityHidden(true)
                                    ForEach(week.days) { day in
                                        HeatmapCell(day: day, size: cellSize, isSelected: selectedDay?.id == day.id)
                                            .onTapGesture {
                                                selectedDay = day.isFuture ? nil : day
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                }

                HStack(spacing: 6) {
                    if let selectedDay {
                        Text("\(selectedDay.date.formatted(date: .abbreviated, time: .omitted)): \(minutesText(selectedDay.minutes))")
                            .font(.caption.weight(.medium))
                    } else {
                        Text("Tap a day for its minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Less")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(HeatmapCell.fill(level: level))
                            .frame(width: 10, height: 10)
                    }
                    Text("More")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Month name above the first week of each month.
    private func monthLabel(for week: HeatmapWeek, at index: Int) -> String {
        guard let firstDay = week.days.first?.date else { return "" }
        let month = calendar.component(.month, from: firstDay)
        if index > 0, let previous = weeks[index - 1].days.first?.date,
           calendar.component(.month, from: previous) == month {
            return ""
        }
        return firstDay.formatted(.dateTime.month(.abbreviated))
    }

    private func minutesText(_ minutes: Double) -> String {
        minutes <= 0 ? "no practice" : "\(minutes.roundedInt) min"
    }
}

private struct HeatmapCell: View {
    let day: HeatmapDay
    let size: CGFloat
    let isSelected: Bool

    static func fill(level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.14)
        case 1: Theme.targetZone.opacity(0.3)
        case 2: Theme.targetZone.opacity(0.55)
        case 3: Theme.targetZone.opacity(0.8)
        default: Theme.targetZone
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(day.isFuture ? Color.clear : Self.fill(level: day.level))
            .overlay {
                if day.level >= 3 {
                    // A dot marks goal-met days, so the meaning isn't color alone.
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: size * 0.25, height: size * 0.25)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary : (day.isFuture ? Color.secondary.opacity(0.15) : Color.clear), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(day.isFuture ? "Upcoming" : (day.minutes > 0 ? "\(day.minutes.roundedInt) minutes\(day.level >= 3 ? ", goal met" : "")" : "No practice"))
    }
}
