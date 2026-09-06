import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// The per-day reuse key must witness every stream `analyzeDay` scores, not HR alone (#29).
///
/// A WHOOP history offload does not commit its channels together: HR can land first and R-R (or
/// respiration, or SpO2) minutes later, and an offloaded HR row duplicating a live one is dropped by
/// `ON CONFLICT DO NOTHING`. So a banked night can be scored once from HR alone and then have its R-R
/// arrive with the night's HR `(count, maxTs)` completely unmoved. The whole-pass gate already sees that —
/// `WhoopStore.analysisFingerprint` covers every raw stream — so the pass runs; it was the PER-DAY key that
/// said "reuse", re-serving the HRV-less scan for the rest of the session, force refreshes included.
///
/// `AnalyzeRecentDayCacheTests` pins the key's contract on literal witnesses. This one drives the two real
/// halves against each other — `analyzeDay` for what the night actually scores, a real store for what the
/// witness actually reports — so neither half can drift into agreeing with a broken other half.
/// Swift-only: it drives a real `WhoopStore`, and Kotlin pins the same contract from the key side in
/// `AnalyzeRecentDayCacheTest`.
final class AnalyzeRecentDayCacheStreamWitnessTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"
    private let owner = "whoop-A"

    /// 16 h awake around 74 +/- 11 bpm then 8 h asleep around 64 +/- 5, anchored so the night runs
    /// 00:00-08:00 on `day` — the same field-shaped generator `AnalyticsEngineHrOnlyDayTests` uses. No
    /// gravity, which is the shape of the banked night in the report: a strap that streamed HR and R-R.
    private func streams() -> ([HRSample], [RRInterval]) {
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let t0 = dayStart - 16 * 3600
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(16 * 3600) {
            let bpm = 74 + Int(sin(Double(i) / 500.0) * 11)
            hr.append(HRSample(ts: t0 + i, bpm: bpm))
            rr.append(RRInterval(ts: t0 + i, rrMs: 60000 / bpm))
        }
        for j in 0..<(8 * 3600) {
            let bpm = 64 + Int(sin(Double(j) / 900.0) * 5)
            hr.append(HRSample(ts: dayStart + j, bpm: bpm))
            rr.append(RRInterval(ts: dayStart + j, rrMs: 60000 / bpm))
        }
        return (hr, rr)
    }

    private func scan(hr: [HRSample], rr: [RRInterval]) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, profile: profile,
                                   providedSleep: SleepStager.hrOnlySessions(hr: hr, rr: rr, resp: []))
    }

    /// R-R landing after HR changes what the night scores, so it must change the reuse key.
    func testLateRrChangesTheNightAndInvalidatesTheKey() async throws {
        let (hr, rr) = streams()
        let from = hr.map(\.ts).min() ?? 0
        let to = hr.map(\.ts).max() ?? 0

        // What the night scores. Pass 1: HR is committed, R-R has not landed. Pass 2: same HR, plus R-R.
        let hrOnly = scan(hr: hr, rr: [])
        let withRr = scan(hr: hr, rr: rr)
        XCTAssertNil(hrOnly.daily.avgHrv, "an R-R-less night has no nightly HRV to bank")
        XCTAssertNotNil(withRr.daily.avgHrv, "once R-R lands the night scores an HRV — the cached scan is stale")

        // What the store reports, over the SAME two commits.
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: hr), deviceId: owner)
        let beforeFp = try await store.hrFingerprint(deviceId: owner, from: from, to: to)
        let beforeStreams = try await store.dayStreamFingerprint(deviceId: owner, from: from, to: to)

        _ = try await store.insert(Streams(rr: rr), deviceId: owner)
        let afterFp = try await store.hrFingerprint(deviceId: owner, from: from, to: to)
        let afterStreams = try await store.dayStreamFingerprint(deviceId: owner, from: from, to: to)

        // The HR witness alone cannot see this commit — that is the whole defect.
        XCTAssertEqual(beforeFp.count, afterFp.count)
        XCTAssertEqual(beforeFp.maxTs, afterFp.maxTs)
        XCTAssertNotEqual(beforeStreams, afterStreams, "the R-R commit must move the other-stream witness")

        let before = AnalyzeRecentDayCache.cacheKey(
            owner: owner, hrCount: beforeFp.count, hrMaxTs: beforeFp.maxTs, skinAnchorRaw: nil,
            streams: beforeStreams, hrvWindowDetail: false)
        let after = AnalyzeRecentDayCache.cacheKey(
            owner: owner, hrCount: afterFp.count, hrMaxTs: afterFp.maxTs, skinAnchorRaw: nil,
            streams: afterStreams, hrvWindowDetail: false)
        XCTAssertNotEqual(before, after,
                          "the night's R-R arrived — reusing the HRV-less scan is the #29 defect")

        // And a pass that commits nothing must still reuse: the fix must not re-score every night forever.
        let idleFp = try await store.hrFingerprint(deviceId: owner, from: from, to: to)
        let idleStreams = try await store.dayStreamFingerprint(deviceId: owner, from: from, to: to)
        XCTAssertEqual(after, AnalyzeRecentDayCache.cacheKey(
            owner: owner, hrCount: idleFp.count, hrMaxTs: idleFp.maxTs, skinAnchorRaw: nil,
            streams: idleStreams, hrvWindowDetail: false))
    }
}
