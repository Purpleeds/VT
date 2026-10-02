import Foundation
import SwiftData
import Testing
@testable import VoiceBloom

/// Saving sessions, recordings and check-ins in an in-memory SwiftData store.
@MainActor
@Suite("SessionStore", .serialized)
struct SessionStoreTests {
    /// Kept as a property so the store lives as long as the test.
    let container: ModelContainer
    let store: SessionStore

    /// Midnight UTC, 10 March 2026.
    private let march10 = Date(timeIntervalSince1970: 1_773_100_800)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    init() throws {
        container = try VoiceBloomDatabase.makeContainer(inMemory: true)
        store = SessionStore(context: container.mainContext)
    }

    private var context: ModelContext { container.mainContext }

    private func hours(_ value: Double) -> Date {
        march10.addingTimeInterval(value * 3_600)
    }

    /// A snapshot with `voicedFrames` frames of 200 Hz voice (0.01 s each).
    private func snapshot(
        id: UUID = UUID(),
        start: Date? = nil,
        voicedFrames: Int,
        slips: Int = 0
    ) -> SessionSnapshot {
        var stats = VoiceSessionStats()
        for index in 0..<voicedFrames {
            stats.pitch.add(FrameFixture.frame(time: Double(index) * 0.01, frequency: 200), target: .feminine)
        }
        stats.resonance.add(70)
        stats.weight.add(55)
        stats.intonation.add(40)
        stats.brightResonance.add(true)
        return SessionSnapshot(
            id: id,
            startDate: start ?? hours(9),
            activeDuration: Double(voicedFrames) * 0.02,
            frameInterval: 0.01,
            stats: stats,
            voiceQuality: VoiceQualitySummary(jitterPercent: 0.5, shimmerPercent: 3, harmonicsToNoiseDb: 18, sampleCount: 10),
            target: .feminine,
            resonanceMode: .ee,
            slipAlertCount: slips,
            strainWarningCount: 1
        )
    }

    private func clip(transcript: String? = "Hello there") -> RecentClip {
        let audio = AudioClip(samples: [Float](repeating: 0, count: 4_800), sampleRate: 48_000, startTime: 0)
        let records = (0..<10).map { FrameRecord(time: Double($0) * 0.01, pitch: 190, resonanceScore: 50, weightScore: 50) }
        let stats = ClipStats.compute(records: records, from: 0, through: 0.1, target: .feminine, frameInterval: 0.01)
        return RecentClip(audio: audio, stats: stats, transcript: transcript)
    }

