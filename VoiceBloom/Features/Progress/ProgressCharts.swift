import Charts
import Foundation
import SwiftUI

/// Rounded card with a title, used for every chart on the Progress tab.
struct ChartCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

extension ChartCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        accessory = { EmptyView() }
        self.content = content
    }
}

/// Shown inside a chart card when the range has nothing to plot.
struct EmptyChartMessage: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .multilineTextAlignment(.center)
    }
}

extension View {
    /// Tapping the chart opens the session closest to the tapped date.
    func opensSession(nearestTo points: [SessionPoint], onSelect: @escaping (UUID) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geometry[plotFrame].origin
                        guard let date: Date = proxy.value(atX: location.x - origin.x),
                              let nearest = ProgressAnalytics.nearest(to: date, in: points)
                        else { return }
                        onSelect(nearest.id)
                    }
            }
        }
    }
}

/// The span of dates a chart shows.
struct ChartDomain: Equatable {
    let start: Date
    let end: Date

    var range: ClosedRange<Date> { start...max(end, start.addingTimeInterval(3_600)) }
}

private func spokenDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

// MARK: - Average pitch

/// Average pitch per session with the target zone shaded and each session's
/// lowest-to-highest range as a faint bar.
struct PitchTrendChart: View {
    let points: [SessionPoint]
    let target: PitchTargetZone
    let domain: ChartDomain
    let onSelect: (UUID) -> Void

    private var measured: [SessionPoint] { points.filter { $0.averagePitch != nil } }

    private var yDomain: ClosedRange<Double> {
        let values = measured.flatMap { [$0.averagePitch, $0.minimumPitch, $0.maximumPitch].compactMap { $0 } }
        let low = min(values.min() ?? target.lowerBound, target.lowerBound) - 15
        let high = max(values.max() ?? target.upperBound, target.upperBound) + 15
        return max(50, low)...high
    }

