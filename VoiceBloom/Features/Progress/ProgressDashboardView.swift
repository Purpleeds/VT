import Foundation
import SwiftData
import SwiftUI
import UIKit

/// The Progress tab (SPEC section 11): trends, practice calendar, check-ins,
/// scenario skills, Then vs Now, weekly summary and export.
struct ProgressDashboardView: View {
    @Environment(PracticeSessionController.self) private var sessionController
    @Environment(\.calendar) private var calendar
    @Environment(\.displayScale) private var displayScale
    @Query(sort: \PracticeSession.startDate) private var sessions: [PracticeSession]
    @Query(sort: \ScenarioResult.date) private var scenarioResults: [ScenarioResult]
    @Query(sort: \Recording.createdAt) private var recordings: [Recording]
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @AppStorage("progress.range") private var rangeRawValue = ProgressRange.month.rawValue
    @State private var selectedSessionID: UUID?
    @State private var shareImage: Image?

    private var range: ProgressRange { ProgressRange(rawValue: rangeRawValue) ?? .month }

    private var target: PitchTargetZone {
        profiles.first?.targetZone ?? sessionController.monitor.targetZone
    }

    private var dailyGoal: Int { profiles.first?.dailyGoalMinutes ?? 15 }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions yet", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text("Practice for a few seconds and your charts start here: pitch, resonance, weight, intonation, practice time and check-ins.\n\nWant to look around first? More › Debug & Tuning › Generate sample history.")
                    }
                } else {
                    dashboard
                }
            }
            .background { AppBackground() }
            .navigationTitle("Progress")
            .navigationDestination(item: $selectedSessionID) { id in
                SessionDestination(sessionID: id)
            }
        }
    }

    private var dashboard: some View {
        let now = Date()
        let allPoints = sessions.map(SessionPoint.init)
        let start = range.startDate(now: now, calendar: calendar, earliest: allPoints.first?.date)
        let domain = ChartDomain(start: start, end: now)
        let points = ProgressAnalytics.points(allPoints, in: range, now: now, calendar: calendar)
        let summary = ProgressAnalytics.weeklySummary(allPoints, now: now, calendar: calendar)
        let scenarios = scenarioResults.filter { $0.date >= start && $0.date <= now }
        let radar = ProgressAnalytics.radar(scenarios.map(\.turnScores))
        let open: (UUID) -> Void = { selectedSessionID = $0 }

        return ScrollView {
            VStack(spacing: 16) {
                Picker("Time range", selection: $rangeRawValue) {
                    ForEach(ProgressRange.allCases) { range in
                        Text(range.title)
                            .accessibilityLabel(range.spokenTitle)
                            .tag(range.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                WeeklySummaryCard(summary: summary, dailyGoal: dailyGoal)

                AchievementsSummaryCard()

                PitchTrendChart(points: points, target: target, domain: domain, onSelect: open)
                ScoreTrendChart(points: points, domain: domain, onSelect: open)
                InTargetChart(points: points, domain: domain, onSelect: open)
                PracticeMinutesChart(points: points, domain: domain, dailyGoal: Double(dailyGoal))
                CalendarHeatmapView(
                    weeks: ProgressAnalytics.heatmap(
                        allPoints,
                        weeks: range.heatmapWeeks,
                        now: now,
                        dailyGoal: Double(dailyGoal),
                        calendar: calendar
                    ),
                    dailyGoal: Double(dailyGoal)
                )
                ComfortHistoryChart(points: points, domain: domain, onSelect: open)
                ScenarioRadarChart(values: radar)

                thenVsNow

                ProgressExportCard(
                    csv: SessionsCSVFile(rows: sessions.map(SessionExportRow.init)),
                    shareImage: shareImage
                )

                NavigationLink {
                    SessionListView()
                } label: {
                    Label("All sessions (\(sessions.count))", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .task(id: "\(range.rawValue)-\(points.count)-\(points.last?.date.timeIntervalSince1970 ?? 0)") {
            renderShareImage(summary: summary, points: points)
        }
    }

    @ViewBuilder
    private var thenVsNow: some View {
        let pair = ProgressAnalytics.thenAndNow(recordings.map(RecordingSummary.init))
        if let pair,
           let then = recordings.first(where: { $0.id == pair.then.id }),
           let now = recordings.first(where: { $0.id == pair.now.id }) {
            ThenVsNowCard(then: then, now: now)
        } else {
            ThenVsNowPlaceholder()
        }
    }

    private func renderShareImage(summary: WeeklySummary, points: [SessionPoint]) {
        let card = ProgressShareCard(range: range, summary: summary, points: points)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = displayScale
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
        }
    }
}

/// Opens a session by id (from a tapped chart point).
struct SessionDestination: View {
    @Environment(PracticeSessionController.self) private var sessionController
    let sessionID: UUID

    var body: some View {
        if let session = sessionController.session(id: sessionID) {
            SessionDetailView(session: session)
        } else {
            ContentUnavailableView("Session not found", systemImage: "questionmark.circle", description: Text("It may have been deleted."))
        }
    }
}