    private func sessionCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<PracticeSession>())
    }

    // MARK: Sessions

    @Test("Sessions with under 3 seconds of voice aren't kept")
    func shortSessions() throws {
        let saved = try store.save(snapshot(voicedFrames: 250), finished: true)
        let count = try sessionCount()
        #expect(saved == nil)
        #expect(count == 0)
    }

    @Test("A session is saved with its stats and updated in place")
    func saveAndUpdate() throws {
        let id = UUID()
        let firstSaved = try store.save(snapshot(id: id, voicedFrames: 400, slips: 2), finished: false)
        let first = try #require(firstSaved)
        #expect(first.id == id)
        #expect(first.endDate == nil)
        #expect(abs(first.voicedDuration - 4) < 1e-9)
        #expect(abs(first.duration - 8) < 1e-9)
        #expect(first.averagePitch == 200)
        #expect(first.minimumPitch == 200)
        #expect(first.maximumPitch == 200)
        #expect(first.percentInTarget == 100)
        #expect(first.resonanceScore == 70)
        #expect(first.brightResonancePercent == 100)
        #expect(first.resonanceModeRawValue == ResonanceMode.ee.rawValue)
        #expect(first.weightScore == 55)
        #expect(first.intonationScore == 40)
        #expect(first.jitterPercent == 0.5)
        #expect(first.shimmerPercent == 3)
        #expect(first.harmonicsToNoiseDb == 18)
        #expect(first.slipAlertCount == 2)
        #expect(first.strainWarningCount == 1)
        #expect(first.targetZone == .feminine)
        #expect(first.kind == .freePractice)

        let finishTime = hours(10)
        let secondSaved = try store.save(snapshot(id: id, voicedFrames: 600), finished: true, now: finishTime)
        let second = try #require(secondSaved)
        #expect(second.id == id)
        #expect(abs(second.voicedDuration - 6) < 1e-9)
        #expect(second.endDate == finishTime)
        #expect(second.isFinished)
        let count = try sessionCount()
        #expect(count == 1)
    }

    @Test("Saving a clip keeps a session that is still short")
    func clipKeepsShortSession() throws {
        let short = snapshot(voicedFrames: 50)
        let session = store.ensureSession(for: short)
        let recording = try store.addRecording(id: UUID(), fileName: "test-clip.m4a", clip: clip(), to: session)

        let count = try sessionCount()
        #expect(count == 1)
        #expect(session.recordings?.count == 1)
        #expect(recording.session?.id == short.id)
        #expect(recording.sessionID == short.id)
        #expect(recording.transcript == "Hello there")
        #expect(recording.averagePitch == 190)
        #expect(recording.percentInTarget == 100)
        #expect(abs(recording.duration - 0.1) < 1e-9)
        #expect(recording.kind == .clip)

        // Later saves of the same session update it even though it's short.
        let updated = try store.save(snapshot(id: short.id, voicedFrames: 60), finished: true)
        #expect(updated != nil)
    }

    @Test("Deleting a session deletes its recordings")
    func cascadeDelete() throws {
        let session = store.ensureSession(for: snapshot(voicedFrames: 400))
        try store.addRecording(id: UUID(), fileName: "a.m4a", clip: clip(), to: session)
        try store.addRecording(id: UUID(), fileName: "b.m4a", clip: clip(transcript: nil), to: session)
        let recordingsBefore = try context.fetchCount(FetchDescriptor<Recording>())
        #expect(recordingsBefore == 2)

        try store.delete(session)
        let sessionsAfter = try sessionCount()
        let recordingsAfter = try context.fetchCount(FetchDescriptor<Recording>())
        #expect(sessionsAfter == 0)
        #expect(recordingsAfter == 0)
    }

    @Test("Deleting one recording keeps the session")
    func deleteRecording() throws {
        let session = store.ensureSession(for: snapshot(voicedFrames: 400))
        let recording = try store.addRecording(id: UUID(), fileName: "c.m4a", clip: clip(), to: session)
        try store.delete(recording)
        let sessions = try sessionCount()
        let recordings = try context.fetchCount(FetchDescriptor<Recording>())
        #expect(sessions == 1)
        #expect(recordings == 0)
    }

    @Test("Sessions left in progress by an earlier launch are closed")
    func abandonedSessions() throws {
        let abandonedSaved = try store.save(snapshot(start: hours(8), voicedFrames: 400), finished: false)
        let abandoned = try #require(abandonedSaved)
        let currentSaved = try store.save(snapshot(start: hours(9), voicedFrames: 400), finished: false)
        let current = try #require(currentSaved)

        try store.finishAbandonedSessions(except: current.id)
        #expect(abandoned.endDate == hours(8).addingTimeInterval(abandoned.duration))
        #expect(current.endDate == nil)
    }

    // MARK: Check-ins

    @Test("Check-in answers are saved")
    func checkInSaved() throws {
        let sessionSaved = try store.save(snapshot(voicedFrames: 400), finished: true, now: hours(10))
        let session = try #require(sessionSaved)
        let advice = try store.recordCheckIn(for: session, comfort: .tired, naturalness: 7, now: hours(10), calendar: calendar)
        #expect(advice == .none)
        #expect(session.comfort == .tired)
        #expect(session.naturalnessRating == 5)
        #expect(session.checkInDate == hours(10))
        #expect(session.hasCheckIn)
    }

    @Test("A second “Sore” within 3 days suggests a rest day and remembers it")
    func soreTwice() throws {
        let earlierSaved = try store.save(snapshot(start: hours(-40), voicedFrames: 400), finished: true, now: hours(-39))
        let earlier = try #require(earlierSaved)
        let laterSaved = try store.save(snapshot(start: hours(9), voicedFrames: 400), finished: true, now: hours(10))
        let later = try #require(laterSaved)

        let firstAdvice = try store.recordCheckIn(for: earlier, comfort: .sore, naturalness: 3, now: hours(-39), calendar: calendar)
        #expect(firstAdvice == .none)

        let secondAdvice = try store.recordCheckIn(for: later, comfort: .sore, naturalness: 2, now: hours(10), calendar: calendar)
        #expect(secondAdvice == .restDay)
        let profile = ProfileStore(context: context).profile()
        #expect(profile.restSuggestedDate == hours(10))

        let reports = try store.comfortReports(since: hours(-72))
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.comfort == .sore })
    }

    @Test("A finished session without a check-in is offered for one later")
    func awaitingCheckIn() throws {
        let sessionSaved = try store.save(snapshot(start: hours(9), voicedFrames: 400), finished: true, now: hours(9.5))
        let session = try #require(sessionSaved)
        #expect(store.sessionAwaitingCheckIn(now: hours(12))?.id == session.id)
        // Too long ago.
        #expect(store.sessionAwaitingCheckIn(now: hours(30)) == nil)

        _ = try store.recordCheckIn(for: session, comfort: .fine, naturalness: 4, now: hours(12), calendar: calendar)
        #expect(store.sessionAwaitingCheckIn(now: hours(12)) == nil)
    }

    // MARK: Profile

    @Test("There is one profile, created with the default targets")
    func singleProfile() throws {
        let profiles = ProfileStore(context: context)
        let first = profiles.profile()
        let second = profiles.profile()
        #expect(first.id == second.id)
        #expect(first.targetZone == .feminine)
        #expect(first.goalType == .feminine)
        let count = try context.fetchCount(FetchDescriptor<UserProfile>())
        #expect(count == 1)
    }
}