    var body: some View {
        ChartCard(
            title: "Average pitch",
            subtitle: "Shaded band: your target zone (\(target.formatted)). Tap a point to open that session."
        ) {
            if measured.isEmpty {
                EmptyChartMessage(message: "No voiced sessions in this range yet.")
            } else {
                Chart {
                    RectangleMark(
                        xStart: .value("Start", domain.range.lowerBound),
                        xEnd: .value("End", domain.range.upperBound),
                        yStart: .value("Target low", target.lowerBound),
                        yEnd: .value("Target high", target.upperBound)
                    )
                    .foregroundStyle(Theme.targetZone.opacity(0.16))
                    .accessibilityHidden(true)

                    ForEach(measured) { point in
                        if let low = point.minimumPitch, let high = point.maximumPitch {
                            RuleMark(
                                x: .value("Date", point.date),
                                yStart: .value("Lowest", low),
                                yEnd: .value("Highest", high)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                            .foregroundStyle(Theme.pitchLine.opacity(0.18))
                            .accessibilityHidden(true)
                        }
                    }

                    ForEach(measured) { point in
                        if let pitch = point.averagePitch {
                            LineMark(x: .value("Date", point.date), y: .value("Average pitch", pitch))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Theme.pitchLine)
                                .accessibilityLabel(spokenDate(point.date))
                                .accessibilityValue("\(pitch.roundedInt) hertz")
                            PointMark(x: .value("Date", point.date), y: .value("Average pitch", pitch))
                                .symbolSize(28)
                                .foregroundStyle(Theme.pitchLine)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .chartXScale(domain: domain.range)
                .chartYScale(domain: yDomain)
                .chartYAxisLabel("Hz")
                .opensSession(nearestTo: measured, onSelect: onSelect)
                .frame(height: 220)
            }
        }
    }
}

// MARK: - Scores

private struct ScoreSample: Identifiable {
    let id: String
    let date: Date
    let metric: ProgressMetric
    let value: Double
}

/// Resonance, weight and intonation scores over time, each switchable.
struct ScoreTrendChart: View {
    let points: [SessionPoint]
    let domain: ChartDomain
    let onSelect: (UUID) -> Void
    @State private var shown: Set<ProgressMetric> = [.resonance, .weight, .intonation]

    static let metrics: [ProgressMetric] = [.resonance, .weight, .intonation]

    private var samples: [ScoreSample] {
        points.flatMap { point in
            Self.metrics.filter(shown.contains).compactMap { metric in
                point.value(of: metric).map {
                    ScoreSample(id: "\(point.id.uuidString)-\(metric.rawValue)", date: point.date, metric: metric, value: $0)
                }
            }
        }
    }

    var body: some View {
        ChartCard(title: "Resonance, weight & intonation", subtitle: "Session averages, 0–100. Higher is closer to your target.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(Self.metrics) { metric in
                        SeriesToggle(
                            title: metric.title,
                            symbol: Self.symbolName(for: metric),
                            color: Self.color(for: metric),
                            isOn: shown.contains(metric)
                        ) {
                            if shown.contains(metric) {
                                shown.remove(metric)
                            } else {
                                shown.insert(metric)
                            }
                        }
                    }
                }

                if samples.isEmpty {
                    EmptyChartMessage(message: shown.isEmpty ? "Turn on a score above to see it." : "No scores in this range yet.")
                } else {
                    Chart(samples) { sample in
                        LineMark(
                            x: .value("Date", sample.date),
                            y: .value("Score", sample.value),
                            series: .value("Measure", sample.metric.title)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Measure", sample.metric.title))
                        .symbol(by: .value("Measure", sample.metric.title))
                        .accessibilityLabel("\(sample.metric.title), \(spokenDate(sample.date))")
                        .accessibilityValue("\(sample.value.roundedInt) out of 100")
                    }
                    .chartForegroundStyleScale([
                        ProgressMetric.resonance.title: Theme.resonanceSeries,
                        ProgressMetric.weight.title: Theme.weightSeries,
                        ProgressMetric.intonation.title: Theme.intonationSeries,
                    ])
                    .chartSymbolScale([
                        ProgressMetric.resonance.title: BasicChartSymbolShape.circle,
                        ProgressMetric.weight.title: BasicChartSymbolShape.square,
                        ProgressMetric.intonation.title: BasicChartSymbolShape.triangle,
                    ])
                    .chartLegend(.hidden)
                    .chartXScale(domain: domain.range)
                    .chartYScale(domain: 0...100)
                    .opensSession(nearestTo: points, onSelect: onSelect)
                    .frame(height: 220)
                }
            }
        }
    }

    static func color(for metric: ProgressMetric) -> Color {
        switch metric {
        case .resonance: Theme.resonanceSeries
        case .weight: Theme.weightSeries
        case .intonation: Theme.intonationSeries
        case .inTarget: Theme.targetZone
        }
    }

    static func symbolName(for metric: ProgressMetric) -> String {
        switch metric {
        case .resonance: "circle.fill"
        case .weight: "square.fill"
        case .intonation: "triangle.fill"
        case .inTarget: "target"
        }
    }
}

/// A chip that shows or hides one chart series (with its symbol as the legend).
struct SeriesToggle: View {
    let title: String
    let symbol: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(isOn ? color : Color.secondary)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? color.opacity(0.15) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? color.opacity(0.6) : Color.clear, lineWidth: 1))
            .opacity(isOn ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Time in target

struct InTargetChart: View {
    let points: [SessionPoint]
    let domain: ChartDomain
    let onSelect: (UUID) -> Void

    private var measured: [SessionPoint] { points.filter { $0.percentInTarget != nil } }

    var body: some View {
        ChartCard(title: "Time in target", subtitle: "Share of voiced time inside your pitch target, per session. The dashed line is the 70% lesson goal.") {
            if measured.isEmpty {
                EmptyChartMessage(message: "No voiced sessions in this range yet.")
            } else {
                Chart {
                    RuleMark(y: .value("Goal", 70))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("70% goal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                    ForEach(measured) { point in
                        if let percent = point.percentInTarget {
                            AreaMark(x: .value("Date", point.date), y: .value("In target", percent))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Theme.targetZone.opacity(0.15))
                                .accessibilityHidden(true)
                            LineMark(x: .value("Date", point.date), y: .value("In target", percent))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Theme.targetZone)
                                .symbol(.circle)
                                .accessibilityLabel(spokenDate(point.date))
                                .accessibilityValue("\(percent.roundedInt) percent in target")
                        }
                    }
                }
                .chartXScale(domain: domain.range)
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("%")
                .opensSession(nearestTo: measured, onSelect: onSelect)
                .frame(height: 200)
            }
        }
    }
}

// MARK: - Practice minutes

