import Foundation
import WhoopProtocol

// SleepStager.swift — sleep/wake detection + APPROXIMATE 4-class staging.
//
// Ported from server/ingest/app/analysis/sleep.py and sleep_features.py.
//
// HONEST HEDGING: these stages are APPROXIMATIONS, not PSG-validated, not medical
// advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019).
// Light/deep separation is the weakest link — deep-minute estimates are the least
// reliable output.
//
// Pipeline (30 s epochs):
//   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke
//            (te Lindert 30 s) computed as a citable cross-check; HR confirms runs.
//   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window
//            (mean HR, DoG-HR variability, RMSSD/SDNN from RR, resp rate + RRV).
//   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
//   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in
//            the first third of the night).
//
// NOTE: the Python source computes RMSSD/SDNN/HF/LF/LFHF via neurokit2 per epoch.
// On-device we have no neurokit2/scipy, so frequency-domain features (HF, LF/HF)
// are omitted and the parasympathetic-tone signal is RMSSD only. Respiration rate
// + RRV are derived from the raw 1 Hz resp channel with a simple peak detector
// (the Python source explicitly derives these "robustly ourselves" too, so this
// path is a faithful port rather than an approximation). The classifier seam,
// percentile bands, smoothing, and physiology rules are reproduced exactly.

// MARK: - Public output shapes

/// A contiguous sleep-stage segment. Times are wall-clock unix seconds.
public struct StageSegment: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var stage: String  // "wake" | "light" | "deep" | "rem"
    public init(start: Int, end: Int, stage: String) {
        self.start = start; self.end = end; self.stage = stage
    }
}

/// A detected sleep session (in-bed span) with APPROXIMATE staging.
public struct SleepSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake).
    public let efficiency: Double
    public let stages: [StageSegment]
    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    public let restingHR: Int?
    /// Mean RMSSD over 5-min windows across the session (ms), or nil.
    public let avgHRV: Double?

    public init(start: Int, end: Int, efficiency: Double, stages: [StageSegment],
                restingHR: Int?, avgHRV: Double?) {
        self.start = start; self.end = end; self.efficiency = efficiency
        self.stages = stages; self.restingHR = restingHR; self.avgHRV = avgHRV
    }
}

public enum SleepStager {

    // MARK: - Stage 0 constants (sleep.py)

    /// Per-sample gravity change (g) at/below which a sample is "still".
    public static let gravityStillThresholdG: Double = 0.01
    /// Rolling stillness window (minutes).
    public static let stillWindowMin: Int = 15
    /// Fraction of still samples to call the window-center "sleep".
    public static let stillFraction: Double = 0.70
    /// Data gap (minutes) that always breaks a run.
    public static let maxGapMin: Int = 20
    /// Runs shorter than this (minutes) are absorbed into neighbours.
    public static let mergeMin: Int = 15
    /// A sleep run must exceed this (minutes) to count as a session.
    public static let minSleepMin: Int = 60
    /// Assumed sample interval (seconds) when not inferable.
    public static let defaultIntervalS: Double = 60.0

    // MARK: - Daytime false-sleep guard (#90)

    // A long, still, sedentary daytime stretch (reading, a desk, a sofa) is gravity-
    // indistinguishable from a real nap, so the gravity spine alone misclassifies it as
    // sleep. The fix is NOT to drop daytime sleep — real naps are legitimate sessions —
    // but to hold a window whose CENTER falls in the local daytime band to a stricter bar:
    // it must be long enough to be a real nap AND show a genuine cardiac dip (a sedentary
    // stretch keeps a near-baseline HR). Overnight windows are UNCHANGED.

    /// Local hour (inclusive) at which the stricter daytime bar begins.
    public static let daytimeBandStartHour: Int = 11
    /// Local hour (exclusive) at which the stricter daytime bar ends. A window whose center
    /// is in [start, end) local hours is "daytime"; everything else is "overnight".
    public static let daytimeBandEndHour: Int = 20
    /// A still sleep run that resumes within this gap of an overnight sleep chain is the
    /// night's TAIL — a late wake past the daytime-band start, or a brief morning stir then
    /// back to sleep — not an isolated daytime nap, so it skips the daytime guard. Without
    /// this, a real sleep that ran past ~11:00 local had its tail rejected as a "nap" and the
    /// displayed wake time was truncated to late morning (late sleepers / shift workers).
    // Reimplemented from @vulnix0x4's PR #353.
    public static let nightContinuationGapMin: Int = 90
    /// A daytime window must run at least this long (minutes) to count — short still
    /// daytime stretches are the dominant false-positive and are rejected outright.
    public static let daytimeMinSleepMin: Int = 90
    /// A daytime window's resting HR (lowest 5-min rolling mean) must be at or below
    /// baseline × this to confirm a real cardiac dip. Stricter than the overnight 1.05:
    /// a true nap dips BELOW the waking-day median, sedentary stillness does not.
    public static let daytimeRestingHRMult: Double = 0.95

    // MARK: - H4 physiological in-bed span cap (#547 / #531 / #509 / tail)

    /// Maximum plausible in-bed span (seconds) for a SINGLE assembled main-sleep run. No real single night
    /// runs longer than this: a 12 h+ "sleep" is a bad-clock artefact (a stale/duplicated timestamp range,
    /// or a strap that banked one frozen still stretch under a wrong clock) reading as one enormous still
    /// block — which then reports a 12 h sleep and poisons Rest / the debt ledger / the headline. 16 h is
    /// well above any genuine night (incl. recovery/illness sleeps and late weekend lie-ins) yet below the
    /// clock-artefact range. A run whose span exceeds this is DROPPED (not silently truncated to 16 h, which
    /// would fabricate a wake time): an over-long block is not trustworthy enough to assert a span for at
    /// all. (#547 / #531 / #509 tail)
    public static let maxMainSleepSpanS: Int = 16 * 60 * 60

    // MARK: - H7 morning-stillness nap suppression (#531)

    // After a real overnight wake the wrist is often still (sitting with coffee, back in bed scrolling, a
    // sofa) for a stretch that the gravity spine reads as a fresh "nap" — #531's 9 am phantom nap right after
    // the night ended. It is NOT a night-tail continuation (that is handled by `nightContinuationGapMin` and
    // exempted), and it can clear the ordinary daytime guard (it is long + the post-wake HR is still low), so
    // it slipped through. H7 holds a daytime block that BEGINS within `morningStillnessWindowMin` of the
    // just-detected overnight wake to a STRONGER bar than an ordinary daytime nap: it must show a genuine
    // SUSTAINED re-onset — a real second sleep dips clearly below the day median, not merely near it.

    /// A daytime block whose onset falls within this many minutes AFTER an overnight chain's wake is treated
    /// as suspected morning residual stillness and held to the stronger re-onset bar below. ~3 h covers the
    /// post-wake window where residual stillness masquerades as a nap; a genuine afternoon nap (hours later)
    /// is past it and faces only the ordinary daytime guard. (#531)
    public static let morningStillnessWindowMin: Int = 180

    /// The stronger resting-HR bar (× day baseline) a suspected-morning-stillness block must clear to be kept
    /// as a real re-onset. Stricter than the ordinary daytime `daytimeRestingHRMult` (0.95): residual waking
    /// stillness keeps a near-waking HR, so only a block that dips clearly (a true second sleep) survives.
    public static let morningReonsetRestingHRMult: Double = 0.90

    /// The persisted v18 BAND sleep_state value that means "asleep" (Interpreter's `(sb>>4)&3`: 0 wake /
    /// 1 still / 2 asleep / 3 up). The strap's OWN scored band state — an independent anchor we CONSUME to
    /// confirm a borderline morning re-onset (H7) without re-deriving anything. (#531 / H8 consume)
    public static let bandStateAsleep: Int = 2

    /// Fraction of a suspected-morning-stillness block's epochs whose persisted band sleep_state must read
    /// "asleep" (`bandStateAsleep`) for the strap's OWN signal to CONFIRM a genuine re-onset and KEEP the
    /// block even when its HR dip is borderline. A real second sleep the strap itself scored asleep is a
    /// strong, honest anchor; a residual-stillness false nap reads "still"/"up", not "asleep". ≥0.6 keeps
    /// this conservative. (H8 consume)
    public static let morningReonsetBandAsleepFrac: Double = 0.6
    /// Seconds in a calendar day (for local-hour-of-day arithmetic).
    static let secondsPerDay: Int = 86_400
    /// Floor on the rolling-window size in samples.
    public static let minWindowSamples: Int = 3
    /// A run is HR-confirmed only if mean HR ≤ baseline × this.
    public static let hrSleepBaselineMult: Double = 1.05
    /// Skip HR refinement (trust gravity) when fewer than this many HR samples.
    public static let hrRefineMinSamples: Int = 30
    /// Consecutive sleep epochs required to declare onset.
    public static let onsetPersistEpochs: Int = 3

    // MARK: - Off-wrist backstop (#500)

    // A wrist-OFF stretch reads as perfectly still gravity with no contrary motion, so the
    // gravity spine classifies it as sleep — and because the off-wrist epochs carry zero/missing
    // HR the daytime guard treats them as "missing data" and lets them through (a daytime desk-off
    // strap logged a phantom sleep). The backstop measures OFF-WRIST COVERAGE: while the strap is
    // worn it emits ~1 Hz HR, so a long CONTIGUOUS gap in the HR samples spanning part of a candidate
    // sleep run is a strong off-wrist proxy that works even when explicit WRIST_OFF events are absent;
    // explicit WRIST_OFF→WRIST_ON intervals (when the store surfaces them) sharpen it. A run is dropped
    // only when that coverage reaches maxOffWristSleepFraction of its duration (the FRACTIONAL rule from
    // j0b-dev's #504), so a real night that over-extends into a SHORT off-wrist tail survives. This is
    // independent of the daytime band — off-wrist time is off-wrist day or night, and a night-tail
    // continuation does NOT exempt it.
    /// A contiguous HR-sample gap of at least this many minutes contributes to a candidate run's
    /// off-wrist coverage. Sized at maxGapMin so a real worn night (dense ~1 Hz HR, or PPG-derived HR
    /// on a 5/MG) contributes ~no gap, but a wrist-off stretch (HR flatlines to no samples) contributes
    /// its whole span. The edges of the run count too: a run that begins/ends far from its nearest HR
    /// sample is partially uncovered.
    public static let offWristHRGapMin: Int = 20

    /// FRACTIONAL off-wrist rejection (#500), design credited to j0b-dev's #504 analysis. A candidate
    /// sleep run is dropped ONLY when its off-wrist coverage — the UNION of its long HR-gap spans and
    /// any WRIST_OFF→WRIST_ON intervals overlapping it — is at least this fraction of its duration. The
    /// earlier guard dropped the WHOLE run on ANY contiguous HR gap or ANY single WRIST_OFF blip, which
    /// nuked a real night that over-extended into a SHORT off-wrist morning tail (strap removed shortly
    /// after waking) or that contained one stray WRIST_OFF event. 0.5 keeps such a night (<50% off-wrist)
    /// while still dropping an all-day desk strap (≈100% gap) or a session genuinely spent off-wrist.
    public static let maxOffWristSleepFraction: Double = 0.5

    /// Minimum average HR-stream density for the off-wrist HR-gap proxy to be trusted (#507). The proxy
    /// reads a >`offWristHRGapMin`-minute hole in HR as "off the wrist" — valid only when HR is otherwise
    /// dense (live 5/MG, or a worn night with continuous HR), so a real gap is anomalous. A WHOOP 4.0's
    /// SYNCED night is reconstructed mostly from MOTION with sparse, derived HR, whose natural gaps would
    /// otherwise read as off-wrist and wrongly DROP a real night. So if the HR stream averages fewer than
    /// one sample per this many seconds, we don't assert off-wrist from gaps at all (WRIST_OFF events
    /// still apply). Self-consistent: a night sparse enough to be >50% gap-covered is, by definition,
    /// below this density, so it is spared. Measured over the whole stream, so an off-wrist HOLE inside an
    /// otherwise dense, worn day (#500) is still caught.
    static let hrDenseSpacingS: Int = 600   // one HR sample per 10 minutes, averaged over the stream

    // MARK: - Sparse-gravity robustness (#308)

    // On an un-unlocked WHOOP 5.0 the strap backfills mostly v18/v26 records where gravity is
    // sparse/clumped (~25% coverage), so the gravity-only Stage-0 spine fragments the night at
    // every >maxGapMin gravity gap and detectSleep drops every <minSleepMin fragment — collapsing
    // a ~6 h night to ~1 h. The fix derives the in-bed spine from a sustained low-HR stretch and
    // uses gravity stillness only to REFINE it, but is GATED ENTIRELY behind a "gravity is sparse"
    // condition so dense WHOOP-4.0 nights stay BYTE-IDENTICAL (a 4.0 regression is unacceptable).

    /// Gravity is "sparse" when its timespan covers less than this fraction of the HR-sample
    /// timespan. A dense 4.0 night has gravity spanning the whole HR window (≈1.0) and never
    /// trips this; a 5.0 backfill clumps gravity into a fraction of the night.
    public static let sparseGravitySpanFrac: Double = 0.5
    /// When sparse, HR drives the in-bed spine: an HR sample is "sleep-band" when its bpm ≤
    /// baseline × this. Reuses the overnight HR-confirmation multiplier so the band is the same
    /// one detectSleep already trusts to confirm a run.
    public static let hrSleepBandMult: Double = hrSleepBaselineMult
    /// When sparse, two adjacent sleep runs separated ONLY by a gravity gap up to this many
    /// minutes are merged if the intervening HR stays in the sleep band — so a real night is not
    /// shredded into sub-minSleepMin fragments by gravity dropouts. Sized at the daytime-nap
    /// floor (a real continuous night never has a true >90 min wake bridge mid-sleep).
    public static let sparseBridgeGapMin: Int = 90

    /// A single intervening ACTIVE run up to this long may be absorbed when bridging two sleep runs
    /// (#1657).
    ///
    /// This started as `maxGapMin` (20), on the reasoning that the file already had a threshold for
    /// "a discontinuity this long is decisive". An end-to-end test through `detectSleep` showed that was
    /// too tight to reach the case the issue is about: a FIFTEEN-minute interruption produced a
    /// TWENTY-ONE-minute active run, because `classifyStill` smears the still/moving boundary by roughly
    /// its rolling window and `buildRuns` closes runs at sample edges. The detected run is systematically
    /// longer than the interruption it represents, so a bound set from the interruption's true length
    /// rejects it.
    ///
    /// 30 is a judgement, and stated as one rather than dressed up as derived: a realistic trip out of
    /// bed of up to about a quarter of an hour, plus the ~6 minutes of smear that measurement showed,
    /// with a little headroom. It is deliberately well under `minSleepMin` — an interruption long enough
    /// to be a session in its own right is a genuine awakening and should split the night.
    ///
    /// The bound is the cheap half of the guard. The real one is the HR band across the whole span: a
    /// wearer who is actually up keeps HR elevated for the duration and fails it, while a brief stir does
    /// not. `mergeMin` (15) already absorbs shorter active runs upstream in `mergePeriods`.
    public static let sparseBridgeActiveMaxMin: Int = 30

    // MARK: - Stage 1–3 constants (sleep_features.py)

    public static let epochS: Double = 30.0
    public static let featureWindowS: Double = 5 * 60.0
    public static let ckCountDivisor: Double = 100.0
    public static let ckCountClip: Double = 300.0
    public static let moveDeltaThresholdG: Double = 0.01
    public static let hrDogSigma1S: Double = 120.0
    public static let hrDogSigma2S: Double = 600.0

    public static let stageHRLowPct: Double = 25.0
    public static let stageHRHighPct: Double = 70.0
    public static let stageHRVHighPct: Double = 70.0
    public static let stageHRVarHighPct: Double = 65.0
    public static let stageRRVHighPct: Double = 65.0
    public static let stageRRVLowPct: Double = 50.0
    public static let stageWakeMoveFrac: Double = 0.15
    public static let stageStillMoveFrac: Double = 0.10

    /// Fraction of sleep-period epochs that must carry a MISSING per-epoch RMSSD (sparse R-R) for the
    /// session's cardiac signal to count as PPG-DERIVED / sparse-cardiac. On a WHOOP 5/MG the PPG-derived
    /// HR feeds a noisier per-epoch HR-variance, which inflates `hrVar` on otherwise still, low-HR sleep
    /// epochs and was tripping the Stage-2 WAKE rule (which keys on the `hrvarHigh` percentile) — so a
    /// whole night over-reported WAKE. We already trust `!rmssd.isFinite` as a PPG/sparse tell for the
    /// pro-deep RMSSD handling (#127/#129); at this share across the night it also down-weights the
    /// HR-variance half of the WAKE rule. ~50% keeps a real worn 4.0 night (dense R-R) on the strict
    /// path and only relaxes nights whose cardiac signal is genuinely sparse/derived. (#705)
    public static let cardiacSparseEpochFrac: Double = 0.5

    public static let smoothEpochs: Int = 5
    public static let noREMAfterOnsetMin: Double = 15.0
    public static let deepFirstFraction: Double = 1.0 / 3.0

    /// Fragment-merge threshold (#274). A staged run shorter than this is "noise": the
    /// WHOOP 5/MG banks sparse motion, so the stager emits lots of sub-minute stage flecks
    /// and the hypnogram reads choppier than WHOOP's. mergeFragments (a DISPLAY/scoring
    /// smoothing applied AFTER staging, never to the underlying detection) absorbs runs
    /// below this into their neighbours. 3 min is conservative — long enough to clear the
    /// fleck noise, short enough to leave a genuine stage transition (a real deep or REM
    /// block runs many minutes) untouched.
    public static let fragmentMergeMin: Double = 3.0
    /// fragmentMergeMin expressed in 30 s epochs (6). A run with < this many epochs merges.
    public static let fragmentMergeEpochs: Int = Int((fragmentMergeMin * 60.0 / epochS).rounded())

