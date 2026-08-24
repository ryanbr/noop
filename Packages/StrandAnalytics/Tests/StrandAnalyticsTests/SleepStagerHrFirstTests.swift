import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// HR-first sleep detection (experimental, default OFF): weight HR over motion when the two
/// disagree, and assemble one session per sleep period across short wake gaps.
///
/// Per the "validate against varying inputs" rule (#194/#345), these tests inject the sleep window
/// at DIFFERENT positions and lengths and assert the rescue TRACKS it — and that the identical
/// motion pattern with an elevated (awake) HR is refused — rather than pinning one matched night.
/// The Kotlin twin (`SleepStagerHrFirstTest`) runs the same scenarios with the same numbers.
final class SleepStagerHrFirstTests: XCTestCase {

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

    // MARK: - Restless-night rescue (the DROPPED-night failure)

    /// A night that is restless (motion says "active") but cardiac-unambiguous (HR 52 vs awake 75)
    /// from 22:00 to 04:30, then still to 06:00. OFF: only the quiescent morning fragment scores —
    /// the real-world symptom. ON: the whole night is one session.
    func testRestlessNightRescuedToFullSession() {
        let grav = restlessGravity(start: at(22), durationS: 6 * 3_600 + 1_800)      // 22:00–04:30
            + stillGravity(start: at(28, min: 30), durationS: 90 * 60)               // 04:30–06:00
        let hr = hrStream(start: at(20), durationS: 2 * 3_600, bpm: 75)     // 20:00–22:00 awake
            + hrStream(start: at(22), durationS: 8 * 3_600, bpm: 52)        // 22:00–06:00 asleep
            + hrStream(start: at(30), durationS: 2 * 3_600, bpm: 75)        // 06:00–08:00 awake

        let off = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(off.count, 1, "OFF: only the still morning fragment should score")
        XCTAssertGreaterThanOrEqual(off[0].start, at(28, min: 25), "OFF fragment starts near 04:30")
        XCTAssertLessThanOrEqual(off[0].start, at(28, min: 45))

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on.count, 1, "ON: one assembled session for the whole night")
        XCTAssertLessThanOrEqual(on[0].start, at(22) + 120, "ON: onset tracks the injected 22:00 sleep start")
        XCTAssertGreaterThanOrEqual(on[0].end, at(30) - 120, "ON: end tracks the injected 06:00 wake")
    }

    /// Same rescue with the sleep window injected at a DIFFERENT position and length (01:00–07:30,
    /// all restless, no still stretch at all): OFF finds nothing; ON tracks the injected bounds.
    func testRestlessRescueTracksInjectedWindow() {
        let grav = restlessGravity(start: at(25), durationS: 6 * 3_600 + 1_800)      // 01:00–07:30
        let hr = hrStream(start: at(22), durationS: 3 * 3_600, bpm: 75)              // 22:00–01:00 awake
            + hrStream(start: at(25), durationS: 6 * 3_600 + 1_800, bpm: 52)         // 01:00–07:30 asleep
            + hrStream(start: at(31, min: 30), durationS: 2 * 3_600, bpm: 75)        // 07:30–09:30 awake

        XCTAssertEqual(SleepStager.detectSleep(hr: hr, gravity: grav).count, 0,
                       "OFF: an all-restless night scores nothing")

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on.count, 1)
        XCTAssertLessThanOrEqual(abs(on[0].start - at(25)), 120, "onset tracks the moved window")
        XCTAssertLessThanOrEqual(abs(on[0].end - at(31, min: 30)), 120, "end tracks the moved window")
    }

    /// The IDENTICAL motion pattern as the full-night rescue, but with the night HR elevated (78 vs
    /// a 62 day median — awake-in-bed restlessness): the rescue must refuse the restless stretch.
    /// (The STILL morning fragment is still accepted — by the pre-existing motion-corroborated
    /// quiescent band (#462), which deliberately tolerates elevated-but-flat HR on a motionless
    /// run — so the assertion is that HR-first adds NOTHING: same single fragment, not a full
    /// night, with an onset still at the quiescent stretch.)
    func testElevatedHrNightIsNotRescued() {
        let grav = restlessGravity(start: at(22), durationS: 6 * 3_600 + 1_800)      // 22:00–04:30
            + stillGravity(start: at(28, min: 30), durationS: 90 * 60)               // 04:30–06:00
        let hr = hrStream(start: at(22), durationS: 8 * 3_600, bpm: 78)              // 22:00–06:00 elevated
            + hrStream(start: at(30), durationS: 10 * 3_600, bpm: 62)                // 06:00–16:00 day median

        let off = SleepStager.detectSleep(hr: hr, gravity: grav)
        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on, off, "same motion, elevated HR: HR-first must change nothing")
        XCTAssertEqual(on.count, 1)
        XCTAssertGreaterThanOrEqual(on[0].start, at(28, min: 25),
                                    "the restless 22:00–04:30 stretch must NOT be rescued")
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

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on.count, 1, "ON: one session bridging the get-up")
        XCTAssertLessThanOrEqual(abs(on[0].start - at(23)), 120)
        XCTAssertLessThanOrEqual(abs(on[0].end - at(31)), 120)
    }

    /// An 80-min genuinely-awake block (elevated HR, real movement) exceeds the 45-min bridge:
    /// the night stays two sessions even with HR-first ON.
    func testLongWakeGapStaysSplit() {
        let grav = stillGravity(start: at(22), durationS: 3 * 3_600)                 // 22:00–01:00
            + restlessGravity(start: at(25), durationS: 80 * 60)                     // 01:00–02:20 awake
            + stillGravity(start: at(26, min: 20), durationS: 3 * 3_600 + 40 * 60)   // 02:20–06:00
        let hr = hrStream(start: at(20), durationS: 2 * 3_600, bpm: 75)
            + hrStream(start: at(22), durationS: 3 * 3_600, bpm: 52)
            + hrStream(start: at(25), durationS: 80 * 60, bpm: 78)
            + hrStream(start: at(26, min: 20), durationS: 3 * 3_600 + 40 * 60, bpm: 52)
            + hrStream(start: at(30), durationS: 2 * 3_600, bpm: 75)

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on.count, 2, "an over-threshold wake gap must not be bridged")
    }

    // MARK: - Guards still hold on assembled runs

    /// A rescued + bridged DAYTIME stretch (in-band flat HR 60, no cardiac dip) must still be
    /// dropped by the daytime false-sleep guard: the rescue may not create phantom daytime naps.
    func testDaytimeGuardStillAppliesToRescuedRuns() {
        let grav = stillGravity(start: at(11), durationS: 2 * 3_600)                 // 11:00–13:00
            + restlessGravity(start: at(13), durationS: 2 * 3_600)                   // 13:00–15:00
            + stillGravity(start: at(15), durationS: 2 * 3_600)                      // 15:00–17:00
        let hr = hrStream(start: at(10), durationS: 8 * 3_600, bpm: 60)              // flat, no dip

        let on = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: true)
        XCTAssertEqual(on.count, 0, "no resting-HR dip: the daytime guard must reject the rescue")
    }

    /// Default-off byte-identity: omitting the flag and passing `false` produce the identical result.
    func testDefaultOffIsByteIdentical() {
        let grav = stillGravity(start: at(23), durationS: 4 * 3_600)
            + restlessGravity(start: at(27), durationS: 16 * 60)
            + stillGravity(start: at(27, min: 16), durationS: 3 * 3_600 + 44 * 60)
        let hr = hrStream(start: at(23), durationS: 8 * 3_600, bpm: 52)
            + hrStream(start: at(31), durationS: 4 * 3_600, bpm: 75)

        let implicitDefault = SleepStager.detectSleep(hr: hr, gravity: grav)
        let explicitFalse = SleepStager.detectSleep(hr: hr, gravity: grav, hrFirstSleep: false)
        XCTAssertEqual(implicitDefault, explicitFalse)
    }

    // MARK: - Pure helpers

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

    func testHrRescueRespectsBandAndSampleFloor() {
        let p = SleepStager.Period(stage: "active", start: 0, end: 3_600)
        let inBand = (0..<3_600).map { HRSample(ts: $0, bpm: 52) }
        let rescued = SleepStager.hrRescueActiveRuns([p], hr: inBand, baseline: 52.0)
        XCTAssertEqual(rescued[0].stage, "sleep")

        let outOfBand = (0..<3_600).map { HRSample(ts: $0, bpm: 60) }
        let kept = SleepStager.hrRescueActiveRuns([p], hr: outOfBand, baseline: 52.0)
        XCTAssertEqual(kept[0].stage, "active", "median above baseline × 1.05 must not rescue")

        // Below the hrRefineMinSamples floor: too little cardiac evidence to overrule motion.
        let sparse = (0..<10).map { HRSample(ts: $0 * 60, bpm: 52) }
        let untouched = SleepStager.hrRescueActiveRuns([p], hr: sparse, baseline: 52.0)
        XCTAssertEqual(untouched[0].stage, "active")

        // No baseline at all: nothing to weigh HR against.
        let noBase = SleepStager.hrRescueActiveRuns([p], hr: inBand, baseline: nil)
        XCTAssertEqual(noBase[0].stage, "active")
    }
}
