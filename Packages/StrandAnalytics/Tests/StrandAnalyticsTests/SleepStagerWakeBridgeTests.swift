import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Wake-gap bridging (experimental, default OFF): assemble adjacent sleep runs across ≤ 45-min wake
/// gaps into ONE candidate run, so a brief get-up stays inside one session as staged wake.
///
/// Includes a REAL-DATA pin: the exact seam layout of a reporting wearer's stored fragmented nights
/// (Aug 2026 mirror), asserting precisely which seams the bridge merges and which it leaves split.
/// An HR-led rescue of restless-but-asleep nights was prototyped alongside this bridge and WITHDRAWN
/// after a real-data replay — see the history note above `SleepStager.wakeBridgeMaxMin`; the
/// restless-night test below pins that the bridge deliberately does NOT fix that failure.
/// The Kotlin twin (`SleepStagerWakeBridgeTest`) runs the same scenarios with the same numbers.
final class SleepStagerWakeBridgeTests: XCTestCase {

    // MARK: - Stream builders (1 Hz, mirroring SleepStagerTests)

    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// Oscillating orientation (0.5 g jumps per sample) — clearly "moving" to the stillness spine.
    private func restlessGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let phase = Double(i % 2) * 0.5
            return GravitySample(ts: start + i, x: phase, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// 2026-06-10 00:00:00 UTC + `hourUTC` hours (tz offset 0 in every test, so local == UTC).
    private func at(_ hourUTC: Int, min: Int = 0) -> Int {
        1_749_513_600 + hourUTC * 3_600 + min * 60
    }

    // MARK: - Wake-gap bridging (the SPLIT-night failure)

    /// A 16-min get-up (real movement + HR 80) mid-night. The centered rolling window smears it to a
    /// >mergeMin active run, so OFF stores TWO sessions. ON bridges them into ONE session.
    func testBriefGetUpBridgedIntoOneSession() {
        let grav = stillGravity(start: at(23), durationS: 4 * 3_600)                 // 23:00–03:00
            + restlessGravity(start: at(27), durationS: 16 * 60)                     // 03:00–03:16 get-up
            + stillGravity(start: at(27, min: 16), durationS: 3 * 3_600 + 44 * 60)   // 03:16–07:00
        let hr = hrStream(start: at(21), durationS: 2 * 3_600, bpm: 75)              // 21:00–23:00 awake
            + hrStream(start: at(23), durationS: 4 * 3_600, bpm: 52)                 // 23:00–03:00 asleep
            + hrStream(start: at(27), durationS: 16 * 60, bpm: 80)                   // get-up spike
            + hrStream(start: at(27, min: 16), durationS: 3 * 3_600 + 44 * 60, bpm: 52) // back asleep
            + hrStream(start: at(31), durationS: 2 * 3_600, bpm: 75)                 // 07:00–09:00 awake

        let off = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(off.count, 2, "OFF: the smeared get-up splits the night")

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, wakeBridge: true)
        XCTAssertEqual(on.count, 1, "ON: one session bridging the get-up")
        XCTAssertLessThanOrEqual(abs(on[0].start - at(23)), 120)
        XCTAssertLessThanOrEqual(abs(on[0].end - at(31)), 120)
    }

