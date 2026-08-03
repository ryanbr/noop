import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStagerTests: XCTestCase {

    // MARK: - Cole–Kripke

    func testColeKripkeAllStillIsSleep() {
        // Zero activity → SI = 0 < 1 for every epoch → all sleep.
        let flags = SleepStager.coleKripke([Double](repeating: 0, count: 20))
        XCTAssertTrue(flags.allSatisfy { $0 })
    }

    func testColeKripkeHighActivityIsWake() {
        // A large clipped count at the center weight (230) → SI ≥ 1 → wake.
        // rescaled count of 300 (the clip) at A0: 0.001 * 230 * 300 = 69 ≥ 1.
        var counts = [Double](repeating: 0, count: 9)
        counts[4] = 300
        let flags = SleepStager.coleKripke(counts)
        XCTAssertFalse(flags[4])  // center epoch is wake
    }

    func testRescaleCountsDivideAndClip() {
        XCTAssertEqual(SleepStager.rescaleCounts([200]), [2.0])
        XCTAssertEqual(SleepStager.rescaleCounts([50000]), [300.0])  // clipped
    }

    // MARK: - Gravity stillness spine

    /// Build a still gravity stream (constant orientation) at 1 Hz.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// Build an active gravity stream (oscillating) at 1 Hz.
    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let phase = Double(i % 2) * 0.5  // 0.5 g jumps per sample → clearly moving
            return GravitySample(ts: start + i, x: phase, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// Unix start at `hourUTC:00:00` on a fixed reference day. With the detector's default
    /// tzOffset=0, local hour == UTC hour, so this lets a test place a window's center in or
    /// out of the daytime band [11,20) deterministically.
    private func startAtHour(_ hourUTC: Int) -> Int {
        // 2026-06-10 00:00:00 UTC (an arbitrary fixed midnight) + hourUTC hours.
        let refMidnight = 1_749_513_600
        return refMidnight + hourUTC * 3_600
    }
    /// Window anchored at a clear NIGHT hour (center stays out of [11,20) for short windows).
    private func nightStart(_ hourUTC: Int) -> Int { startAtHour(hourUTC) }
    /// Window anchored at a DAYTIME hour (center lands in [11,20) for the durations tested).
    private func daytimeStart(_ hourUTC: Int) -> Int { startAtHour(hourUTC) }

    func testDetectSleepFindsStillNight() {
        // 90 min still + low HR (50 bpm) → one sleep session.
        // Anchored at 02:00 UTC (center 02:45) so the window is OVERNIGHT at the default
        // tzOffset=0 and never trips the daytime false-sleep guard (#90) — a plain still
        // night must always register regardless of the guard.
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.start, start)
        XCTAssertGreaterThan(s.efficiency, 0.5)
        XCTAssertEqual(s.restingHR, 50)
    }

    func testDetectSleepRejectsShortBout() {
        // Only 30 min still — below MIN_SLEEP_MIN (60) → no session.
        let start = 2_000_000
        let grav = stillGravity(start: start, durationS: 30 * 60)
        let hr = hrStream(start: start, durationS: 30 * 60, bpm: 50)
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, gravity: grav).isEmpty)
    }

    func testDetectSleepEmptyGravity() {
        XCTAssertTrue(SleepStager.detectSleep(gravity: []).isEmpty)
    }

    func testDetectSleepHRConfirmationRejectsHighHR() {
        // Still gravity but HR is well above the day median*1.05. The daytime is
        // long (4 h) and low-HR (55) so the day median stays ~55; the still 90-min
        // "night" runs at 120 bpm, which exceeds 55*1.05 → the run is HR-rejected.
        let start = 3_000_000
        let sleepDur = 90 * 60
        let dayDur = 4 * 60 * 60
        let dayGrav = activeGravity(start: start, durationS: dayDur)
        let dayHR = hrStream(start: start, durationS: dayDur, bpm: 55)
        let nightGrav = stillGravity(start: start + dayDur, durationS: sleepDur)
        let nightHR = hrStream(start: start + dayDur, durationS: sleepDur, bpm: 120)
        let sessions = SleepStager.detectSleep(hr: dayHR + nightHR, gravity: dayGrav + nightGrav)
        // The still run's mean HR (120) >> median(55)*1.05 → rejected.
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Daytime false-sleep guard (#90)

    /// A 70-min still, LOW-HR daytime window is rejected: even though its HR dips, it is
    /// shorter than the daytime minimum (90 min), so it's the dominant false-positive a
    /// sedentary daytime stretch produces. The preceding active block lifts the day HR
    /// baseline so the HR test would otherwise PASS — proving the rejection is the duration
    /// gate, not the HR gate.
    func testDaytimeShortLowHRWindowRejected() {
        let dayStart = daytimeStart(10)           // 10:00 active context
        let dayDur = 3 * 60 * 60                   // 3 h awake, moving, HR 72
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let napStart = dayStart + dayDur           // 13:00, center 13:35 → daytime band
        let napDur = 70 * 60                        // 70 min < 90 min daytime minimum
        let napGrav = stillGravity(start: napStart, durationS: napDur)
        let napHR = hrStream(start: napStart, durationS: napDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + napHR, gravity: dayGrav + napGrav)
        XCTAssertTrue(sessions.isEmpty, "a 70-min daytime still window must be rejected by the guard")
    }

    /// A 120-min still, genuine-dip daytime nap STILL registers: ≥ 90 min AND its resting HR
    /// (50) sits clearly below the day HR baseline (~72), the cardiac signature of a real nap.
    /// The guard must not suppress legitimate daytime sleep.
    func testDaytimeQualityNapRegisters() {
        let dayStart = daytimeStart(10)            // 10:00 active context, HR 72
        let dayDur = 3 * 60 * 60
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let napStart = dayStart + dayDur            // 13:00, center 14:00 → daytime band
        let napDur = 120 * 60                        // 120 min ≥ 90 min daytime minimum
        let napGrav = stillGravity(start: napStart, durationS: napDur)
        let napHR = hrStream(start: napStart, durationS: napDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + napHR, gravity: dayGrav + napGrav)
        XCTAssertEqual(sessions.count, 1, "a 120-min daytime nap with a real HR dip must register")
        // The run begins at/just after the active→still transition (the rolling stillness window
        // shifts the boundary by a few minutes), and its center is firmly in the daytime band.
        XCTAssertGreaterThanOrEqual(sessions[0].start, napStart)
        XCTAssertLessThan(sessions[0].start, napStart + 10 * 60)
        XCTAssertEqual(sessions[0].restingHR, 50)
    }

    /// REGRESSION (late wake): a real overnight sleep whose TAIL runs past the daytime-band
    /// start — here a brief 40-min morning stir then back to sleep until ~12:40 — must keep the
    /// LATE wake time. The tail is daytime-centered and, on its own, fails the daytime guard's
    /// resting-HR bar (its HR sits at baseline, not below it), so before the continuation
    /// exemption it was rejected and the wake was truncated to ~10:00 ("woke at noon" bug).
    /// Because the tail directly continues a chain that began overnight (gap ≤ 90 min), it is
    /// kept — the night's wake reaches ~12:40, not late morning.
    /// Reimplemented from @vulnix0x4's PR #353.
    func testOvernightSleepTailPastNoonKeepsLateWake() {
        let nStart = nightStart(02)                 // 02:00 overnight onset
        let nDur = 8 * 60 * 60                       // → 10:00
        let wStart = nStart + nDur                  // 10:00 brief morning wake
        let wDur = 40 * 60                          // 40 min: > mergeMin (15), ≤ continuation (90)
        let tStart = wStart + wDur                  // 10:40 back to sleep
        let tDur = 2 * 60 * 60                       // → 12:40; center ~11:40 in the daytime band

        // Tail HR == night HR == baseline (50): passes the basic HR confirmation (≤ baseline×1.05)
        // but FAILS the stricter daytime resting bar (> baseline×0.95), so only the overnight
        // continuation exemption can keep it.
        let grav = stillGravity(start: nStart, durationS: nDur)
                 + activeGravity(start: wStart, durationS: wDur)
                 + stillGravity(start: tStart, durationS: tDur)
        let hr = hrStream(start: nStart, durationS: nDur, bpm: 50)
               + hrStream(start: wStart, durationS: wDur, bpm: 70)
               + hrStream(start: tStart, durationS: tDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        let latestWake = sessions.map(\.end).max() ?? 0
        XCTAssertGreaterThanOrEqual(
            latestWake, tStart + tDur - 10 * 60,
            "overnight sleep's post-11:00 tail must be kept — wake not truncated to late morning")
    }

    /// A 70-min still, low-HR OVERNIGHT window registers unchanged: its center (≈03:35) is
    /// outside the daytime band, so the guard never applies and only the base 60-min minimum
    /// gates it. This pins that the guard leaves overnight detection exactly as it was.
    func testOvernightShortWindowUnchanged() {
        let dayStart = nightStart(00)               // 00:00 active context so a baseline exists
        let dayDur = 3 * 60 * 60                     // moving, HR 72
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        let sleepStartTs = dayStart + dayDur         // 03:00, center 03:35 → overnight
        let sleepDur = 70 * 60                         // 70 min > 60 min base minimum
        let sleepGrav = stillGravity(start: sleepStartTs, durationS: sleepDur)
        let sleepHR = hrStream(start: sleepStartTs, durationS: sleepDur, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + sleepHR, gravity: dayGrav + sleepGrav)
        XCTAssertEqual(sessions.count, 1, "a 70-min overnight still window must register unchanged")
        // Begins at/just after the active→still transition; center stays out of the daytime band.
        XCTAssertGreaterThanOrEqual(sessions[0].start, sleepStartTs)
        XCTAssertLessThan(sessions[0].start, sleepStartTs + 10 * 60)
    }

    /// The guard is offset-aware: the SAME absolute window that is overnight at tzOffset=0
    /// becomes daytime under a +10 h offset and is then held to the stricter bar. With no
    /// preceding awake block there is no HR baseline, so the daytime path rejects it (it can't
    /// confirm a real dip) — while at offset 0 the identical 70-min still window registers.
    func testTzOffsetShiftsWindowIntoDaytimeBand() {
        let start = nightStart(02)                   // 02:00 UTC, center 02:35
        let dur = 70 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)

        // offset 0: overnight → registers.
        XCTAssertEqual(SleepStager.detectSleep(hr: hr, gravity: grav).count, 1)
        // +10 h: local center ≈ 12:35 → daytime band → stricter bar; no awake baseline → rejected.
        let shifted = SleepStager.detectSleep(hr: hr, gravity: grav, tzOffsetSeconds: 10 * 3_600)
        XCTAssertTrue(shifted.isEmpty, "a +10h offset pushes the window into the daytime band → rejected")
    }

    /// Guards against the index-out-of-range crash class from the prior attempt: no candidate
    /// at all (single still day, no HR) must return [] cleanly, not trap on empty median /
    /// first/last accesses inside the daytime path.
    func testDaytimeGuardEmptyInputsNoCrash() {
        // A still daytime stretch with NO HR at all → baseline nil → daytime path returns false
        // without touching any HR array; must not crash and must yield no sessions.
        let start = daytimeStart(13)
        let grav = stillGravity(start: start, durationS: 120 * 60)
        XCTAssertTrue(SleepStager.detectSleep(gravity: grav).isEmpty)
        // And the pure band/guard helpers tolerate a degenerate zero-length period.
        let p = SleepStager.Period(stage: "sleep", start: start, end: start)
        _ = SleepStager.isDaytimeCenter(p, tzOffsetSeconds: 0)
        XCTAssertFalse(SleepStager.passesDaytimeGuard(p, restingHR: nil, baseline: nil))
    }

    // MARK: - Off-wrist backstop (#500)

    /// A long, still DAYTIME stretch where the HR stream has a >20-min contiguous gap (the strap was
    /// off the wrist, so it banked no HR there) must NOT be classified as sleep. Before the off-wrist
    /// backstop the gravity spine read the stillness as sleep and the daytime guard let it through as
    /// "missing data" (nil restingHR) → a phantom daytime sleep. Here the dip-confirming HR before the
    /// gap would even satisfy the daytime guard's resting-HR bar, so ONLY the HR-gap backstop rejects it.
    func testOffWristDaytimeGapNotSleep() {
        let dayStart = daytimeStart(10)             // 10:00 active context, HR 72 (lifts the baseline)
        let dayDur = 2 * 60 * 60
        let dayGrav = activeGravity(start: dayStart, durationS: dayDur)
        let dayHR = hrStream(start: dayStart, durationS: dayDur, bpm: 72)

        // 12:00 the strap goes still on a desk for 2 h (≥90-min daytime minimum, center in [11,20)).
        let offStart = dayStart + dayDur
        let offDur = 2 * 60 * 60
        let offGrav = stillGravity(start: offStart, durationS: offDur)
        // HR covers only the FIRST 20 min at a low 50 bpm (a real dip that would pass the daytime
        // guard), then NOTHING for the rest — a >20-min contiguous off-wrist gap.
        let offHR = hrStream(start: offStart, durationS: 20 * 60, bpm: 50)

        let sessions = SleepStager.detectSleep(hr: dayHR + offHR, gravity: dayGrav + offGrav)
        XCTAssertTrue(sessions.isEmpty,
                      "a still daytime stretch with a >20-min HR-coverage gap is off-wrist, not sleep")
    }

    /// The off-wrist backstop must NOT suppress a genuine worn night: dense 1 Hz HR has no gap, so the
    /// same 90-min still overnight window still registers as exactly one session.
    func testWornNightWithDenseHRStillRegisters() {
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1, "a worn night with dense, gap-free HR must still register")
    }

    /// THE critical case j0b-dev's #504 designed (HR-gap path): a real overnight night whose detected
    /// still period over-extends into a SHORT off-wrist morning tail — the user takes the strap off
    /// shortly after waking, so the tail flatlines to no HR — is KEPT. The old binary guard dropped the
    /// WHOLE night on that one trailing gap; the fractional rule keeps it because the tail is < 50% of
    /// the period. Here: ~3.5 h worn (dense HR) + 30 min off-wrist tail (no HR) ⇒ ~12.5% off-wrist.
    func testRealNightWithShortOffWristTailIsKept_HRGapPath() {
        let start = nightStart(01)
        let wornDur = 210 * 60                 // 3.5 h worn, dense 1 Hz HR
        let tailDur = 30 * 60                  // 30 min off-wrist tail: still gravity, NO HR
        let grav = stillGravity(start: start, durationS: wornDur + tailDur)  // one continuous still run
        let hr = hrStream(start: start, durationS: wornDur, bpm: 50)         // HR stops at the wake
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1,
                       "a real night with a short (<50%) off-wrist morning tail must be KEPT, not dropped")
    }

    /// FRACTIONAL rule (#504), explicit-interval variant: a real night whose detected period over-extends
    /// into a short off-wrist tail covered by an explicit WRIST_OFF→WRIST_ON interval (HR is dense the
    /// whole window, e.g. a 5/MG still streaming PPG-HR) is KEPT — the interval covers < 50% of the run.
    func testRealNightWithShortOffWristTailIsKept_IntervalPath() {
        let start = nightStart(01)
        let dur = 240 * 60                     // 4 h, dense HR throughout
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        // Strap removed for the last 30 min (12.5% of the run) → tiny overlap, keep the night.
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav,
                                               wristOff: [(start: start + dur - 30 * 60, end: start + dur)])
        XCTAssertEqual(sessions.count, 1,
                       "a real night with a short (<50%) explicit off-wrist tail must be KEPT")
    }

    /// The explicit-interval path (#500), FRACTIONAL rule (#504): a WRIST_OFF→WRIST_ON interval that
    /// covers most of an otherwise-valid overnight window drops it, even though the HR here is dense
    /// and gap-free — its off-wrist coverage is ≥ maxOffWristSleepFraction.
    func testWristOffIntervalCoveringMostOfRunDropsIt() {
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        // No interval → registers (control); a near-full off-wrist interval (≥50%) → dropped.
        XCTAssertEqual(SleepStager.detectSleep(hr: hr, gravity: grav).count, 1)
        let dropped = SleepStager.detectSleep(hr: hr, gravity: grav,
                                              wristOff: [(start: start + 5 * 60, end: start + dur)])
        XCTAssertTrue(dropped.isEmpty, "a WRIST_OFF interval covering ≥50% of the run must drop it")
    }

    /// FRACTIONAL rule (#504): a single BRIEF WRIST_OFF blip (well under 50% of the run) must NOT drop a
    /// real, dense, worn night — the flaw the binary "any WRIST_OFF drops it" guard had. Here a 5-min
    /// off-wrist interval over a 90-min night is ~5.5% coverage, so the night is kept.
    func testBriefWristOffBlipKeepsWornNight() {
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let kept = SleepStager.detectSleep(hr: hr, gravity: grav,
                                           wristOff: [(start: start + 30 * 60, end: start + 35 * 60)])
        XCTAssertEqual(kept.count, 1, "a brief (<50%) WRIST_OFF blip must NOT drop a real worn night")
    }

    /// #507 — the off-wrist HR-gap proxy must NOT drop a real night that simply has SPARSE heart rate.
    /// A WHOOP 4.0's synced night is motion-reconstructed with thin, derived HR, so it's naturally full
    /// of >20-min HR gaps; the proxy would otherwise read it as ~100% off-wrist and drop a real night
    /// (the regression a 4.0 owner hit after upgrading). The density gate disables the proxy when the
    /// stream averages fewer than one sample per `hrDenseSpacingS`, so the fraction is 0 and it's kept —
    /// while explicit WRIST_OFF events remain authoritative regardless of HR density.
    func testSparseHRNightDisablesOffWristProxy_507() {
        let p = SleepStager.Period(stage: "sleep", start: 0, end: 5_400)   // 90-min night
        // HR every 25 min → 4 samples, gaps of 1500 s (≥ 20 min): under the OLD logic almost entirely
        // "off-wrist". Density = 4 samples over a 4500 s span < 4500/600 = 7 ⇒ proxy disabled.
        let sparse = [0, 1_500, 3_000, 4_500].map { HRSample(ts: $0, bpm: 52) }
        XCTAssertTrue(SleepStager.offWristHRGapSpans(p, hr: sparse).isEmpty,
                      "sparse HR (motion-reconstructed 4.0 night) must NOT register off-wrist gap spans")
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: sparse, wristOff: []), 0.0, accuracy: 1e-9,
                       "a sparse-HR real night must read 0% off-wrist, so it is never dropped (#507)")
        // An explicit WRIST_OFF interval still drops a genuinely off-wrist sparse night (events are
        // independent of the density gate): [0, 3000) over 5400 s = ~55% ≥ maxOffWristSleepFraction.
        XCTAssertGreaterThanOrEqual(
            SleepStager.offWristFraction(p, hr: sparse, wristOff: [(start: 0, end: 3_000)]), 0.5,
            "WRIST_OFF events remain authoritative regardless of HR density")
    }

    /// The fractional helpers are precise about the threshold, edges, and the union. `offWristHRGapSpans`
    /// returns the ≥20-min gaps as concrete spans; `offWristFraction` divides their union (with the
    /// wrist-off intervals) by duration; a run with NO HR at all leaves the gravity-only path alone.
    func testOffWristFractionAndGapSpans() {
        let p = SleepStager.Period(stage: "sleep", start: 0, end: 3_600)
        // Dense coverage → no gap span, zero fraction.
        let dense = (0...3_600).map { HRSample(ts: $0, bpm: 50) }
        XCTAssertTrue(SleepStager.offWristHRGapSpans(p, hr: dense).isEmpty)
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: dense, wristOff: []), 0.0, accuracy: 1e-9)
        // A single 21-min interior gap (≥ 20 min) → one span, fraction = 1260/3600.
        let gappy = (0...600).map { HRSample(ts: $0, bpm: 50) }
                  + (1_860...3_600).map { HRSample(ts: $0, bpm: 50) }   // gap 600→1860 = 1260 s ≥ 1200
        let spans = SleepStager.offWristHRGapSpans(p, hr: gappy)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, 600); XCTAssertEqual(spans[0].end, 1_860)
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: gappy, wristOff: []),
                       1_260.0 / 3_600.0, accuracy: 1e-9)
        // Union must not double-count: a wrist-off interval overlapping the gap doesn't inflate coverage.
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: gappy,
                                                    wristOff: [(start: 800, end: 1_500)]),
                       1_260.0 / 3_600.0, accuracy: 1e-9)
        // A disjoint wrist-off interval adds to coverage (union of 1260 s gap + 600 s event = 1860 s).
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: gappy,
                                                    wristOff: [(start: 2_400, end: 3_000)]),
                       1_860.0 / 3_600.0, accuracy: 1e-9)
        // No HR stream at all → no gap spans, zero fraction (can't assert off-wrist without HR).
        XCTAssertTrue(SleepStager.offWristHRGapSpans(p, hr: []).isEmpty)
        XCTAssertEqual(SleepStager.offWristFraction(p, hr: [], wristOff: []), 0.0, accuracy: 1e-9)
    }

    // MARK: - Staging output integrity

    func testStagesTileSessionExactly() {
        let start = 4_000_000
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let s = SleepStager.detectSleep(hr: hr, gravity: grav)[0]
        XCTAssertFalse(s.stages.isEmpty)
        // Segments must be contiguous and span exactly [start, end].
        XCTAssertEqual(s.stages.first!.start, s.start)
        XCTAssertEqual(s.stages.last!.end, s.end)
        for i in 0..<(s.stages.count - 1) {
            XCTAssertEqual(s.stages[i].end, s.stages[i + 1].start)
        }
        // Every stage label is one of the four valid classes.
        for seg in s.stages {
            XCTAssertTrue(["wake", "light", "deep", "rem"].contains(seg.stage))
        }
    }

    func testEfficiencyComputation() {
        // A 1000 s session with 100 s of wake → efficiency = 0.9.
        let stages = [
            StageSegment(start: 0, end: 100, stage: "wake"),
            StageSegment(start: 100, end: 1000, stage: "light"),
        ]
        let eff = SleepStager.efficiency(start: 0, end: 1000, stages: stages)
        XCTAssertEqual(eff, 0.9, accuracy: 1e-9)
    }

    // MARK: - Hypnogram metrics

    func testHypnogramMetricsAASM() {
        // SOL 60 s, then light 540 s, deep 300 s, wake 60 s (disturbance), rem 240 s.
        let stages = [
            StageSegment(start: 0, end: 60, stage: "wake"),       // pre-onset latency
            StageSegment(start: 60, end: 600, stage: "light"),    // 540 s
            StageSegment(start: 600, end: 900, stage: "deep"),    // 300 s
            StageSegment(start: 900, end: 960, stage: "wake"),    // WASO 60 s
            StageSegment(start: 960, end: 1200, stage: "rem"),    // 240 s
        ]
        let session = SleepSession(start: 0, end: 1200, efficiency: 0.95,
                                   stages: stages, restingHR: 50, avgHRV: 60)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.tibS, 1200, accuracy: 1e-9)
        XCTAssertEqual(m.tstS, 540 + 300 + 240, accuracy: 1e-9)  // 1080
        XCTAssertEqual(m.solS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.wasoS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.disturbances, 1)
        XCTAssertEqual(m.deepMin, 5.0, accuracy: 1e-9)
        XCTAssertEqual(m.remMin, 4.0, accuracy: 1e-9)
        XCTAssertEqual(m.lightMin, 9.0, accuracy: 1e-9)
        // Percentages sum to ~100.
        XCTAssertEqual(m.deepPct + m.remPct + m.lightPct, 100.0, accuracy: 1e-6)
    }

    func testHypnogramREMLatency() {
        let stages = [
            StageSegment(start: 0, end: 300, stage: "light"),   // onset at 0
            StageSegment(start: 300, end: 600, stage: "rem"),   // first REM at 300
        ]
        let session = SleepSession(start: 0, end: 600, efficiency: 1.0,
                                   stages: stages, restingHR: nil, avgHRV: nil)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.remLatencyS, 300, accuracy: 1e-9)
    }

    // MARK: - Respiration helper

    func testRespRateFromSyntheticBreathing() {
        // Synthesize a clean 0.25 Hz breathing wave (15 br/min) over 60 s at 1 Hz.
        let n = 60
        let resp = (0..<n).map { i -> Double in sin(2 * Double.pi * 0.25 * Double(i)) * 10 + 100 }
        let (rate, rrv) = SleepStager.respRateAndRRV(resp)
        XCTAssertFalse(rate.isNaN)
        XCTAssertEqual(rate, 15.0, accuracy: 2.0)  // ~15 breaths/min
        XCTAssertGreaterThanOrEqual(rrv, 0)
    }

    func testRespRateTooFewSamples() {
        let (rate, rrv) = SleepStager.respRateAndRRV([1, 2, 3])
        XCTAssertTrue(rate.isNaN)
        XCTAssertTrue(rrv.isNaN)
    }

    // #127 / #129: a depth-signature epoch (still, low HR, regular breathing) must be classed DEEP
    // even when per-epoch RMSSD is missing — sparse R-R (common on BLE-offloaded nights, esp. 5/MG)
    // used to hard-block deep, so those nights decoded 0 m of deep sleep. A MEASURABLE-but-low RMSSD
    // must still keep the epoch out of deep (the high-tone bar applies when we can measure it).
    private func depthEpoch(rmssd: Double) -> SleepStager.EpochFeatures {
        SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0,   // still
                                  ckSleep: true, hr: 50, hrVar: 0, rmssd: rmssd, sdnn: 0,
                                  // No respiration reading: `RespEvidence.unmeasured`, which is WAIVED for
                                  // deep (not asserted as "regular" — see SleepStagerRespEvidenceTests).
                                  respRate: 14, rrv: .nan,
                                  clock: 0.5)
    }

    func testMissingRmssdNoLongerBlocksDeep() {
        // hrLo=55 (so hr=50 is "low"), rmssdHi=50, no cardiac activation.
        let withMissingRmssd = SleepStager.classifyOne(depthEpoch(rmssd: .nan),
            hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5)
        XCTAssertEqual(withMissingRmssd, "deep", "a missing per-epoch RMSSD must not block deep")

        let withLowRmssd = SleepStager.classifyOne(depthEpoch(rmssd: 10),
            hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5)
        XCTAssertNotEqual(withLowRmssd, "deep", "a measurable-but-low RMSSD epoch must still clear the high-tone bar")
    }

    // #705: a still, low-HR sleep epoch with INFLATED HR-variance (hrVar ≥ the high bar) but a normal HR
    // (below hrHigh) and a touch of movement used to be flipped to WAKE on a WHOOP 5/MG night, because the
    // PPG-derived HR makes per-epoch hrVar noisy and the WAKE rule trusted hrvarHigh as cardiac activation.
    // On a sparse/PPG night the WAKE rule must vet the cardiac half by HR only (down-weight hrVar), so the
    // epoch stays sleep. A dense 4.0 night (cardiacSparse:false) keeps the original hrHigh||hrvarHigh signal.
    private func ppgWakeEpoch() -> SleepStager.EpochFeatures {
        // moveFrac just over the wake bar (0.15), HR normal (60, below hrHi=90, above hrLo=55 so not deep),
        // hrVar inflated above the high bar, missing R-R (sparse → resp also NaN → unmeasured/waived).
        SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0.16,
                                  ckSleep: true, hr: 60, hrVar: 200, rmssd: .nan, sdnn: 0,
                                  respRate: 14, rrv: .nan, clock: 0.5)
    }

    func testSparseCardiacDoesNotPromoteStillSleepToWakeOnHrVarAlone_705() {
        // Dense path: hrvarHigh alone clears the WAKE cardiac bar → this epoch reads wake (old behaviour).
        let dense = SleepStager.classifyOne(ppgWakeEpoch(),
            hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5,
            cardiacSparse: false)
        XCTAssertEqual(dense, "wake", "dense 4.0 night keeps the full hrHigh||hrvarHigh wake signal")

        // Sparse/PPG path: the noisy hrVar is down-weighted for the wake promotion → no longer wake.
        let sparse = SleepStager.classifyOne(ppgWakeEpoch(),
            hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 100, rrvHi: 1, rrvLo: 0.5,
            cardiacSparse: true)
        XCTAssertNotEqual(sparse, "wake", "a sparse/PPG night must not flip still low-HR sleep to wake on hrVar alone")
    }

    func testCardiacSparseFlagFiresOnMostlyMissingRmssd_705() {
        // A night where >= half the sleep epochs carry no finite RMSSD is PPG-derived / sparse-cardiac.
        let withRR = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true,
            hr: 55, hrVar: 0, rmssd: 40, sdnn: 0, respRate: 14, rrv: .nan, clock: 0.5)
        let noRR = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true,
            hr: 55, hrVar: 0, rmssd: .nan, sdnn: 0, respRate: 14, rrv: .nan, clock: 0.5)
        XCTAssertTrue(SleepStager.isCardiacSparse([noRR, noRR, noRR, withRR]),
            "3/4 epochs missing R-R is sparse-cardiac")
        XCTAssertFalse(SleepStager.isCardiacSparse([withRR, withRR, withRR, noRR]),
            "1/4 epochs missing R-R is a dense (4.0-style) night")
        XCTAssertFalse(SleepStager.isCardiacSparse([]), "empty session is not sparse")
    }

    // #705 (golden): a still PPG night used to score mostly WAKE because the noisy PPG-derived hrVar
    // tripped the high hrVar bar on still, low-HR sleep epochs and the WAKE rule treated that as cardiac
    // activation. We classify a batch of such epochs with FIXED session bars (deterministic — same shape
    // as the #127 tests) under both rules. On the dense rule the over-wake reproduces; with the
    // sparse-cardiac gate the WAKE share collapses while the elevated-HR awakenings still read wake.
    func testStillPpgNightNoLongerScoresMostlyWake_705() {
        // Fixed bars: hrLo=48, hrHi=70, hrvarHi=120. A still, low-HR (52) epoch with a touch of motion
        // (0.16) and inflated hrVar (200) — no finite R-R/resp. 9/10 such, 1/10 a real HR-elevated wake.
        func epoch(hr: Double, hrVar: Double) -> SleepStager.EpochFeatures {
            SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0.16,
                                      ckSleep: true, hr: hr, hrVar: hrVar, rmssd: .nan, sdnn: 0,
                                      respRate: 14, rrv: .nan, clock: 0.5)
        }
        let night: [SleepStager.EpochFeatures] = (0..<40).map { i in
            (i % 10 == 9) ? epoch(hr: 80, hrVar: 200)   // genuine elevated-HR awakening
                          : epoch(hr: 52, hrVar: 200)   // still, low-HR sleep with noisy PPG hrVar
        }
        let bars = (hrLo: 48.0, hrHi: 70.0, rmssdHi: 50.0, hrvarHi: 120.0, rrvHi: 1.0, rrvLo: 0.5)

        func wakeShare(cardiacSparse: Bool) -> Double {
            let labels = night.map {
                SleepStager.classifyOne($0, hrLo: bars.hrLo, hrHi: bars.hrHi, rmssdHi: bars.rmssdHi,
                                        hrvarHi: bars.hrvarHi, rrvHi: bars.rrvHi, rrvLo: bars.rrvLo,
                                        cardiacSparse: cardiacSparse)
            }
            return Double(labels.filter { $0 == "wake" }.count) / Double(labels.count)
        }

        // Dense rule reproduces the bug: almost the whole night reads wake (hrvarHigh alone promotes).
        XCTAssertGreaterThan(wakeShare(cardiacSparse: false), 0.80,
            "dense rule still over-reports wake on a noisy-hrVar night (reproduces #705)")
        // Sparse-cardiac gate: only the real HR-elevated awakenings stay wake (~10%).
        XCTAssertLessThan(wakeShare(cardiacSparse: true), 0.40,
            "a still PPG night must not be classified as mostly wake (was 40%+ before #705)")
    }

    // #127 (follow-up): the "deep is front-loaded" re-imposition zeroed deep entirely on nights whose
    // whole deep block lands after the first third (clock > 1/3). It must only re-impose late "deep" to
    // light when there's deep in the first third to anchor it; otherwise keep the best estimate.
    private func clockEpoch(_ clock: Double) -> SleepStager.EpochFeatures {
        SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true,
                                  hr: 50, hrVar: 0, rmssd: 60, sdnn: 0, respRate: 14, rrv: .nan, clock: clock)
    }

    func testDeepReimpositionKeepsLateDeepWhenNoEarlyDeep() {
        let labels = ["deep", "deep", "deep", "deep"]
        // Early deep present (clock 0.2): the later deep (> 1/3) is re-imposed to light.
        let withEarly = SleepStager.reimposePhysiology(labels,
            features: [clockEpoch(0.2), clockEpoch(0.5), clockEpoch(0.7), clockEpoch(0.9)],
            onsetIdx: 0, finalWakeIdx: 3)
        XCTAssertEqual(withEarly, ["deep", "light", "light", "light"])
        // No early deep (all clocks > 1/3): the late deep is KEPT rather than zeroed to 0 m. (#127)
        let allLate = SleepStager.reimposePhysiology(labels,
            features: [clockEpoch(0.5), clockEpoch(0.6), clockEpoch(0.7), clockEpoch(0.9)],
            onsetIdx: 0, finalWakeIdx: 3)
        XCTAssertEqual(allLate, ["deep", "deep", "deep", "deep"])
    }

    // MARK: - Fragment merge / hypnogram smoothing (#274)

    /// Expand a [(stage, epochs)] run-list into a flat per-epoch label array.
    private func expand(_ runs: [(String, Int)]) -> [String] {
        var out: [String] = []
        for (s, n) in runs { out.append(contentsOf: repeatElement(s, count: n)) }
        return out
    }
    /// Collapse a flat label array back into [(stage, epochs)] runs for terse assertions.
    private func runs(_ labels: [String]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for s in labels {
            if let last = out.last, last.0 == s { out[out.count - 1].1 += 1 }
            else { out.append((s, 1)) }
        }
        return out
    }
    private func assertRuns(_ labels: [String], _ expected: [(String, Int)],
                            _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let got = runs(labels)
        XCTAssertEqual(got.count, expected.count, "\(msg) run count — got \(got)", file: file, line: line)
        for i in 0..<min(got.count, expected.count) {
            XCTAssertEqual(got[i].0, expected[i].0, "\(msg) run \(i) stage", file: file, line: line)
            XCTAssertEqual(got[i].1, expected[i].1, "\(msg) run \(i) len", file: file, line: line)
        }
    }

    func testMergeFragmentsAbsorbsSameStageBridge() {
        // A 2-epoch "deep" fleck (< 6-epoch threshold) bridged by light on both sides is
        // absorbed: the choppy light→deep→light blip becomes one continuous light block.
        let input = expand([("light", 8), ("deep", 2), ("light", 8)])
        let out = SleepStager.mergeFragments(input)
        XCTAssertEqual(out.count, input.count, "length preserved")
        assertRuns(out, [("light", 18)], "same-stage bridge")
    }

    func testMergeFragmentsPreservesGenuineTransition() {
        // Three real multi-minute blocks (each ≥ 6 epochs = 3 min) — a genuine cycle, not
        // noise — pass through completely untouched.
        let input = expand([("light", 10), ("deep", 10), ("rem", 10)])
        let out = SleepStager.mergeFragments(input)
        assertRuns(out, [("light", 10), ("deep", 10), ("rem", 10)], "genuine transition")
    }

    func testMergeFragmentsBiasesLighterOnTie() {
        // A 3-epoch "deep" fleck between equal-length light and rem neighbours (8 vs 8) is a
        // tie; the lighter stage (light, rank 1 < rem rank 2) wins so smoothing never inflates
        // deep/REM. The deep fleck must NOT survive and must NOT become rem.
        let input = expand([("light", 8), ("deep", 3), ("rem", 8)])
        let out = SleepStager.mergeFragments(input)
        assertRuns(out, [("light", 11), ("rem", 8)], "tie → lighter neighbour")
        XCTAssertFalse(out.contains("deep"), "a stray deep fleck must not survive a tie merge")
    }

    func testMergeFragmentsFoldsIntoLongerNeighbour() {
        // A short rem fleck (2) with a longer light neighbour (8) on one side and a short deep
        // run (4, itself sub-threshold) on the other collapses entirely into light — the longer
        // neighbour dominates and the trailing short deep folds back too. No deep/REM inflation.
        let input = expand([("light", 8), ("rem", 2), ("deep", 4)])
        let out = SleepStager.mergeFragments(input)
        assertRuns(out, [("light", 14)], "fold into longer neighbour")
    }

    func testMergeFragmentsLeadingAndTrailingFlecks() {
        // A leading deep fleck folds forward into light; a trailing rem fleck folds back into
        // light. Edge runs with only one neighbour are still smoothed.
        let input = expand([("deep", 2), ("light", 10), ("rem", 2)])
        let out = SleepStager.mergeFragments(input)
        assertRuns(out, [("light", 14)], "leading + trailing flecks")
    }

    func testMergeFragmentsThresholdConstant() {
        // The threshold is the named 3-min constant, i.e. 6 epochs at 30 s.
        XCTAssertEqual(SleepStager.fragmentMergeEpochs, 6)
        // A run exactly AT the threshold (6 epochs) is a real transition and is preserved.
        let input = expand([("light", 10), ("deep", 6), ("light", 10)])
        let out = SleepStager.mergeFragments(input)
        assertRuns(out, [("light", 10), ("deep", 6), ("light", 10)], "at-threshold run kept")
    }

    func testMergeFragmentsDegenerateInputs() {
        // Empty and single-run inputs pass through unchanged (nothing to merge into).
        XCTAssertTrue(SleepStager.mergeFragments([]).isEmpty)
        let single = expand([("light", 3)])  // sub-threshold but no neighbours
        assertRuns(SleepStager.mergeFragments(single), [("light", 3)], "single run kept")
    }

    // MARK: - Sparse-gravity robustness (#308)

    /// Still gravity sampled sparsely — one sample every `everyS` seconds (constant orientation,
    /// so every inter-sample delta is 0 → "still"). Reproduces the WHOOP 5.0 v18/v26 backfill where
    /// gravity is clumped/sparse, leaving multiple >maxGapMin gaps across the night.
    private func sparseStillGravity(start: Int, durationS: Int, everyS: Int) -> [GravitySample] {
        stride(from: 0, to: durationS, by: everyS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    func testSparseGravityNightNotShredded() {
        // A ~6 h overnight window: DENSE 1 Hz sleep-band HR (50 bpm) but SPARSE gravity — one still
        // sample every 25 min, so every inter-sample gap (1500 s) exceeds maxGapMin (1200 s). Before
        // #308 buildRuns broke the run at every gap and detectSleep dropped every <60-min fragment,
        // collapsing the night to ~0. Now the sparse path keeps it as ONE continuous ~6 h session.
        let start = nightStart(01)                  // 01:00, center stays overnight
        let dur = 6 * 60 * 60                        // 6 h
        let grav = sparseStillGravity(start: start, durationS: dur, everyS: 25 * 60)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)

        // The gate must classify this gravity as sparse (median gap 1500 s > 1200 s).
        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hr), "clumped gravity must read as sparse")

        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1, "a sparse-gravity night must be ONE session, not shredded")
        let s = sessions[0]
        // One ~6 h span (bounded by first/last gravity sample), not a sub-60-min fragment.
        XCTAssertGreaterThan(Double(s.end - s.start), 5.0 * 60 * 60,
                             "the bridged session must be ~6 h, not a sub-hour fragment")
        XCTAssertEqual(s.restingHR, 50)
    }

    func testDenseGravityNightUnchangedBySparsePath() {
        // Snapshot/regression guard for the 4.0 path: a DENSE 1 Hz still gravity night must NOT be
        // classified sparse, and must produce the SAME single stable session it did before #308 —
        // identical start, end and resting HR. Proves the sparse branches never touch the dense path.
        let start = nightStart(02)
        let dur = 6 * 60 * 60
        let grav = stillGravity(start: start, durationS: dur)    // dense 1 Hz
        let hr = hrStream(start: start, durationS: dur, bpm: 50)

        XCTAssertFalse(SleepStager.isGravitySparse(grav, hr: hr), "dense 1 Hz gravity must NOT read as sparse")

        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        // Stable bounds: dense gravity tiles the whole window, so the session is [start, last sample].
        XCTAssertEqual(s.start, start)
        XCTAssertEqual(s.end, start + dur - 1)   // last 1 Hz sample is at start+dur-1
        XCTAssertEqual(s.restingHR, 50)
    }

    // #345 END-TO-END: a locked synthetic WHOOP-4.0 OFFLOAD night — dense sleep-band HR but clumped/sparse
    // motion (~the reporter's ~20% coverage) — must flow REAL isGravitySparse → REAL ScoreConfidence.rest →
    // .building, EVEN when the night ALSO looks healthy (high efficiency + ~45% restorative). That healthy-
    // looking case is exactly what H9 misses, so without the sparse guard it would read a confident .solid
    // 85–100 — the #319 signature. The guard validated against a realistic synthetic offload night, since no
    // real offload capture exists yet.
    func testSparseOffloadNightForcesRestBuildingEndToEnd() {
        let start = nightStart(01)
        let dur = 6 * 60 * 60
        let grav = sparseStillGravity(start: start, durationS: dur, everyS: 25 * 60)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sparse = SleepStager.isGravitySparse(grav, hr: hr)
        XCTAssertTrue(sparse, "the locked synthetic 4.0-offload night must read sparse")
        let asleep = 8.0 * 3600.0
        XCTAssertEqual(
            ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                 asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
                                 efficiency: 0.95, gravitySparse: sparse),
            .building,
            "a sparse night — even high-efficiency AND healthy restorative (the #319 case H9 misses) — must not earn SOLID")
    }

    func testDenseNightKeepsRestSolidEndToEnd() {
        // The dense counterpart: same healthy night on DENSE 1 Hz motion → not sparse → .solid stands.
        let start = nightStart(02)
        let dur = 6 * 60 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sparse = SleepStager.isGravitySparse(grav, hr: hr)
        XCTAssertFalse(sparse, "the dense night must NOT read sparse")
        let asleep = 8.0 * 3600.0
        XCTAssertEqual(
            ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                 asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
                                 efficiency: 0.95, gravitySparse: sparse),
            .solid,
            "a dense healthy night keeps SOLID — the sparse guard never touches it")
    }

    func testBuildRunsDenseGravityByteIdenticalToLegacy() {
        // Direct byte-identity proof: buildRuns with the sparse override OFF (the default) returns
        // exactly the same runs as passing sparse:false, on a gravity stream with a real >maxGapMin
        // gap. The legacy two-arg call and the sparse=false call must be indistinguishable.
        let start = 5_000_000
        // Two still blocks separated by a 30-min (>20 min) gap → legacy buildRuns splits them.
        let blockA = stillGravity(start: start, durationS: 40 * 60)
        let gapStart = start + 40 * 60 + 30 * 60
        let blockB = stillGravity(start: gapStart, durationS: 40 * 60)
        let grav = blockA + blockB
        let deltas = SleepStager.gravityDeltas(grav)
        let flags = SleepStager.classifyStill(grav, deltas)

        let legacy = SleepStager.buildRuns(grav, flags)                      // default sparse:false
        let explicit = SleepStager.buildRuns(grav, flags, sparse: false)
        XCTAssertEqual(legacy.count, explicit.count)
        for (a, b) in zip(legacy, explicit) {
            XCTAssertEqual(a.stage, b.stage); XCTAssertEqual(a.start, b.start); XCTAssertEqual(a.end, b.end)
        }
        // The dense >20-min gap still splits the night (a real wake), so there are ≥2 runs.
        XCTAssertGreaterThanOrEqual(legacy.count, 2, "a real >20-min gap must still split the dense path")
    }

    func testGravitySparseGateConditions() {
        // The gate trips on EITHER a short gravity span vs HR span OR any inter-sample gravity gap > maxGapMin.
        let start = 6_000_000
        let hr = hrStream(start: start, durationS: 6 * 60 * 60, bpm: 50)

        // (a) Span test: gravity confined to the first 30 min of a 6 h HR window (< 0.5 frac).
        let clumped = stillGravity(start: start, durationS: 30 * 60)
        XCTAssertTrue(SleepStager.isGravitySparse(clumped, hr: hr), "short gravity span → sparse")

        // (b) Large-gap test: gravity spans the night but every gap is 25 min (> maxGapMin).
        let bigGaps = sparseStillGravity(start: start, durationS: 6 * 60 * 60, everyS: 25 * 60)
        XCTAssertTrue(SleepStager.isGravitySparse(bigGaps, hr: hr), "a large inter-sample gap → sparse")

        // (c) Dense gravity over the same span is NOT sparse.
        let dense = stillGravity(start: start, durationS: 6 * 60 * 60)
        XCTAssertFalse(SleepStager.isGravitySparse(dense, hr: hr), "dense gravity → not sparse")

        // (d) Degenerate HR (<2 samples) keeps the dense path regardless of gravity.
        XCTAssertFalse(SleepStager.isGravitySparse(bigGaps, hr: []), "no HR span → keep dense path")

        // (e) #28: gravity SPANS the night (span gate stays dense) with a ~1 s MEDIAN gap (dense
        // bursts) but a single >maxGapMin dropout — the median test misses it, the max-gap test
        // catches it. Two 160-min blocks split by a 40-min dropout cover the whole 6 h HR window.
        let clumpedBigGap = stillGravity(start: start, durationS: 160 * 60)
            + stillGravity(start: start + (160 + 40) * 60, durationS: 160 * 60)
        XCTAssertTrue(SleepStager.isGravitySparse(clumpedBigGap, hr: hr),
                      "clumped gravity + one long dropout (small median, large max) → sparse")
    }

    func testClumpedGravityWithLongDropoutBridged_28() {
        // #28: WHOOP 4.0 motion arrives CLUMPED — two dense 40-min still blocks split by a 30-min
        // dropout, the gravity spanning the whole HR window. The block-internal gaps are ~1 s so the
        // MEDIAN gate stays dense and the span gate doesn't fire; only the new max-gap arm catches the
        // dropout. With sleep-band HR across the gap the night is bridged into ONE session instead of
        // two dropped sub-minSleepMin fragments (~0 sleep) under the old median-only gate.
        let start = nightStart(02)
        let block = 40 * 60
        let gap = 30 * 60
        let grav = stillGravity(start: start, durationS: block)
            + stillGravity(start: start + block + gap, durationS: block)
        let dur = 2 * block + gap                       // HR spans the whole window
        let hr = hrStream(start: start, durationS: dur, bpm: 50)

        XCTAssertTrue(SleepStager.isGravitySparse(grav, hr: hr),
                      "clumped motion with a long dropout (small median, large max gap) must read as sparse")
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1,
                       "the dropout must be bridged into ONE session — not dropped sub-60-min fragments")
        XCTAssertGreaterThan(Double(sessions[0].end - sessions[0].start), Double(2 * block),
                             "the bridged session must span both blocks across the dropout")
    }

    func testSessionAvgHRVRejectsEctopicSpikes() {
        // A 5-min window of steady ~900 ms beats (≈67 bpm) with a +600 ms ectopic
        // spike every 15th beat — the shape of PPG-derived 0x2A37 RR on a WHOOP 5/MG.
        // rMSSD is built from SUCCESSIVE differences, so the spikes would inflate the
        // session HRV if left in. cleanRR's Malik ectopic rejection drops them, so the
        // cleaned series is steady → HRV ≈ 0. Pre-fix (rangeFilter only) this path
        // returned ~200 ms; this guards the #262/#235 fix against regression.
        var rr: [RRInterval] = []
        let start = 1000, end = start + 300
        for i in 0..<300 {
            rr.append(RRInterval(ts: start + i, rrMs: (i % 15 == 0) ? 1500 : 900))
        }
        let hrv = SleepStager.sessionAvgHRV(start: start, end: end, rr: rr)
        XCTAssertNotNil(hrv)
        XCTAssertLessThan(hrv!, 50, "ectopic spikes must be rejected before rMSSD")
    }

    // MARK: - Helper robustness

    func testConvolveReflectShortInputDoesNotCrash() {
        // A signal far shorter than the kernel radius must not index out of bounds. The DoG sigma2
        // kernel has radius 60; a 3-sample signal would read x[60] without the length guard. (The
        // production caller is gated by the 60-min session floor, so this is defensive hardening.)
        let kernel = SleepStager.gaussianKernel(sigmaS: 600)   // radius 60
        let short = [1.0, 2.0, 3.0]
        XCTAssertEqual(SleepStager.convolveReflect(short, kernel), short,
                       "a signal shorter than the kernel radius returns unchanged instead of trapping")
    }

    func testFindPeaksTieBreakKeepsLowestIndex() {
        // Two equal-height peaks within `distance` of each other: the greedy min-distance
        // suppression must keep the LOWER index deterministically (matching the Android stable
        // sort), rather than relying on the stdlib sort's incidental tie order.
        let x = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0]   // equal peaks at indices 2 and 4
        XCTAssertEqual(SleepStager.findPeaks(x, distance: 5, height: 0.5), [2],
                       "equal-height peaks within distance keep the lowest index")
    }

    // MARK: - H4 physiological in-bed span cap (#547/#531/#509 tail)

    func testDetectSleepClampsOverlongBadClockBlock() {
        // A frozen-still 18 h "night" (a bad-clock artefact) exceeds the 16 h physiological cap → DROPPED,
        // so it can never report a 12 h+ sleep. Anchored at a night hour with low HR so ONLY the span cap
        // can reject it (the duration floor + HR confirmation both pass).
        let start = nightStart(22)
        let dur = 18 * 60 * 60                     // 18 h > maxMainSleepSpanS (16 h)
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, gravity: grav).isEmpty,
                      "an 18 h still block is a bad-clock artefact and is dropped by the span cap")
    }

    func testDetectSleepKeepsLongButPlausibleNight() {
        // A genuinely long but plausible night (just under the 16 h cap) is KEPT — the cap only drops the
        // clock-artefact range, never a real recovery/lie-in night.
        let start = nightStart(21)
        let dur = 15 * 60 * 60                     // 15 h ≤ cap
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        XCTAssertEqual(SleepStager.detectSleep(hr: hr, gravity: grav).count, 1,
                       "a 15 h night is below the cap and survives")
    }

    // MARK: - H7 morning-stillness nap suppression (#531) — pure guard

    /// A daytime Period helper (center lands in the [11,20) band at tzOffset 0).
    private func daytimePeriod(_ startHour: Int, durMin: Int) -> SleepStager.Period {
        let s = startAtHour(startHour)
        return SleepStager.Period(stage: "sleep", start: s, end: s + durMin * 60)
    }

    func testMorningStillnessRejectedNearOvernightWake() {
        // A 120-min daytime block at 09:00 that clears the ORDINARY daytime guard (resting 74 ≤ 0.95×80=76)
        // but NOT the stronger re-onset bar (74 > 0.90×80=72), beginning right after a 08:00 overnight wake,
        // is REJECTED as morning residual stillness.
        let p = daytimePeriod(9, durMin: 120)
        let wakeEnd = startAtHour(8)               // overnight chain woke at 08:00, ~1 h before p
        XCTAssertFalse(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 74, baseline: 80, morningWakeEnd: wakeEnd),
            "a still block right after the overnight wake with no clear re-onset dip is rejected")
    }

    func testMorningStillnessKeptOnStrongReonsetDip() {
        // Same morning window, but a clear cardiac dip (resting 70 ≤ 0.90×80=72) → a genuine second sleep
        // is KEPT.
        let p = daytimePeriod(9, durMin: 120)
        let wakeEnd = startAtHour(8)
        XCTAssertTrue(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 70, baseline: 78, morningWakeEnd: wakeEnd),
            "a clear re-onset HR dip keeps a genuine morning second sleep")
    }

    func testMorningStillnessGuardNoOpOutsideWindow() {
        // A nap hours later (no overnight wake nearby → morningWakeEnd nil) faces only the ordinary daytime
        // guard, unchanged.
        let p = daytimePeriod(14, durMin: 120)     // 14:00 afternoon nap
        XCTAssertTrue(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 70, baseline: 80, morningWakeEnd: nil),
            "outside the morning window the guard is the ordinary daytime bar")
    }

    func testMorningStillnessRescuedByBandSleepState() {
        // The strap's OWN banked band sleep_state reads predominantly "asleep" (2) over the block → the H7
        // guard KEEPS it even though the HR dip is borderline (74 > 0.90×80=72, would otherwise be rejected).
        // CONSUME path.
        let p = daytimePeriod(9, durMin: 120)
        let wakeEnd = startAtHour(8)
        // 80% of in-block samples are state 2 (asleep) ≥ the 0.6 fraction.
        var band: [(ts: Int, state: Int)] = []
        let n = 100
        for i in 0..<n { band.append((ts: p.start + i * 60, state: i < 80 ? 2 : 1)) }
        XCTAssertTrue(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 74, baseline: 80,
                                                    morningWakeEnd: wakeEnd, bandSleepState: band),
            "the strap's own 'asleep' band rescues a borderline-HR morning re-onset")
        // Without the band anchor the same borderline-HR block is rejected (74 > 0.90×80=72).
        XCTAssertFalse(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 74, baseline: 80, morningWakeEnd: wakeEnd))
    }

    func testBandStateConfirmsAsleepFractionGate() {
        let p = daytimePeriod(9, durMin: 60)
        // 50% asleep < 0.6 → NOT confirmed.
        var half: [(ts: Int, state: Int)] = []
        for i in 0..<100 { half.append((ts: p.start + i * 30, state: i < 50 ? 2 : 0)) }
        XCTAssertFalse(SleepStager.bandStateConfirmsAsleep(p, bandSleepState: half))
        // Empty band → never confirmed (no fabricated reading).
        XCTAssertFalse(SleepStager.bandStateConfirmsAsleep(p, bandSleepState: []))
    }

    // MARK: - H8 per-epoch motion (persisted beside stagesJSON)

    func testSessionEpochMotionGridsToStageEpochs() {
        // 90-min still night → ~180 thirty-second epochs of near-zero motion, on the same grid as staging.
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let motion = SleepStager.sessionEpochMotion(start: start, end: start + dur, grav: grav)
        // 90 min / 30 s = 180 epochs.
        XCTAssertEqual(motion.count, 180, "one motion value per 30 s epoch")
        XCTAssertTrue(motion.allSatisfy { $0 >= 0 }, "motion magnitudes are non-negative |Δgravity| sums")
        // A perfectly still stream has ~zero motion.
        XCTAssertEqual(motion.reduce(0, +), 0, accuracy: 1e-6)
    }

    func testSessionEpochMotionEmptyWhenNoGravity() {
        // Too little gravity to grid → [] so the caller persists NULL, never a fabricated zero series.
        XCTAssertTrue(SleepStager.sessionEpochMotion(start: 0, end: 1800, grav: []).isEmpty)
    }

    // MARK: - #175 per-session band sleep_state gridding (persisted beside stagesJSON)

    func testSessionEpochSleepStateGridsOnePerEpoch() {
        // 90-min session at 1 sample/30 s all "asleep" (2) → 180 epochs, all 2, on the same grid as staging.
        let start = 1_000_000
        let dur = 90 * 60
        var band: [(ts: Int, state: Int)] = []
        for i in 0..<(dur / 30) { band.append((ts: start + i * 30, state: 2)) }
        let states = SleepStager.sessionEpochSleepState(start: start, end: start + dur, sleepState: band)
        XCTAssertEqual(states.count, 180, "one band-state value per 30 s epoch (matches sessionEpochMotion)")
        XCTAssertTrue(states.allSatisfy { $0 == 2 }, "an all-asleep band grids to all-asleep epochs")
    }

    func testSessionEpochSleepStateCarriesForwardAndVerbatim() {
        // A sparse band that flips wake(0)→asleep(2)→up(3): each epoch takes the last in-window state and
        // carries it forward across empty epochs. state 0 is a REAL wake reading, carried verbatim.
        let start = 0
        let dur = 6 * 30                       // 6 epochs
        let band: [(ts: Int, state: Int)] = [
            (ts: 0, state: 0),                 // epoch 0 → 0 (wake)
            (ts: 75, state: 2),                // epoch 2 → 2 (asleep); epoch 1 carries 0 forward
            (ts: 160, state: 3),               // epoch 5 → 3 (up); epochs 3,4 carry 2 forward
        ]
        let states = SleepStager.sessionEpochSleepState(start: start, end: start + dur, sleepState: band)
        XCTAssertEqual(states, [0, 0, 2, 2, 2, 3], "last-in-epoch wins; empty epochs carry forward; 0 kept")
    }

    func testSessionEpochSleepStateEmptyWhenNoBandSamples() {
        // No band samples in the window → [] so the caller persists NULL (a WHOOP 4.0 / unbanded window),
        // never a fabricated array. This is what keeps the derived-only path intact for straps without it.
        XCTAssertTrue(SleepStager.sessionEpochSleepState(start: 0, end: 1800, sleepState: []).isEmpty)
        // Samples entirely outside the window are also ignored.
        let far: [(ts: Int, state: Int)] = [(ts: 9_000, state: 2)]
        XCTAssertTrue(SleepStager.sessionEpochSleepState(start: 0, end: 1800, sleepState: far).isEmpty)
    }

    func testSessionGridFeedsTheReonsetGuardEndToEnd() {
        // The FULL #175 consume chain, as a unit: an "asleep"-banded morning block grids to a per-session
        // state array (what IntelligenceEngine persists via persistSessionSleepState), which — expanded back
        // to (startTs + i·30, state) samples exactly as IntelligenceEngine.bandSleepStateSamples does — makes
        // the H7 re-onset CONFIRM guard KEEP a borderline-HR block it would otherwise reject. This is the
        // dormant guard the missing stream starved; it never overrides the derived stage, only confirms.
        let p = daytimePeriod(9, durMin: 120)         // 120-min morning block → 240 epochs (clears the 90-min bar)
        let wakeEnd = startAtHour(8)
        // The strap banked this block predominantly "asleep" (2).
        var band: [(ts: Int, state: Int)] = []
        for i in 0..<240 { band.append((ts: p.start + i * 30, state: 2)) }

        // 1) Grid it per session (the persist-ready array).
        let states = SleepStager.sessionEpochSleepState(start: p.start, end: p.end, sleepState: band)
        XCTAssertEqual(states.count, 240)
        XCTAssertTrue(states.allSatisfy { $0 == 2 })

        // 2) Expand back to timestamped samples the way the H7 read path does (startTs + i·epochS).
        let epochS = 30
        let reconstructed = states.enumerated().map { (ts: p.start + $0.offset * epochS, state: $0.element) }

        // 3) The guard now CONFIRMS the borderline-HR re-onset (74 > 0.90×80=72 would otherwise reject).
        XCTAssertTrue(
            SleepStager.passesMorningStillnessGuard(p, restingHR: 74, baseline: 80,
                                                    morningWakeEnd: wakeEnd, bandSleepState: reconstructed),
            "the persisted+re-expanded band grid drives the H7 confirm end to end")
    }

    // MARK: - REM-funnel diagnostic (#688)

    /// A still, REM-eligible epoch (still + cardiac-activated + irregular resp). The percentile
    /// arguments below are chosen so this epoch clears every REM gate.
    private func remEpoch() -> SleepStager.EpochFeatures {
        SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0,  // still
                                  ckSleep: true, hr: 80, hrVar: 5, rmssd: 20, sdnn: 0,
                                  respRate: 14, rrv: 2.0, clock: 0.5)          // irregular resp
    }

    func testRemRejectReasonAttributesEachGate() {
        // Percentiles: hrLo=55, hrHi=70 (hr=80 is high), rmssdHi=50, hrvarHi=1 (hrVar=5 is high),
        // rrvHi=1 (rrv=2 is irregular), rrvLo=0.5. The base remEpoch clears all REM gates.
        let (hrLo, hrHi, rmssdHi, hrvarHi, rrvHi, rrvLo) =
            (55.0, 70.0, 50.0, 1.0, 1.0, 0.5)
        func reason(_ f: SleepStager.EpochFeatures) -> SleepStager.REMRejectReason {
            SleepStager.remRejectReason(f, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo)
        }
        XCTAssertEqual(reason(remEpoch()), .remEligible, "still + cardiac + irregular resp → REM")

        // notStill: raise moveFrac above the wake bar — but keep cardiac LOW so it doesn't win wake.
        // hr=60 (< hrHi 70, > hrLo 55) and hrVar=0 → not cardiac-activated, so NOT wake; rrv high but
        // not still → the REM rule fails first on stillness.
        let notStill = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0.5,
                                                 ckSleep: true, hr: 60, hrVar: 0, rmssd: 60, sdnn: 0,
                                                 respRate: 14, rrv: 2.0, clock: 0.5)
        XCTAssertEqual(reason(notStill), .notStill, "moving body (no cardiac) → blocked notStill")

        // noCardiacActivation: still, resp irregular, but HR mid + flat HR-variability.
        let noCardiac = SleepStager.EpochFeatures(
            index: 0, midTs: 0, count: 0, moveFrac: 0, ckSleep: true, hr: 60, hrVar: 0,
            rmssd: 20, sdnn: 0, respRate: 14, rrv: 2.0, clock: 0.5)
        XCTAssertEqual(reason(noCardiac), .noCardiacActivation, "still + irregular resp but no cardiac → blocked")

        // respRegular: still + cardiac-activated but resp present and REGULAR (rrv below rrvLo).
        // Keep RMSSD high so it doesn't win deep (deep needs hrLow too — hr=80 isn't low — so it's safe).
        let respReg = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0,
                                                ckSleep: true, hr: 80, hrVar: 5, rmssd: 20, sdnn: 0,
                                                respRate: 14, rrv: 0.1, clock: 0.5)  // rrv ≤ rrvLo → regular
        XCTAssertEqual(reason(respReg), .respRegular, "still + cardiac but regular resp → blocked respRegular")

        // noRespFallbackBar: resp ABSENT (rrv NaN) and the stricter no-resp REM bar unmet
        // (needs BOTH hrHigh AND hrvarHigh). Here hr high but hrVar flat → fallback bar fails.
        let noRespBar = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0,
                                                  ckSleep: true, hr: 80, hrVar: 0, rmssd: 20, sdnn: 0,
                                                  respRate: .nan, rrv: .nan, clock: 0.5)
        XCTAssertEqual(reason(noRespBar), .noRespFallbackBar, "resp absent + no-resp bar unmet → blocked")
    }

    func testRemRejectReasonNoRespFallbackIsRemEligible() {
        // The no-resp REM fallback: still + HR-high + HR-variability-high + resp absent → REM eligible.
        let f = SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: 0,
                                          ckSleep: true, hr: 80, hrVar: 5, rmssd: 20, sdnn: 0,
                                          respRate: .nan, rrv: .nan, clock: 0.5)
        let r = SleepStager.remRejectReason(f, hrLo: 55, hrHi: 70, rmssdHi: 50,
                                            hrvarHi: 1, rrvHi: 1, rrvLo: 0.5)
        XCTAssertEqual(r, .remEligible, "no-resp fallback (high HR + high HR-var) is REM-eligible")
    }

    func testRemFunnelDiagnosticNilWhenNoGravity() {
        XCTAssertNil(SleepStager.remFunnelDiagnostic(start: 0, end: 1800, grav: [],
                                                     hr: [], rr: [], resp: []))
    }

    func testRemFunnelDiagnosticZeroREMNightSurfacesRespAbsent() {
        // A WHOOP-4.0-style night: still body, low HR, NO respiration and NO R-R → the classifier
        // can never reach REM (the no-resp fallback needs cardiac activation, which a flat low-HR
        // still night lacks). The hypnogram is 0% REM; the diagnostic must say WHY: resp ABSENT, and
        // every sleep epoch attributed to a concrete non-REM reason. This is a triage surface only —
        // it asserts the diagnostic, NOT that the stager should have found REM.
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)   // flat, low → no cardiac activation
        let diag = SleepStager.remFunnelDiagnostic(start: start, end: start + dur,
                                                   grav: grav, hr: hr, rr: [], resp: [])
        XCTAssertNotNil(diag)
        let d = diag!
        XCTAssertTrue(d.isZeroREM, "a flat still low-HR no-resp night has 0% REM")
        XCTAssertEqual(d.remAfterReimpose, 0)
        XCTAssertFalse(d.respChannelPresent, "no resp and no R-R → respChannelPresent false")
        XCTAssertGreaterThan(d.sleepEpochs, 0, "the sleep period must contain epochs to explain")
        // Conservation: every sleep epoch is attributed to exactly one bucket at the classifier mouth.
        let attributed = d.remAtClassify + d.wonOtherStage + d.blockedNotStill
            + d.blockedNoCardiacActivation + d.blockedRespRegular + d.blockedNoRespFallbackBar
        XCTAssertEqual(attributed, d.sleepEpochs, "per-epoch reasons must partition the sleep epochs")
        // The summary line a caller would log mentions the absent resp channel.
        XCTAssertTrue(d.summary.contains("resp=ABSENT"), "summary surfaces the absent resp channel")
    }

    func testRemFunnelDiagnosticIsReadOnly() {
        // The diagnostic must not perturb the hypnogram stageSession produces for the same window.
        let start = nightStart(02)
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let before = SleepStager.stageSession(start: start, end: start + dur,
                                              grav: grav, hr: hr, rr: [], resp: [])
        _ = SleepStager.remFunnelDiagnostic(start: start, end: start + dur,
                                            grav: grav, hr: hr, rr: [], resp: [])
        let after = SleepStager.stageSession(start: start, end: start + dur,
                                             grav: grav, hr: hr, rr: [], resp: [])
        XCTAssertEqual(before, after, "remFunnelDiagnostic must not change the staged hypnogram")
    }
}
