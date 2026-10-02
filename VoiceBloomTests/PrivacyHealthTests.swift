import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

/// Noon UTC on 2026-03-`day`.
private func marchNoon(_ day: Int, hour: Int = 12) -> Date {
    Date(timeIntervalSince1970: 1_773_144_000 + Double(day - 10) * 86_400 + Double(hour - 12) * 3_600)
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

@Suite("Privacy: notification wording and app icon")
struct PrivacyTests {
    @Test("Neutral wording never says what is practiced")
    func neutralWording() {
        let neutral = [NotificationWording.dailyReminder(.neutral), NotificationWording.eveningNudge(.neutral)]
        for wording in neutral {
            #expect(wording.isNeutral)
            #expect(!wording.title.isEmpty && !wording.body.isEmpty)
        }
        #expect(NotificationWording.dailyReminder(.neutral).title == "Time for practice")
        #expect(!NotificationWording.dailyReminder(.descriptive).isNeutral)
        #expect(!NotificationWording.eveningNudge(.descriptive).isNeutral)
    }

    @Test("No wording guilt-trips")
    func noGuilt() {
        let guiltWords = ["miss", "lose", "lost", "fail", "should have", "don’t forget", "streak", "disappoint"]
        for style in NotificationWordingStyle.allCases {
            for wording in [NotificationWording.dailyReminder(style), NotificationWording.eveningNudge(style)] {
                let text = (wording.title + " " + wording.body).lowercased()
                #expect(!guiltWords.contains { text.contains($0) }, "\(text)")
            }
        }
    }

    @Test("The icon choice follows the alternate icon name")
    func iconChoice() {
        #expect(AppIconChoice(alternateIconName: nil) == .standard)
        #expect(AppIconChoice(alternateIconName: "NeutralIcon") == .neutral)
        #expect(AppIconChoice(alternateIconName: "Other") == .standard)
        #expect(AppIconChoice.standard.alternateIconName == nil)
        #expect(AppIconChoice.neutral.alternateIconName == "NeutralIcon")
    }
}

@Suite("Vocal health: breaks, limits and the weekly summary")
struct VocalHealthTests {
    @Test("Breaks every 15 minutes, then the 45-minute soft limit")
    func breaks() {
        #expect(BreakAdvisor.advice(todayMinutes: 10, sessionMinutes: 10) == .none)
        #expect(BreakAdvisor.advice(todayMinutes: 16, sessionMinutes: 16) == .shortBreak(sessionMinutes: 15))
        #expect(BreakAdvisor.advice(todayMinutes: 35, sessionMinutes: 31) == .shortBreak(sessionMinutes: 30))
        #expect(BreakAdvisor.advice(todayMinutes: 40, sessionMinutes: 5) == .nearLimit(remainingMinutes: 5))
        #expect(BreakAdvisor.advice(todayMinutes: 43.2, sessionMinutes: 5) == .nearLimit(remainingMinutes: 2))
        #expect(BreakAdvisor.advice(todayMinutes: 44.9, sessionMinutes: 20) == .nearLimit(remainingMinutes: 1))
        #expect(BreakAdvisor.advice(todayMinutes: 45, sessionMinutes: 2) == .overLimit(todayMinutes: 45))
        #expect(BreakAdvisor.advice(todayMinutes: 52.7, sessionMinutes: 40) == .overLimit(todayMinutes: 52))
        #expect(PracticeSessionController.dailySoftCapMinutes == BreakAdvisor.dailyLimitMinutes)
    }

    @Test("Every suggestion has words and an icon")
    func adviceText() {
        let all: [BreakAdvice] = [.shortBreak(sessionMinutes: 15), .nearLimit(remainingMinutes: 1), .overLimit(todayMinutes: 50)]
        for advice in all {
            #expect(!advice.title.isEmpty)
            #expect(!advice.message.isEmpty)
            #expect(!advice.systemImage.isEmpty)
        }
        #expect(BreakAdvice.nearLimit(remainingMinutes: 1).message.contains("1 minute left"))
        #expect(BreakAdvice.nearLimit(remainingMinutes: 3).message.contains("3 minutes left"))
    }

    @Test("The summary counts the last 7 days and suggests rest")
    func summary() {
        let sessions = [
            HealthSessionInput(date: marchNoon(10, hour: 9), minutes: 20, comfort: .fine, strainWarnings: 1),
            HealthSessionInput(date: marchNoon(9), minutes: 15, comfort: .sore, strainWarnings: 2),
            HealthSessionInput(date: marchNoon(8), minutes: 10, comfort: .sore, strainWarnings: 0),
            HealthSessionInput(date: marchNoon(2), minutes: 30, comfort: .sore, strainWarnings: 5),
        ]
        let summary = VocalHealthSummary.make(sessions: sessions, now: marchNoon(10), calendar: utc)
        #expect(summary.todayMinutes == 20)
        #expect(summary.weekMinutes == 45)
        #expect(summary.remainingMinutes == 25)
        #expect(summary.fineCount == 1)
        #expect(summary.tiredCount == 0)
        #expect(summary.soreCount == 2)
        #expect(summary.checkInCount == 3)
        #expect(summary.strainWarnings == 3)
        #expect(summary.recentStrainWarnings == 3)
        #expect(summary.suggestsEasyDay)
        #expect(summary.advice == .restDay)

        let calm = VocalHealthSummary.make(sessions: [sessions[0]], now: marchNoon(10), calendar: utc)
        #expect(!calm.suggestsEasyDay)
        #expect(calm.advice == .none)
        #expect(VocalHealthSummary.make(sessions: [], now: marchNoon(10), calendar: utc) == VocalHealthSummary())
    }

    @Test("The articles cover every topic in the spec")
    func articles() {
        let articles = HealthLibrary.articles
        #expect(Set(articles.map(\.id)).count == articles.count)
        let required: Set<String> = ["how-the-voice-works", "safe-habits", "hydration", "rest", "signs-of-strain", "falsetto-forcing", "see-an-slp"]
        #expect(Set(articles.map(\.id)) == required)
        for article in articles {
            #expect(!article.title.isEmpty)
            #expect(!article.summary.isEmpty)
            #expect(article.parts.count >= 3, "\(article.id)")
            #expect(article.parts.allSatisfy { !$0.heading.isEmpty && !($0.paragraphs.isEmpty && $0.bullets.isEmpty) }, "\(article.id)")
            #expect((1...4).contains(article.readingMinutes), "\(article.id)")
        }
        #expect(HealthLibrary.article(id: "hydration")?.title == "Hydration")
        #expect(HealthLibrary.article(id: "nope") == nil)
    }
}

@MainActor
@Suite("Backup and restore", .serialized)
struct BackupTests {
    let source: ModelContainer
    let destination: ModelContainer

    init() throws {
        source = try VoiceBloomDatabase.makeContainer(inMemory: true)
        destination = try VoiceBloomDatabase.makeContainer(inMemory: true)
    }

    private let sessionID = UUID()
    private let recordingID = UUID()
    private let entryID = UUID()

    /// Fills `context` with one of everything. Dates are whole seconds, as
    /// ISO 8601 keeps them.
    private func fill(_ context: ModelContext) throws {
        let profile = UserProfile()
        profile.createdAt = marchNoon(1)
        profile.targetPitchLow = 175
        profile.targetPitchHigh = 230
        profile.targetF2 = 1_900
        profile.dailyGoalMinutes = 20
        profile.hasCompletedOnboarding = true
        profile.restSuggestedDate = marchNoon(9)
        context.insert(profile)

        let session = PracticeSession(id: sessionID, startDate: marchNoon(9), kind: .lesson)
        session.endDate = marchNoon(9, hour: 13)
        session.duration = 900
        session.voicedDuration = 400
        session.lessonID = "week-1"
        session.averagePitch = 190
        session.percentInTarget = 62
        session.comfortRawValue = ComfortRating.sore.rawValue
        session.checkInDate = marchNoon(9, hour: 13)
        session.strainWarningCount = 2
        context.insert(session)

        let recording = Recording(id: recordingID, fileName: "\(recordingID.uuidString).m4a", duration: 30, kind: .clip, createdAt: marchNoon(9))
        recording.transcript = "Hello there"
        recording.sessionID = sessionID
        context.insert(recording)
        recording.session = session

        let entry = DailyJournalEntry(date: marchNoon(8), sentence: "The quick brown fox.")
        entry.id = entryID
        entry.averagePitch = 185
        context.insert(entry)
        let journalRecording = Recording(fileName: "journal.m4a", duration: 4, kind: .journal, createdAt: marchNoon(8))
        context.insert(journalRecording)
        journalRecording.journalEntry = entry

        context.insert(LessonProgress(week: 1, unlockedDate: marchNoon(1)))
        let target = TargetVoiceProfile(name: "Calm")
        target.createdAt = marchNoon(3)
        target.averagePitch = 205
        target.pitchHistogram = [0, 0.5, 0.5]
        target.sourceClipFileName = "target.m4a"
        context.insert(target)
        let scenario = ScenarioResult(scenarioID: "coffee-order", difficulty: .hard)
        scenario.date = marchNoon(7)
        scenario.overallScore = 71
        scenario.usedAIPartner = true
        context.insert(scenario)
        context.insert(Achievement(identifier: "firstSession", unlockedDate: marchNoon(2)))
        try context.save()
    }

    /// Sorts the arrays so archives from different stores compare equal.
    private func normalized(_ archive: BackupArchive) -> BackupArchive {
        var copy = archive
        copy.profiles.sort { $0.id.uuidString < $1.id.uuidString }
        copy.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        copy.recordings.sort { $0.id.uuidString < $1.id.uuidString }
        copy.lessonProgress.sort { $0.week < $1.week }
        copy.targetVoices.sort { $0.id.uuidString < $1.id.uuidString }
        copy.scenarioResults.sort { $0.id.uuidString < $1.id.uuidString }
        copy.achievements.sort { $0.identifier < $1.identifier }
        copy.journalEntries.sort { $0.id.uuidString < $1.id.uuidString }
        copy.files.sort { $0.name < $1.name }
        return copy
    }

    @Test("An archive survives encoding and decoding")
    func encodeDecode() throws {
        try fill(source.mainContext)
        var archive = try BackupService.makeArchive(context: source.mainContext, now: marchNoon(10), includeFiles: false)
        // Fixed preferences (the real ones live in shared UserDefaults).
        archive.preferences = BackupPreferences(
            journalSentence: "Hello",
            aiProvider: "automatic",
            discreetMode: true,
            challengeDays: ["2026-03-10"],
            pitchGameScores: [PitchGameRecord(score: 7, date: marchNoon(9))],
            placementWeek: 3
        )
        archive.files = [BackupFile(name: "clip.m4a", data: Data([1, 2, 3]))]
        #expect(archive.recordCount == 9)
        #expect(archive.sessions.first?.comfortRawValue == "sore")
        #expect(archive.recordings.first { $0.id == recordingID }?.sessionID == sessionID)
        #expect(archive.recordings.contains { $0.journalEntryID == entryID })

        let data = try BackupService.encode(archive)
        let decoded = try BackupService.decode(data)
        #expect(decoded == archive)
    }

    @Test("Restoring replaces everything and relinks relationships")
    func restore() throws {
        try fill(source.mainContext)
        let archive = try BackupService.makeArchive(context: source.mainContext, now: marchNoon(10), includeFiles: false)

        let context = destination.mainContext
        let stale = PracticeSession(startDate: marchNoon(5))
        context.insert(stale)
        context.insert(UserProfile())
        try context.save()

        let decoded = try BackupService.decode(try BackupService.encode(archive))
        try BackupService.restore(decoded, context: context, includesDeviceState: false)

        let sessions = try context.fetch(FetchDescriptor<PracticeSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == sessionID)
        #expect(sessions.first?.comfort == .sore)
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)

        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let clip = recordings.first { $0.id == recordingID }
        #expect(clip?.session?.id == sessionID)
        let journalClip = recordings.first { $0.kind == .journal }
        #expect(journalClip?.journalEntry?.id == entryID)

        var restored = try BackupService.makeArchive(context: context, now: marchNoon(10), includeFiles: false)
        // Preferences come from the shared UserDefaults, not the stores.
        restored.preferences = archive.preferences
        #expect(normalized(restored) == normalized(archive))
    }

    @Test("Unreadable and newer backups are refused")
    func refusals() {
        #expect(throws: BackupError.unreadable) {
            try BackupService.decode(Data("not a backup".utf8))
        }
        #expect(throws: BackupError.newerFormat) {
            try BackupService.decode(Data(#"{"format": 99}"#.utf8))
        }
        #expect(throws: BackupError.unreadable) {
            try BackupService.decode(Data(#"{"format": 1}"#.utf8))
        }
    }

    @Test("Only plain file names are restored")
    func fileNames() {
        #expect(BackupService.isSafeFileName("A1B2.m4a"))
        #expect(!BackupService.isSafeFileName(""))
        #expect(!BackupService.isSafeFileName("../secret"))
        #expect(!BackupService.isSafeFileName("folder/clip.m4a"))
        #expect(!BackupService.isSafeFileName(".hidden"))
        #expect(!BackupService.isSafeFileName("C:clip"))
        #expect(BackupService.fileName(for: marchNoon(10)).hasPrefix("Chirp Backup 2026-03-10"))
    }
}
