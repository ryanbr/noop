import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// `analyzeDay`'s calorie-path selection (#2242): a day that carries the owner's OWN MET series scores
/// `activeKcalEst` by `Calories.estimateDayEnergyFromMET`; below the coverage floor it withholds the number
/// rather than falling back to HR; no MET (every WHOOP / toggle-OFF caller) keeps the HR path byte-identical.
/// The Kotlin twin (`AnalyticsEngineMetCaloriesTest`) mirrors these vectors value-for-value.
final class AnalyticsEngineMetCaloriesTests: XCTestCase {

    private let day = "2026-08-15"
    private let off = 7_200   // Europe/Paris in August
    private var localMid: Int { AnalyticsEngine.dayStartUtcSeconds(day) - off }
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    private func dayHr() -> [HRSample] {
        stride(from: localMid, to: localMid + 86_400, by: 10).map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
    }
    /// Full-day MET at 1.0 with a 40-min 5.0-MET bout, plus spill into both neighbour days that must be ignored.
    private func fullMet() -> [Calories.MetSample] {
        stride(from: localMid - 3_600, to: localMid + 86_400 + 3_600, by: 60).map { ts in
            let minute = (ts - localMid) / 60
            let met = (ts < localMid || ts >= localMid + 86_400) ? 9.0 : ((600..<640).contains(minute) ? 5.0 : 1.0)
            return Calories.MetSample(ts: ts, met: met)
        }
    }

    func testMetPathReplacesHrPathWhenCovered() {
        var lines: [String] = []
        let res = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), dayMet: fullMet(),
                                             caloriesDiag: { lines.append($0) },
                                             profile: profile, tzOffsetSeconds: off)
        let expected = Calories.estimateDayEnergyFromMET(fullMet(), profile: profile,
                                                         dayStart: localMid, dayEnd: localMid + 86_400)
        XCTAssertEqual(expected.coverageFraction, 1.0, accuracy: 1e-12)
        XCTAssertEqual(res.daily.activeKcalEst ?? -1, expected.totalKcal, accuracy: 1e-9)
        // And it is NOT the HR number.
        let hrOnly = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), profile: profile, tzOffsetSeconds: off)
        XCTAssertNotEqual(hrOnly.daily.activeKcalEst ?? -1, expected.totalKcal, accuracy: 1e-6)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("calories 2026-08-15: MET path - coverage 100% (1560 samples), active "), lines[0])
    }

    func testBelowCoverageFloorWithholdsRatherThanSubstitutes() {
        var lines: [String] = []
        let thin = Array(fullMet().prefix(60 + 400))   // 1 h spill + 400 covered minutes = 28 % of the day
        let res = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), dayMet: thin,
                                             caloriesDiag: { lines.append($0) },
                                             profile: profile, tzOffsetSeconds: off)
        XCTAssertNil(res.daily.activeKcalEst)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("coverage 28% (460 samples) below 50% floor, estimate withheld"), lines[0])
    }

    func testTodayIsJudgedAgainstElapsedHours() {
        // Same 400 covered minutes, but `now` is 07:00 local: 400/420 min = 95 % of the elapsed window.
        var lines: [String] = []
        let thin = Array(fullMet().prefix(60 + 400))
        let res = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), dayMet: thin, dayMetNow: localMid + 7 * 3600,
                                             caloriesDiag: { lines.append($0) },
                                             profile: profile, tzOffsetSeconds: off)
        let expected = Calories.estimateDayEnergyFromMET(thin, profile: profile,
                                                         dayStart: localMid, dayEnd: localMid + 7 * 3600)
        XCTAssertEqual(res.daily.activeKcalEst ?? -1, expected.totalKcal, accuracy: 1e-9)
        XCTAssertTrue(lines[0].contains("coverage 95% (460 samples)"), lines[0])
    }

    func testNoMetKeepsHrPathByteIdentical() {
        var lines: [String] = []
        let base = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), profile: profile, tzOffsetSeconds: off)
        let nilMet = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), dayMet: nil,
                                                caloriesDiag: { lines.append($0) },
                                                profile: profile, tzOffsetSeconds: off)
        let emptyMet = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr(), dayMet: [],
                                                  caloriesDiag: { lines.append($0) },
                                                  profile: profile, tzOffsetSeconds: off)
        XCTAssertEqual(base.daily, nilMet.daily)
        XCTAssertEqual(base.daily, emptyMet.daily)
        XCTAssertNotNil(base.daily.activeKcalEst)
        XCTAssertTrue(lines.isEmpty, "the HR path logs nothing new")
    }
}