struct PracticeMinutesChart: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"

        var id: String { rawValue }
    }

    let points: [SessionPoint]
    let domain: ChartDomain
    let dailyGoal: Double
    @State private var grouping: Grouping = .day
    @Environment(\.calendar) private var calendar

    private var buckets: [PracticeBucket] {
        switch grouping {
        case .day:
            ProgressAnalytics.dailyMinutes(points, from: domain.start, through: domain.end, calendar: calendar)
        case .week:
            ProgressAnalytics.weeklyMinutes(points, from: domain.start, through: domain.end, calendar: calendar)
        }
    }

    private var goal: Double { grouping == .day ? dailyGoal : dailyGoal * 7 }

    private var total: Double { points.reduce(0) { $0 + $1.minutes } }

    var body: some View {
        ChartCard(
            title: "Practice time",
            subtitle: "\(total.roundedInt) min in this range. Several short sessions beat one long one; stay under 45 min a day."
        ) {
            Picker("Group by", selection: $grouping) {
                ForEach(Grouping.allCases) { grouping in
                    Text(grouping.rawValue).tag(grouping)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        } content: {
            Chart {
                ForEach(buckets) { bucket in
                    BarMark(
                        x: .value(grouping == .day ? "Day" : "Week", bucket.start, unit: grouping == .day ? .day : .weekOfYear),
                        y: .value("Minutes", bucket.minutes)
                    )
                    .foregroundStyle(bucket.minutes >= goal ? Theme.targetZone : Theme.pitchLine.opacity(0.7))
                    .accessibilityLabel(bucket.start.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(bucket.minutes.roundedInt) minutes\(bucket.minutes >= goal ? ", goal met" : "")")
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal \(Int(goal)) min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
            }
            .chartYAxisLabel("min")
            .frame(height: 200)
        }
    }
}

// MARK: - Check-ins

/// "How did your throat feel?" per session, plus the naturalness rating.
struct ComfortHistoryChart: View {
    let points: [SessionPoint]
    let domain: ChartDomain
    let onSelect: (UUID) -> Void

    private var checkedIn: [SessionPoint] { points.filter { $0.comfort != nil } }
    private var rated: [SessionPoint] { points.filter { $0.naturalness != nil } }

    private var soreCount: Int { checkedIn.filter { $0.comfort == .sore }.count }

    var body: some View {
        ChartCard(
            title: "Comfort check-ins",
            subtitle: checkedIn.isEmpty ? nil : "\(checkedIn.count) check-ins in this range, \(soreCount) sore."
        ) {
            if checkedIn.isEmpty {
                EmptyChartMessage(message: "Check-ins appear here after you finish sessions.")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Chart(checkedIn) { point in
                        if let comfort = point.comfort {
                            PointMark(x: .value("Date", point.date), y: .value("Throat", comfort.title))
                                .foregroundStyle(by: .value("Throat", comfort.title))
                                .symbol(by: .value("Throat", comfort.title))
                                .symbolSize(60)
                                .accessibilityLabel(spokenDate(point.date))
                                .accessibilityValue("Throat felt \(comfort.title.lowercased())")
                        }
                    }
                    .chartForegroundStyleScale([
                        ComfortRating.fine.title: Theme.targetZone,
                        ComfortRating.tired.title: Theme.intonationSeries,
                        ComfortRating.sore.title: Theme.warning,
                    ])
                    .chartSymbolScale([
                        ComfortRating.fine.title: BasicChartSymbolShape.circle,
                        ComfortRating.tired.title: BasicChartSymbolShape.diamond,
                        ComfortRating.sore.title: BasicChartSymbolShape.triangle,
                    ])
                    .chartYScale(domain: [ComfortRating.sore.title, ComfortRating.tired.title, ComfortRating.fine.title])
                    .chartXScale(domain: domain.range)
                    .chartLegend(.hidden)
                    .opensSession(nearestTo: checkedIn, onSelect: onSelect)
                    .frame(height: 140)

                    if !rated.isEmpty {
                        Text("How natural it felt (1–5)")
                            .font(.subheadline.weight(.medium))
                        Chart(rated) { point in
                            if let rating = point.naturalness {
                                LineMark(x: .value("Date", point.date), y: .value("Naturalness", rating))
                                    .interpolationMethod(.monotone)
                                    .symbol(.circle)
                                    .foregroundStyle(Theme.resonanceSeries)
                                    .accessibilityLabel(spokenDate(point.date))
                                    .accessibilityValue("Naturalness \(rating) of 5")
                            }
                        }
                        .chartXScale(domain: domain.range)
                        .chartYScale(domain: 1...5)
                        .chartYAxis {
                            AxisMarks(values: [1, 2, 3, 4, 5])
                        }
                        .opensSession(nearestTo: rated, onSelect: onSelect)
                        .frame(height: 120)
                    }
                }
            }
        }
    }
}
