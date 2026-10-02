import Foundation

/// All of a session's statistics as one CSV row.
nonisolated struct SessionExportRow: Sendable, Equatable {
    var date: Date
    var kind: String
    var durationSeconds: Double
    var voicedSeconds: Double
    var averagePitch: Double?
    var minimumPitch: Double?
    var maximumPitch: Double?
    var percentInTarget: Double?
    var targetLow: Double
    var targetHigh: Double
    var resonance: Double?
    var brightResonancePercent: Double?
    var weight: Double?
    var intonation: Double?
    var jitterPercent: Double?
    var shimmerPercent: Double?
    var harmonicsToNoiseDb: Double?
    var slipAlerts: Int
    var strainWarnings: Int
    var comfort: String?
    var naturalness: Int?
    var recordingCount: Int

    init(_ session: PracticeSession) {
        date = session.startDate
        kind = session.kind.title
        durationSeconds = session.duration
        voicedSeconds = session.voicedDuration
        averagePitch = session.averagePitch
        minimumPitch = session.minimumPitch
        maximumPitch = session.maximumPitch
        percentInTarget = session.percentInTarget
        targetLow = session.targetPitchLow
        targetHigh = session.targetPitchHigh
        resonance = session.resonanceScore
        brightResonancePercent = session.brightResonancePercent
        weight = session.weightScore
        intonation = session.intonationScore
        jitterPercent = session.jitterPercent
        shimmerPercent = session.shimmerPercent
        harmonicsToNoiseDb = session.harmonicsToNoiseDb
        slipAlerts = session.slipAlertCount
        strainWarnings = session.strainWarningCount
        comfort = session.comfort?.title
        naturalness = session.naturalnessRating
        recordingCount = session.recordings?.count ?? 0
    }

    init(date: Date, kind: String, durationSeconds: Double) {
        self.date = date
        self.kind = kind
        self.durationSeconds = durationSeconds
        voicedSeconds = 0
        targetLow = 180
        targetHigh = 220
        slipAlerts = 0
        strainWarnings = 0
        recordingCount = 0
    }
}

/// "Export: CSV of all stats" (SPEC section 11).
nonisolated enum ProgressCSV {
    static let header = [
        "date", "type", "practice_minutes", "voiced_minutes",
        "average_pitch_hz", "lowest_pitch_hz", "highest_pitch_hz",
        "percent_in_target", "target_low_hz", "target_high_hz",
        "resonance_score", "bright_resonance_percent", "weight_score", "intonation_score",
        "jitter_percent", "shimmer_percent", "hnr_db",
        "slip_alerts", "tired_voice_warnings", "throat_comfort", "naturalness_1_to_5", "recordings",
    ]

    /// One header line plus one line per session (oldest first), with CRLF
    /// line endings as spreadsheet apps expect.
    static func make(rows: [SessionExportRow], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines = [header.joined(separator: ",")]
        for row in rows.sorted(by: { $0.date < $1.date }) {
            let fields: [String] = [
                formatter.string(from: row.date),
                row.kind,
                number(row.durationSeconds / 60, decimals: 1),
                number(row.voicedSeconds / 60, decimals: 1),
                number(row.averagePitch, decimals: 1),
                number(row.minimumPitch, decimals: 1),
                number(row.maximumPitch, decimals: 1),
                number(row.percentInTarget, decimals: 1),
                number(row.targetLow, decimals: 0),
                number(row.targetHigh, decimals: 0),
                number(row.resonance, decimals: 1),
                number(row.brightResonancePercent, decimals: 1),
                number(row.weight, decimals: 1),
                number(row.intonation, decimals: 1),
                number(row.jitterPercent, decimals: 2),
                number(row.shimmerPercent, decimals: 2),
                number(row.harmonicsToNoiseDb, decimals: 1),
                String(row.slipAlerts),
                String(row.strainWarnings),
                row.comfort ?? "",
                row.naturalness.map(String.init) ?? "",
                String(row.recordingCount),
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a field when it contains a comma, quote or line break (RFC 4180).
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Fixed-point with a "." decimal separator whatever the language, or empty for no value.
    static func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    /// e.g. "VoiceBloom sessions 2026-03-10.csv"
    static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "VoiceBloom sessions \(formatter.string(from: now)).csv"
    }
}
