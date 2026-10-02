import Foundation
import Testing
@testable import VoiceBloom

@Suite("CheckInRules")
struct CheckInRulesTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Midnight UTC, 10 March 2026.
    private let march10 = Date(timeIntervalSince1970: 1_773_100_800)

    /// A time on a day relative to 10 March (0 = 10 March, −1 = 9 March).
    private func day(_ offset: Int, hour: Double = 12) -> Date {
        march10.addingTimeInterval(Double(offset) * 86_400 + hour * 3_600)
    }

    private var now: Date { day(0, hour: 18) }

    private func sore(_ offset: Int, hour: Double = 12) -> ComfortReport {
        ComfortReport(date: day(offset, hour: hour), comfort: .sore)
    }

    @Test("One sore report is not enough for advice")
    func singleSore() {
        #expect(CheckInRules.advice(for: [sore(0)], now: now, calendar: calendar) == .none)
    }

    @Test("Sore twice within 3 days suggests a rest day")
    func twiceInThreeDays() {
        let reports = [sore(0), sore(-2, hour: 9)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .restDay)
    }

    @Test("Twice on the same day also counts")
    func twiceToday() {
        let reports = [sore(0, hour: 9), sore(0, hour: 17)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .restDay)
    }

    @Test("Sore reports 3 days apart are outside the window")
    func outsideWindow() {
        let reports = [sore(0), sore(-3, hour: 23)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .none)
    }

    @Test("Soreness that keeps coming back recommends seeing a professional")
    func repeatedSoreness() {
        let reports = [sore(0), sore(-3), sore(-6, hour: 1)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .seeSpecialist)
    }

    @Test("Reports a week or more ago don't count toward the specialist advice")
    func weekWindow() {
        let reports = [sore(0), sore(-1), sore(-7)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .restDay)
    }

    @Test("Only “Sore” answers count")
    func otherAnswers() {
        let reports = (0..<5).map { ComfortReport(date: day(-$0), comfort: .tired) }
            + [ComfortReport(date: day(0), comfort: .fine), sore(-1)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .none)
    }

    @Test("Future dates (a changed clock) are ignored")
    func futureDates() {
        let reports = [sore(0), sore(1)]
        #expect(CheckInRules.advice(for: reports, now: now, calendar: calendar) == .none)
    }

    @Test("A rest-day suggestion shows that day and the next")
    func restDayWindow() {
        #expect(CheckInRules.isRestDaySuggested(suggestedOn: day(0, hour: 8), now: now, calendar: calendar))
        #expect(CheckInRules.isRestDaySuggested(suggestedOn: day(-1, hour: 23), now: now, calendar: calendar))
        #expect(!CheckInRules.isRestDaySuggested(suggestedOn: day(-2, hour: 23), now: now, calendar: calendar))
        #expect(!CheckInRules.isRestDaySuggested(suggestedOn: nil, now: now, calendar: calendar))
    }

    @Test("Advice always has text to show")
    func adviceText() {
        for advice in [CheckInAdvice.restDay, .seeSpecialist] {
            #expect(!advice.title.isEmpty)
            #expect(advice.message.contains("speech-language pathologist"))
        }
    }
}