    /// An 80-min genuinely-awake block (elevated HR, real movement) exceeds the 45-min bridge:
    /// the night stays two sessions even with the bridge ON.
    func testLongWakeGapStaysSplit() {
        let grav = stillGravity(start: at(22), durationS: 3 * 3_600)                 // 22:00–01:00
            + restlessGravity(start: at(25), durationS: 80 * 60)                     // 01:00–02:20 awake
            + stillGravity(start: at(26, min: 20), durationS: 3 * 3_600 + 40 * 60)   // 02:20–06:00
        let hr = hrStream(start: at(20), durationS: 2 * 3_600, bpm: 75)
            + hrStream(start: at(22), durationS: 3 * 3_600, bpm: 52)
            + hrStream(start: at(25), durationS: 80 * 60, bpm: 78)
            + hrStream(start: at(26, min: 20), durationS: 3 * 3_600 + 40 * 60, bpm: 52)
            + hrStream(start: at(30), durationS: 2 * 3_600, bpm: 75)

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, wakeBridge: true)
        XCTAssertEqual(on.count, 2, "an over-threshold wake gap must not be bridged")
    }

    /// The withdrawn-rescue pin: a restless night (motion "active", HR at clear sleep levels) is NOT
    /// rescued by the bridge — ON must change nothing versus OFF. The bridge only assembles runs the
    /// unchanged stillness spine already accepted; the restless-night DROPPING failure is documented
    /// open (see the history note above `wakeBridgeMaxMin`).
    func testRestlessNightIsNotRescuedByBridge() {
        let grav = restlessGravity(start: at(22), durationS: 6 * 3_600 + 1_800)      // 22:00–04:30
            + stillGravity(start: at(28, min: 30), durationS: 90 * 60)               // 04:30–06:00
        let hr = hrStream(start: at(20), durationS: 2 * 3_600, bpm: 75)
            + hrStream(start: at(22), durationS: 8 * 3_600, bpm: 52)
            + hrStream(start: at(30), durationS: 2 * 3_600, bpm: 75)

        let off = SleepStager.detectSleep(hr: hr, gravity: grav)
        let on = SleepStager.detectSleep(hr: hr, gravity: grav, wakeBridge: true)
        XCTAssertEqual(on, off, "the bridge must not reclassify restless stretches")
        XCTAssertEqual(on.count, 1, "only the still morning fragment scores either way")
        XCTAssertGreaterThanOrEqual(on[0].start, at(28, min: 25))
    }

    // MARK: - Guards still hold on assembled runs

    /// Two still DAYTIME stretches bridged across a 30-min gap (flat in-band HR, no cardiac dip)
    /// must still be dropped by the daytime false-sleep guard on the ASSEMBLED window.
    func testDaytimeGuardStillAppliesToBridgedRuns() {
        let grav = stillGravity(start: at(12), durationS: 2 * 3_600)                 // 12:00–14:00
            + stillGravity(start: at(14, min: 30), durationS: 2 * 3_600)             // 14:30–16:30
        let hr = hrStream(start: at(10), durationS: 8 * 3_600, bpm: 60)              // flat, no dip

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, wakeBridge: true)
        XCTAssertEqual(on.count, 0, "no resting-HR dip: the daytime guard must reject the bridged window")
    }

    /// Default-off byte-identity: omitting the flag and passing `false` produce the identical result.
    func testDefaultOffIsByteIdentical() {
        let grav = stillGravity(start: at(23), durationS: 4 * 3_600)
            + restlessGravity(start: at(27), durationS: 16 * 60)
            + stillGravity(start: at(27, min: 16), durationS: 3 * 3_600 + 44 * 60)
        let hr = hrStream(start: at(23), durationS: 8 * 3_600, bpm: 52)
            + hrStream(start: at(31), durationS: 4 * 3_600, bpm: 75)

        let implicitDefault = SleepStager.detectSleep(hr: hr, gravity: grav)
        let explicitFalse = SleepStager.detectSleep(hr: hr, gravity: grav, wakeBridge: false)
        XCTAssertEqual(implicitDefault, explicitFalse)
    }

    // MARK: - Pure helper

    func testBridgeWakeGapsMergesOnlyUnderThreshold() {
        let a = SleepStager.Period(stage: "sleep", start: 0, end: 3_600)
        let gap = SleepStager.Period(stage: "active", start: 3_600, end: 3_600 + 40 * 60)
        let b = SleepStager.Period(stage: "sleep", start: 3_600 + 40 * 60, end: 3 * 3_600)
        let merged = SleepStager.bridgeWakeGaps([a, gap, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 3 * 3_600)

        let farGap = SleepStager.Period(stage: "active", start: 3_600, end: 3_600 + 46 * 60)
        let c = SleepStager.Period(stage: "sleep", start: 3_600 + 46 * 60, end: 4 * 3_600)
        let unmerged = SleepStager.bridgeWakeGaps([a, farGap, c])
        XCTAssertEqual(unmerged.count, 3, "a 46-min gap is over wakeBridgeMaxMin (45) and must not merge")
    }

    /// H4 span guard: a merge whose ASSEMBLED span would exceed maxMainSleepSpanS (16 h) is refused,
    /// so a pathological chain can never assemble and then be dropped whole by the ladder's cap —
    /// the exact failure the withdrawn HR rescue exhibited on real data.
    func testBridgeRefusesOverSpanCapMerge() {
        let a = SleepStager.Period(stage: "sleep", start: 0, end: 8 * 3_600)
        let b = SleepStager.Period(stage: "sleep", start: 8 * 3_600 + 30 * 60, end: 17 * 3_600)
        let out = SleepStager.bridgeWakeGaps([a, b])
        XCTAssertEqual(out.count, 2, "a merge assembling a >16 h span must be refused")
    }

    // MARK: - Real-data seam pin (Aug 2026 mirror, reporting wearer's stored fragments)

    /// The stored fragment layouts of five REAL split nights, as (start, end) unix pairs from the
    /// wearer's server mirror. Asserts exactly which seams the 45-min bridge merges (16/12/28/25+19/
    /// 17-min arousal seams) and which it leaves split (2.2–3.9 h genuine wake gaps, and a 90-min
    /// morning re-sleep gap — over the threshold, left to the selector's #861 night-tail bridge).
    func testRealNightSeamsBridgeExactly() {
        func sleeps(_ spans: [(Int, Int)]) -> [SleepStager.Period] {
            spans.map { SleepStager.Period(stage: "sleep", start: $0.0, end: $0.1) }
        }
        // Aug 11→12 ET: 4 fragments; only the 16-min bathroom seam (06:17→06:33 ET) merges → 3 blocks.
        let aug12 = sleeps([(1786491049, 1786496628), (1786510824, 1786514588),
                            (1786522512, 1786529853), (1786530794, 1786541952)])
        let aug12Out = SleepStager.bridgeWakeGaps(aug12)
        XCTAssertEqual(aug12Out.map { [$0.start, $0.end] },
                       [[1786491049, 1786496628], [1786510824, 1786514588], [1786522512, 1786541952]])

        // Aug 17→18 ET: 3 fragments; the 12-min seam merges, the 3.8 h gap stays → 2 blocks.
        let aug18 = sleeps([(1787032890, 1787037056), (1787050829, 1787054649),
                            (1787055394, 1787063445)])
        XCTAssertEqual(SleepStager.bridgeWakeGaps(aug18).map { [$0.start, $0.end] },
                       [[1787032890, 1787037056], [1787050829, 1787063445]])

        // Aug 18→19 ET: 2 fragments at a 28-min seam → 1 block.
        let aug19 = sleeps([(1787126248, 1787132602), (1787134284, 1787141425)])
        XCTAssertEqual(SleepStager.bridgeWakeGaps(aug19).map { [$0.start, $0.end] },
                       [[1787126248, 1787141425]])

        // Aug 20→21 ET: 3 fragments at 25-min and 19-min seams → 1 block (11.4 h < the 16 h cap).
        // NOTE: the mirror's correction pass (an HR-evidence-led edit session, not a human label)
        // kept the third block (a 10:44–12:03 post-wake morning doze) as a SEPARATE doze; the
        // 45-min rule cannot distinguish "brief wake, more sleep" from "woke, dozed again", so the
        // bridge deliberately folds it in (wake staged inside) and a wearer who disagrees hand-edits
        // that one seam. Pinned as-is, eyes open.
        let aug21 = sleeps([(1787287220, 1787297404), (1787298936, 1787322337),
                            (1787323440, 1787328166)])
        XCTAssertEqual(SleepStager.bridgeWakeGaps(aug21).map { [$0.start, $0.end] },
                       [[1787287220, 1787328166]])

        // Aug 23→24 ET: 2 fragments at a 90-min gap → stays split (over the 45-min bridge). The
        // mirror's correction pass filled this gap as SLEEP on HR evidence — it is the
        // withdrawn-rescue (restless dropping) class, not a seam; the bridge must not guess it.
        let aug24 = sleeps([(1787546768, 1787551261), (1787556701, 1787575851)])
        XCTAssertEqual(SleepStager.bridgeWakeGaps(aug24).count, 2)
    }
}
