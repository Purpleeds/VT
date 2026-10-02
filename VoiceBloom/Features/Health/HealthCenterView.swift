import Foundation
import SwiftData
import SwiftUI

/// The Vocal Health Center (SPEC section 14): today's practice against the
/// soft limit, rest suggestions, the last week's check-ins and strain
/// warnings, and short articles.
struct HealthCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PracticeSessionController.self) private var sessionController
    @State private var summary = VocalHealthSummary()

    var body: some View {
        List {
            Section {
                TodayLimitRow(summary: summary)
            } header: {
                Text("Today")
            } footer: {
                Text("A soft limit: practice isn’t blocked, but your voice gets stronger while it rests. Take a short break every \(Int(BreakAdvisor.breakIntervalMinutes)) minutes.")
            }

            if let notice = restNotice {
                Section {
                    NoticeBanner(title: notice.title, message: notice.message, systemImage: notice.systemImage)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section {
                CheckInCountsRow(summary: summary)
                LabeledContent("Strain warnings", value: "\(summary.strainWarnings)")
                    .accessibilityValue(summary.strainWarnings == 0 ? "None" : "\(summary.strainWarnings)")
                LabeledContent("Practice", value: "\(summary.weekMinutes.roundedInt) min")
            } header: {
                Text("Last 7 days")
            } footer: {
                Text("Strain warnings appear during practice when your voice sounds rougher than your usual. Check-ins come after each session.")
            }

            Section {
                ForEach(HealthLibrary.articles) { article in
                    NavigationLink {
                        HealthArticleView(article: article)
                    } label: {
                        HealthArticleRow(article: article)
                    }
                }
            } header: {
                Text("Learn")
            } footer: {
                Text(HealthLibrary.disclaimer)
            }
        }
        .navigationTitle("Vocal Health Center")
        .onAppear(perform: refresh)
    }

    private struct RestNotice {
        let title: String
        let message: String
        let systemImage: String
    }

    private var restNotice: RestNotice? {
        if summary.advice == .seeSpecialist {
            return RestNotice(title: summary.advice.title, message: summary.advice.message, systemImage: "stethoscope")
        }
        if sessionController.isRestDaySuggested || summary.advice == .restDay {
            return RestNotice(title: "Rest day suggested", message: CheckInAdvice.restDay.message, systemImage: "bed.double.fill")
        }
        if summary.suggestsEasyDay {
            return RestNotice(
                title: "Take it easy today",
                message: "You’ve had \(summary.recentStrainWarnings) strain warnings in the last two days. Keep sessions short and gentle, or take a rest day. If your voice stays rough, see a speech-language pathologist.",
                systemImage: "leaf.fill"
            )
        }
        return nil
    }

    private func refresh() {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(VocalHealthSummary.windowDays + 1), to: calendar.startOfDay(for: Date())) ?? .distantPast
        let descriptor = FetchDescriptor<PracticeSession>(predicate: #Predicate<PracticeSession> { $0.startDate >= start })
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let inputs = sessions.map { session in
            HealthSessionInput(
                date: session.startDate,
                minutes: session.duration / 60,
                comfort: session.comfort,
                strainWarnings: session.strainWarningCount
            )
        }
        var newSummary = VocalHealthSummary.make(sessions: inputs, now: Date())
        // Include the session in progress.
        newSummary.todayMinutes = max(newSummary.todayMinutes, sessionController.minutesPracticedToday())
        summary = newSummary
    }
}

private struct TodayLimitRow: View {
    let summary: VocalHealthSummary

    private var limit: Double { BreakAdvisor.dailyLimitMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(summary.todayMinutes.roundedInt) of \(Int(limit)) min")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Text(summary.remainingMinutes > 0 ? "\(summary.remainingMinutes.roundedInt) min left" : "Limit reached")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(summary.todayMinutes, limit), total: limit)
                .tint(summary.remainingMinutes > 0 ? Theme.targetZone : Theme.warning)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Practice today")
        .accessibilityValue("\(summary.todayMinutes.roundedInt) of \(Int(limit)) minutes. \(summary.remainingMinutes > 0 ? "\(summary.remainingMinutes.roundedInt) minutes left" : "Soft limit reached")")
    }
}

private struct CheckInCountsRow: View {
    let summary: VocalHealthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check-ins")
            if summary.checkInCount == 0 {
                Text("No check-ins yet this week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Icons and words, not just colors.
                HStack(spacing: 16) {
                    countLabel(ComfortRating.fine.title, count: summary.fineCount, systemImage: "checkmark.circle")
                    countLabel(ComfortRating.tired.title, count: summary.tiredCount, systemImage: "battery.25percent")
                    countLabel(ComfortRating.sore.title, count: summary.soreCount, systemImage: "exclamationmark.circle")
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Check-ins")
        .accessibilityValue(summary.checkInCount == 0
            ? "None this week"
            : "\(summary.fineCount) fine, \(summary.tiredCount) a bit tired, \(summary.soreCount) sore")
    }

    private func countLabel(_ title: String, count: Int, systemImage: String) -> some View {
        Label("\(count) \(title.lowercased())", systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }
}

private struct HealthArticleRow: View {
    let article: HealthArticle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: article.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                Text(article.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("\(article.readingMinutes) min read")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct HealthArticleView: View {
    let article: HealthArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(article.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(article.parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(part.heading)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(part.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(part.bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .accessibilityHidden(true)
                                Text(bullet)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Text(HealthLibrary.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A break suggestion above the practice screen, with a gentle haptic.
struct BreakAdviceBanner: View {
    let advice: BreakAdvice
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticeBanner(title: advice.title, message: advice.message, systemImage: advice.systemImage, tint: Theme.targetZone)
            Button("Got It", action: onDismiss)
                .buttonStyle(.glass)
        }
    }
}