    /// te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1.
    public static let ckWeights: [Double] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0]
    public static let ckScale: Double = 0.001
    public static let ckBack: Int = 4
    public static let ckFwd: Int = 2

    // MARK: - Gravity deltas

    /// Per-record movement proxy = L2 magnitude of the gravity change vs the
    /// previous record. First record → 0. (No dropout sentinel needed: GravitySample
    /// always carries finite x/y/z.)
    static func gravityDeltas(_ grav: [GravitySample]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(grav.count)
        var prev: GravitySample? = nil
        for (i, r) in grav.enumerated() {
            if i == 0 {
                deltas.append(0.0)
            } else if let p = prev {
                let dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z
                deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
            } else {
                deltas.append(0.0)
            }
            prev = r
        }
        return deltas
    }

    /// Median spacing between consecutive timestamps, restricted to (0, 300 s).
    static func medianIntervalS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return defaultIntervalS }
        var gaps: [Double] = []
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return defaultIntervalS }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }

    static func windowSize(_ times: [Int]) -> Int {
        let interval = medianIntervalS(times)
        return max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
    }

    // MARK: - Sparse-gravity gate (#308)

    /// Largest spacing between consecutive timestamps (seconds), NO upper cap; 0 for <2 samples.
    /// Used to detect clumped/sparse gravity where the dropouts themselves are the signal: a few
    /// long dropouts in otherwise-dense (clumped) motion keep the MEDIAN gap small but still break
    /// runs, so the largest gap — not the median — is the right signal (#28).
    static func largestGapS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return 0 }
        var mx = 0.0
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > mx { mx = g }
        }
        return mx
    }

    /// True when gravity is too sparse for the gravity-only spine to be trusted across gaps:
    /// the gravity timespan covers < sparseGravitySpanFrac of the HR-sample timespan, OR the
    /// LARGEST gravity inter-sample gap exceeds maxGapMin. The largest-gap test (not just the
    /// median) catches CLUMPED motion — dense bursts split by a few long dropouts, the typical
    /// WHOOP 4.0 backfill (#28) — whose median gap stays small yet which still hides run-breaking
    /// gaps. Requires a real HR span to compare against — with no/degenerate HR the dense path is
    /// kept (false), so a 4.0 with absent HR is never reclassified as sparse.
    static func isGravitySparse(_ grav: [GravitySample], hr: [HRSample]) -> Bool {
        if grav.count < 2 || hr.count < 2 { return false }
        let hrSpan = Double(hr[hr.count - 1].ts - hr[0].ts)
        if hrSpan <= 0 { return false }
        let gravSpan = Double(grav[grav.count - 1].ts - grav[0].ts)
        if gravSpan < sparseGravitySpanFrac * hrSpan { return true }
        // #28: clumped 4.0 motion keeps a SMALL median gap yet still contains >maxGapMin dropouts
        // the gravity-only spine shreds the night on. The largest gap catches what a median would
        // miss (largest ≥ median, so this subsumes the old median check). Flagging sparse only
        // ENABLES buildRuns' HR-vouched bridge — a real wake (HR above the sleep band) still breaks.
        return largestGapS(grav.map { $0.ts }) > Double(maxGapMin * 60)
    }

    /// True when HR stays in the sleep band (≤ baseline × hrSleepBandMult) across (a, b], used to
    /// decide whether a pure gravity gap is a real wake or just a dropout. With no baseline or no
    /// HR in the interval, the answer is false (cannot vouch for the gap → treat as a real break).
    static func hrSleepBandAcross(_ a: Int, _ b: Int, hr: [HRSample], baseline: Double?) -> Bool {
        guard let baseline = baseline else { return false }
        let seg = hr.filter { $0.ts > a && $0.ts <= b }
        if seg.isEmpty { return false }
        // MEDIAN, not mean (#1657). `confirmSleepWithHR` below already documents why the mean is the
        // wrong statistic here — "a real sleep night carries brief arousal / wake HR spikes (observed to
        // ~190 bpm)" that drag it above the band — and uses the median for exactly that reason. This gate
        // answers the same question over a SHORTER window, where a single spike dominates the mean even
        // harder: a two-minute stir inside a fifteen-minute interval can put the mean out of band while
        // the wearer was asleep for thirteen of those minutes. The median rejects a SUSTAINED elevation
        // just as firmly, which is the discrimination this gate exists to make.
        let medianHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        return medianHR <= baseline * hrSleepBandMult
    }

    /// Per-record sleep flags from a rolling fraction of "still" samples.
    static func classifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        if n < 2 { return [Bool](repeating: false, count: n) }
        let half = windowSize(grav.map { $0.ts }) / 2
        // stillPrefix[i] = # still samples among deltas[0..<i]: O(1) window counts → an O(n) scan, not
        // O(n×window). The old nested loop burned minutes of CPU per analysis tick (and on Android, on
        // the main thread, froze the app into ANRs after a few nights of 1 Hz history). Identical output.
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            stillPrefix[i + 1] = stillPrefix[i] + (deltas[i] < gravityStillThresholdG ? 1 : 0)
        }
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let stillCount = stillPrefix[hi] - stillPrefix[lo]
            flags.append(Double(stillCount) / Double(hi - lo) >= stillFraction)
        }
        return flags
    }

    struct Period { var stage: String; var start: Int; var end: Int }

    /// Collapse per-record flags into contiguous runs, breaking on class change
    /// or a gap > maxGapMin minutes.
    ///
    /// When `sparse` (gravity is too clumped to bridge gaps — #308), a PURE gravity data-gap
    /// (no contrary motion) does NOT close a SLEEP run while HR stays in the sleep band across
    /// the gap: the strap simply banked no motion there, not a wake. A class change always still
    /// closes the run, and the dense path (`sparse == false`) is byte-identical to the original.
    static func buildRuns(_ grav: [GravitySample], _ flags: [Bool],
                          sparse: Bool = false, hr: [HRSample] = [], baseline: Double? = nil) -> [Period] {
        let n = grav.count
        if n == 0 { return [] }
        let times = grav.map { $0.ts }
        let maxGapS = maxGapMin * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...n {
            let atEnd = (i == n)
            let close: Bool
            if atEnd {
                close = true
            } else {
                let classChanged = flags[i] != flags[runStart]
                var gapExceeded = (times[i] - times[i - 1]) > maxGapS
                // Sparse override: a pure gravity gap (no class change) does not break a sleep
                // run when HR stays in the sleep band across it — the gap is a dropout, not a wake.
                if sparse && gapExceeded && !classChanged && flags[runStart]
                    && hrSleepBandAcross(times[i - 1], times[i], hr: hr, baseline: baseline) {
                    gapExceeded = false
                }
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Absorb runs shorter than mergeMin minutes into their neighbours.
    static func mergePeriods(_ periods: [Period], mergeMinutes: Int = mergeMin) -> [Period] {
        if periods.isEmpty { return [] }
        var pending = periods
        let thresholdS = mergeMinutes * 60
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            let tooShort = (current.end - current.start) < thresholdS
            if !tooShort { merged.append(current); i += 1; continue }

            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            let bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if bridgesSame {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1] = Period(stage: pending[i + 1].stage,
                                        start: current.start, end: pending[i + 1].end)
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    /// Why `bridgeSparseSleep` did or did not merge one adjacent pair of runs (#737).
    ///
    /// The existing trace reports only `runsBefore`/`runsAfter`, so a bridge that changed NOTHING gives
    /// no reason — and there are three very different causes (gap over the tolerance, HR outside the
    /// sleep band, or the pair simply not being two adjacent sleep runs). A reporter's night showed
    /// `runsBefore=13 runsAfter=13` with 8 runs then discarded by `minSleepMin`, and the log could not
    /// say which cause applied, so no fix could be chosen responsibly. This names it per pair.
    struct SparseBridgeAttempt: Equatable, Sendable {
        /// Gap between the two runs, in whole minutes (negative when they overlap).
        let gapMin: Int
        /// Minutes of intervening ACTIVE run, or 0 when the pair was only separated by a gap (#1657).
        let activeMin: Int
        /// Whether the intervening HR stayed in the sleep band (the bridge's second condition).
        let hrInSleepBand: Bool
        /// Whether this pair was merged.
        let bridged: Bool
        /// Stable token for the log: bridged / gapTooLong / hrOutOfBand / overlap / activeTooLong.
        let reason: String
    }

    /// Per-pair explanation of `bridgeSparseSleep`, mirroring its rule EXACTLY (same adjacency walk,
    /// same `gap >= 0 && gap <= sparseBridgeGapMin*60`, same HR-band check) so the reasons describe what
    /// actually happened rather than an approximation. Only pairs the bridge itself CONSIDERS (two
    /// adjacent sleep runs) produce an attempt; a pair separated by an active run is never considered,
    /// which is itself the answer when no attempts are reported. Pure — no I/O, no side effects.
    /// The bridge, plus what it considered. See `bridgeSparseSleep` for the merge rule.
    ///
    /// #1657: an intervening ACTIVE run no longer blocks the merge permanently. The original loop could
    /// only join runs already adjacent in its own output, so any active run between two sleep runs was
    /// appended first and made the next pair unreachable — and a field trace found the bridge merging
    /// NOTHING on 14 of 14 sparse nights for exactly that reason. Since a bathroom trip is definitionally
    /// an active run, the rescue built for fragmentation was unavailable in the case that needs it most.
    ///
    /// A single active run up to `sparseBridgeActiveMaxMin` is now absorbed, with the whole span still
    /// subject to `sparseBridgeGapMin` and to the HR band. Two or more consecutive active runs are not:
    /// that is a night with real structure in it, not one interruption.
    ///
    /// This USED to be a shadow copy of the loop kept only for tracing, which had to be edited in step
    /// with the real one — a trace that quietly disagrees with the behaviour it describes is worse than
    /// no trace. Merge and trace are one pass now. Kotlin twin: `bridgeSparseSleepTraced`.
    static func bridgeSparseSleepTraced(_ periods: [Period], sparse: Bool, hr: [HRSample],
                                        baseline: Double?) -> ([Period], [SparseBridgeAttempt]) {
        if !sparse || periods.isEmpty { return (periods, []) }
        let bridgeGapS = sparseBridgeGapMin * 60
        let activeMaxS = sparseBridgeActiveMaxMin * 60
        var out: [Period] = []
        var attempts: [SparseBridgeAttempt] = []

        /// Judge one candidate pair, record it, and merge when it passes.
        ///
        /// The order of the checks fixes which reason a failing pair reports, and it is deliberate:
        /// overlap and gap are properties of the pair, activeTooLong is a property of what sits between
        /// them, and hrOutOfBand is last because it is the only one that needed the HR series to decide.
        func consider(_ left: Period, _ right: Period, activeS: Int,
                      dropTrailing: Bool, activeMaxS: Int) -> Bool {
            let gap = right.start - left.end
            let inBand = hrSleepBandAcross(left.end, right.start, hr: hr, baseline: baseline)
            let reason: String
            if gap < 0 { reason = "overlap" }
            else if gap > bridgeGapS { reason = "gapTooLong" }
            else if activeS > activeMaxS { reason = "activeTooLong" }
            else if !inBand { reason = "hrOutOfBand" }
            else { reason = "bridged" }
            let bridged = reason == "bridged"
            attempts.append(SparseBridgeAttempt(gapMin: gap / 60, activeMin: activeS / 60,
                                                hrInSleepBand: inBand, bridged: bridged, reason: reason))
            guard bridged else { return false }
            if dropTrailing { out.removeLast() }
            out[out.count - 1] = Period(stage: "sleep", start: left.start, end: right.end)
            return true
        }

        for p in periods {
            if p.stage == "sleep" {
                // Case 1: the previous run is sleep — the original adjacent-pair merge.
                if let last = out.last, last.stage == "sleep" {
                    if consider(last, p, activeS: 0, dropTrailing: false, activeMaxS: 0) { continue }
                }
                // Case 2: exactly one active run sits between two sleep runs. Absorbed when short
                // enough, which is the #1657 case the original loop could never reach.
                if out.count >= 2, let last = out.last, last.stage == "active",
                   out[out.count - 2].stage == "sleep" {
                    let prev = out[out.count - 2]
                    if consider(prev, p, activeS: last.end - last.start,
                                dropTrailing: true, activeMaxS: activeMaxS) { continue }
                }
            }
            out.append(p)
        }
        return (out, attempts)
    }

    /// Sparse-gravity bridge (#308): merge two SLEEP runs when the intervening HR stays in the sleep
    /// band — so a real night fragmented by gravity dropouts is re-stitched into one continuous in-bed
    /// span BEFORE the minSleepMin gate drops the pieces. A no-op when `sparse == false`, so the dense
    /// 4.0 path is unchanged.
    ///
    /// What sits between the two runs may be a bare gap (up to `sparseBridgeGapMin`) or ONE active run
    /// (additionally up to `sparseBridgeActiveMaxMin`). Over-threshold gaps, longer active runs and two
    /// consecutive active runs are all left untouched.
    ///
    /// The previous wording here — "Active runs … are left untouched; the span between two bridged sleep
    /// runs (an "active"/gap run, if present) is absorbed" — read as though an intervening active run was
    /// already handled. It was not: only a bare gap was, and that sentence is a large part of why #1657
    /// went unnoticed. Kept in the history rather than quietly deleted, because the next person to widen
    /// this function will read this comment first.
    static func bridgeSparseSleep(_ periods: [Period], sparse: Bool,
                                  hr: [HRSample], baseline: Double?) -> [Period] {
        bridgeSparseSleepTraced(periods, sparse: sparse, hr: hr, baseline: baseline).0
    }

    // MARK: - HR refinement

    static func rowsBetween<T>(_ rows: [T], start: Int, end: Int, ts: (T) -> Int) -> [T] {
        rows.filter { ts($0) >= start && ts($0) <= end }
    }

    /// Day HR baseline = median bpm over all HR samples; nil if none.
    static func hrBaseline(_ hr: [HRSample]) -> Double? {
        let vals = hr.map { Double($0.bpm) }
        guard !vals.isEmpty else { return nil }
        return HRVAnalyzer.median(vals)
    }

    /// HR-confirmation with MOTION CORROBORATION (motion-corroborated wake). A run is confirmed as sleep when
    /// its MEDIAN HR sits within the sleep band relative to `baseline`. The band is normally `hrSleepBaselineMult`
    /// (×1.05); on a run that is DEEPLY MOTION-QUIESCENT (`runIsDeeplyQuiescent` — the wrist barely moved and its
    /// posture did not change across the whole span) the band widens to `quiescentHRSleepMult`, because a raised
    /// but FLAT overnight HR with a motionless wrist is a supplement / fever / hot-room / alcohol artefact, not
    /// wakefulness — elevated-HR-alone must not reject a still run. The wider band STILL keeps a floor: a
    /// genuinely awake, high-HR run (median above `quiescentHRSleepMult × baseline`) is rejected even when still,
    /// so all-night in-bed wakefulness is not scored asleep. `sleepHRBaseline` (directive b) overrides `baseline`
    /// with the wearer's personalised overnight band (`adaptiveOvernightHRBaseline`) when the caller supplies
    /// one, so a supplement / fitness era self-calibrates instead of drifting against a fixed day-median.
    /// `grav` defaults to empty (motion unprovable → strict band, byte-identical to the pre-corroboration gate);
    /// the detection call site passes the night's gravity. Mirrors Kotlin `confirmSleepWithHR`.
    static func confirmSleepWithHR(_ p: Period, hr: [HRSample], baseline: Double?,
                                   grav: [GravitySample] = [], sleepHRBaseline: Double? = nil) -> Bool {
        let effBaseline = sleepHRBaseline ?? baseline
        guard let effBaseline = effBaseline else { return true }
        let seg = rowsBetween(hr, start: p.start, end: p.end) { $0.ts }
        if seg.count < hrRefineMinSamples { return true }
        // Confirm on the run's MEDIAN, not its mean. A real sleep night carries brief arousal / wake HR
        // spikes (observed to ~190 bpm) that pull the MEAN above baseline × mult and reject the run — and for
        // a typical single main-sleep run per night that means zero sessions ("no sleep recorded") — while
        // the spike-robust median stays at the true sleep level. Baseline is itself a median, so both sides
        // use the same robust statistic; a genuinely elevated (awake) run still has a high median and fails.
        // Median ≤ mean for the right-skewed HR of a real night, so this only ever RELAXES the gate — every
        // run the mean already accepted still passes, and runs the mean wrongly dropped are recovered.
        let medHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        let mult = runIsDeeplyQuiescent(p, grav: grav) ? quiescentHRSleepMult : hrSleepBaselineMult
        return medHR <= effBaseline * mult
    }

    // MARK: - Motion-corroborated wake (elevated-but-flat-HR nights)

    // Both stagers call "wake" primarily off HR / HR-variability, and the HR-led session confirmation
    // (`confirmSleepWithHR`) rejects a still run whose median HR sits above the sleep band. On a night with
    // pharmacologically- or metabolically-elevated resting HR that keeps HR up WITHOUT the wearer getting up
    // (a supplement protocol, a fever, a hot room, alcohol), that HR-led logic misreads hot-but-motionless
    // sleep as wake. The corroboration rule is: elevated-HR ALONE is insufficient — a run/epoch at the night's
    // quiescent MOTION floor with UNCHANGED posture cannot be called wake on cardiac evidence alone. The
    // per-epoch half lives in the stagers (`SleepStagerV2.motionQuiescent`); this is the session-detection half.

    /// The relaxed sleep-band multiplier applied to `confirmSleepWithHR` when the run is DEEPLY motion-quiescent.
    /// Wider than `hrSleepBaselineMult` (1.05) so a supplement-elevated but motionless overnight run is not
    /// rejected, yet bounded (the floor) so a genuinely awake still run above this band is still dropped.
    public static let quiescentHRSleepMult: Double = 1.30

    /// Per-minute gravity posture variance (g²) at/below which a minute counts as posture-STABLE — the wrist
    /// orientation barely moved within the minute. Mirrors the stage-level posture threshold; a minute with too
    /// few gravity samples to compute a variance is conservatively NOT counted as stable (silence ≠ stillness).
    public static let quiescentPostureVarG2: Double = 0.05

    /// Fraction of a run's minutes that must be posture-STABLE for the run to be DEEPLY motion-quiescent. Set
    /// well above the Stage-0 stillness bar (`stillFraction` 0.70) so only a genuinely motionless run — not an
    /// ordinary restless-but-in-bed night — earns the widened HR band; a night with real turn-overs/fidgets
    /// across >10% of its minutes falls back to the strict band.
    public static let quiescentStableFrac: Double = 0.90

    /// Minimum posture-stable minutes with COMPUTABLE variance a run needs before the deeply-quiescent verdict
    /// is trusted at all — a run with almost no dense-gravity minutes can't prove stillness, so it defers to
    /// the strict HR band rather than being waved through.
    public static let quiescentMinStableMinutes: Int = 20

    /// True when `[p.start, p.end)` is DEEPLY motion-quiescent: at least `quiescentStableFrac` of the minutes
    /// that carry enough gravity to judge are posture-stable (per-minute variance < `quiescentPostureVarG2`),
    /// over at least `quiescentMinStableMinutes` such minutes. Empty/sparse gravity → false (motion unprovable,
    /// defer to the strict HR band). Pure + deterministic.
    static func runIsDeeplyQuiescent(_ p: Period, grav: [GravitySample]) -> Bool {
        if grav.isEmpty || p.end <= p.start { return false }
        var byMinute: [Int: [GravitySample]] = [:]
        for g in grav where g.ts >= p.start && g.ts < p.end { byMinute[g.ts / 60, default: []].append(g) }
        var judged = 0, stable = 0
        for (_, samples) in byMinute {
            guard let v = posturVarianceG2(samples) else { continue }   // too few samples this minute
            judged += 1
            if v < quiescentPostureVarG2 { stable += 1 }
        }
        guard judged >= quiescentMinStableMinutes else { return false }
        return Double(stable) / Double(judged) >= quiescentStableFrac
    }

    /// Trace of the covariance of a minute's gravity vectors (Σ over x/y/z of the mean squared deviation from
    /// the minute's own mean vector). ~0 when the wrist orientation is fixed within the minute; spikes on a
    /// turn-over. nil below 2 samples (a single sample has zero variance by construction and would read as a
    /// false "stable"). Shared shape with the stage-level posture check and the Kotlin twin.
    static func posturVarianceG2(_ samples: [GravitySample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let n = Double(samples.count)
        var sx = 0.0, sy = 0.0, sz = 0.0
        for s in samples { sx += s.x; sy += s.y; sz += s.z }
        let mx = sx / n, my = sy / n, mz = sz / n
        var sumSq = 0.0
        for s in samples {
            let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        return sumSq / n
    }

    /// Personalised overnight HR baseline (directive b): the median of recent nights' overnight median HRs, so
    /// the sleep band self-calibrates to the wearer's current era (a supplement protocol, a fitness change)
    /// instead of a fixed day-median that a sustained shift silently drifts against. Returns nil with no history
    /// (the caller keeps the day-median). A FLOOR keeps the band from collapsing so a genuinely wakeful era is
    /// not scored asleep: the returned value is never below `adaptiveBaselineFloor` bpm. Pure + deterministic.
    public static let adaptiveBaselineFloor: Double = 40.0
    public static func adaptiveOvernightHRBaseline(recentOvernightMedians: [Double]) -> Double? {
        let vals = recentOvernightMedians.filter { $0.isFinite && $0 > 0 }
        guard !vals.isEmpty else { return nil }
        return max(adaptiveBaselineFloor, HRVAnalyzer.median(vals))
    }

    /// True when the run's CENTER, shifted to LOCAL time by tzOffsetSeconds, lands in the
    /// daytime band [daytimeBandStartHour, daytimeBandEndHour). The center (not the edges)
    /// is used so a window straddling a band edge is classified once, by where it mostly is.
    /// `((x % d) + d) % d` is a floored modulo so a negative local-shifted time still maps
    /// into [0, secondsPerDay).
    static func isDaytimeCenter(_ p: Period, tzOffsetSeconds: Int) -> Bool {
        // Int overflow-safe: starts/ends are unix seconds; midpoint via average of the two.
        let center = p.start + (p.end - p.start) / 2
        let local = center + tzOffsetSeconds
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return hour >= daytimeBandStartHour && hour < daytimeBandEndHour
    }

    /// True when a run's ONSET (start), in LOCAL time, falls OUTSIDE the daytime band — i.e.
    /// the sleep began at night, not during the day. Anchors a continuous-sleep chain: only a
    /// chain that began overnight may carry its tail past the daytime-band start (a late wake).
    static func isOvernightOnset(_ start: Int, tzOffsetSeconds: Int) -> Bool {
        let local = start + tzOffsetSeconds
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return !(hour >= daytimeBandStartHour && hour < daytimeBandEndHour)
    }

    /// Stricter bar for a daytime-centered window (#90). A real daytime nap clears it; a
    /// long sedentary still stretch (the false-positive this guards) does not, because it
    /// is either too short or never shows a genuine cardiac dip below the day median.
    /// Overnight windows never reach here. Returns true = keep, false = reject.
    ///
    /// `restingHR` is the window's own lowest 5-min rolling-mean HR (the sleep-depth proxy
    /// detectSleep already computes); `baseline` is the day's median HR. With no usable HR
    /// evidence (nil baseline OR nil restingHR) a daytime stretch cannot be confirmed as a
    /// real nap, so it is rejected — sedentary daytime stillness without a measured HR dip
    /// is far more likely than an unmonitored nap, and this path can never touch the night.
    static func passesDaytimeGuard(_ p: Period, restingHR: Int?, baseline: Double?) -> Bool {
        let daytimeMinSleepS = daytimeMinSleepMin * 60
        if (p.end - p.start) < daytimeMinSleepS { return false }
        guard let baseline = baseline, let resting = restingHR else { return false }
        return Double(resting) <= baseline * daytimeRestingHRMult
    }

    /// H7 morning-stillness nap suppression (#531). Returns true = KEEP, false = REJECT, for a daytime block
    /// `p` that begins shortly after a real overnight wake. `morningWakeEnd` is the end of the just-detected
    /// OVERNIGHT chain (nil when the prior chain was not overnight, or there was none) — when `p.start` is
    /// within `morningStillnessWindowMin` of it, the block is suspected morning residual stillness and must
    /// clear the ORDINARY daytime guard AND show a SUSTAINED re-onset: its resting HR must dip below the
    /// stronger `morningReonsetRestingHRMult × baseline` bar (a true second sleep, not near-waking stillness).
    /// Outside the morning window this is a no-op (returns the plain daytime-guard result), so a genuine
    /// afternoon nap is unaffected. (#531)
    static func passesMorningStillnessGuard(_ p: Period, restingHR: Int?, baseline: Double?,
                                            morningWakeEnd: Int?,
                                            bandSleepState: [(ts: Int, state: Int)] = []) -> Bool {
        // Only a daytime block beginning within the post-wake window of an overnight chain is suspected.
        guard let wakeEnd = morningWakeEnd, p.start >= wakeEnd,
              (p.start - wakeEnd) <= morningStillnessWindowMin * 60 else {
            return passesDaytimeGuard(p, restingHR: restingHR, baseline: baseline)
        }
        // Suspected morning stillness needs at least the ordinary daytime guard (long enough + a real dip).
        if !passesDaytimeGuard(p, restingHR: restingHR, baseline: baseline) { return false }
        // CONSUME the strap's OWN banked band sleep_state (#531 / H8): if the strap itself scored this block
        // predominantly "asleep", that is a strong independent re-onset anchor — KEEP it even on a borderline
        // HR dip. This only ever RESCUES a block the strap says was real sleep; it never fabricates one.
        if bandStateConfirmsAsleep(p, bandSleepState: bandSleepState) { return true }
        // Otherwise require the clearly-deeper cardiac dip of a true second sleep.
        guard let baseline = baseline, let resting = restingHR else { return false }
        return Double(resting) <= baseline * morningReonsetRestingHRMult
    }

    /// CONSUME-side helper (#531 / H8): true when the strap's OWN persisted v18 band sleep_state over the
    /// block `[p.start, p.end]` reads predominantly "asleep" (`bandStateAsleep`), at/above
    /// `morningReonsetBandAsleepFrac` of the in-block samples — an independent confirmation of a real
    /// re-onset. Empty/absent band state → false (no anchor → fall back to the HR bar); we never invent a
    /// "asleep" reading the strap did not bank. Pure + deterministic. (#531 / H8 consume)
    static func bandStateConfirmsAsleep(_ p: Period, bandSleepState: [(ts: Int, state: Int)]) -> Bool {
        let inBlock = bandSleepState.filter { $0.ts >= p.start && $0.ts <= p.end }
        guard !inBlock.isEmpty else { return false }
        let asleep = inBlock.reduce(0) { $0 + ($1.state == bandStateAsleep ? 1 : 0) }
        return Double(asleep) / Double(inBlock.count) >= morningReonsetBandAsleepFrac
    }

    // MARK: - Band sleep_state WAKE-veto (recover strap-disputed false wakes)

    // NOOP's cardiorespiratory stager is known to OVER-CALL wake: an EEG-free stager reads a still, low-HR
    // but not-quite-asleep epoch as wake far more often than the wearer was actually awake. WHOOP's OWN
    // per-second sleep-state band (the persisted v18 @81 high-nibble `(sb>>4)&3`: 0 wake/1 still/2 asleep/
    // 3 up — banked as `sleepStateJSON`, gridded by `sessionEpochSleepState`) is an INDEPENDENT scored
    // signal, not a re-derivation of ours. On real banded nights the strap scores "asleep"
    // (`bandStateAsleep`) across ~two-thirds of the epochs NOOP calls wake, while the reverse disagreement
    // (NOOP asleep, strap wake) is an order of magnitude smaller. So letting the strap's OWN "asleep"
    // verdict VETO an INTERIOR wake call recovers most of the spurious wake with near-zero downside.
    // Unlike the H8 consume confirm (which only ever KEEPS a whole borderline re-onset session), this
    // operates per EPOCH on the final hypnogram and only ever turns wake INTO sleep.

    /// Default-OFF gate for the band sleep_state WAKE-veto — off until PSG supports it, and the PSG
    /// harness currently says the OPPOSITE: against the 31-subject sleep-accel truth set the shipped
    /// recipe UNDER-calls wake (wake% 4.15 vs ~9.1 true, bias −4.92 pp, wake sensitivity 30.8%), so a
    /// veto that converts wake→light moves the population result AWAY from truth even though it fixes
    /// real strap-disputed false wakes on HR-inflated nights (the n=12 that motivated it). Flip to true
    /// only with PSG evidence in hand — `sleeppsg --section variants` prints the wake%/bias row this
    /// decision keys on. The mechanism stays fully tested behind the flag (tests pass `enabled: true`
    /// explicitly). An absent band stream (WHOOP 4.0 / unbanded window) is a no-op regardless.
    public static let bandStateWakeVetoEnabled: Bool = false

    /// #1210 item 2 (retroactive-rescore story): the new-nights-only cutoff. When the veto is flipped on
    /// (`bandStateWakeVetoEnabled = true`), a NON-ZERO cutoff (a unix second) restricts the correction to
    /// sessions whose `start >= cutoffTs` — nights already in history keep their raw efficiency, so flipping
    /// the default cannot silently re-score months of banked nights upward. `0` (the default) applies the
    /// veto to every banded night (the "just ship the one-time shift" path). Inert while the flag is off.
    /// Set this to the flip date at the same time as the flag. Mirrors Kotlin `bandStateWakeVetoCutoffTs`.
    public static let bandStateWakeVetoCutoffTs: Int = 0

    /// The sleep stage a band-vetoed false-wake epoch is reclassified to. `bandStateAsleep` (band sleep_state == 2) means
    /// only "asleep" — the band carries NO light/deep/REM resolution — so the veto maps it to the generic,
    /// most-common sleep stage rather than inventing deep/REM detail the strap never asserted (deep/REM
    /// minutes feed the recovery gate; the veto must not inflate them). "light" is the honest projection of a
    /// bare "asleep".
    static let bandVetoRecoverStage: String = "light"

    /// #1210: a TRACE-ONLY line reporting what the (dormant) band wake-veto WOULD recover on a banded night,
    /// so a validator gathers the recovered-minutes distribution across real nights without any output change
    /// (the persisted hypnogram stays the flag-gated, unchanged one). Namespaced `bandVeto(shadow):` and free
    /// of a `day=` / `t=…s` token so `CaptureAccumulator` never counts it as a captured day. Mirrors Kotlin
    /// `bandVetoShadowLine`. (band sleep_state veto)
    static func bandVetoShadowLine(startTs: Int, recoveredMin: Double, rawEff: Double, shadowEff: Double) -> String {
        "bandVeto(shadow): startTs=\(startTs) recoveredMin=\(Int(recoveredMin.rounded())) "
            + "eff \(Int((rawEff * 100).rounded()))%->\(Int((shadowEff * 100).rounded()))%"
    }

    /// Band sleep_state WAKE-veto. Given a staged hypnogram `stages` (StageSegments tiling `[start, end]`)
    /// and the strap's OWN per-timestamp band sleep_state, reclassify INTERIOR wake epochs the strap itself
    /// scored "asleep" (`bandStateAsleep`) to `bandVetoRecoverStage`. Conservative by construction:
    ///   - ONLY `bandStateAsleep` (2) vetoes — a "still" (1) / "up" (3) / "wake" (0) band reading is LEFT as
    ///     wake, so the veto never blind-trusts the band, only its explicit "asleep";
    ///   - the LEADING wake block (sleep-onset latency, before the first sleep epoch) and the TRAILING wake
    ///     block (final-morning wake, after the last sleep epoch) are NEVER touched — the veto cannot move
    ///     sleep onset earlier or final wake later, it only recovers wake FLANKED by sleep;
    ///   - it only ever turns wake INTO sleep (raising efficiency), never sleep into wake.
    /// The band is gridded to the SAME 30 s epochs as `stagesJSON` / `sessionEpochMotion` via
    /// `sessionEpochSleepState`, so epoch i here is epoch i of the persisted `sleepStateJSON`. Empty band
    /// state, the flag off, or a hypnogram with no interior sleep → returns `stages` UNCHANGED (byte-
    /// identical). Applies to whichever stager (V1 or V2) produced `stages`. Pure + deterministic.
    /// (band sleep_state veto)
    static func applyBandStateWakeVeto(_ stages: [StageSegment], start: Int, end: Int,
                                       bandSleepState: [(ts: Int, state: Int)],
                                       enabled: Bool = bandStateWakeVetoEnabled,
                                       cutoffTs: Int = bandStateWakeVetoCutoffTs) -> [StageSegment] {
        guard enabled, !bandSleepState.isEmpty, !stages.isEmpty, end > start else {
            return stages
        }
        // #1210 item 2: new-nights-only gate. A non-zero cutoff spares nights that started before it (history
        // keeps its raw efficiency); `0` applies to every banded night. Inert while the flag is off.
        if cutoffTs > 0, start < cutoffTs { return stages }
        // Per-epoch band on the 30 s stagesJSON grid — byte-identical to the persisted sleepStateJSON.
        let states = sessionEpochSleepState(start: start, end: end, sleepState: bandSleepState)
        if states.isEmpty { return stages }
        let n = states.count
        // Epoch i spans [start + i·epochS, …); boundaries sit on 30 s edges, so expanding the segment tiling
        // to a per-epoch stage array and re-collapsing it is an exact round-trip (no-op when nothing changes).
        func epochStart(_ i: Int) -> Int { start + Int(Double(i) * epochS) }
        var labels = [String](repeating: "wake", count: n)
        for i in 0..<n {
            let t = epochStart(i)
            if let seg = stages.first(where: { $0.start <= t && t < $0.end })
                ?? stages.first(where: { $0.start <= t && t <= $0.end }) {
                labels[i] = seg.stage
            }
        }
        // Interior = [firstSleep, lastSleep]; leading/trailing wake blocks are excluded from the veto.
        guard let onset = labels.firstIndex(where: { $0 != "wake" }),
              let finalWake = labels.lastIndex(where: { $0 != "wake" }), onset <= finalWake else {
            return stages   // no sleep at all → nothing to recover
        }
        var changed = false
        for i in onset...finalWake where labels[i] == "wake" && states[i] == bandStateAsleep {
            labels[i] = bandVetoRecoverStage
            changed = true
        }
        if !changed { return stages }   // the band disputed nothing → byte-identical hypnogram
        // Re-collapse consecutive same-stage epochs back into segments tiling [start, end].
        var out: [StageSegment] = []
        for i in 0..<n {
            let segStart = epochStart(i)
            let segEnd = (i == n - 1) ? end : epochStart(i + 1)
            if let last = out.last, last.stage == labels[i] {
                out[out.count - 1].end = segEnd
            } else {
                out.append(StageSegment(start: segStart, end: segEnd, stage: labels[i]))
            }
        }
        if !out.isEmpty { out[out.count - 1].end = end }
        return out
    }

    /// Off-wrist HR-gap spans (#500). The contiguous HR-coverage gaps of at least `offWristHRGapMin`
    /// minutes WITHIN [p.start, p.end], as concrete `[start, end)` sub-intervals — a strong wrist-OFF
    /// proxy. Worn, the strap streams ~1 Hz HR (or PPG-derived HR on a 5/MG), so a real night yields no
    /// long gap; an off-wrist stretch flatlines to no HR samples and yields a span. The leading edge
    /// (`p.start` → first in-run sample) and trailing edge (last in-run sample → `p.end`) count too,
    /// and a run with NO in-run HR at all is one full-period gap. With NO HR data at all (no stream)
    /// this returns [] (the gravity-only path is left to the existing guards — we can't assert
    /// off-wrist without HR). These spans are UNIONed with the WRIST_OFF intervals by `offWristFraction`.
    static func offWristHRGapSpans(_ p: Period, hr: [HRSample]) -> [(start: Int, end: Int)] {
        if hr.isEmpty || p.end <= p.start { return [] }
        // Density gate (#507): only trust the HR-gap off-wrist proxy when the HR STREAM is dense enough
        // that a long gap is anomalous. A WHOOP 4.0 synced night is motion-reconstructed with sparse HR,
        // so its natural gaps must NOT read as off-wrist (that wrongly dropped a real night). Judge over
        // the whole stream so an off-wrist HOLE inside an otherwise dense, worn day (#500) is still caught.
        let sortedAll = hr.sorted { $0.ts < $1.ts }
        let streamSpan = sortedAll[sortedAll.count - 1].ts - sortedAll[0].ts
        if streamSpan >= hrDenseSpacingS && hr.count < streamSpan / hrDenseSpacingS { return [] }
        let gapS = offWristHRGapMin * 60
        let seg = hr.filter { $0.ts >= p.start && $0.ts <= p.end }.sorted { $0.ts < $1.ts }
        // No HR anywhere inside a run long enough to matter → the whole period is one gap.
        if seg.isEmpty { return (p.end - p.start) >= gapS ? [(start: p.start, end: p.end)] : [] }
        var spans: [(start: Int, end: Int)] = []
        // Leading edge: run start to first sample.
        if seg[0].ts - p.start >= gapS { spans.append((start: p.start, end: seg[0].ts)) }
        // Interior: any gap between consecutive in-run samples.
        for i in 1..<seg.count where seg[i].ts - seg[i - 1].ts >= gapS {
            spans.append((start: seg[i - 1].ts, end: seg[i].ts))
        }
        // Trailing edge: last sample to run end.
        if p.end - seg[seg.count - 1].ts >= gapS { spans.append((start: seg[seg.count - 1].ts, end: p.end)) }
        return spans
    }

    /// Fractional off-wrist coverage of a candidate run [p.start, p.end] in [0, 1] (#500).
    /// Design credited to j0b-dev's #504 analysis: instead of a binary drop on ANY HR gap or ANY single
    /// WRIST_OFF blip, we measure how much of the run is off-wrist and let the caller drop it only past
    /// `maxOffWristSleepFraction`. Coverage = (length of the UNION of) the HR-gap spans (`offWristHRGapSpans`)
    /// AND the supplied WRIST_OFF→WRIST_ON `wristOff` intervals, clipped to the run, divided by duration.
    /// Unioning avoids double-counting overlapping gap+event time. A real night with a small (<50%)
    /// off-wrist tail scores low and is kept; an all-day desk strap (HR-gap ≈100%, no events needed) or a
    /// session genuinely spent off the wrist scores high and is dropped.
    static func offWristFraction(_ p: Period, hr: [HRSample], wristOff: [(start: Int, end: Int)]) -> Double {
        let dur = p.end - p.start
        if dur <= 0 { return 0 }
        // Collect every off-wrist span, clipped to the run: HR-gap proxy spans + explicit wrist-off events.
        var spans = offWristHRGapSpans(p, hr: hr)
        for w in wristOff {
            let s = max(w.start, p.start), e = min(w.end, p.end)
            if e > s { spans.append((start: s, end: e)) }
        }
        if spans.isEmpty { return 0 }
        // Union the spans so overlapping gap+event time is counted once, then sum the covered length.
        spans.sort { $0.start < $1.start }
        var covered = 0, curStart = spans[0].start, curEnd = spans[0].end
        for sp in spans.dropFirst() {
            if sp.start <= curEnd {
                curEnd = max(curEnd, sp.end)              // overlapping/adjacent → extend
            } else {
                covered += curEnd - curStart             // disjoint → bank the run
                curStart = sp.start; curEnd = sp.end
            }
        }
        covered += curEnd - curStart
        return Double(covered) / Double(dur)
    }

    // MARK: - detectSleep (public)

    /// Detect sleep sessions from biometric streams. Empty/absent gravity → [].
    /// Gravity-only input degrades gracefully (HR/RR/resp refinements skipped).
    ///
    /// `tzOffsetSeconds` is the wall-clock UTC offset (TimeZone.current.secondsFromGMT)
    /// used ONLY to place each window's center on a LOCAL clock for the daytime
    /// false-sleep guard (#90). It defaults to 0 so the pure function and its tests stay
    /// UTC; the live call site (IntelligenceEngine) passes the device's real offset.
    /// `wristOff` is an optional list of off-wrist `[start, end)` intervals (unix seconds), paired from
    /// the strap's WRIST_OFF/WRIST_ON events by `AnalyticsEngine.offWristIntervals`. When the call site
    /// has them (IntelligenceEngine reads `store.events`), they sharpen the always-on HR-gap off-wrist
    /// backstop: a candidate run is dropped when its off-wrist coverage (HR-gap spans UNION these
    /// intervals) reaches `maxOffWristSleepFraction` of its duration — the FRACTIONAL rule from #504, so
    /// a real night with a short off-wrist tail survives (#500). Defaults to empty (HR-gap proxy only),
    /// so the pure function and its tests stay event-free.
    /// `bandSleepState` is the strap's OWN persisted v18 BAND sleep_state per timestamp (Interpreter's
    /// `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up), used ONLY to CONSUME-confirm a borderline H7 morning
    /// re-onset (#531): a daytime block the strap itself scored predominantly "asleep" is KEPT even on a
    /// borderline HR dip. Default empty keeps pure-function callers/tests free of it; IntelligenceEngine
    /// passes the night window's persisted band state. It can only RESCUE a real-sleep block, never fabricate.
    /// `useSleepStagerV2` (7.0.0; default ON since #277/#351): which recipe stages an accepted night — the cardiorespiratory
    /// `SleepStagerV2.stageSession` when true, V1's `stageSession` when false. DETECTION is unchanged
    /// (same accepted windows); only the per-epoch hypnogram differs.
    ///
    /// THE TWO DEFAULTS ARE NOT THE SAME, and reading only the signature gets this backwards. This
    /// PARAMETER defaults false so pure-function callers and the frozen-golden tests stay byte-identical.
    /// The SHIPPED app never takes that default: the live call site threads
    /// `PuffinExperiment.experimentalSleepV2Enabled`, which is **default ON** (V2 was promoted over V1 in
    /// #277 and extended to every strap family in #351), so a normal user's nights are staged by **V2**.
    /// `= false` here describes the library's contract with its callers, not the product's behaviour.
    /// `sleepHRBaseline` (motion-corroborated wake, directive b): the wearer's PERSONALISED overnight HR band
    /// (`adaptiveOvernightHRBaseline`), used by `confirmSleepWithHR` in place of the day-median so a supplement /
    /// fitness era self-calibrates the sleep band. Default nil keeps the day-median (byte-identical to before);
    /// the live call site can thread a value derived from the trailing sleep history.
    public static func detectSleep(hr: [HRSample] = [],
                                   rr: [RRInterval] = [],
                                   resp: [RespSample] = [],
                                   gravity: [GravitySample],
                                   tzOffsetSeconds: Int = 0,
                                   wristOff: [(start: Int, end: Int)] = [],
                                   bandSleepState: [(ts: Int, state: Int)] = [],
                                   useSleepStagerV2: Bool = false,
                                   sleepHRBaseline: Double? = nil,
                                   traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        // Sleep & Rest test mode only: when a trace is requested we MUST run the live ladder, not a
        // memoized result, so each gate verdict is emitted for THIS night. The trace is side-effect-
        // only and never changes the sessions, so a traced and an untraced call return the identical
        // array. With no sink (the default, every existing call site) the path below is byte-identical
        // to before: same memo key, same compute.
        if let traceSink {
            return detectSleepUncached(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                       tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                       bandSleepState: bandSleepState, useSleepStagerV2: useSleepStagerV2,
                                       sleepHRBaseline: sleepHRBaseline, traceSink: traceSink)
        }
        // v7.0.2 perf (#707): the single heaviest analytics call — it sorts the dense full-day gravity
        // stream (~tens of thousands of samples for a worn day), builds the gravity-delta/still spine, and
        // stages every accepted run. The post-sync scoring loop calls it once PER DAY across the window, and
        // a re-run with the SAME raw (an idempotent re-pass, or a later sync that didn't touch this day's
        // streams) re-does all of it for an identical `[SleepSession]`. Memoize on a FULL key: every input
        // that steers detection or staging — the four streams, the tz offset (daytime-guard + onset band),
        // the off-wrist intervals (#500 backstop), the persisted band state (#531 H8), and the V2 toggle (an
        // edit to any re-keys to a fresh compute). Result-only + bounded; the raw arrays are never retained.
        // Match Android's raw-axis semantics: mix x/y/z IEEE-754 bits in order, never their lossy sum.
        let key = DetectKey(
            grav: StreamFingerprint.of(gravity, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            }),
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            resp: StreamFingerprint.of(resp, ts: { $0.ts }, quant: { $0.raw }),
            tz: tzOffsetSeconds,
            wristOff: StreamFingerprint.of(wristOff, ts: { $0.start }, quant: { $0.end }),
            band: StreamFingerprint.of(bandSleepState, ts: { $0.ts }, quant: { $0.state }),
            v2: useSleepStagerV2,
            sleepHRBaseline: sleepHRBaseline)
        return detectSleepCache.value(key) {
            detectSleepUncached(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                bandSleepState: bandSleepState, useSleepStagerV2: useSleepStagerV2,
                                sleepHRBaseline: sleepHRBaseline, traceSink: nil)
        }
    }

    private struct DetectKey: Hashable {
        let grav: StreamFingerprint; let hr: StreamFingerprint
        let rr: StreamFingerprint; let resp: StreamFingerprint
        let tz: Int
        let wristOff: StreamFingerprint; let band: StreamFingerprint
        let v2: Bool
        let sleepHRBaseline: Double?
    }
    /// ≈ the number of distinct days in a scoring window; FIFO-evicted, holds only small session arrays.
    private static let detectSleepCache = AnalyticsMemoCache<DetectKey, [SleepSession]>(capacity: 40)

    /// The unchanged detection+staging pipeline; split out verbatim so the public entry memoizes in front.
    private static func detectSleepUncached(hr: [HRSample],
                                            rr: [RRInterval],
                                            resp: [RespSample],
                                            gravity: [GravitySample],
                                            tzOffsetSeconds: Int,
                                            wristOff: [(start: Int, end: Int)],
                                            bandSleepState: [(ts: Int, state: Int)],
                                            useSleepStagerV2: Bool,
                                            sleepHRBaseline: Double? = nil,
                                            traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        if grav.count < 2 { return [] }

        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sortedByTsStable()   // stable: keeps #823 emission order within a second
        let respS = resp.sorted { $0.ts < $1.ts }

        let baseline = hrBaseline(hrS)
        // Sparse-gravity gate (#308): an un-unlocked WHOOP 5.0 backfills mostly v18/v26 records
        // where gravity is clumped (~25% coverage), so the gravity-only spine fragments the night.
        // ONLY when sparse do the three robustness branches engage; a dense 4.0 night is `false`
        // here and follows the exact original path (byte-identical).
        let sparse = isGravitySparse(grav, hr: hrS)

        let deltas = gravityDeltas(grav)
        let flags = classifyStill(grav, deltas)
        var runs = buildRuns(grav, flags, sparse: sparse, hr: hrS, baseline: baseline)
        runs = mergePeriods(runs)
        // Re-stitch sleep runs fragmented by pure gravity dropouts (sparse only) before minSleepMin.
        let runsBeforeBridge = traceSink == nil ? 0 : runs.filter { $0.stage == "sleep" }.count
        // #737: capture the per-pair reasons BEFORE the merge mutates `runs`, so a bridge that changed
        // nothing still says why (gapTooLong / hrOutOfBand / overlap) instead of only before==after.
        let bridgeResult = bridgeSparseSleepTraced(runs, sparse: sparse, hr: hrS, baseline: baseline)
        let bridgeAttempts = bridgeResult.1
        runs = bridgeResult.0
        // Sleep & Rest test mode (E3): record the sparse-gravity bridge result, so a sparse 5.0 night
        // rescued from fragmentation is visible. Only emitted when gravity is sparse (the only case the
        // bridge can act) and only when tracing. Side-effect-only.
        if let traceSink, sparse {
            let runsAfterBridge = runs.filter { $0.stage == "sleep" }.count
            traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0,
                verdict: runsAfterBridge < runsBeforeBridge ? .kept : .dropped, gate: "sparseBridge",
                detail: "sparse=true gapMin=\(sparseBridgeGapMin) runsBefore=\(runsBeforeBridge) runsAfter=\(runsAfterBridge)"))
            // #737: one line per pair the bridge CONSIDERED, each naming what it decided.
            //
            // #1657 changed what an empty list MEANS, so the wording changed with it. It used to mean
            // "the fragments are separated by active runs", because such a pair could never be reached —
            // that absence was the diagnosis. A single short active run is now a considered pair, so an
            // empty list can only mean there was no candidate at all: one sleep run, or fragments split
            // by two or more consecutive active runs. Leaving the old text would have pointed the next
            // reader at a cause that had just been removed.
            if bridgeAttempts.isEmpty {
                traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0, verdict: .dropped,
                    gate: "sparseBridge",
                    detail: "no candidate pairs (one sleep run, or fragments split by consecutive active runs)"))
            }
            for (i, a) in bridgeAttempts.enumerated() {
                traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0,
                    verdict: a.bridged ? .kept : .dropped, gate: "sparseBridgePair",
                    detail: "pair=\(i) gapMin=\(a.gapMin) activeMin=\(a.activeMin) "
                        + "hrInSleepBand=\(a.hrInSleepBand) reason=\(a.reason)"))
            }
        }

        let minSleepS = minSleepMin * 60

        var sessions: [SleepSession] = []
        // Continuous-sleep chain tracking so a real overnight sleep that runs PAST the daytime-band
        // start (a late wake, or a brief morning stir then back to sleep that leaves the tail as its
        // own daytime-centered run) is NOT mistaken for an isolated daytime nap and rejected — which
        // truncated the displayed wake time to ~late morning. A daytime run skips the nap guard ONLY
        // when it directly continues (≤ nightContinuationGap) a chain that BEGAN overnight; isolated
        // daytime stillness (hours after waking) still faces the full guard.
        // Reimplemented from @vulnix0x4's PR #353.
        let continuationGapS = nightContinuationGapMin * 60
        var chainPrevEnd: Int? = nil       // end of the last accepted sleep run
        var chainFromOvernight = false     // did the current contiguous chain begin overnight?
        // Sleep & Rest test mode (E2): each candidate sleep run emits ONE verdict line naming the gate
        // that kept or dropped it. The decisions below are byte-identical to the untraced path; the
        // `traceSink?(...)` calls are the only addition and never alter `sessions`. `runIndex` counts
        // only sleep-stage runs so the trace numbers match the candidate ordinal.
        var runIndex = -1
        // #737 follow-up: counters for the one-line detection summary emitted before `return` (below).
        // Trace-only — never read back into `sessions`, so the untraced path stays byte-identical. They
        // make the "slept 8h, app shows 1h" shape legible at a glance: a big detectedSpan with most runs
        // dropped by the 60-min gate is the fragmentation signature.
        var sleepRunsSeen = 0
        var minSleepDrops = 0
        var firstSleepStart = Int.max
        var lastSleepEnd = 0
        for p in runs {
            if p.stage != "sleep" { continue }
            runIndex += 1
            sleepRunsSeen += 1
            firstSleepStart = min(firstSleepStart, p.start)
            lastSleepEnd = max(lastSleepEnd, p.end)
            let spanMin = (p.end - p.start) / 60
            if (p.end - p.start) <= minSleepS {
                minSleepDrops += 1
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "minSleepMin",
                    detail: "spanMin=\(spanMin) minSleepMin=\(minSleepMin)"))
                continue
            }
            // H4 physiological in-bed span cap (#547/#531/#509 tail): a single assembled main-sleep run
            // longer than ~16 h is a bad-clock artefact (a frozen still stretch banked under a stale/wrong
            // clock), not a real night. Drop it rather than report (or truncate to) a 12 h+ "sleep" — an
            // over-long block can't be trusted to assert a span at all, and truncating would fabricate a
            // wake time. Checked before staging so the artefact never reaches the aggregate.
            if (p.end - p.start) > maxMainSleepSpanS {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "maxMainSleepSpanS",
                    detail: "spanMin=\(spanMin) maxMainSleepSpanMin=\(maxMainSleepSpanS / 60)"))
                continue
            }
            if !confirmSleepWithHR(p, hr: hrS, baseline: baseline, grav: grav, sleepHRBaseline: sleepHRBaseline) {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "hrConfirm",
                    detail: "hrSleepBaselineMult=\(hrSleepBaselineMult) baseline=\(baseline.map { Int($0) } ?? -1)"))
                continue
            }
            // Off-wrist backstop (#500), FRACTIONAL rule (design credited to j0b-dev's #504 analysis):
            // a wrist-OFF stretch is still gravity with no HR, so it slips past both the gravity spine
            // and the daytime guard's "missing data" path. Measure off-wrist COVERAGE — the union of the
            // run's long HR-coverage gaps (the must-have proxy) and any WRIST_OFF→WRIST_ON intervals
            // overlapping it — and drop the run only when that reaches maxOffWristSleepFraction of its
            // duration. This no longer nukes a real night that over-extends into a SHORT (<50%) off-wrist
            // morning tail, or that holds a single stray WRIST_OFF blip, while an all-day desk strap
            // (≈100% gap) is still dropped. Checked BEFORE the night-tail exemption: off-wrist time is
            // off-wrist day or night and must NOT ride a continuation chain. It does NOT re-anchor the
            // chain (the run is simply skipped).
            let offFrac = offWristFraction(p, hr: hrS, wristOff: wristOff)
            if offFrac >= maxOffWristSleepFraction {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "offWrist",
                    detail: "offWristFrac=\(round2(offFrac)) max=\(maxOffWristSleepFraction)"))
                continue
            }
            // Daytime false-sleep guard (#90): a window centered in the local daytime band
            // must clear a stricter bar (≥daytimeMinSleepMin AND a real resting-HR dip).
            // Overnight windows skip this entirely. restingHR is computed here (reused below).
            let resting = sessionRestingHR(start: p.start, end: p.end, hr: hrS)
            let continuesChain = chainPrevEnd.map { p.start - $0 <= continuationGapS } ?? false
            let isNightTail = continuesChain && chainFromOvernight   // the night's tail, not a nap
            // H7 (#531): when the prior accepted chain BEGAN overnight, its wake (`chainPrevEnd`) anchors the
            // morning-stillness window. A daytime block beginning within it that is NOT a night-tail must
            // clear the STRONGER re-onset bar — killing the 9 am phantom nap of residual post-wake stillness
            // while keeping a genuine second sleep. Outside the window the guard is the ordinary daytime bar.
            let morningWakeEnd = chainFromOvernight ? chainPrevEnd : nil
            let isDaytime = isDaytimeCenter(p, tzOffsetSeconds: tzOffsetSeconds)
            // Evaluate the morning-stillness guard ONLY when the run is daytime-centered, preserving the
            // original short-circuit (overnight runs never call it). The boolean used to `continue` below
            // is identical to the original combined condition.
            let passesMorning = isDaytime
                ? passesMorningStillnessGuard(p, restingHR: resting, baseline: baseline,
                                              morningWakeEnd: morningWakeEnd,
                                              bandSleepState: bandSleepState)
                : true
            if isDaytime, !passesMorning, !isNightTail {
                let gateName = (morningWakeEnd != nil) ? "morningStillness" : "daytimeGuard"
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: gateName,
                    detail: "daytime=true restingHR=\(resting ?? -1) baseline=\(baseline.map { Int($0) } ?? -1) nightTail=false"))
                continue
            }
            let rawStages = useSleepStagerV2
                ? SleepStagerV2.stageSession(start: p.start, end: p.end, grav: grav,
                                             hr: hrS, rr: rrS, resp: respS)
                : stageSession(start: p.start, end: p.end, grav: grav,
                               hr: hrS, rr: rrS, resp: respS)
            // Band sleep_state WAKE-veto: recover INTERIOR false-wake epochs the strap's OWN band
            // (`bandSleepState`) scored "asleep". No-op when the band is absent (WHOOP 4.0) or the flag is
            // off; stager-agnostic (corrects whichever hypnogram V1/V2 produced). Efficiency below is then
            // computed on the corrected stages, so a night NOOP over-called wake on reports true efficiency.
            let stages = applyBandStateWakeVeto(rawStages, start: p.start, end: p.end,
                                                bandSleepState: bandSleepState)
            let eff = efficiency(start: p.start, end: p.end, stages: stages)
            let avgHrv = sessionAvgHRV(start: p.start, end: p.end, rr: rrS)
            sessions.append(SleepSession(start: p.start, end: p.end, efficiency: eff,
                                         stages: stages, restingHR: resting, avgHRV: avgHrv))
            traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                verdict: .kept, gate: "accepted",
                detail: "spanMin=\(spanMin) eff=\(round2(eff)) restingHR=\(resting ?? -1) daytime=\(isDaytime)"))
            // #1210 shadow: the band wake-veto is dormant (default-off), but its recovered-vs-reverse ratio
            // can only come from banded nights. When a band stream is present, compute what the veto WOULD
            // recover and trace it — OUTPUT-NEUTRAL: `stages`/`eff` persisted above are the flag-gated
            // (unchanged) values and nothing reads `shadowStages`. Guarded on `traceSink`, so it fires ONLY
            // while a diagnostic is collecting (zero production cost). Retire once the flip (#1210) lands.
            if let traceSink, !bandStateWakeVetoEnabled, !bandSleepState.isEmpty {
                // `cutoffTs: 0` on purpose: the shadow measures the FULL veto potential across EVERY banded
                // night (history included) to build the validation distribution, independent of whatever
                // new-nights cutoff the eventual flip uses.
                let shadowStages = applyBandStateWakeVeto(rawStages, start: p.start, end: p.end,
                                                          bandSleepState: bandSleepState,
                                                          enabled: true, cutoffTs: 0)
                let shadowEff = efficiency(start: p.start, end: p.end, stages: shadowStages)
                let recoveredMin = (shadowEff - eff) * Double(p.end - p.start) / 60.0
                if recoveredMin >= 1.0 {
                    traceSink(bandVetoShadowLine(startTs: p.start, recoveredMin: recoveredMin,
                                                 rawEff: eff, shadowEff: shadowEff))
                }
            }
            // A run that does NOT continue the chain re-anchors it on this run's onset.
            if !continuesChain { chainFromOvernight = isOvernightOnset(p.start, tzOffsetSeconds: tzOffsetSeconds) }
            chainPrevEnd = p.end
        }
        sessions.sort { $0.start < $1.start }
        // #737 follow-up: one glanceable line summarising the whole detection pass. A large
        // `detectedSpanMin` with most runs `droppedMinSleep` and a small `survivingSpanMin` is exactly
        // the "slept ~8h, only ~1h confirmed" fragmentation the field reports describe — this makes it
        // readable without hand-summing the per-run lines above. Trace-only.
        if let traceSink {
            let detectedSpanMin = lastSleepEnd > firstSleepStart ? (lastSleepEnd - firstSleepStart) / 60 : 0
            let survivingSpanMin = sessions.reduce(0) { $0 + ($1.end - $1.start) } / 60
            traceSink("sleep-detect summary: sleepRuns=\(sleepRunsSeen) droppedMinSleep=\(minSleepDrops) "
                + "kept=\(sessions.count) detectedSpanMin=\(detectedSpanMin) survivingSpanMin=\(survivingSpanMin) "
                + "sparse=\(sparse) grav=\(grav.count) hr=\(hrS.count)")
        }
        return sessions
    }

    /// asleep / in-bed in [0, 1]; asleep = in-bed − wake.
    static func efficiency(start: Int, end: Int, stages: [StageSegment]) -> Double {
        let inBed = Double(end - start)
        if inBed <= 0 { return 0 }
        let wake = stages.filter { SleepStageVocabulary.isWake($0.stage) }.reduce(0.0) { $0 + Double($1.end - $1.start) }
        let asleep = max(0.0, inBed - wake)
        return min(1.0, asleep / inBed)
    }

    // MARK: - Stage 1–3: staging over a 30 s epoch grid

    /// First persistent-sleep epoch (onset) and last sleep epoch (final wake).
    static func onsetAndFinalWake(_ ckFlags: [Bool]) -> (Int, Int) {
        let n = ckFlags.count
        if n == 0 { return (0, 0) }
        var onset: Int? = nil
        var run = 0
        for (i, s) in ckFlags.enumerated() {
            run = s ? run + 1 : 0
            if run >= onsetPersistEpochs { onset = i - onsetPersistEpochs + 1; break }
        }
        var final: Int? = nil
        for i in stride(from: n - 1, through: 0, by: -1) where ckFlags[i] { final = i; break }
        let o = onset ?? 0
        var f = final ?? (n - 1)
        if f < o { f = n - 1 }
        return (o, f)
    }

    /// Build a 30 s hypnogram for [start, end] and return StageSegments.
    /// Stage a FORCED window from raw streams (no boundary detection): the same per-epoch classifier
    /// the detection path uses, run over exactly `[start, end]`. The sleep-edit path calls this to
    /// re-derive real stages for a hand-corrected window — so extending a boundary recovers genuine
    /// stages from the sensor data instead of a fabricated "awake" block. (#318)
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // v7.0.2 perf (#707): stage each window AT MOST ONCE per (window, input-fingerprint). Both
        // `detectSleep` (per accepted run) and the sleep-edit restage call this with byte-identical streams
        // across post-sync passes / `body` re-evaluations; each call builds a fresh 30 s epoch grid +
        // per-epoch feature arrays before collapsing to a few `StageSegment`s. The key folds in the window
        // (an edit re-keys) and a strided fingerprint of every stream the V1 recipe READS (grav/hr/rr/resp —
        // resp IS consumed here via the epoch grid, unlike V2). Result-only, bounded, no raw arrays retained.
        let key = V1StageKey(
            start: start, end: end,
            grav: StreamFingerprint.of(grav, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            }),
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            resp: StreamFingerprint.of(resp, ts: { $0.ts }, quant: { $0.raw }))
        return stageSessionCache.value(key) {
            stageSessionUncached(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        }
    }

    private struct V1StageKey: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint
        let rr: StreamFingerprint; let resp: StreamFingerprint
    }
    private static let stageSessionCache = AnalyticsMemoCache<V1StageKey, [StageSegment]>(capacity: 32)

    /// Unchanged V1 staging recipe; split verbatim so the public entry memoizes in front of it.
    private static func stageSessionUncached(start: Int, end: Int, grav: [GravitySample],
                                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return [StageSegment(start: start, end: end, stage: "light")] }

        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }

        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return [StageSegment(start: start, end: end, stage: "light")] }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)

        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, features: feats,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)
        // Conservative fragment merge (#274): absorb sub-3-min stage flecks (the WHOOP 5/MG
        // sparse-motion artefact) so the hypnogram stops reading choppier than WHOOP's,
        // without erasing genuine multi-minute transitions. Display/scoring only — the
        // per-epoch detection above is unchanged.
        labels = mergeFragments(labels)

        // Pre-onset and post-final-wake epochs are not sleep → force wake.
        for i in 0..<labels.count where i < onsetIdx || i > finalWakeIdx { labels[i] = "wake" }

        // Merge consecutive same-stage epochs into segments tiling [start, end].
        var segments: [StageSegment] = []
        for (i, stage) in labels.enumerated() {
            let segStart = Int(grid.edges[i].rounded())
            let segEnd = Int(grid.edges[i + 1].rounded())
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        if !segments.isEmpty { segments[segments.count - 1].end = end }
        return segments
    }

    // MARK: - Per-epoch motion (H8 — persisted beside stagesJSON)

    /// The per-epoch MOTION magnitudes for a session window, on the SAME 30 s epoch grid as `stageSession`'s
    /// `stagesJSON` (one entry per epoch, in order). Each value is the epoch's summed |Δgravity| (the raw
    /// pre-rescale Cole–Kripke activity count) — the strap's own motion signal, banked so later passes and
    /// the UI can read per-epoch movement without re-reading the raw gravity stream. Returns `[]` when the
    /// window has too little gravity to grid (mirrors `stageSession`'s degenerate fallback), so the caller
    /// persists NULL (no fabricated zero series). Pure + deterministic; shares `buildEpochGrid` with staging
    /// so the grids align epoch-for-epoch. (H8)
    public static func sessionEpochMotion(start: Int, end: Int, grav: [GravitySample]) -> [Double] {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return [] }
        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }
        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: [], rr: [], resp: [])
        return grid.counts
    }

    /// #175: the strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up) gridded onto the SAME 30 s
    /// epoch grid `stagesJSON` / `sessionEpochMotion` use, so the caller can persist it via
    /// `WhoopStore.persistSessionSleepState` and the H7 re-onset CONFIRM guard can read it back as timestamped
    /// `(startTs + i*epochS, state)` samples. Returns EMPTY when the session carries no band-state samples
    /// (a WHOOP 4.0, or an unbanded window) — an absent signal stays absent, never a fabricated array. When
    /// present, each epoch takes the band's LAST reported state within its `[start+i·30, start+(i+1)·30)`
    /// window; an epoch with no sample of its own CARRIES FORWARD the previous epoch's state (band state is a
    /// step function). Leading epochs before the first sample take the first sample's state. The band code is
    /// carried VERBATIM — this never converts an unproven code into a derived stage; consumers decide meaning.
    public static func sessionEpochSleepState(start: Int, end: Int,
                                              sleepState: [(ts: Int, state: Int)]) -> [Int] {
        let seg = rowsBetween(sleepState, start: start, end: end) { $0.ts }.sorted { $0.ts < $1.ts }
        guard !seg.isEmpty, end > start else { return [] }
        let nEpochs = max(1, Int(ceil(Double(end - start) / epochS)))
        var out = [Int](repeating: seg[0].state, count: nEpochs)   // lead-in = first sample's state
        var last = seg[0].state
        var si = 0
        for i in 0..<nEpochs {
            let epochEnd = start + Int(Double(i + 1) * epochS)
            // Advance through every sample that falls in/at-or-before this epoch's window; the LAST one wins.
            while si < seg.count && seg[si].ts < epochEnd {
                last = seg[si].state
                si += 1
            }
            out[i] = last   // carry-forward when the epoch had no sample of its own
        }
        return out
    }

    // MARK: - Epoch grid

    struct EpochGrid {
        let start: Double
        let end: Double
        let edges: [Double]
        let counts: [Double]      // per-epoch summed |Δgravity| (raw, pre-rescale)
        let moveFrac: [Double]    // scale-robust per-epoch moving-sample fraction
        let hr: [Double]          // per-epoch mean HR (bpm) or NaN
        let rr: [[Double]]        // per-epoch RR intervals (ms)
        let resp: [[Double]]      // per-epoch raw respiration samples
        var nEpochs: Int { counts.count }
        func epochMid(_ i: Int) -> Double { edges[i] + epochS / 2.0 }
    }

    static func buildEpochGrid(start: Double, end: Double,
                               gravTimes: [Int], gravDeltas: [Double],
                               hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> EpochGrid {
        if end <= start {
            return EpochGrid(start: start, end: end, edges: [start], counts: [],
                             moveFrac: [], hr: [], rr: [], resp: [])
        }
        let nEpochs = max(1, Int(ceil((end - start) / epochS)))
        var edges = (0...nEpochs).map { start + Double($0) * epochS }
        edges[nEpochs] = max(edges[nEpochs], end)

        var counts = [Double](repeating: 0, count: nEpochs)
        var moveN = [Int](repeating: 0, count: nEpochs)
        var gravN = [Int](repeating: 0, count: nEpochs)
        var hrSum = [Double](repeating: 0, count: nEpochs)
        var hrCnt = [Int](repeating: 0, count: nEpochs)
        var rrBuckets = [[Double]](repeating: [], count: nEpochs)
        var respBuckets = [[Double]](repeating: [], count: nEpochs)

        func idx(_ ts: Double) -> Int? {
            if ts < start || ts >= end {
                if ts == end { return nEpochs - 1 }
                return nil
            }
            let i = Int((ts - start) / epochS)
            return min(i, nEpochs - 1)
        }

        for (t, d) in zip(gravTimes, gravDeltas) {
            guard let i = idx(Double(t)) else { continue }
            counts[i] += d
            gravN[i] += 1
            if d >= moveDeltaThresholdG { moveN[i] += 1 }
        }
        for r in hr {
            guard let i = idx(Double(r.ts)) else { continue }
            hrSum[i] += Double(r.bpm); hrCnt[i] += 1
        }
        for r in rr {
            guard let i = idx(Double(r.ts)) else { continue }
            rrBuckets[i].append(Double(r.rrMs))
        }
        for r in resp {
            guard let i = idx(Double(r.ts)) else { continue }
            respBuckets[i].append(Double(r.raw))
        }

        let hrMean = (0..<nEpochs).map { hrCnt[$0] > 0 ? hrSum[$0] / Double(hrCnt[$0]) : Double.nan }
        // No gravity coverage → 1.0 (treat as moving; conservative).
        let moveFrac = (0..<nEpochs).map { gravN[$0] > 0 ? Double(moveN[$0]) / Double(gravN[$0]) : 1.0 }

        return EpochGrid(start: start, end: end, edges: edges, counts: counts,
                         moveFrac: moveFrac, hr: hrMean, rr: rrBuckets, resp: respBuckets)
    }

    // MARK: - Cole–Kripke

    static func rescaleCounts(_ counts: [Double]) -> [Double] {
        counts.map { min($0 / ckCountDivisor, ckCountClip) }
    }

    static func coleKripke(_ rescaled: [Double]) -> [Bool] {
        let n = rescaled.count
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            var si = 0.0
            for (k, w) in ckWeights.enumerated() {
                let j = i - ckBack + k
                let a = (j >= 0 && j < n) ? rescaled[j] : 0.0
                si += w * a
            }
            si *= ckScale
            flags.append(si < 1.0)
        }
        return flags
    }

    // MARK: - Walch difference-of-Gaussians HR variability

    static func gaussianKernel(sigmaS: Double, dtS: Double = epochS) -> [Double] {
        let sigma = max(sigmaS / dtS, 1e-6)  // σ in epochs
        let radius = max(1, Int(ceil(3 * sigma)))
        var k = [Double]()
        for x in -radius...radius { k.append(exp(-0.5 * pow(Double(x) / sigma, 2))) }
        let sum = k.reduce(0, +)
        return k.map { $0 / sum }
    }

    /// Same-length convolution with reflect padding (edge-stable).
    static func convolveReflect(_ x: [Double], _ kernel: [Double]) -> [Double] {
        let r = kernel.count / 2
        // A signal shorter than the kernel radius can't be reflect-padded (the mirror reads x[r]
        // and x[x.count-2-i]) — return it unchanged rather than indexing out of bounds. In practice
        // the only caller is gated by the 60-min session floor, so this is defensive.
        if r == 0 || x.count <= r { return x }
        // Reflect padding: numpy 'reflect' mirrors WITHOUT repeating the edge sample.
        var padded = [Double]()
        padded.reserveCapacity(x.count + 2 * r)
        for i in 0..<r { padded.append(x[r - i]) }            // x[r], x[r-1], ... x[1]
        padded.append(contentsOf: x)
        for i in 0..<r { padded.append(x[x.count - 2 - i]) }  // x[n-2], x[n-3], ...
        // Valid convolution, then take the first x.count outputs.
        var out = [Double]()
        out.reserveCapacity(x.count)
        let m = kernel.count
        // np.convolve(padded, kernel, 'valid') has length padded.count - m + 1.
        for i in 0...(padded.count - m) {
            var acc = 0.0
            for j in 0..<m { acc += padded[i + j] * kernel[m - 1 - j] }
            out.append(acc)
            if out.count == x.count { break }
        }
        return out
    }

    /// DoG-filtered HR (σ1=120 s minus σ2=600 s). NaNs linearly interpolated first;
    /// all-NaN → zeros.
    static func dogHRVariability(_ hrPerEpoch: [Double]) -> [Double] {
        let n = hrPerEpoch.count
        if n == 0 { return [] }
        let maskIdx = (0..<n).filter { !hrPerEpoch[$0].isNaN }
        if maskIdx.isEmpty { return [Double](repeating: 0, count: n) }

        // Linear interpolation over the grid (numpy.interp semantics: clamp at edges).
        var filled = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if !hrPerEpoch[i].isNaN { filled[i] = hrPerEpoch[i]; continue }
            // find surrounding known points
            if i <= maskIdx.first! { filled[i] = hrPerEpoch[maskIdx.first!]; continue }
            if i >= maskIdx.last! { filled[i] = hrPerEpoch[maskIdx.last!]; continue }
            var lo = maskIdx.first!, hi = maskIdx.last!
            for m in maskIdx { if m <= i { lo = m } ; if m >= i { hi = m; break } }
            if hi == lo { filled[i] = hrPerEpoch[lo] }
            else {
                let frac = Double(i - lo) / Double(hi - lo)
                filled[i] = hrPerEpoch[lo] + frac * (hrPerEpoch[hi] - hrPerEpoch[lo])
            }
        }

        let k1 = gaussianKernel(sigmaS: hrDogSigma1S)
        let k2 = gaussianKernel(sigmaS: hrDogSigma2S)
        let g1 = convolveReflect(filled, k1)
        let g2 = convolveReflect(filled, k2)
        return (0..<n).map { g1[$0] - g2[$0] }
    }

    // MARK: - Respiration rate + RRV (raw 1 Hz)

    /// Estimate respiratory rate (breaths/min) and RRV (s) from a raw resp window.
    /// Detrend → peak-pick (≥2 s apart) → breath intervals (1.5–12 s) → rate =
    /// 60/median interval, RRV = std of intervals. (nan, nan) when too few samples.
    ///
    /// NOTE: faithful port of sleep_features.resp_rate_and_rrv (which the Python
    /// source derives without neurokit), using a simple local-maxima peak finder.
    static func respRateAndRRV(_ respRaw: [Double], dtS: Double = 1.0) -> (Double, Double) {
        let nan = Double.nan
        if respRaw.count < 8 { return (nan, nan) }
        let mean = respRaw.reduce(0, +) / Double(respRaw.count)
        let x = respRaw.map { $0 - mean }
        if x.allSatisfy({ abs($0) < 1e-12 }) { return (nan, nan) }

        let std = standardDeviation(x)
        if std <= 0 { return (nan, nan) }

        let minDistance = max(2, Int((2.0 / dtS).rounded()))
        let peaks = findPeaks(x, distance: minDistance, height: 0.0)
        if peaks.count < 3 { return (nan, nan) }

        var intervals: [Double] = []
        for i in 1..<peaks.count {
            let iv = Double(peaks[i] - peaks[i - 1]) * dtS
            if iv >= 1.5 && iv <= 12.0 { intervals.append(iv) }
        }
        if intervals.count < 2 { return (nan, nan) }
        let rate = 60.0 / HRVAnalyzer.median(intervals)
        let rrv = standardDeviation(intervals)  // population std (numpy default)
        return (rate, rrv)
    }

    /// Local-maxima peak finder mirroring scipy.find_peaks(distance, height):
    /// a sample is a peak if strictly greater than both neighbours and ≥ height;
    /// peaks closer than `distance` are resolved by keeping the taller.
    static func findPeaks(_ x: [Double], distance: Int, height: Double) -> [Int] {
        let n = x.count
        if n < 3 { return [] }
        var candidates: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i] > x[i - 1] && x[i] >= height {
                // handle flat plateaus: find right edge of the plateau
                var j = i
                while j + 1 < n && x[j + 1] == x[i] { j += 1 }
                if j + 1 < n && x[j + 1] < x[i] {
                    candidates.append((i + j) / 2)  // plateau midpoint
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        if distance <= 1 || candidates.isEmpty { return candidates }
        // Enforce minimum distance: greedily keep tallest, scipy-style. Tie-break on the lower
        // index so equal-height peaks resolve deterministically and identically to the Android
        // port's stable sort (Swift's sorted(by:) is not guaranteed stable).
        let byHeight = candidates.sorted { x[$0] != x[$1] ? x[$0] > x[$1] : $0 < $1 }
        var keep = [Bool](repeating: true, count: candidates.count)
        let indexOf = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1, $0) })
        for p in byHeight {
            guard let pi = indexOf[p], keep[pi] else { continue }
            for (qi, q) in candidates.enumerated() where qi != pi && keep[qi] {
                if abs(q - p) < distance { keep[qi] = false }
            }
        }
        return candidates.enumerated().filter { keep[$0.offset] }.map { $0.element }.sorted()
    }

    // MARK: - Respiration rate from R-R (RSA) — WHOOP5 on-wire path

    /// RSA tachogram resample rate (Hz). 4 Hz is the standard HRV resample grid.
    static let rsaResampleHz = 4.0

    /// Moving-mean detrend window for the RSA tachogram (seconds).
    static let rsaDetrendWindowS = 8.0

    /// Minimum spacing between breath peaks on the tachogram (seconds) → ≤24 bpm.
    static let rsaMinPeakDistanceS = 2.5

    /// Per-window length for the per-window rate estimate (seconds).
    static let rsaWindowS = 300.0

    /// #977: wall-clock seconds a beat-to-beat step may exceed its own RR before the series is treated
    /// as SPLICED there. `ts` is whole seconds, so a 1 s discrepancy is quantisation, not a gap; the
    /// blocks that prompted this were 30-45 s. PROVISIONAL, like `coveragePlausibleCeiling` - wide
    /// enough that only an unambiguous dropout trips it, and deliberately not tuned to a corpus.
    static let rsaGapToleranceS = 3.0

    /// Physiologic breath-interval band (seconds): 0.1–0.4 Hz = 6–24 breaths/min.
    static let rsaMinBreathIntervalS = 2.5   // 24 bpm
    static let rsaMaxBreathIntervalS = 10.0  // 6 bpm

    /// THE canonical plausible sleeping-respiratory-rate band (bpm). The RSA peak-pick below can
    /// yield 6–8 bpm at its noise floor, but every consumer (illness/readiness gates) only acts on
    /// 8–25 — so respRateFromRR clamps its output to this band (NaN outside it) and the stored
    /// value can never disagree with what's acted on. Mirrors Android SleepStager.
    public static let respPlausibleRangeBpm: ClosedRange<Double> = 8.0...25.0

    /// APPROXIMATE respiratory rate (breaths/min) from the R-R interval stream via
    /// respiratory sinus arrhythmia (RSA), for use when no raw resp ADC channel is
    /// available (WHOOP5 v18 wire is RR-only; resp ADC is WHOOP4 / cloud-only).
    ///
    /// This is an ON-DEVICE ESTIMATE, NOT a cloud/clinical respiration measurement.
    /// It recovers the breathing-modulation of beat-to-beat timing, which tracks but
    /// does not equal a chest-band / capnography rate.
    ///
    /// Pipeline (per matched in-bed session [start, end], unix SECONDS):
    ///   1. Restrict RR ROWS to ts in [start, end] and apply the same range test
    ///      HRVAnalyzer.rangeFilter applies, keeping the rows so `ts` survives (#977).
    ///   2. Reconstruct beat times by cumulatively summing the kept RR intervals
    ///      from the first in-bed beat, yielding an (irregular) tachogram, and note
    ///      where the wall clock outran the beats (#977) — the cumulative sum cannot
    ///      represent a dropout, so those points are splices, not elapsed time.
    ///   3. Resample the tachogram onto a uniform ~4 Hz grid by linear interpolation.
    ///   4. Detrend: subtract a centered moving mean (rsaDetrendWindowS).
    ///   5. Per ~5-min window, SKIPPING any window containing a splice: findPeaks
    ///      (min distance rsaMinPeakDistanceS) on the detrended grid, keep peak-to-peak
    ///      intervals in the 6–24 bpm band, rate = 60 / median(intervals). Take the
    ///      median across windows.
    ///
    /// Known bound on the splice skip (#977): step 4's centered mean spans ±rsaDetrendWindowS/2, so a
    /// splice just inside one window's edge leaves ~4 s of contaminated samples at the neighbouring
    /// window's edge. That window is KEPT deliberately — discarding five minutes to avoid four seconds
    /// costs far more data than it saves, and both medians (over intervals, then over windows) dilute a
    /// single spurious peak among a five-minute window's worth.
    /// Returns NaN when too few intervals survive (honest no-data).
    static func respRateFromRR(_ rr: [RRInterval], start: Int, end: Int) -> Double {
        let nan = Double.nan
        if end <= start { return nan }

        // 1. In-bed RR rows in chronological order, range-filtered. STABLE sort: step 2 reconstructs
        // beat times by cumulative sum, so the order of a second's beats moves every subsequent beat
        // time and with it the RSA estimate. Kotlin's twin uses sortedBy, stable by contract. (#823)
        //
        // #977: the ROWS are kept, not just their values, because `ts` is the only signal that a beat is
        // missing. Beats lost before storage never enter the array, so contiguity derived from rejection
        // (cleanRRGapAware) cannot see them - it takes only [Double] and has no clock. Filtering the rows
        // by the same predicate `HRVAnalyzer.rangeFilter` applies keeps the surviving VALUES identical
        // (it is an order-preserving range test), which RespRateGapAwareTests pins.
        let inBedRows = rr.filter { $0.ts >= start && $0.ts <= end }
            .sortedByTsStable()
            .filter { Double($0.rrMs) >= HRVAnalyzer.rrMinMs && Double($0.rrMs) <= HRVAnalyzer.rrMaxMs }

        // Beat-accuracy gate (#882/#883): RSA needs per-beat-accurate TIMING - each row's wall-clock gap
        // must be ≈ its own R-R value. A BANKED stream (an Oura overnight IBI stamps a whole record of
        // intervals on one coarse ring-time) fails this, and the estimate it produces is not physiology;
        // return NaN instead. Beat-accurate callers (WHOOP R-R, the synthetic RSA fixtures) measure ~100%
        // and pass unchanged. Needs a few beats to judge; below that the count gate below handles it.
        //
        // Shares HRVAnalyzer's ONE definition of the judgement (#1108) rather than keeping a second copy:
        // "is each stored interval a real beat-to-beat measurement?" is the same question SDNN asks, and
        // one boundary deserves one set of constants. `rangeFilter` has already run, so an out-of-range
        // R-R cannot fail the accuracy test spuriously.
        //
        // WHAT THIS ACTUALLY CATCHES, measured (2026-08-07, two Oura nights, 31,460 and 30,754 in-bed
        // beats, fraction 0.0246 / 0.0235): NOT a corrupted time AXIS - the ring's records tile the night,
        // sum(R-R) over wall span is 1.030 / 1.008, so beat-time reconstructs the night to 1-3%. What is
        // unusable is the interval VALUES: the ring decomposes each ~6.6 s record into ~6 intervals whose
        // SUM is right to ~1% while the individual values are not beat-to-beat measurements (the same
        // decomposition documented on `HRVAnalyzer.beatValuesAreTrustworthy`). RSA reads the beat-to-beat
        // variation, so it has nothing to read, and the peak-picker returns its own floor: on both nights
        // the ungated estimate is 13.33 bpm, and SHUFFLING or REVERSING the night's R-R values returns the
        // SAME 13.3333 to four decimals. It is a plausible-looking number carrying zero information -
        // squarely inside `respPlausibleRangeBpm`, so the range clamp below never sees it. That is why the
        // gate is on BANKED-ness rather than on the output value.
        //
        // DISTINCT FROM #977's splice skip below, and BOTH are needed - they catch opposite banking
        // GEOMETRIES. #977 catches banking that TILES time (the real ring: a ~7 s record boundary against a
        // ~1.1 s interval reads as a splice, and on those two nights it independently discards 113/113 and
        // 114/114 windows). This catches banking that COMPRESSES time - `testRespRateFromRRBatchedTimestamps`
        // stamps 6 beats per single second, so no gap ever exceeds `rsaGapToleranceS` and the splice skip
        // never fires. Neither subsumes the other; a firmware that changes its record period moves a stream
        // from one geometry to the other without warning.
        if inBedRows.count >= 30 {
            let fraction = HRVAnalyzer.beatAccurateFraction(tsSec: inBedRows.map { $0.ts },
                                                            rrMs: inBedRows.map { Double($0.rrMs) })
            if !HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: fraction) { return nan }
        }

        let filtered = inBedRows.map { Double($0.rrMs) }
        if filtered.count < 30 { return nan }  // need enough beats for any RSA estimate

        // 2. Reconstruct beat times (seconds from session start) by cumulative sum.
        // #977: a dropout is where the WALL CLOCK outran the beat - ts jumps 30-45 s while the RR only
        // accounts for ~1 s. The cumulative sum cannot represent that, so it stitches the two sides
        // together and the tachogram gets a discontinuity the peak-picker reads as breathing. Record the
        // beat-time of each splice here; step 5 drops the windows containing one. Beat times are NOT
        // shifted by the gap: within a run the relative timing is right, and that is all a kept window uses.
        //
        // This fires on a beat REJECTED just above too, not only one lost before storage: the range
        // test drops out-of-range intervals, so `ts` steps across them exactly as it does across a
        // dropout. That is the intent - both genuinely splice the tachogram, which is the same reason
        // #204/#195 made RMSSD skip differences across a removed beat - but it does mean a night with
        // heavy ectopic rejection now loses windows it used to keep.
        var beatTimes = [Double](repeating: 0, count: filtered.count)
        var spliceAtS: [Double] = []
        var acc = 0.0
        for i in filtered.indices {
            if i > 0 {
                let wallStepS = Double(inBedRows[i].ts - inBedRows[i - 1].ts)
                if wallStepS - filtered[i] / 1000.0 > rsaGapToleranceS { spliceAtS.append(acc) }
            }
            acc += filtered[i] / 1000.0
            beatTimes[i] = acc
        }
        let totalSpanS = beatTimes[beatTimes.count - 1]
        if totalSpanS < rsaWindowS / 2.0 { return nan }  // < ~2.5 min of beats

        // 3. Resample onto a uniform grid by linear interpolation.
        let dt = 1.0 / rsaResampleHz
        let nGrid = Int(totalSpanS / dt) + 1
        if nGrid < 8 { return nan }
        var grid = [Double](repeating: 0, count: nGrid)
        var seg = 0
        for g in 0..<nGrid {
            let t = Double(g) * dt
            // advance segment so beatTimes[seg] <= t <= beatTimes[seg+1]
            while seg < beatTimes.count - 2 && beatTimes[seg + 1] < t { seg += 1 }
            let t0 = beatTimes[seg]
            let t1 = beatTimes[seg + 1]
            let v0 = filtered[seg]
            let v1 = filtered[seg + 1]
            grid[g] = t1 <= t0 ? v0 : v0 + min(max((t - t0) / (t1 - t0), 0), 1) * (v1 - v0)
        }

        // 4. Detrend: subtract a centered moving mean (removes slow LF/baseline drift).
        let halfW = max(1, Int((rsaDetrendWindowS * rsaResampleHz / 2.0).rounded()))
        var detrended = [Double](repeating: 0, count: nGrid)
        for i in 0..<nGrid {
            let lo = max(0, i - halfW)
            let hi = min(nGrid - 1, i + halfW)
            var sum = 0.0
            for j in lo...hi { sum += grid[j] }
            detrended[i] = grid[i] - sum / Double(hi - lo + 1)
        }
        if standardDeviation(detrended) <= 1e-9 { return nan }  // flat → no RSA

        // 5. Per ~5-min window peak-pick → 60/median(breath interval); median across.
        let spliceGrid = spliceAtS.map { Int($0 / dt) }
        let minDistSamples = max(2, Int((rsaMinPeakDistanceS * rsaResampleHz).rounded()))
        let windowSamples = max(minDistSamples * 3, Int((rsaWindowS * rsaResampleHz).rounded()))
        var perWindowRates: [Double] = []
        var w = 0
        while w < nGrid {
            let wEnd = min(nGrid, w + windowSamples)
            // #977: a window straddling a splice is measuring a discontinuity, not a breath. Dropping it
            // costs one window; keeping it puts a fabricated interval into the median. All windows spliced
            // leaves perWindowRates empty and the function returns NaN, which is the honest answer.
            let spliced = spliceGrid.contains { $0 >= w && $0 < wEnd }
            if !spliced && wEnd - w >= minDistSamples * 3 {
                let winSeg = Array(detrended[w..<wEnd])
                // findPeaks with height = 0.0 selects the positive RSA peaks (one per
                // breath) on the zero-mean detrended tachogram.
                let peaks = findPeaks(winSeg, distance: minDistSamples, height: 0.0)
                if peaks.count >= 3 {
                    var intervals: [Double] = []
                    for i in 1..<peaks.count {
                        let ivS = Double(peaks[i] - peaks[i - 1]) * dt
                        if ivS >= rsaMinBreathIntervalS && ivS <= rsaMaxBreathIntervalS {
                            intervals.append(ivS)
                        }
                    }
                    if intervals.count >= 2 {
                        let med = HRVAnalyzer.median(intervals)
                        if med > 0.0 { perWindowRates.append(60.0 / med) }
                    }
                }
            }
            w += windowSamples
        }
        if perWindowRates.isEmpty { return nan }
        // Reject estimates outside the canonical consumer band (NaN = "no usable estimate") so the
        // persisted value never silently disagrees with the illness/readiness plausibility gate.
        let median = HRVAnalyzer.median(perWindowRates)
        return respPlausibleRangeBpm.contains(median) ? median : nan
    }

    // MARK: - Per-epoch features

    struct EpochFeatures {
        let index: Int
        let midTs: Double
        let count: Double      // rescaled Cole–Kripke activity count
        let moveFrac: Double
        let ckSleep: Bool
        let hr: Double         // mean HR over the feature window
        let hrVar: Double      // Walch DoG-HR windowed std
        let rmssd: Double      // ms
        let sdnn: Double       // ms
        let respRate: Double   // breaths/min
        let rrv: Double        // respiratory-rate variability (s)
        let clock: Double      // normalized time since onset, 0..1
    }

    static func extractFeatures(grid: EpochGrid, ckFlags: [Bool], dogHR: [Double],
                                onsetIdx: Int, finalWakeIdx: Int) -> [EpochFeatures] {
        let n = grid.nEpochs
        let rescaled = rescaleCounts(grid.counts)
        let halfW = Int((featureWindowS / epochS / 2).rounded())
        let span = Double(max(1, finalWakeIdx - onsetIdx))

        var feats: [EpochFeatures] = []
        feats.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)

            let winHR = (lo..<hi).map { grid.hr[$0] }.filter { !$0.isNaN }
            let hrMean = winHR.isEmpty ? Double.nan : winHR.reduce(0, +) / Double(winHR.count)

            let winDog = (lo..<hi).map { dogHR.isEmpty ? 0.0 : dogHR[$0] }
            let hrVar = winDog.count >= 2 ? standardDeviation(winDog) : Double.nan

            // RMSSD/SDNN over the pooled RR window (range-filtered, like the
            // Python per-epoch hrv_from_rr which uses RAW range-filtered RR).
            var winRR: [Double] = []
            for j in lo..<hi { winRR.append(contentsOf: grid.rr[j]) }
            let filteredRR = HRVAnalyzer.rangeFilter(winRR)
            let rmssd = filteredRR.count >= 5 ? (HRVAnalyzer.rmssdRaw(filteredRR) ?? Double.nan) : Double.nan
            let sdnn = filteredRR.count >= 5 ? (HRVAnalyzer.sdnnRaw(filteredRR) ?? Double.nan) : Double.nan

            var winResp: [Double] = []
            for j in lo..<hi { winResp.append(contentsOf: grid.resp[j]) }
            let (respRate, rrv) = respRateAndRRV(winResp)

            let clock = min(1.0, max(0.0, Double(i - onsetIdx) / span))

            feats.append(EpochFeatures(
                index: i, midTs: grid.epochMid(i), count: rescaled[i],
                moveFrac: grid.moveFrac[i],
                ckSleep: i < ckFlags.count ? ckFlags[i] : true,
                hr: hrMean, hrVar: hrVar, rmssd: rmssd, sdnn: sdnn,
                respRate: respRate, rrv: rrv, clock: clock))
        }
        return feats
    }

    // MARK: - Percentile helper

    /// numpy-style linear-interpolated percentile over finite values; nil if none.
    static func percentile(_ values: [Double], _ pct: Double) -> Double? {
        let vals = values.filter { $0.isFinite }.sorted()
        if vals.isEmpty { return nil }
        return StrainScorer.percentile(vals, pct)
    }

    // MARK: - Classifier seam (Stage 2)

    static func classifyEpochs(_ features: [EpochFeatures]) -> [String] {
        let n = features.count
        if n == 0 { return [] }

        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        let sleepFeats = features.contains { $0.ckSleep } ? features.filter { $0.ckSleep } : features
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        return features.map {
            classifyOne($0, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                        cardiacSparse: cardiacSparse)
        }
    }

    /// Session-level PPG-derived / sparse-cardiac tell: most sleep-period epochs carry NO finite
    /// per-epoch RMSSD (sparse R-R). On those nights the HR is PPG-derived and its windowed variance
    /// (`hrVar`) is noisier, so the percentile `hrvarHigh` bar fires on genuinely still, low-HR sleep —
    /// which the WAKE rule must NOT treat as cardiac activation. Same `!rmssd.isFinite` signal already
    /// trusted for the pro-deep RMSSD handling (#127/#129), aggregated across the night. (#705)
    static func isCardiacSparse(_ sleepFeats: [EpochFeatures]) -> Bool {
        if sleepFeats.isEmpty { return false }
        let sparse = sleepFeats.reduce(0) { $0 + (($1.rmssd.isFinite) ? 0 : 1) }
        return Double(sparse) >= cardiacSparseEpochFrac * Double(sleepFeats.count)
    }

    /// What this epoch's respiration says about depth — FIVE states, because "we did not measure it" is
    /// not an observation and must not be spendable as one.
    ///
    /// This used to be two booleans over a NaN RRV, and the `regular` one read
    /// `(!f.rrv.isFinite) || (f.rrv <= rrvLo)`: a MISSING respiration reading was converted into a
    /// positive assertion that breathing was regular, which is pro-deep. On a WHOOP 5/MG that is not an
    /// edge case, it is the only code path — the v18 layout emits no `resp_rate_raw` at all (pinned by
    /// `Whoop5HistoricalTests`), so `respSample` has zero rows, every epoch's RRV is NaN, and the
    /// fabricated "regular" fires on 100% of epochs. Where a night with real respiration data has ~50% of
    /// its epochs clear the `regular` bar (it is the MEDIAN — `stageRRVLowPct` = 50), a 5/MG night has
    /// 100% clear it, on no measurement whatsoever.
    ///
    /// The five cases are the exact CROSS-PRODUCT of the two predicates this replaced, so the mapping is
    /// total and no case is decided by which bar `of` happens to test first:
    ///
    /// | pre-fix `rrvIrregular` | pre-fix `rrvRegular` | case |
    /// |---|---|---|
    /// | false | true (via `!isFinite`) | `unmeasured` |
    /// | false | true (via the low bar) | `regular` |
    /// | true | false | `irregular` |
    /// | false | false | `measuredMidBand` |
    /// | true | true | `barsDegenerate` |
    ///
    /// `unmeasured` and `measuredMidBand` are deliberately DISTINCT. Both fail the regular and irregular
    /// bars, but they mean opposite things — one is "no reading", the other is a real reading that simply
    /// sits between the bars — and the classifier already treats them differently (the REM fallback fires
    /// only on a missing reading). Collapsing them would silently change the hypnogram.
    enum RespEvidence {
        /// A finite RRV at or below the session's low bar — breathing measured as regular.
        case regular
        /// A finite RRV at or above the session's high bar — breathing measured as irregular.
        case irregular
        /// A finite RRV between the bars: measured, but neither notably regular nor notably irregular.
        case measuredMidBand
        /// No usable RRV for this epoch. Either the strap has no respiration channel at all (every 5/MG),
        /// or this epoch's window had too few / too flat samples to derive one (`respRateAndRRV` returns
        /// NaN below 8 samples, on a flat signal, under 3 peaks, or under 2 in-band breath intervals).
        case unmeasured
        /// A finite RRV that clears BOTH bars at once — at or above the high bar AND at or below the low
        /// bar. The session's two percentile bars have collapsed onto this reading, so it satisfies each
        /// of them and the pair carries no information at this value.
        ///
        /// Reachable, not hypothetical, and for a structural reason: RRV is the population std of breath
        /// intervals measured in WHOLE SECONDS (`respRateAndRRV`, `dtS` = 1), so it is quantised onto a
        /// small discrete lattice and exact ties between epochs are ordinary. `percentile` interpolates
        /// between order statistics, so p50 and p65 coincide whenever the tie run spans them — and when
        /// only ONE sleep epoch has a finite RRV (the rest NaN, which that same function returns freely on
        /// short, flat or low-peak windows) `percentile` returns that single value for both, so the epoch
        /// that SET the bars necessarily sits on both of them.
        ///
        /// Kept as its own case because a four-state enum cannot represent it: both pre-fix booleans were
        /// true here, so whichever bar the factory tested first would silently decide the label. Behaviour
        /// is pinned to the pre-fix outcome — waived for depth (`rrvRegular` was true, see
        /// `contradictsDepth`) and clearing the REM irregular bar (`rrvIrregular` was true, see
        /// `meetsIrregularBar`) — which keeps this change a representation fix.
        ///
        /// That pre-fix outcome resolves to DEEP only because the deep rule is written before the REM rule
        /// in `classifyOne`; statement order is not a reason, and re-deciding it is a live question. It is
        /// deliberately NOT re-decided here: doing so is a scoring change on the degenerate-distribution
        /// nights, and this repo has no staged nights of that shape to validate it against (CLAUDE.md,
        /// "validate against the artifact, not one match"). The point of naming the case is that the
        /// decision is now a one-line edit in `contradictsDepth` / `meetsIrregularBar` with a test that
        /// fails loudly, instead of an invisible consequence of statement order.
        case barsDegenerate

        /// Total mapping of the two pre-fix predicates. Written as an exhaustive switch on the pair
        /// rather than an ordered `if` chain, because an ordered chain is exactly how the `barsDegenerate`
        /// case used to be decided by accident.
        static func of(_ rrv: Double, lowBar: Double?, highBar: Double?) -> RespEvidence {
            guard rrv.isFinite else { return .unmeasured }
            let atOrAboveHigh = highBar.map { rrv >= $0 } ?? false
            let atOrBelowLow = lowBar.map { rrv <= $0 } ?? false
            switch (atOrAboveHigh, atOrBelowLow) {
            case (true, true): return .barsDegenerate
            case (true, false): return .irregular
            case (false, true): return .regular
            case (false, false): return .measuredMidBand
            }
        }

        /// Whether respiration CONTRADICTS depth. The deep rule reads this rather than a "regular" flag,
        /// because `unmeasured` is not evidence of regular breathing — it is the absence of evidence, and
        /// the rule it feeds is "respiration must not rule depth out".
        ///
        /// `unmeasured` is WAIVED here, not because missing respiration is reassuring, but because
        /// blocking on it would decode 0 m of deep on every 5/MG night — the exact regression #127/#129
        /// fixed for the parallel missing-RMSSD case, whose rule statement already carries the same
        /// qualifier ("with high parasympathetic tone WHEN MEASURABLE"). This makes the respiration
        /// waiver explicit and equally qualified instead of leaving it implied by a NaN short-circuit.
        ///
        /// `barsDegenerate` is waived too, matching the pre-fix `rrvRegular`; see its doc for why that is
        /// preserved rather than re-decided.
        ///
        /// KNOWN LIMITATION, deliberately not changed here: on a 5/MG BOTH waivers can fire at once
        /// (sparse R-R leaves RMSSD NaN too), and the deep rule then reduces to stillness + a low HR with
        /// no physiological corroboration at all. That is a real weakness, but it is bounded — `hrLow` is
        /// a PERCENTILE bar (`stageHRLowPct` = 25), so at most ~25% of sleep epochs can clear it however
        /// the respiration term resolves. Narrowing the waiver (e.g. to epoch-level gaps within a night
        /// that HAS a respiration channel, versus a device with no channel at all) is a scoring change
        /// that needs validation data this repo does not have — see the "validate against the artifact,
        /// not one match" rule in CLAUDE.md. `SleepStagerRespEvidenceTests` pins the current behaviour and
        /// quantifies the bias so that decision can be made on numbers.
        var contradictsDepth: Bool {
            switch self {
            case .regular, .unmeasured, .barsDegenerate: return false
            case .irregular, .measuredMidBand: return true
            }
        }

        /// Whether this epoch clears the session's IRREGULAR bar — the pre-fix `rrvIrregular` predicate,
        /// which the main REM rule reads. `barsDegenerate` clears it (it IS at or above the high bar) even
        /// though `contradictsDepth` also waives it; that pair of answers is precisely the pre-fix state
        /// where both booleans were true, and it is preserved deliberately.
        var meetsIrregularBar: Bool {
            switch self {
            case .irregular, .barsDegenerate: return true
            case .regular, .measuredMidBand, .unmeasured: return false
            }
        }
    }

    static func classifyOne(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                            rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                            cardiacSparse: Bool = false) -> String {
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!

        // NOTE: HF omitted (no neurokit2). Parasympathetic tone = RMSSD only. A MISSING per-epoch
        // RMSSD (sparse R-R, common on BLE-offloaded nights and especially 5/MG) is treated as
        // pro-deep rather than deep-blocking — mirroring how a missing respiration value is handled
        // below — so those nights stop decoding 0 m of deep sleep despite a real depth signature
        // (still + low HR + regular breathing). An epoch WITH a finite RMSSD must still clear the
        // high-tone bar. (#127, #129)
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)

        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh

        // WAKE-specific cardiac vetting. On a PPG-derived / sparse-cardiac night the per-epoch HR-variance
        // is noisy, so `hrvarHigh` fires on still, low-HR sleep and used to flip those epochs to WAKE. When
        // the session is sparse we DOWN-WEIGHT hrVar for the wake promotion and require a real elevated HR
        // (`hrHigh`) — the down-weighting mirrors how sparse R-R is trusted for the pro-deep RMSSD handling.
        // Dense 4.0 nights keep the full `hrHigh || hrvarHigh` signal, so their behaviour is unchanged. (#705)
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated

        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)

        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion). On a sparse/PPG night the
        // cardiac half is vetted by HR only (see `cardiacActivatedForWake`), so noisy hrVar no longer
        // over-promotes still sleep to wake. (#705)
        if moving && (cardiacActivatedForWake || !hasHR) { return "wake" }
        // DEEP: still + low HR + respiration that does not RULE OUT depth, with high parasympathetic tone
        // when measurable. `contradictsDepth` is where an unmeasured respiration is waived — see its doc
        // for why the waiver stays and what it costs.
        if still && parasympOK && hrLow && !resp.contradictsDepth { return "deep" }
        // REM: still body + activated cardiac + respiration clearing the irregular bar.
        if still && cardiacActivated && resp.meetsIrregularBar { return "rem" }
        // REM fallback when respiration was never MEASURED (not merely mid-band): require BOTH cardiac
        // signals. A mid-band reading is real evidence and does not earn the fallback.
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return "rem" }
        return "light"
    }

    // MARK: - Post-processing (Stage 3)

    static func smoothLabels(_ labels: [String], window: Int = smoothEpochs) -> [String] {
        let n = labels.count
        if n == 0 || window <= 1 { return labels }
        var w = window
        if w % 2 == 0 { w += 1 }
        let half = w / 2
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for s in labels[lo..<hi] {
                if counts[s] == nil { order.append(s) }
                counts[s, default: 0] += 1
            }
            guard let best = counts.values.max() else { out.append(labels[i]); continue }
            let winners = order.filter { counts[$0] == best }  // insertion order preserved
            out.append(winners.contains(labels[i]) ? labels[i] : winners[0])
        }
        return out
    }

    static func reimposePhysiology(_ labels: [String], features: [EpochFeatures],
                                   onsetIdx: Int, finalWakeIdx: Int) -> [String] {
        var out = labels
        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        // "Deep is front-loaded" re-imposes scattered late "deep" back to light — BUT only when there's
        // deep in the first third to anchor that prior. If the whole detected deep block lands later
        // (individual variation, or HR/HRV-only staging without respiration placing the deepest, lowest-HR
        // window later), zeroing it out gives a wrong "0 m deep"; keeping the best estimate is better. (#127)
        let hasEarlyDeep = zip(labels, features).contains { $0.0 == "deep" && $0.1.clock <= deepFirstFraction }
        for (i, f) in features.enumerated() {
            if i < onsetIdx || i > finalWakeIdx { continue }
            if out[i] == "rem" && (i - onsetIdx) < noREMEpochs { out[i] = "light" }
            if out[i] == "deep" && f.clock > deepFirstFraction && hasEarlyDeep { out[i] = "light" }
        }
        return out
    }

    // MARK: - REM-funnel diagnostic (#688)

    // 0% REM over a whole night is physiologically implausible (healthy adults cycle ~20–25% REM),
    // so a 0%-REM hypnogram — common on WHOOP 4.0 nights staged WITHOUT a respiration channel —
    // points at the STAGER, not the sleeper. The REM path in `classifyOne` is gated by three
    // predicates (still body + activated cardiac + irregular respiration), with a no-resp fallback
    // (still + high HR + high HR-variability), and any surviving early-REM is then stripped by the
    // no-REM-after-onset re-imposition. This pure, READ-ONLY diagnostic re-runs that exact funnel and
    // counts where REM was lost — WITHOUT changing a single label or score — so a 0%-REM night can be
    // triaged (e.g. "respiration unavailable AND HR-variability never cleared its high bar → no epoch
    // could be REM" vs "REM was detected but all of it fell inside the 15-min onset guard"). It is a
    // triage surface, logged by the caller, never a scoring change.

    /// Why REM funneled toward zero for one staged session window. Counts are over the SLEEP-PERIOD
    /// epochs (onset…finalWake) the classifier actually ranges; pure + deterministic; shares the exact
    /// classifier seam with `stageSession`, so it explains the SAME hypnogram the app shows. (#688)
    public struct REMFunnelDiagnostic: Equatable, Sendable {
        /// Sleep-period epochs considered (onset…finalWake inclusive).
        public let sleepEpochs: Int
        /// Epochs the classifier labelled "rem" BEFORE smoothing / re-imposition.
        public let remAtClassify: Int
        /// "rem" epochs surviving the no-REM-after-onset re-imposition (the final hypnogram's REM).
        public let remAfterReimpose: Int
        /// Classified-REM epochs stripped specifically by the 15-min onset guard.
        public let remStrippedByOnsetGuard: Int
        /// Whether ANY epoch carried a finite respiration-variability feature (the resp channel was
        /// usable). False ⇒ the whole night ran the no-resp REM fallback — the dominant 4.0 cause.
        public let respChannelPresent: Bool
        /// Among sleep-period epochs, how many were blocked from REM by each gate (a per-epoch reason,
        /// counted at the FIRST gate that rejected it, in classifier precedence). These sum with
        /// `remAtClassify` (and any wake/deep wins) to the sleep-epoch total.
        public let blockedNotStill: Int          // body not still enough (moveFrac above the still bar)
        public let blockedNoCardiacActivation: Int  // neither HR-high nor HR-variability-high
        public let blockedRespRegular: Int       // resp present but NOT irregular (regular breathing)
        public let blockedNoRespFallbackBar: Int // resp absent and the stricter no-resp REM bar unmet
        /// Won a non-REM stage outright (wake/deep/light) before any REM gate — not a REM rejection.
        public let wonOtherStage: Int

        public init(sleepEpochs: Int, remAtClassify: Int, remAfterReimpose: Int,
                    remStrippedByOnsetGuard: Int, respChannelPresent: Bool,
                    blockedNotStill: Int, blockedNoCardiacActivation: Int,
                    blockedRespRegular: Int, blockedNoRespFallbackBar: Int, wonOtherStage: Int) {
            self.sleepEpochs = sleepEpochs; self.remAtClassify = remAtClassify
            self.remAfterReimpose = remAfterReimpose; self.remStrippedByOnsetGuard = remStrippedByOnsetGuard
            self.respChannelPresent = respChannelPresent
            self.blockedNotStill = blockedNotStill
            self.blockedNoCardiacActivation = blockedNoCardiacActivation
            self.blockedRespRegular = blockedRespRegular
            self.blockedNoRespFallbackBar = blockedNoRespFallbackBar
            self.wonOtherStage = wonOtherStage
        }

        /// True when the final hypnogram carries no REM at all — the case this diagnostic exists to
        /// triage. (`remAfterReimpose == 0`.)
        public var isZeroREM: Bool { remAfterReimpose == 0 }

        /// One human-readable line for the caller to LOG. No I/O here — the engine stays pure.
        public var summary: String {
            "REM-funnel: \(sleepEpochs) sleep-epochs, classify=\(remAtClassify) rem, "
            + "final=\(remAfterReimpose) rem (onset-guard stripped \(remStrippedByOnsetGuard)); "
            + "resp=\(respChannelPresent ? "present" : "ABSENT"); "
            + "blocked[notStill=\(blockedNotStill), noCardiac=\(blockedNoCardiacActivation), "
            + "respRegular=\(blockedRespRegular), noRespBar=\(blockedNoRespFallbackBar)], "
            + "otherStage=\(wonOtherStage)"
        }
    }

    /// Per-epoch reason REM was rejected, evaluated in classifier precedence order. `remEligible`
    /// means the epoch WOULD be labelled REM. Internal — drives `remFunnelDiagnostic`.
    enum REMRejectReason { case remEligible, wonOtherStage, notStill, noCardiacActivation, respRegular, noRespFallbackBar }

    /// Classify a single epoch's REM-eligibility AND, when not eligible, the FIRST reason it failed —
    /// using the exact predicates and precedence of `classifyOne` so the diagnostic can never diverge
    /// from the real classifier. Read-only. (#688)
    static func remRejectReason(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                                rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                                cardiacSparse: Bool = false) -> REMRejectReason {
        // Mirror classifyOne's derived predicates exactly.
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)
        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated
        // Same respiration evidence the classifier uses, from the same factory — so the diagnostic cannot
        // drift from the rule it explains (these predicates were duplicated by hand).
        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)
        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // classifyOne precedence: WAKE, then DEEP, then REM (then REM fallback), else LIGHT.
        // An epoch that wins WAKE or DEEP was never a REM candidate.
        if moving && (cardiacActivatedForWake || !hasHR) { return .wonOtherStage }     // → wake
        if still && parasympOK && hrLow && !resp.contradictsDepth { return .wonOtherStage } // → deep
        // From here the epoch did NOT win wake/deep; it is either REM or falls through to LIGHT.
        if still && cardiacActivated && resp.meetsIrregularBar { return .remEligible }
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return .remEligible }
        // Not REM → attribute to the FIRST unmet REM precondition (in REM-rule order).
        if !still { return .notStill }
        if !cardiacActivated { return .noCardiacActivation }
        if resp != .unmeasured { return .respRegular }   // resp measured but not irregular
        return .noRespFallbackBar                          // resp never measured and the no-resp bar unmet
    }

    /// Read-only REM-funnel triage for ONE in-bed window [start, end] (#688). Re-runs the SAME Stage-0→3
    /// staging seam `stageSession` uses (epoch grid → Cole–Kripke → features → classify → smooth →
    /// re-impose), but instead of emitting a hypnogram it COUNTS where REM was lost. Changes NOTHING:
    /// no label, no score, no session. Returns nil only when the window has too little gravity to grid
    /// (mirroring `stageSession`'s degenerate fallback, which carries no REM to explain). The caller
    /// logs `.summary`; tests assert the counts. Pure + deterministic. (#688)
    public static func remFunnelDiagnostic(start: Int, end: Int, grav: [GravitySample],
                                           hr: [HRSample], rr: [RRInterval],
                                           resp: [RespSample]) -> REMFunnelDiagnostic? {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return nil }
        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }
        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return nil }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)
        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        // The SAME session-relative reference percentiles classifyEpochs derives.
        let sleepFeats = feats.contains { $0.ckSleep } ? feats.filter { $0.ckSleep } : feats
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        // Classify + post-process exactly as stageSession does, so we explain the SAME hypnogram.
        let labels = classifyEpochs(feats)
        let smoothed = smoothLabels(labels)
        let reimposed = reimposePhysiology(smoothed, features: feats,
                                           onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        var sleepEpochs = 0, remAtClassify = 0, remAfterReimpose = 0, remStrippedByOnsetGuard = 0
        var blockedNotStill = 0, blockedNoCardiacActivation = 0, blockedRespRegular = 0
        var blockedNoRespFallbackBar = 0, wonOtherStage = 0
        var respChannelPresent = false

        for i in onsetIdx...max(onsetIdx, finalWakeIdx) where i < feats.count {
            let f = feats[i]
            sleepEpochs += 1
            if f.rrv.isFinite { respChannelPresent = true }
            // Per-epoch REM reason at the raw classifier seam (pre-smoothing) — the funnel's mouth.
            switch remRejectReason(f, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                                   hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                                   cardiacSparse: cardiacSparse) {
            case .remEligible:           remAtClassify += 1
            case .wonOtherStage:         wonOtherStage += 1
            case .notStill:              blockedNotStill += 1
            case .noCardiacActivation:   blockedNoCardiacActivation += 1
            case .respRegular:           blockedRespRegular += 1
            case .noRespFallbackBar:     blockedNoRespFallbackBar += 1
            }
            // Final-hypnogram REM (post smooth + re-impose) and the onset-guard strip.
            if reimposed[i] == "rem" { remAfterReimpose += 1 }
            // The re-imposition strips a SMOOTHED "rem" epoch inside the onset guard → light; count
            // the strip off the smoothed labels reimpose actually sees (exact, not the raw seam).
            if smoothed[i] == "rem" && (i - onsetIdx) < noREMEpochs { remStrippedByOnsetGuard += 1 }
        }

        return REMFunnelDiagnostic(
            sleepEpochs: sleepEpochs, remAtClassify: remAtClassify, remAfterReimpose: remAfterReimpose,
            remStrippedByOnsetGuard: remStrippedByOnsetGuard, respChannelPresent: respChannelPresent,
            blockedNotStill: blockedNotStill, blockedNoCardiacActivation: blockedNoCardiacActivation,
            blockedRespRegular: blockedRespRegular, blockedNoRespFallbackBar: blockedNoRespFallbackBar,
            wonOtherStage: wonOtherStage)
    }

    /// Sleep-depth rank, lighter → deeper: wake 0, light 1, rem 2, deep 3. Used by
    /// mergeFragments to bias an ambiguous merge toward the LIGHTER stage so smoothing
    /// can never inflate deep/REM. Unknown labels rank lightest (0) — they never win deep.
    static func stageDepthRank(_ stage: String) -> Int {
        switch stage {
        case "light": return 1
        case "rem":   return 2
        case "deep":  return 3
        default:      return 0  // "wake" and any unexpected label
        }
    }

    /// Display/scoring smoothing of the staged label sequence (#274). Absorbs sub-threshold
    /// "noise" runs WITHOUT erasing real transitions — applied AFTER staging, it never
    /// touches the underlying per-epoch detection.
    ///
    /// Per run shorter than fragmentMergeEpochs:
    ///   • bridged by two SAME-stage neighbours → absorbed into them (the fleck was a blip
    ///     inside one continuous stage);
    ///   • between DIFFERENT stages → relabelled to the dominant (longer) neighbour. On a tie
    ///     — or when the longer neighbour is the deeper one and the shorter is lighter and of
    ///     comparable length — it biases toward the LIGHTER neighbour so a stray fleck can
    ///     never inflate deep/REM (the least-reliable, most-overcountable classes).
    ///
    /// Single left-to-right pass over runs, mirroring mergePeriods' control flow so the
    /// Swift and Kotlin ports stay byte-identical. A run already ≥ threshold is a real
    /// transition and is always preserved.
    static func mergeFragments(_ labels: [String], thresholdEpochs: Int = fragmentMergeEpochs) -> [String] {
        let n = labels.count
        if n == 0 || thresholdEpochs <= 1 { return labels }

        // Collapse the per-epoch labels into contiguous runs of (stage, length).
        var runs: [(stage: String, len: Int)] = []
        for s in labels {
            if let last = runs.last, last.stage == s { runs[runs.count - 1].len += 1 }
            else { runs.append((stage: s, len: 1)) }
        }
        if runs.count < 2 { return labels }

        var merged: [(stage: String, len: Int)] = []
        var i = 0
        while i < runs.count {
            let current = runs[i]
            if current.len >= thresholdEpochs { merged.append(current); i += 1; continue }

            let hasPrev = !merged.isEmpty
            let hasNext = i + 1 < runs.count

            if hasPrev && hasNext && merged[merged.count - 1].stage == runs[i + 1].stage {
                // Same-stage bridge: absorb the fleck and the next run into the previous one.
                merged[merged.count - 1].len += current.len + runs[i + 1].len
                i += 2
            } else if hasPrev && hasNext {
                // Between two DIFFERENT stages: relabel to the dominant neighbour, biasing
                // toward the lighter stage when the two neighbours are tied in length.
                let prev = merged[merged.count - 1]
                let next = runs[i + 1]
                let winner: String
                if prev.len > next.len { winner = prev.stage }
                else if next.len > prev.len { winner = next.stage }
                else {
                    // Tie → lighter (smaller depth rank) wins; never inflate deep/REM.
                    winner = stageDepthRank(prev.stage) <= stageDepthRank(next.stage) ? prev.stage : next.stage
                }
                // Fold the fleck into whichever neighbour it became; the OTHER neighbour
                // stays its own run (handled on the next iterations).
                if winner == prev.stage {
                    merged[merged.count - 1].len += current.len
                    i += 1
                } else {
                    // Becomes part of the NEXT run: extend next, drop current.
                    runs[i + 1] = (stage: next.stage, len: next.len + current.len)
                    i += 1
                }
            } else if hasNext {
                // No previous run (leading fleck): fold forward into the next run.
                runs[i + 1] = (stage: runs[i + 1].stage, len: runs[i + 1].len + current.len)
                i += 1
            } else if hasPrev {
                // No next run (trailing fleck): fold back into the previous run.
                merged[merged.count - 1].len += current.len
                i += 1
            } else {
                // Single sub-threshold run with no neighbours — nothing to merge into.
                merged.append(current)
                i += 1
            }
        }

        // Re-expand the runs back into a per-epoch label sequence of the same length.
        var out: [String] = []
        out.reserveCapacity(n)
        for r in merged { out.append(contentsOf: repeatElement(r.stage, count: r.len)) }
        return out
    }

    // MARK: - Per-session HR / HRV

    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    static func sessionRestingHR(start: Int, end: Int, hr: [HRSample]) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }
        let windowS = 5 * 60
        var means: [Double] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + windowS }
            if !win.isEmpty { means.append(Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)) }
            t += windowS
        }
        if let m = means.min() { return Int(m.rounded()) }
        let all = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        return Int(all.rounded())
    }

    /// One 5-min HRV window: its start ts, the sleep stage at its center, the clean-beat count, and the
    /// window RMSSD (nil when <2 clean beats). Drives both `sessionAvgHRV` and the HRV test-mode trace. (#141)
    public struct HrvWindow: Sendable {
        public let startTs: Int
        public let stage: String
        public let cleanBeats: Int
        public let rmssd: Double?
    }

    /// Mean RMSSD over 5-min tumbling windows across the session (ms), or nil.
    /// Uses the same range-filter + ≥2-valid-interval rule as hrv.rmssd().
    static func sessionAvgHRV(start: Int, end: Int, rr: [RRInterval]) -> Double? {
        let vals = sessionHrvWindows(start: start, end: end, rr: rr, stages: []).compactMap { $0.rmssd }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    /// Per-5-min-window RMSSD across a session, each window tagged with the sleep stage at its CENTER
    /// (from `stages`) — the SINGLE source `sessionAvgHRV` averages, and the HRV nightly trace reads.
    /// Passing `[]` for `stages` tags every window "?" (the plain-average path needs no stages). (#141)
    static func sessionHrvWindows(start: Int, end: Int, rr: [RRInterval], stages: [StageSegment]) -> [HrvWindow] {
        // CONTRACT: `rr` MUST already be ts-sorted (RMSSD is built from SUCCESSIVE differences, so a bucket
        // has to be chronological). The value path passes the loop's pre-sorted `rrS`; the trace caller sorts
        // its own copy. Not sorted here on purpose — re-sorting the value path could reorder same-second RR
        // under Swift's unstable sort and shift the shipped avgHrv. Same contract the original sessionAvgHRV had.
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return [] }
        let windowS = 5 * 60
        var out: [HrvWindow] = []
        var t = start
        while t < end {
            let bucket = seg.filter { $0.ts >= t && $0.ts < t + windowS }.map { Double($0.rrMs) }
            // Full clean (range + Malik ectopic rejection), not just range — matches the
            // analyze() pipeline. The 0x2A37 RR on a WHOOP 5/MG is PPG-derived and noisier
            // than a 4.0's; rMSSD is built from SUCCESSIVE differences, so an un-rejected
            // jitter spike inflates the session HRV. Ectopic rejection drops those (#262/#235).
            // #204/#195: gap-aware — a successive difference straddling a dropped beat is skipped so a
            // removed out-of-range/ectopic beat can't splice its neighbours into a spurious delta.
            let cleaned = HRVAnalyzer.cleanRRGapAware(bucket)
            let rmssd: Double? = (cleaned.nn.count >= 2) ? HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) : nil
            let center = t + windowS / 2
            let stage = stages.first { center >= $0.start && center < $0.end }?.stage ?? "?"
            out.append(HrvWindow(startTs: t, stage: stage, cleanBeats: cleaned.nn.count, rmssd: rmssd))
            t += windowS
        }
        return out
    }

    /// The LAST contiguous run of deep-stage windows in `windows` — the WHOOP-style "last slow-wave-sleep"
    /// comparator for the HRV nightly trace. Empty when no deep window is present. (#141)
    static func lastDeepRun(_ windows: [HrvWindow]) -> [HrvWindow] {
        var lastRun: [HrvWindow] = []
        var cur: [HrvWindow] = []
        for w in windows {
            if w.stage == "deep" { cur.append(w) } else if !cur.isEmpty { lastRun = cur; cur.removeAll() }
        }
        if !cur.isEmpty { lastRun = cur }
        return lastRun
    }

    // MARK: - AASM hypnogram metrics

    /// AASM-style metrics from a session's stage segments.
    public struct HypnogramMetrics: Equatable, Sendable {
        public let tibS: Double
        public let tstS: Double
        public let sptS: Double
        public let solS: Double
        public let remLatencyS: Double  // NaN if no REM
        public let wasoS: Double
        public let efficiency: Double
        public let disturbances: Int
        public let deepMin: Double
        public let remMin: Double
        public let lightMin: Double
        public let deepPct: Double
        public let remPct: Double
        public let lightPct: Double
    }

    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let tib = max(0.0, Double(session.end - session.start))

        func dur(_ s: StageSegment) -> Double { Double(s.end - s.start) }
        let sleepSegs = segs.filter { $0.stage == "light" || $0.stage == "deep" || $0.stage == "rem" }
        let tst = sleepSegs.reduce(0.0) { $0 + dur($1) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + dur($1) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + dur($1) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + dur($1) }

        let onset: Double, sptEnd: Double, sol: Double
        if let first = sleepSegs.first, let last = sleepSegs.last {
            onset = Double(first.start)
            sptEnd = Double(last.end)
            sol = max(0.0, onset - Double(session.start))
        } else {
            onset = Double(session.end)
            sptEnd = Double(session.end)
            sol = tib
        }

        let remSegs = segs.filter { $0.stage == "rem" }
        let remLatency = remSegs.first.map { Double($0.start) - onset } ?? Double.nan

        var waso = 0.0
        var disturbances = 0
        for s in segs where SleepStageVocabulary.isWake(s.stage) {
            let w0 = max(Double(s.start), onset)
            let w1 = min(Double(s.end), sptEnd)
            if w1 > w0 { waso += (w1 - w0); disturbances += 1 }
        }

        let se = tib > 0 ? tst / tib : 0.0
        func pct(_ x: Double) -> Double { tst > 0 ? x / tst * 100.0 : 0.0 }

        return HypnogramMetrics(
            tibS: tib, tstS: tst, sptS: max(0.0, sptEnd - onset), solS: sol,
            remLatencyS: remLatency, wasoS: waso, efficiency: min(1.0, se),
            disturbances: disturbances, deepMin: deepS / 60.0, remMin: remS / 60.0,
            lightMin: lightS / 60.0, deepPct: pct(deepS), remPct: pct(remS), lightPct: pct(lightS))
    }

    // MARK: - Small stats helpers

    /// Population standard deviation (numpy default, ddof=0).
    static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return (ss / Double(values.count)).squareRoot()
    }
}
