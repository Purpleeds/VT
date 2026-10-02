import Foundation
import Testing
@testable import VoiceBloom

@Suite("Safe number formatting")
struct FormattingTests {
    @Test("Rounding for display never traps")
    func roundedInt() {
        #expect(12.4.roundedInt == 12)
        #expect(12.5.roundedInt == 13)
        #expect((-2.6).roundedInt == -3)
        #expect(Double.nan.roundedInt == 0)
        #expect(Double.infinity.roundedInt == 0)
        #expect((-Double.infinity).roundedInt == 0)
        #expect(1e300.roundedInt == Int.max)
        #expect((-1e300).roundedInt == Int.min)
    }

    @Test("Saved statistics format safely")
    func sessionFormat() {
        #expect(SessionFormat.hertz(201.6) == "202 Hz")
        #expect(SessionFormat.hertz(.nan) == "0 Hz")
        #expect(SessionFormat.percent(49.5) == "50%")
        #expect(SessionFormat.score(nil) == "—")
        #expect(SessionFormat.duration(.nan) == "0 s")
        #expect(SessionFormat.duration(3_900) == "1 h 5 min")
        #expect(SessionFormat.range(low: 180.2, high: 219.7) == "180–220 Hz")
        #expect(PitchTargetZone(lowerBound: 180, upperBound: 220).formatted == "180–220 Hz")
    }
}
