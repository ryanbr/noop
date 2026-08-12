package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlin.math.sqrt

/*
 * SleepStager.kt — sleep/wake detection + APPROXIMATE 4-class staging.
 *
 * Faithful Kotlin port of StrandAnalytics/SleepStager.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/sleep.py and sleep_features.py.
 *
 * HONEST HEDGING: these stages are APPROXIMATIONS, not PSG-validated, not medical
 * advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019).
 * Light/deep separation is the weakest link — deep-minute estimates are the least
 * reliable output.
 *
 * Pipeline (30 s epochs):
 *   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke
 *            (te Lindert 30 s) computed as a citable cross-check; HR confirms runs.
 *   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window
 *            (mean HR, DoG-HR variability, RMSSD/SDNN from RR, resp rate + RRV).
 *   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
 *   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in
 *            the first third of the night).
 *
 * NOTE: frequency-domain HRV features (HF, LF/HF) are omitted (no neurokit2/scipy
 * on-device); the parasympathetic-tone signal is RMSSD only. Respiration rate +
 * RRV are derived from the raw 1 Hz resp channel with a simple peak detector. The
 * classifier seam, percentile bands, smoothing, and physiology rules are
 * reproduced exactly.
 *
 * Types:
 *   - The detected-sleep type is [DetectedSleep] (AnalyticsModels.kt), NOT a Room
 *     entity. Stage segments are [StageSegment] (AnalyticsModels.kt, fields var).
 *   - [HypnogramMetrics] (AnalyticsModels.kt) is returned by [hypnogramMetrics].
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long); the Swift source
 * uses Int seconds. Math is done in Double throughout, matching the Swift port.
 */
object SleepStager {

    // ── Stage 0 constants (sleep.py) ─────────────────────────────────────────

    /** Per-sample gravity change (g) at/below which a sample is "still". */
    const val gravityStillThresholdG: Double = 0.01

    /** Rolling stillness window (minutes). */
    const val stillWindowMin: Int = 15

    /** Fraction of still samples to call the window-center "sleep". */
    const val stillFraction: Double = 0.70

    /** Data gap (minutes) that always breaks a run. */
    const val maxGapMin: Int = 20

    /** Runs shorter than this (minutes) are absorbed into neighbours. */
    const val mergeMin: Int = 15

    /** A sleep run must exceed this (minutes) to count as a session. */
    const val minSleepMin: Int = 60

    /** Assumed sample interval (seconds) when not inferable. */
    const val defaultIntervalS: Double = 60.0

    // ── Daytime false-sleep guard (#90) ──────────────────────────────────────
    //
    // A long, still, sedentary daytime stretch (reading, a desk, a sofa) is gravity-
    // indistinguishable from a real nap, so the gravity spine alone misclassifies it as
    // sleep. The fix is NOT to drop daytime sleep — real naps are legitimate sessions —
    // but to hold a window whose CENTER falls in the local daytime band to a stricter bar:
    // it must be long enough to be a real nap AND show a genuine cardiac dip (a sedentary
    // stretch keeps a near-baseline HR). Overnight windows are UNCHANGED. Mirrors Swift.

    /** Local hour (inclusive) at which the stricter daytime bar begins. */
    const val daytimeBandStartHour: Int = 11

    /**
     * Local hour (exclusive) at which the stricter daytime bar ends. A window whose center
     * is in [start, end) local hours is "daytime"; everything else is "overnight".
     */
    const val daytimeBandEndHour: Int = 20

    /**
     * A still sleep run that resumes within this gap of an overnight sleep chain is the
     * night's TAIL — a late wake past the daytime-band start, or a brief morning stir then
     * back to sleep — not an isolated daytime nap, so it skips the daytime guard. Without
     * this, a real sleep that ran past ~11:00 local had its tail rejected as a "nap" and the
     * displayed wake time was truncated to late morning (late sleepers / shift workers).
     * Reimplemented from @vulnix0x4's PR #353.
     */
    const val nightContinuationGapMin: Int = 90

    /**
     * A daytime window must run at least this long (minutes) to count — short still daytime
     * stretches are the dominant false-positive and are rejected outright.
     */
    const val daytimeMinSleepMin: Int = 90

    /**
     * A daytime window's resting HR (lowest 5-min rolling mean) must be at or below
     * baseline × this to confirm a real cardiac dip. Stricter than the overnight 1.05:
     * a true nap dips BELOW the waking-day median, sedentary stillness does not.
     */
    const val daytimeRestingHRMult: Double = 0.95

    // ── H4 physiological in-bed span cap (#547 / #531 / #509 / tail) ───────────
    //
    // Maximum plausible in-bed span (seconds) for a SINGLE assembled main-sleep run. No real single night
    // runs longer than this: a 12 h+ "sleep" is a bad-clock artefact (a stale/duplicated timestamp range,
    // or a strap that banked one frozen still stretch under a wrong clock) reading as one enormous still
    // block — which then reports a 12 h sleep and poisons Rest / the debt ledger / the headline. 16 h is
    // well above any genuine night yet below the clock-artefact range. A run whose span exceeds this is
    // DROPPED (not silently truncated to 16 h, which would fabricate a wake time): an over-long block is
    // not trustworthy enough to assert a span for at all. Mirrors Swift `maxMainSleepSpanS`.
    const val maxMainSleepSpanS: Long = 16L * 60L * 60L

    // ── H7 morning-stillness nap suppression (#531) ───────────────────────────
    //
    // After a real overnight wake the wrist is often still (sitting with coffee, back in bed scrolling, a
    // sofa) for a stretch that the gravity spine reads as a fresh "nap" — #531's 9 am phantom nap right after
    // the night ended. It is NOT a night-tail continuation (handled by nightContinuationGapMin and exempted),
    // and it can clear the ordinary daytime guard (long + the post-wake HR is still low), so it slipped
    // through. H7 holds a daytime block that BEGINS within morningStillnessWindowMin of the just-detected
    // overnight wake to a STRONGER bar: it must show a genuine SUSTAINED re-onset — a real second sleep dips
    // clearly below the day median, not merely near it. Mirrors Swift.

    /** A daytime block whose onset falls within this many minutes AFTER an overnight chain's wake is treated
     *  as suspected morning residual stillness and held to the stronger re-onset bar below. ~3 h covers the
     *  post-wake window where residual stillness masquerades as a nap; a genuine afternoon nap (hours later)
     *  is past it and faces only the ordinary daytime guard. Mirrors Swift `morningStillnessWindowMin`. (#531) */
    const val morningStillnessWindowMin: Int = 180

    /** The stronger resting-HR bar (× day baseline) a suspected-morning-stillness block must clear to be kept
     *  as a real re-onset. Stricter than the ordinary daytime [daytimeRestingHRMult] (0.95): residual waking
     *  stillness keeps a near-waking HR, so only a block that dips clearly (a true second sleep) survives.
     *  Mirrors Swift `morningReonsetRestingHRMult`. (#531) */
    const val morningReonsetRestingHRMult: Double = 0.90

    /** The persisted v18 BAND sleep_state value that means "asleep" (Interpreter's `(sb>>4)&3`: 0 wake /
     *  1 still / 2 asleep / 3 up). The strap's OWN scored band state — an independent anchor we CONSUME to
     *  confirm a borderline morning re-onset (H7). Mirrors Swift `bandStateAsleep`. (#531 / H8 consume) */
    const val bandStateAsleep: Int = 2

    /** Fraction of a suspected-morning-stillness block's epochs whose persisted band sleep_state must read
     *  "asleep" ([bandStateAsleep]) for the strap's OWN signal to CONFIRM a genuine re-onset and KEEP the
     *  block even when its HR dip is borderline. A real second sleep the strap itself scored asleep is a
     *  strong, honest anchor; a residual-stillness false nap reads "still"/"up", not "asleep". ≥0.6 keeps
     *  this conservative. Mirrors Swift `morningReonsetBandAsleepFrac`. (H8 consume) */
    const val morningReonsetBandAsleepFrac: Double = 0.6

    /** Default-OFF gate for the band sleep_state WAKE-veto (the SHIPPED state; the pre-veto hypnogram is what
     *  users see). [bandStateAsleep] is WHOOP's OWN banked verdict (not a signal we re-derive), so vetoing
     *  false-wakes with it is well-founded on the n=12 that motivated it — but the PSG harness measures the
     *  recipe UNDER-calling wake overall (bias -4.92 pp), so a veto that converts wake->light moves the
     *  population result AWAY from truth. Flip to true only with PSG evidence in hand (see #1210), and set
     *  [bandStateWakeVetoCutoffTs] alongside to spare history. It stays a single flip-point + fully tested
     *  (tests pass `enabled = true` explicitly). An absent band stream (WHOOP 4.0 / unbanded window) makes the
     *  veto a no-op regardless of this flag. Mirrors Swift `bandStateWakeVetoEnabled`. (band sleep_state veto) */
    const val bandStateWakeVetoEnabled: Boolean = false

    /** #1210 item 2 (retroactive-rescore story): the new-nights-only cutoff. When the veto is flipped on
     *  ([bandStateWakeVetoEnabled] = true), a NON-ZERO cutoff (a unix second) restricts the correction to
     *  sessions whose `start >= cutoffTs` — nights already in history keep their raw efficiency, so flipping
     *  the default cannot silently re-score months of banked nights upward. `0` (the default) applies the veto
     *  to every banded night (the "just ship the one-time shift" path). Inert while the flag is off. Set this
     *  to the flip date at the same time as the flag. Byte-identical to Swift `bandStateWakeVetoCutoffTs`. */
    const val bandStateWakeVetoCutoffTs: Long = 0L

    /** The sleep stage a band-vetoed false-wake epoch is reclassified to. [bandStateAsleep] (band sleep_state == 2) means
     *  only "asleep" — the band carries NO light/deep/REM resolution — so the veto maps it to the generic,
     *  most-common sleep stage rather than inventing deep/REM detail the strap never asserted (deep/REM
     *  minutes feed the recovery gate; the veto must not inflate them). "light" is the honest projection of a
     *  bare "asleep". Mirrors Swift `bandVetoRecoverStage`. (band sleep_state veto) */
    const val bandVetoRecoverStage: String = "light"

    /** #1210: a TRACE-ONLY line reporting what the (dormant) band wake-veto WOULD recover on a banded night,
     *  so a validator gathers the recovered-minutes distribution across real nights without any output change
     *  (the persisted hypnogram stays the flag-gated, unchanged one). Namespaced `bandVeto(shadow):` and free
     *  of a `day=` / `t=…s` token so `CaptureAccumulator` never counts it as a captured day. Byte-identical to
     *  Swift `bandVetoShadowLine`. (band sleep_state veto) */
    internal fun bandVetoShadowLine(startTs: Long, recoveredMin: Double, rawEff: Double, shadowEff: Double): String =
        "bandVeto(shadow): startTs=$startTs recoveredMin=${Math.round(recoveredMin)} " +
            "eff ${Math.round(rawEff * 100)}%->${Math.round(shadowEff * 100)}%"

    /** Seconds in a calendar day (for local-hour-of-day arithmetic). */
    const val secondsPerDay: Long = 86_400L

    /** Floor on the rolling-window size in samples. */
    const val minWindowSamples: Int = 3

    /** A run is HR-confirmed only if mean HR ≤ baseline × this. */
    const val hrSleepBaselineMult: Double = 1.05

    // ── Motion-corroborated wake (elevated-but-flat-HR nights, #462) ───────────
    //
    // Both stagers call "wake" primarily off HR / HR-variability, and the HR-led session confirmation
    // ([confirmSleepWithHR]) rejects a still run whose median HR sits above the sleep band. On a night with
    // pharmacologically- or metabolically-elevated resting HR that keeps HR up WITHOUT the wearer getting up
    // (a supplement protocol, a fever, a hot room, alcohol), that HR-led logic misreads hot-but-motionless
    // sleep as wake. The corroboration rule is: elevated-HR ALONE is insufficient — a run/epoch at the night's
    // quiescent MOTION floor with UNCHANGED posture cannot be called wake on cardiac evidence alone. The
    // per-epoch half lives in the stagers ([SleepStagerV2.motionQuiescent]); this is the session-detection half.

    /** The relaxed sleep-band multiplier applied to [confirmSleepWithHR] when the run is DEEPLY motion-quiescent.
     *  Wider than [hrSleepBaselineMult] (1.05) so a supplement-elevated but motionless overnight run is not
     *  rejected, yet bounded (the floor) so a genuinely awake still run above this band is still dropped.
     *  Mirrors Swift `quiescentHRSleepMult`. */
    const val quiescentHRSleepMult: Double = 1.30

    /** Per-minute gravity posture variance (g²) at/below which a minute counts as posture-STABLE — the wrist
     *  orientation barely moved within the minute. A minute with too few gravity samples to compute a variance
     *  is conservatively NOT counted as stable (silence ≠ stillness). Mirrors Swift `quiescentPostureVarG2`. */
    const val quiescentPostureVarG2: Double = 0.05

    /** Fraction of a run's minutes that must be posture-STABLE for the run to be DEEPLY motion-quiescent. Set
     *  well above the Stage-0 stillness bar ([stillFraction] 0.70) so only a genuinely motionless run — not an
     *  ordinary restless-but-in-bed night — earns the widened HR band. Mirrors Swift `quiescentStableFrac`. */
    const val quiescentStableFrac: Double = 0.90

    /** Minimum posture-stable minutes with COMPUTABLE variance a run needs before the deeply-quiescent verdict
     *  is trusted at all — a run with almost no dense-gravity minutes can't prove stillness, so it defers to
     *  the strict HR band rather than being waved through. Mirrors Swift `quiescentMinStableMinutes`. */
    const val quiescentMinStableMinutes: Int = 20

    /** Floor (bpm) under [adaptiveOvernightHRBaseline] so a genuinely wakeful era cannot collapse the sleep
     *  band and score wakefulness asleep. Mirrors Swift `adaptiveBaselineFloor`. */
    const val adaptiveBaselineFloor: Double = 40.0

    /** Skip HR refinement (trust gravity) when fewer than this many HR samples. */
    const val hrRefineMinSamples: Int = 30

    /** Consecutive sleep epochs required to declare onset. */
    const val onsetPersistEpochs: Int = 3

    // ── Off-wrist backstop (#500) ─────────────────────────────────────────────
    //
    // A wrist-OFF stretch reads as perfectly still gravity with no contrary motion, so the
    // gravity spine classifies it as sleep — and because the off-wrist epochs carry zero/missing
    // HR the daytime guard treats them as "missing data" and lets them through (a daytime desk-off
    // strap logged a phantom sleep). The backstop measures OFF-WRIST COVERAGE: while worn the strap
    // emits ~1 Hz HR, so a long CONTIGUOUS gap in the HR samples spanning part of a candidate sleep
    // run is a strong off-wrist proxy that works even when explicit WRIST_OFF events are absent;
    // explicit WRIST_OFF→WRIST_ON intervals (when the store surfaces them) sharpen it. A run is dropped
    // only when that coverage reaches maxOffWristSleepFraction of its duration (the FRACTIONAL rule from
    // j0b-dev's #504), so a real night that over-extends into a SHORT off-wrist tail survives. Independent
    // of the daytime band — off-wrist is off-wrist day OR night, and a night-tail continuation does NOT
    // exempt it. Mirrors Swift.

    /**
     * A contiguous HR-sample gap of at least this many minutes contributes to a candidate run's
     * off-wrist coverage. Sized at maxGapMin so a real worn night (dense ~1 Hz HR, or PPG-derived HR
     * on a 5/MG) contributes ~no gap, but a wrist-off stretch (HR flatlines to no samples) contributes
     * its whole span. The edges of the run count too: a run that begins/ends far from its nearest HR
     * sample is partially uncovered.
     */
    const val offWristHRGapMin: Int = 20

    /**
     * FRACTIONAL off-wrist rejection (#500), design credited to j0b-dev's #504 analysis. A candidate
     * sleep run is dropped ONLY when its off-wrist coverage — the UNION of its long HR-gap spans and
     * any WRIST_OFF→WRIST_ON intervals overlapping it — is at least this fraction of its duration. The
     * earlier guard dropped the WHOLE run on ANY contiguous HR gap or ANY single WRIST_OFF blip, which
     * nuked a real night that over-extended into a SHORT off-wrist morning tail (strap removed shortly
     * after waking) or that contained one stray WRIST_OFF event. 0.5 keeps such a night (<50% off-wrist)
     * while still dropping an all-day desk strap (≈100% gap) or a session genuinely spent off-wrist.
     * Mirrors Swift.
     */
    const val maxOffWristSleepFraction: Double = 0.5

    /**
     * Minimum average HR-stream density for the off-wrist HR-gap proxy to be trusted (#507). The proxy
     * reads a >[offWristHRGapMin]-minute hole in HR as "off the wrist" — valid only when HR is otherwise
     * dense. A WHOOP 4.0's SYNCED night is reconstructed mostly from MOTION with sparse, derived HR, whose
     * natural gaps would otherwise read as off-wrist and wrongly DROP a real night. So if the HR stream
     * averages fewer than one sample per this many seconds, we don't assert off-wrist from gaps at all
     * (WRIST_OFF events still apply). Self-consistent: a night sparse enough to be >50% gap-covered is, by
     * definition, below this density, so it is spared. Measured over the whole stream, so an off-wrist HOLE
     * inside an otherwise dense, worn day (#500) is still caught. Mirrors Swift.
     */
    const val hrDenseSpacingS: Int = 600   // one HR sample per 10 minutes, averaged over the stream

    // ── Sparse-gravity robustness (#308) ──────────────────────────────────────
    //
    // On an un-unlocked WHOOP 5.0 the strap backfills mostly v18/v26 records where gravity is
    // sparse/clumped (~25% coverage), so the gravity-only Stage-0 spine fragments the night at
    // every >maxGapMin gravity gap and detectSleep drops every <minSleepMin fragment — collapsing
    // a ~6 h night to ~1 h. The fix derives the in-bed spine from a sustained low-HR stretch and
    // uses gravity stillness only to REFINE it, but is GATED ENTIRELY behind a "gravity is sparse"
    // condition so dense WHOOP-4.0 nights stay BYTE-IDENTICAL (a 4.0 regression is unacceptable).
    // Mirrors Swift.

    /**
     * Gravity is "sparse" when its timespan covers less than this fraction of the HR-sample
     * timespan. A dense 4.0 night has gravity spanning the whole HR window (≈1.0) and never trips
     * this; a 5.0 backfill clumps gravity into a fraction of the night.
     */
    const val sparseGravitySpanFrac: Double = 0.5

    /**
     * When sparse, HR drives the in-bed spine: an HR sample is "sleep-band" when its bpm ≤
     * baseline × this. Reuses the overnight HR-confirmation multiplier so the band is the same one
     * detectSleep already trusts to confirm a run.
     */
    const val hrSleepBandMult: Double = hrSleepBaselineMult

    /**
     * When sparse, two adjacent sleep runs separated ONLY by a gravity gap up to this many minutes
     * are merged if the intervening HR stays in the sleep band — so a real night is not shredded
     * into sub-minSleepMin fragments by gravity dropouts. Sized at the daytime-nap floor (a real
     * continuous night never has a true >90 min wake bridge mid-sleep).
     */
    const val sparseBridgeGapMin: Int = 90

    // ── Stage 1–3 constants (sleep_features.py) ──────────────────────────────

    const val epochS: Double = 30.0
    const val featureWindowS: Double = 5 * 60.0
    const val ckCountDivisor: Double = 100.0
    const val ckCountClip: Double = 300.0
    const val moveDeltaThresholdG: Double = 0.01
    const val hrDogSigma1S: Double = 120.0
    const val hrDogSigma2S: Double = 600.0

    const val stageHRLowPct: Double = 25.0
    const val stageHRHighPct: Double = 70.0
    const val stageHRVHighPct: Double = 70.0
    const val stageHRVarHighPct: Double = 65.0
    const val stageRRVHighPct: Double = 65.0
    const val stageRRVLowPct: Double = 50.0
    const val stageWakeMoveFrac: Double = 0.15
    const val stageStillMoveFrac: Double = 0.10

    /**
     * Fraction of sleep-period epochs that must carry a MISSING per-epoch RMSSD (sparse R-R) for the
     * session's cardiac signal to count as PPG-DERIVED / sparse-cardiac. On a WHOOP 5/MG the PPG-derived
     * HR feeds a noisier per-epoch HR-variance, which inflates `hrVar` on otherwise still, low-HR sleep
     * epochs and was tripping the Stage-2 WAKE rule (which keys on the `hrvarHigh` percentile), so a
     * whole night over-reported WAKE. We already trust `!rmssd.isFinite()` as a PPG/sparse tell for the
     * pro-deep RMSSD handling (#127/#129); at this share across the night it also down-weights the
     * HR-variance half of the WAKE rule. ~50% keeps a real worn 4.0 night (dense R-R) on the strict
     * path and only relaxes nights whose cardiac signal is genuinely sparse/derived. (#705)
     */
    const val cardiacSparseEpochFrac: Double = 0.5

    const val smoothEpochs: Int = 5
    const val noREMAfterOnsetMin: Double = 15.0
    const val deepFirstFraction: Double = 1.0 / 3.0

    /**
     * Fragment-merge threshold (#274). A staged run shorter than this is "noise": the
     * WHOOP 5/MG banks sparse motion, so the stager emits lots of sub-minute stage flecks
     * and the hypnogram reads choppier than WHOOP's. mergeFragments (a DISPLAY/scoring
     * smoothing applied AFTER staging, never to the underlying detection) absorbs runs
     * below this into their neighbours. 3 min is conservative — long enough to clear the
     * fleck noise, short enough to leave a genuine stage transition (a real deep or REM
     * block runs many minutes) untouched. Mirrors Swift.
     */
    const val fragmentMergeMin: Double = 3.0

    /** fragmentMergeMin expressed in 30 s epochs (6). A run with < this many epochs merges. */
    val fragmentMergeEpochs: Int = (fragmentMergeMin * 60.0 / epochS).roundToInt()

    /** te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1. */
    val ckWeights: List<Double> = listOf(106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0)
    const val ckScale: Double = 0.001
    const val ckBack: Int = 4
    const val ckFwd: Int = 2

    // ── Gravity deltas ───────────────────────────────────────────────────────

    /**
     * Per-record movement proxy = L2 magnitude of the gravity change vs the
     * previous record. First record → 0. (No dropout sentinel needed: GravitySample
     * always carries finite x/y/z.)
     */
    internal fun gravityDeltas(grav: List<GravitySample>): List<Double> {
        val deltas = ArrayList<Double>(grav.size)
        var prev: GravitySample? = null
        for ((i, r) in grav.withIndex()) {
            if (i == 0) {
                deltas.add(0.0)
            } else {
                val p = prev
                if (p != null) {
                    val dx = p.x - r.x
                    val dy = p.y - r.y
                    val dz = p.z - r.z
                    deltas.add(sqrt(dx * dx + dy * dy + dz * dz))
                } else {
                    deltas.add(0.0)
                }
            }
            prev = r
        }
        return deltas
    }

    /** Median spacing between consecutive timestamps, restricted to (0, 300 s). */
    internal fun medianIntervalS(times: List<Long>): Double {
        if (times.size < 2) return defaultIntervalS
        val gaps = ArrayList<Double>(times.size)
        for (i in 0 until times.size - 1) {
            val g = (times[i + 1] - times[i]).toDouble()
            if (g > 0 && g < 300) gaps.add(g)
        }
        if (gaps.isEmpty()) return defaultIntervalS
        gaps.sort()
        return maxOf(gaps[gaps.size / 2], 1.0)
    }

    internal fun windowSize(times: List<Long>): Int {
        val interval = medianIntervalS(times)
        return maxOf(minWindowSamples, (stillWindowMin * 60 / interval).toInt())
    }

    // ── Sparse-gravity gate (#308) ─────────────────────────────────────────────

    /**
     * Largest spacing between consecutive timestamps (seconds), NO upper cap; 0.0 for <2 samples.
     * Used to detect clumped/sparse gravity where the dropouts themselves are the signal: a few
     * long dropouts in otherwise-dense (clumped) motion keep the MEDIAN gap small but still break
     * runs, so the largest gap — not the median — is the right signal (#28).
     */
    internal fun largestGapS(times: List<Long>): Double {
        if (times.size < 2) return 0.0
        var mx = 0.0
        for (i in 0 until times.size - 1) {
            val g = (times[i + 1] - times[i]).toDouble()
            if (g > mx) mx = g
        }
        return mx
    }

    /**
     * True when gravity is too sparse for the gravity-only spine to be trusted across gaps: the
     * gravity timespan covers < sparseGravitySpanFrac of the HR-sample timespan, OR the LARGEST
     * gravity inter-sample gap exceeds maxGapMin. The largest-gap test (not just the median) catches
     * CLUMPED motion — dense bursts split by a few long dropouts, the typical WHOOP 4.0 backfill
     * (#28) — whose median gap stays small yet which still hides run-breaking gaps. Requires a real
     * HR span to compare against — with no/degenerate HR the dense path is kept (false), so a 4.0
     * with absent HR is never reclassified as sparse.
     */
    internal fun isGravitySparse(grav: List<GravitySample>, hr: List<HrSample>): Boolean {
        if (grav.size < 2 || hr.size < 2) return false
        val hrSpan = (hr[hr.size - 1].ts - hr[0].ts).toDouble()
        if (hrSpan <= 0) return false
        val gravSpan = (grav[grav.size - 1].ts - grav[0].ts).toDouble()
        if (gravSpan < sparseGravitySpanFrac * hrSpan) return true
        // #28: clumped 4.0 motion keeps a SMALL median gap yet still contains >maxGapMin dropouts
        // the gravity-only spine shreds the night on. The largest gap catches what a median would
        // miss (largest >= median, so this subsumes the old median check). Flagging sparse only
        // ENABLES buildRuns' HR-vouched bridge — a real wake (HR above the sleep band) still breaks.
        return largestGapS(grav.map { it.ts }) > (maxGapMin * 60).toDouble()
    }

    /**
     * True when HR stays in the sleep band (≤ baseline × hrSleepBandMult) across (a, b], used to
     * decide whether a pure gravity gap is a real wake or just a dropout. With no baseline or no HR
     * in the interval, the answer is false (cannot vouch for the gap → treat as a real break).
     */
    internal fun hrSleepBandAcross(a: Long, b: Long, hr: List<HrSample>, baseline: Double?): Boolean {
        if (baseline == null) return false
        val seg = hr.filter { it.ts > a && it.ts <= b }
        if (seg.isEmpty()) return false
        val meanHR = seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble()
        return meanHR <= baseline * hrSleepBandMult
    }

    /** Per-record sleep flags from a rolling fraction of "still" samples. */
    internal fun classifyStill(grav: List<GravitySample>, deltas: List<Double>): List<Boolean> {
        val n = grav.size
        if (n < 2) return List(n) { false }
        val half = windowSize(grav.map { it.ts }) / 2
        // stillPrefix[i] = number of still samples among deltas[0 until i]. Turns each per-sample
        // window count from O(window) into O(1), so the whole scan is O(n) not O(n×window). The old
        // nested loop ran ~n×window times per night and — ×21 nights, on the MAIN THREAD — froze the
        // app into ANRs after a few nights of 1 Hz history. Output is byte-identical. (#125)
        val stillPrefix = IntArray(n + 1)
        for (i in 0 until n) {
            stillPrefix[i + 1] = stillPrefix[i] + if (deltas[i] < gravityStillThresholdG) 1 else 0
        }
        val flags = ArrayList<Boolean>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - half)
            val hi = minOf(n, i + half + 1)
            val stillCount = stillPrefix[hi] - stillPrefix[lo]
            flags.add(stillCount.toDouble() / (hi - lo).toDouble() >= stillFraction)
        }
        return flags
    }

    /** A contiguous sleep/active run. `stage` ∈ {"sleep", "active"}. */
    internal data class Period(val stage: String, val start: Long, val end: Long)

    /**
     * Collapse per-record flags into contiguous runs, breaking on class change
     * or a gap > maxGapMin minutes.
     *
     * When [sparse] (gravity is too clumped to bridge gaps — #308), a PURE gravity data-gap (no
     * contrary motion) does NOT close a SLEEP run while HR stays in the sleep band across the gap:
     * the strap simply banked no motion there, not a wake. A class change always still closes the
     * run, and the dense path ([sparse] == false) is byte-identical to the original. Mirrors Swift.
     */
    internal fun buildRuns(
        grav: List<GravitySample>, flags: List<Boolean>,
        sparse: Boolean = false, hr: List<HrSample> = emptyList(), baseline: Double? = null,
    ): List<Period> {
        val n = grav.size
        if (n == 0) return emptyList()
        val times = grav.map { it.ts }
        val maxGapS = (maxGapMin * 60).toLong()
        val periods = ArrayList<Period>()
        var runStart = 0
        for (i in 1..n) {
            val atEnd = (i == n)
            val close: Boolean
            if (atEnd) {
                close = true
            } else {
                val classChanged = flags[i] != flags[runStart]
                var gapExceeded = (times[i] - times[i - 1]) > maxGapS
                // Sparse override: a pure gravity gap (no class change) does not break a sleep run
                // when HR stays in the sleep band across it — the gap is a dropout, not a wake.
                if (sparse && gapExceeded && !classChanged && flags[runStart] &&
                    hrSleepBandAcross(times[i - 1], times[i], hr, baseline)
                ) {
                    gapExceeded = false
                }
                close = classChanged || gapExceeded
            }
            if (close) {
                periods.add(
                    Period(
                        stage = if (flags[runStart]) "sleep" else "active",
                        start = times[runStart],
                        end = times[i - 1],
                    )
                )
                runStart = i
            }
        }
        return periods
    }

    /** Absorb runs shorter than mergeMin minutes into their neighbours. */
    internal fun mergePeriods(periods: List<Period>, mergeMinutes: Int = mergeMin): List<Period> {
        if (periods.isEmpty()) return emptyList()
        val pending = periods.toMutableList()
        val thresholdS = (mergeMinutes * 60).toLong()
        val merged = ArrayList<Period>()
        var i = 0
        while (i < pending.size) {
            val current = pending[i]
            val tooShort = (current.end - current.start) < thresholdS
            if (!tooShort) {
                merged.add(current)
                i += 1
                continue
            }

            val hasPrev = i > 0 && merged.isNotEmpty()
            val hasNext = i + 1 < pending.size
            val bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if (bridgesSame) {
                val prev = merged.removeAt(merged.size - 1)
                merged.add(Period(stage = prev.stage, start = prev.start, end = pending[i + 1].end))
                i += 2
            } else if (hasNext) {
                pending[i + 1] = Period(
                    stage = pending[i + 1].stage,
                    start = current.start,
                    end = pending[i + 1].end,
                )
                i += 1
            } else if (hasPrev) {
                val prev = merged.removeAt(merged.size - 1)
                merged.add(Period(stage = prev.stage, start = prev.start, end = current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    /**
     * Sparse-gravity bridge (#308): merge two adjacent SLEEP runs separated ONLY by a gap up to
     * sparseBridgeGapMin minutes when the intervening HR stays in the sleep band — so a real night
     * fragmented by gravity dropouts is re-stitched into one continuous in-bed span BEFORE the
     * minSleepMin gate drops the pieces. Active runs and over-threshold gaps are left untouched; the
     * span between two bridged sleep runs (an "active"/gap run, if present) is absorbed. A no-op when
     * [sparse] == false, so the dense 4.0 path is unchanged. Mirrors Swift.
     */
    internal fun bridgeSparseSleep(
        periods: List<Period>, sparse: Boolean, hr: List<HrSample>, baseline: Double?,
    ): List<Period> {
        if (!sparse || periods.isEmpty()) return periods
        val bridgeGapS = (sparseBridgeGapMin * 60).toLong()
        val out = ArrayList<Period>()
        for (p in periods) {
            val last = out.lastOrNull()
            if (last != null && last.stage == "sleep" && p.stage == "sleep") {
                val gap = p.start - last.end
                if (gap in 0..bridgeGapS && hrSleepBandAcross(last.end, p.start, hr, baseline)) {
                    out[out.size - 1] = Period(stage = "sleep", start = last.start, end = p.end)
                    continue
                }
            }
            out.add(p)
        }
        return out
    }

    // ── HR refinement ────────────────────────────────────────────────────────

    private inline fun <T> rowsBetween(rows: List<T>, start: Long, end: Long, ts: (T) -> Long): List<T> =
        rows.filter { ts(it) in start..end }

    /** Day HR baseline = median bpm over all HR samples; null if none. */
    internal fun hrBaseline(hr: List<HrSample>): Double? {
        val vals = hr.map { it.bpm.toDouble() }
        if (vals.isEmpty()) return null
        return HrvAnalyzer.median(vals)
    }

    /**
     * HR-confirmation with MOTION CORROBORATION (motion-corroborated wake, #462). A run is confirmed as sleep
     * when its MEDIAN HR sits within the sleep band relative to [baseline]. The band is normally
     * [hrSleepBaselineMult] (×1.05); on a run that is DEEPLY MOTION-QUIESCENT ([runIsDeeplyQuiescent] — the
     * wrist barely moved and its posture did not change across the whole span) the band widens to
     * [quiescentHRSleepMult], because a raised but FLAT overnight HR with a motionless wrist is a supplement /
     * fever / hot-room / alcohol artefact, not wakefulness — elevated-HR-alone must not reject a still run. The
     * wider band STILL keeps a floor: a genuinely awake, high-HR run (median above [quiescentHRSleepMult] ×
     * baseline) is rejected even when still, so all-night in-bed wakefulness is not scored asleep.
     * [sleepHRBaseline] (directive b) overrides [baseline] with the wearer's personalised overnight band
     * ([adaptiveOvernightHRBaseline]) when the caller supplies one, so a supplement / fitness era self-calibrates
     * instead of drifting against a fixed day-median. [grav] defaults to empty (motion unprovable → strict band,
     * byte-identical to the pre-corroboration gate); the detection call site passes the night's gravity.
     * Mirrors Swift `confirmSleepWithHR`.
     */
    internal fun confirmSleepWithHR(
        p: Period, hr: List<HrSample>, baseline: Double?,
        grav: List<GravitySample> = emptyList(), sleepHRBaseline: Double? = null,
    ): Boolean {
        val effBaseline = sleepHRBaseline ?: baseline ?: return true
        val seg = rowsBetween(hr, p.start, p.end) { it.ts }
        if (seg.size < hrRefineMinSamples) return true
        // Confirm on the run's MEDIAN, not its mean. A real sleep night carries brief arousal / wake HR
        // spikes (observed to ~190 bpm) that pull the MEAN above baseline × mult and reject the run — and
        // for a typical single main-sleep run per night that means zero sessions ("no sleep recorded") —
        // while the spike-robust median stays at the true sleep level. Baseline is itself a median, so both
        // sides use the same robust statistic; a genuinely elevated (awake) run still has a high median and
        // fails. Median ≤ mean for the right-skewed HR of a real night, so this only ever RELAXES the gate —
        // every run the mean already accepted still passes, and runs the mean wrongly dropped are recovered.
        // Mirrors Swift `confirmSleepWithHR`.
        val medHR = HrvAnalyzer.median(seg.map { it.bpm.toDouble() })
        val mult = if (runIsDeeplyQuiescent(p, grav)) quiescentHRSleepMult else hrSleepBaselineMult
        return medHR <= effBaseline * mult
    }

    /**
     * True when `[p.start, p.end)` is DEEPLY motion-quiescent: at least [quiescentStableFrac] of the minutes
     * that carry enough gravity to judge are posture-stable (per-minute variance < [quiescentPostureVarG2]),
     * over at least [quiescentMinStableMinutes] such minutes. Empty/sparse gravity → false (motion unprovable,
     * defer to the strict HR band). Pure + deterministic. Mirrors Swift `runIsDeeplyQuiescent`.
     */
    internal fun runIsDeeplyQuiescent(p: Period, grav: List<GravitySample>): Boolean {
        if (grav.isEmpty() || p.end <= p.start) return false
        val byMinute = HashMap<Long, MutableList<GravitySample>>()
        for (g in grav) if (g.ts >= p.start && g.ts < p.end) byMinute.getOrPut(g.ts / 60) { ArrayList() }.add(g)
        var judged = 0
        var stable = 0
        for ((_, samples) in byMinute) {
            val v = posturVarianceG2(samples) ?: continue   // too few samples this minute
            judged += 1
            if (v < quiescentPostureVarG2) stable += 1
        }
        if (judged < quiescentMinStableMinutes) return false
        return stable.toDouble() / judged.toDouble() >= quiescentStableFrac
    }

    /**
     * Trace of the covariance of a minute's gravity vectors (Σ over x/y/z of the mean squared deviation from
     * the minute's own mean vector). ~0 when the wrist orientation is fixed within the minute; spikes on a
     * turn-over. null below 2 samples (a single sample has zero variance by construction and would read as a
     * false "stable"). Shared shape with the stage-level posture check and the Swift twin `posturVarianceG2`.
     */
    internal fun posturVarianceG2(samples: List<GravitySample>): Double? {
        if (samples.size < 2) return null
        val n = samples.size.toDouble()
        var sx = 0.0
        var sy = 0.0
        var sz = 0.0
        for (s in samples) { sx += s.x; sy += s.y; sz += s.z }
        val mx = sx / n
        val my = sy / n
        val mz = sz / n
        var sumSq = 0.0
        for (s in samples) {
            val dx = s.x - mx
            val dy = s.y - my
            val dz = s.z - mz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        return sumSq / n
    }

    /**
     * Personalised overnight HR baseline (directive b): the median of recent nights' overnight median HRs, so
     * the sleep band self-calibrates to the wearer's current era (a supplement protocol, a fitness change)
     * instead of a fixed day-median that a sustained shift silently drifts against. Returns null with no history
     * (the caller keeps the day-median). A FLOOR keeps the band from collapsing so a genuinely wakeful era is
     * not scored asleep: the returned value is never below [adaptiveBaselineFloor] bpm. Pure + deterministic.
     * Mirrors Swift `adaptiveOvernightHRBaseline`.
     */
    fun adaptiveOvernightHRBaseline(recentOvernightMedians: List<Double>): Double? {
        val vals = recentOvernightMedians.filter { it.isFinite() && it > 0 }
        if (vals.isEmpty()) return null
        return maxOf(adaptiveBaselineFloor, HrvAnalyzer.median(vals))
    }

    /**
     * True when the run's CENTER, shifted to LOCAL time by [tzOffsetSeconds], lands in the
     * daytime band [daytimeBandStartHour, daytimeBandEndHour). The center (not the edges) is
     * used so a window straddling a band edge is classified once, by where it mostly is.
     * Math.floorMod keeps the local-shifted time in [0, secondsPerDay) for any sign.
     */
    internal fun isDaytimeCenter(p: Period, tzOffsetSeconds: Long): Boolean {
        val center = p.start + (p.end - p.start) / 2
        val secOfDay = Math.floorMod(center + tzOffsetSeconds, secondsPerDay)
        val hour = (secOfDay / 3_600L).toInt()
        return hour >= daytimeBandStartHour && hour < daytimeBandEndHour
    }

    /**
     * True when a run's ONSET (start), in LOCAL time, falls OUTSIDE the daytime band — i.e. the
     * sleep began at night, not during the day. Anchors a continuous-sleep chain: only a chain
     * that began overnight may carry its tail past the daytime-band start (a late wake).
     * Reimplemented from @vulnix0x4's PR #353.
     */
    internal fun isOvernightOnset(start: Long, tzOffsetSeconds: Long): Boolean {
        val secOfDay = Math.floorMod(start + tzOffsetSeconds, secondsPerDay)
        val hour = (secOfDay / 3_600L).toInt()
        return !(hour >= daytimeBandStartHour && hour < daytimeBandEndHour)
    }

    /**
     * Stricter bar for a daytime-centered window (#90). A real daytime nap clears it; a long
     * sedentary still stretch (the false-positive this guards) does not, because it is either
     * too short or never shows a genuine cardiac dip below the day median. Overnight windows
     * never reach here. Returns true = keep, false = reject.
     *
     * [restingHR] is the window's own lowest 5-min rolling-mean HR (the sleep-depth proxy
     * detectSleep already computes); [baseline] is the day's median HR. With no usable HR
     * evidence (null baseline OR null restingHR) a daytime stretch cannot be confirmed as a
     * real nap, so it is rejected — sedentary daytime stillness without a measured HR dip is
     * far more likely than an unmonitored nap, and this path can never touch the night.
     */
    internal fun passesDaytimeGuard(p: Period, restingHR: Int?, baseline: Double?): Boolean {
        val daytimeMinSleepS = (daytimeMinSleepMin * 60).toLong()
        if ((p.end - p.start) < daytimeMinSleepS) return false
        if (baseline == null || restingHR == null) return false
        return restingHR.toDouble() <= baseline * daytimeRestingHRMult
    }

    /**
     * H7 morning-stillness nap suppression (#531). Returns true = KEEP, false = REJECT, for a daytime block
     * [p] that begins shortly after a real overnight wake. [morningWakeEnd] is the end of the just-detected
     * OVERNIGHT chain (null when the prior chain was not overnight, or there was none) — when [p].start is
     * within [morningStillnessWindowMin] of it, the block is suspected morning residual stillness and must
     * clear the ORDINARY daytime guard AND show a SUSTAINED re-onset: its resting HR must dip below the
     * stronger [morningReonsetRestingHRMult] × baseline bar (a true second sleep, not near-waking stillness).
     * Outside the morning window this is a no-op (returns the plain daytime-guard result), so a genuine
     * afternoon nap is unaffected. Mirrors Swift `passesMorningStillnessGuard`. (#531)
     */
    internal fun passesMorningStillnessGuard(
        p: Period,
        restingHR: Int?,
        baseline: Double?,
        morningWakeEnd: Long?,
        bandSleepState: List<Pair<Long, Int>> = emptyList(),
    ): Boolean {
        // Only a daytime block beginning within the post-wake window of an overnight chain is suspected.
        if (morningWakeEnd == null || p.start < morningWakeEnd ||
            (p.start - morningWakeEnd) > (morningStillnessWindowMin * 60).toLong()
        ) {
            return passesDaytimeGuard(p, restingHR, baseline)
        }
        // Suspected morning stillness needs at least the ordinary daytime guard (long enough + a real dip).
        if (!passesDaytimeGuard(p, restingHR, baseline)) return false
        // CONSUME the strap's OWN banked band sleep_state (#531 / H8): if the strap itself scored this block
        // predominantly "asleep", that is a strong independent re-onset anchor — KEEP it even on a borderline
        // HR dip. This only ever RESCUES a block the strap says was real sleep; it never fabricates one.
        if (bandStateConfirmsAsleep(p, bandSleepState)) return true
        // Otherwise require the clearly-deeper cardiac dip of a true second sleep.
        if (baseline == null || restingHR == null) return false
        return restingHR.toDouble() <= baseline * morningReonsetRestingHRMult
    }

    /**
     * CONSUME-side helper (#531 / H8): true when the strap's OWN persisted v18 band sleep_state over the
     * block [p.start, p.end] reads predominantly "asleep" ([bandStateAsleep]), at/above
     * [morningReonsetBandAsleepFrac] of the in-block samples — an independent confirmation of a real
     * re-onset. Empty/absent band state → false (no anchor → fall back to the HR bar); we never invent an
     * "asleep" reading the strap did not bank. Pure + deterministic. Mirrors Swift `bandStateConfirmsAsleep`.
     * (#531 / H8 consume)
     */
    internal fun bandStateConfirmsAsleep(p: Period, bandSleepState: List<Pair<Long, Int>>): Boolean {
        val inBlock = bandSleepState.filter { it.first in p.start..p.end }
        if (inBlock.isEmpty()) return false
        val asleep = inBlock.count { it.second == bandStateAsleep }
        return asleep.toDouble() / inBlock.size.toDouble() >= morningReonsetBandAsleepFrac
    }

    // ── Band sleep_state WAKE-veto (recover strap-disputed false wakes) ───────
    //
    // NOOP's cardiorespiratory stager is known to OVER-CALL wake: an EEG-free stager reads a still, low-HR
    // but not-quite-asleep epoch as wake far more often than the wearer was actually awake. WHOOP's OWN
    // per-second sleep-state band (the persisted v18 @81 high-nibble `(sb>>4)&3`: 0 wake/1 still/2 asleep/
    // 3 up — banked as `sleepStateJSON`, gridded by [sessionEpochSleepState]) is an INDEPENDENT scored
    // signal, not a re-derivation of ours. On real banded nights the strap scores "asleep"
    // ([bandStateAsleep]) across ~two-thirds of the epochs NOOP calls wake, while the reverse disagreement
    // (NOOP asleep, strap wake) is an order of magnitude smaller. So letting the strap's OWN "asleep"
    // verdict VETO an INTERIOR wake call recovers most of the spurious wake with near-zero downside.
    // Unlike the H8 consume confirm (which only ever KEEPS a whole borderline re-onset session), this
    // operates per EPOCH on the final hypnogram and only ever turns wake INTO sleep.

    /**
     * Band sleep_state WAKE-veto. Given a staged hypnogram [stages] (StageSegments tiling `[start, end]`)
     * and the strap's OWN per-timestamp band sleep_state, reclassify INTERIOR wake epochs the strap itself
     * scored "asleep" ([bandStateAsleep]) to [bandVetoRecoverStage]. Conservative by construction:
     *   - ONLY [bandStateAsleep] (2) vetoes — a "still" (1) / "up" (3) / "wake" (0) band reading is LEFT as
     *     wake, so the veto never blind-trusts the band, only its explicit "asleep";
     *   - the LEADING wake block (sleep-onset latency, before the first sleep epoch) and the TRAILING wake
     *     block (final-morning wake, after the last sleep epoch) are NEVER touched — the veto cannot move
     *     sleep onset earlier or final wake later, it only recovers wake FLANKED by sleep;
     *   - it only ever turns wake INTO sleep (raising efficiency), never sleep into wake.
     * The band is gridded to the SAME 30 s epochs as `stagesJSON` / `sessionEpochMotion` via
     * [sessionEpochSleepState], so epoch i here is epoch i of the persisted `sleepStateJSON`. Empty band
     * state, the flag off, or a hypnogram with no interior sleep -> returns [stages] UNCHANGED (byte-
     * identical). Applies to whichever stager (V1 or V2) produced [stages]. Pure + deterministic.
     * Mirrors Swift `applyBandStateWakeVeto`. (band sleep_state veto)
     */
    internal fun applyBandStateWakeVeto(
        stages: List<StageSegment>, start: Long, end: Long,
        bandSleepState: List<Pair<Long, Int>>,
        enabled: Boolean = bandStateWakeVetoEnabled,
        cutoffTs: Long = bandStateWakeVetoCutoffTs,
    ): List<StageSegment> {
        if (!enabled || bandSleepState.isEmpty() || stages.isEmpty() || end <= start) {
            return stages
        }
        // #1210 item 2: new-nights-only gate. A non-zero cutoff spares nights that started before it (history
        // keeps its raw efficiency); `0` applies to every banded night. Inert while the flag is off.
        if (cutoffTs > 0L && start < cutoffTs) return stages
        // Per-epoch band on the 30 s stagesJSON grid — byte-identical to the persisted sleepStateJSON.
        val states = sessionEpochSleepState(start, end, bandSleepState)
        if (states.isEmpty()) return stages
        val n = states.size
        // Epoch i spans [start + i·epochS, …); boundaries sit on 30 s edges, so expanding the segment tiling
        // to a per-epoch stage array and re-collapsing it is an exact round-trip (no-op when nothing changes).
        fun epochStart(i: Int): Long = start + (i.toDouble() * epochS).toLong()
        val labels = MutableList(n) { "wake" }
        for (i in 0 until n) {
            val t = epochStart(i)
            val seg = stages.firstOrNull { it.start <= t && t < it.end }
                ?: stages.firstOrNull { it.start <= t && t <= it.end }
            if (seg != null) labels[i] = seg.stage
        }
        // Interior = [firstSleep, lastSleep]; leading/trailing wake blocks are excluded from the veto.
        val onset = labels.indexOfFirst { it != "wake" }
        val finalWake = labels.indexOfLast { it != "wake" }
        if (onset < 0 || finalWake < 0 || onset > finalWake) return stages   // no sleep at all -> nothing to recover
        var changed = false
        for (i in onset..finalWake) {
            if (labels[i] == "wake" && states[i] == bandStateAsleep) {
                labels[i] = bandVetoRecoverStage
                changed = true
            }
        }
        if (!changed) return stages   // the band disputed nothing -> byte-identical hypnogram
        // Re-collapse consecutive same-stage epochs back into segments tiling [start, end].
        val out = ArrayList<StageSegment>()
        for (i in 0 until n) {
            val segStart = epochStart(i)
            val segEnd = if (i == n - 1) end else epochStart(i + 1)
            val last = out.lastOrNull()
            if (last != null && last.stage == labels[i]) {
                out[out.size - 1].end = segEnd
            } else {
                out.add(StageSegment(start = segStart, end = segEnd, stage = labels[i]))
            }
        }
        if (out.isNotEmpty()) out[out.size - 1].end = end
        return out
    }

    /**
     * Off-wrist HR-gap spans (#500). The contiguous HR-coverage gaps of at least [offWristHRGapMin]
     * minutes WITHIN [p.start, p.end], as concrete [start, end) sub-intervals — a strong wrist-OFF
     * proxy. Worn, the strap streams ~1 Hz HR (or PPG-derived HR on a 5/MG), so a real night yields no
     * long gap; an off-wrist stretch flatlines to no HR samples and yields a span. The leading edge
     * ([p.start] → first in-run sample) and trailing edge (last in-run sample → [p.end]) count too,
     * and a run with NO in-run HR at all is one full-period gap. With NO HR data at all this returns
     * [] (the gravity-only path is left to the existing guards — we can't assert off-wrist without HR).
     * These spans are UNIONed with the WRIST_OFF intervals by [offWristFraction]. Mirrors Swift.
     */
    internal fun offWristHRGapSpans(p: Period, hr: List<HrSample>): List<Pair<Long, Long>> {
        if (hr.isEmpty() || p.end <= p.start) return emptyList()
        // Density gate (#507): only trust the HR-gap off-wrist proxy when the HR STREAM is dense enough
        // that a long gap is anomalous. A WHOOP 4.0 synced night is motion-reconstructed with sparse HR,
        // so its natural gaps must NOT read as off-wrist (that wrongly dropped a real night). Judge over
        // the whole stream so an off-wrist HOLE inside an otherwise dense, worn day (#500) is still caught.
        val sortedAll = hr.sortedBy { it.ts }
        val streamSpan = sortedAll.last().ts - sortedAll.first().ts
        if (streamSpan >= hrDenseSpacingS && hr.size < streamSpan / hrDenseSpacingS) return emptyList()
        val gapS = (offWristHRGapMin * 60).toLong()
        val seg = hr.filter { it.ts in p.start..p.end }.sortedBy { it.ts }
        // No HR anywhere inside a run long enough to matter → the whole period is one gap.
        if (seg.isEmpty()) return if ((p.end - p.start) >= gapS) listOf(p.start to p.end) else emptyList()
        val spans = ArrayList<Pair<Long, Long>>()
        // Leading edge: run start to first sample.
        if (seg[0].ts - p.start >= gapS) spans.add(p.start to seg[0].ts)
        // Interior: any gap between consecutive in-run samples.
        for (i in 1 until seg.size) if (seg[i].ts - seg[i - 1].ts >= gapS) spans.add(seg[i - 1].ts to seg[i].ts)
        // Trailing edge: last sample to run end.
        if (p.end - seg[seg.size - 1].ts >= gapS) spans.add(seg[seg.size - 1].ts to p.end)
        return spans
    }

    /**
     * Fractional off-wrist coverage of a candidate run [p.start, p.end] in [0, 1] (#500).
     * Design credited to j0b-dev's #504 analysis: instead of a binary drop on ANY HR gap or ANY single
     * WRIST_OFF blip, we measure how much of the run is off-wrist and let the caller drop it only past
     * [maxOffWristSleepFraction]. Coverage = (length of the UNION of) the HR-gap spans ([offWristHRGapSpans])
     * AND the supplied WRIST_OFF→WRIST_ON [wristOff] intervals, clipped to the run, divided by duration.
     * Unioning avoids double-counting overlapping gap+event time. A real night with a small (<50%)
     * off-wrist tail scores low and is kept; an all-day desk strap (HR-gap ≈100%, no events needed) or a
     * session genuinely spent off the wrist scores high and is dropped. Mirrors Swift.
     */
    internal fun offWristFraction(p: Period, hr: List<HrSample>, wristOff: List<Pair<Long, Long>>): Double {
        val dur = p.end - p.start
        if (dur <= 0) return 0.0
        // Collect every off-wrist span, clipped to the run: HR-gap proxy spans + explicit wrist-off events.
        val spans = ArrayList(offWristHRGapSpans(p, hr))
        for (w in wristOff) {
            val s = maxOf(w.first, p.start); val e = minOf(w.second, p.end)
            if (e > s) spans.add(s to e)
        }
        if (spans.isEmpty()) return 0.0
        // Union the spans so overlapping gap+event time is counted once, then sum the covered length.
        spans.sortBy { it.first }
        var covered = 0L; var curStart = spans[0].first; var curEnd = spans[0].second
        for (i in 1 until spans.size) {
            val sp = spans[i]
            if (sp.first <= curEnd) {
                curEnd = maxOf(curEnd, sp.second)        // overlapping/adjacent → extend
            } else {
                covered += curEnd - curStart             // disjoint → bank the run
                curStart = sp.first; curEnd = sp.second
            }
        }
        covered += curEnd - curStart
        return covered.toDouble() / dur.toDouble()
    }

    // ── detectSleep (public) ──────────────────────────────────────────────────

    /**
     * One folded Long per sample stream for the [detectSleep] memo key: folds the COUNT plus every
     * (ts, quantised value) with large odd multipliers — the same every-element discipline as
     * [StagerCache.fingerprint] — so an in-place interior edit (a re-import correcting a value), a
     * truncation, or an append all re-key to a fresh compute and a stale hit is never served.
     * Internal so the fingerprint-completeness test pins those properties directly.
     */
    internal fun <T> streamFingerprint(samples: List<T>, ts: (T) -> Long, quant: (T) -> Long): Long {
        var h = samples.size.toLong() * 2_654_435_761L
        for (e in samples) h = (h * 1_000_003L + ts(e)) * 1_000_003L + quant(e)
        return h
    }

    /** Full memo key for [detectSleep] — every input that steers detection or staging, nothing else. */
    private data class DetectKey(
        val grav: Long, val hr: Long, val rr: Long, val resp: Long,
        val tz: Long, val wristOff: Long, val band: Long, val v2: Boolean,
        val sleepHRBaseline: Double?,
    )

    /** Bound ≈ the distinct days of a scoring window (matches the Swift detectSleepCache capacity, 40).
     *  Access-order LRU so the hottest nights survive a long session; an entry is a handful of small
     *  sessions — the multi-hour raw streams are never retained (#707 rule: the cache must not be the
     *  next leak). */
    private const val DETECT_CACHE_MAX_DAYS = 40
    private val detectCache = object : LinkedHashMap<DetectKey, List<DetectedSleep>>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<DetectKey, List<DetectedSleep>>): Boolean =
            size > DETECT_CACHE_MAX_DAYS
    }
    private val detectCacheLock = Any()

    /** Deep copy across the memo boundary. [DetectedSleep] itself is immutable, but its `stages` are
     *  mutable [StageSegment]s — the exact reason [StagerCache] deep-copies hypnograms — so the memo
     *  holds a private copy and hands every hit a fresh one; a caller reshaping a segment in place can
     *  never poison the cache. Swift needs no copy (value-type structs); Kotlin's mutable StageSegment
     *  does. O(stages), a rounding error next to the detection spine the memo skips. */
    private fun copyDetected(sessions: List<DetectedSleep>): List<DetectedSleep> =
        sessions.map { it.copy(stages = StagerCache.copyOf(it.stages)) }

    /**
     * Detect sleep sessions from biometric streams. Empty/absent gravity → [].
     * Gravity-only input degrades gracefully (HR/RR/resp refinements skipped).
     *
     * [tzOffsetSeconds] is the wall-clock UTC offset (TimeZone.getDefault().getOffset)
     * used ONLY to place each window's center on a LOCAL clock for the daytime false-sleep
     * guard (#90). It defaults to 0 so the pure function and its tests stay UTC; the live
     * call site (IntelligenceEngine) passes the device's real offset.
     *
     * [wristOff] is an optional list of off-wrist [start, end) intervals (unix seconds), paired from
     * the strap's WRIST_OFF/WRIST_ON events by `AnalyticsEngine.offWristIntervals`. When the call site
     * has them (IntelligenceEngine reads `repo.events`), they sharpen the always-on HR-gap off-wrist
     * backstop: a candidate run is dropped when its off-wrist coverage (HR-gap spans UNION these
     * intervals) reaches [maxOffWristSleepFraction] of its duration — the FRACTIONAL rule from #504, so
     * a real night with a short off-wrist tail survives (#500). Defaults to empty (HR-gap proxy only),
     * so the pure function and its tests stay event-free.
     *
     * PERF (#707 parity, mirrors the Swift detectSleepCache): this is the single heaviest analytics
     * call — it sorts the dense full-day gravity stream, builds the delta/still spine, and stages every
     * accepted run — and [IntelligenceEngine.analyzeRecent] re-runs it per day across the window every
     * 15-min tick, so an idempotent re-pass (or a sync that never touched a given day) redid all of it
     * for an identical result; the exact path that ANR'd before #125. Android had only the staging-layer
     * [StagerCache], so the detection spine still re-ran uncached ~21× per pass. The public entry now
     * memoizes the RESULT on a FULL input key (every argument that steers detection or staging: the four
     * streams, tz offset, #500 off-wrist intervals, #531 band state, the V2 toggle) in a bounded LRU. A
     * hit is byte-identical to recomputing — the memo only ever skips work, never changes it.
     */
    fun detectSleep(
        hr: List<HrSample> = emptyList(),
        rr: List<RrInterval> = emptyList(),
        resp: List<RespSample> = emptyList(),
        gravity: List<GravitySample>,
        tzOffsetSeconds: Long = 0L,
        wristOff: List<Pair<Long, Long>> = emptyList(),
        // The strap's OWN persisted v18 BAND sleep_state per timestamp (Interpreter's `(sb shr 4) and 3`:
        // 0 wake / 1 still / 2 asleep / 3 up), consumed ONLY to confirm a borderline H7 morning re-onset
        // (#531): a daytime block the strap itself scored predominantly "asleep" is kept even on a borderline
        // HR dip. Default empty keeps pure-function callers/tests free of it; IntelligenceEngine passes the
        // night window's persisted band state. It can only RESCUE a real-sleep block, never fabricate. Mirrors Swift.
        bandSleepState: List<Pair<Long, Int>> = emptyList(),
        // 7.0.0 (default ON since #277/#351): which recipe stages an accepted night — the cardiorespiratory
        // [SleepStagerV2.stageSession] when true, V1's [stageSession] when false. DETECTION is unchanged
        // (same accepted windows); only the per-epoch hypnogram differs.
        // THE TWO DEFAULTS DIFFER. This PARAMETER defaults false so pure-function callers and the
        // frozen-golden tests stay byte-identical. The SHIPPED app never takes that default: the live call
        // site threads the experimentalSleepV2 preference, which is default TRUE (V2 promoted over V1 in
        // #277, extended to every strap family in #351), so a normal user's nights are staged by V2.
        // Mirrors Swift.
        useSleepStagerV2: Boolean = false,
        // Motion-corroborated wake (#462, directive b): the wearer's PERSONALISED overnight HR band
        // ([adaptiveOvernightHRBaseline]), used by [confirmSleepWithHR] in place of the day-median so a
        // supplement / fitness era self-calibrates the sleep band. Default null keeps the day-median
        // (byte-identical when unset); the live call site can thread a value derived from the trailing sleep
        // history. Folded into the memo key so a changed band re-keys. Mirrors Swift.
        sleepHRBaseline: Double? = null,
        // Sleep & Rest test mode (E10): when non-null, each candidate run emits ONE gate verdict line
        // and the sparse-gravity bridge records its result. Side-effect-only; the returned list is
        // byte-identical to the untraced call. Default null = no work, byte-identical. Mirrors Swift.
        traceSink: ((String) -> Unit)? = null,
    ): List<DetectedSleep> {
        // Test mode ONLY: a requested trace MUST run the live gate ladder so every verdict emits for THIS
        // night — never a silent memo replay. The trace is side-effect-only (the returned list is
        // byte-identical to the untraced call), so every real call still memoizes below. Mirrors the
        // Swift detectSleep traceSink bypass (#707).
        if (traceSink != null) {
            return detectSleepUncached(hr, rr, resp, gravity, tzOffsetSeconds, wristOff,
                bandSleepState, useSleepStagerV2, sleepHRBaseline, traceSink)
        }
        val key = DetectKey(
            // Fold the three gravity axes SEPARATELY (raw IEEE-754 bits, like StagerCache.fingerprint)
            // rather than quantising the x+y+z SUM: two different postures sharing a component sum must
            // not alias. DELIBERATELY harder than the Swift key's summed quant — a fingerprint difference
            // can only cost one platform an extra recompute, never change a value, so this is free
            // collision hardening, not a parity break.
            grav = streamFingerprint(gravity, { it.ts }) { s ->
                var q = java.lang.Double.doubleToRawLongBits(s.x)
                q = q * 1_000_003L + java.lang.Double.doubleToRawLongBits(s.y)
                q = q * 1_000_003L + java.lang.Double.doubleToRawLongBits(s.z)
                q
            },
            hr = streamFingerprint(hr, { it.ts }) { it.bpm.toLong() },
            rr = streamFingerprint(rr, { it.ts }) { it.rrMs.toLong() },
            resp = streamFingerprint(resp, { it.ts }) { it.raw.toLong() },
            tz = tzOffsetSeconds,
            wristOff = streamFingerprint(wristOff, { it.first }) { it.second },
            band = streamFingerprint(bandSleepState, { it.first }) { it.second.toLong() },
            v2 = useSleepStagerV2,
            sleepHRBaseline = sleepHRBaseline,
        )
        synchronized(detectCacheLock) { detectCache[key] }?.let { return copyDetected(it) }
        // Compute OUTSIDE the lock (the Swift AnalyticsMemoCache does the same): a slow night never
        // serialises another thread's lookup, and a racing duplicate compute just overwrites the entry
        // with an identical value — benign, the function is deterministic.
        val sessions = detectSleepUncached(hr, rr, resp, gravity, tzOffsetSeconds, wristOff,
            bandSleepState, useSleepStagerV2, sleepHRBaseline, null)
        synchronized(detectCacheLock) { detectCache[key] = copyDetected(sessions) }
        return sessions
    }

    /** The unchanged detection + staging pipeline, split out verbatim so [detectSleep] can memoize in
     *  front (#707 parity). Parameters are documented on the public wrapper. */
    private fun detectSleepUncached(
        hr: List<HrSample>,
        rr: List<RrInterval>,
        resp: List<RespSample>,
        gravity: List<GravitySample>,
        tzOffsetSeconds: Long,
        wristOff: List<Pair<Long, Long>>,
        bandSleepState: List<Pair<Long, Int>>,
        useSleepStagerV2: Boolean,
        sleepHRBaseline: Double?,
        traceSink: ((String) -> Unit)?,
    ): List<DetectedSleep> {
        val grav = gravity.sortedBy { it.ts }
        if (grav.size < 2) return emptyList()

        val hrS = hr.sortedBy { it.ts }
        val rrS = rr.sortedBy { it.ts }
        val respS = resp.sortedBy { it.ts }

        val baseline = hrBaseline(hrS)
        // Sparse-gravity gate (#308): an un-unlocked WHOOP 5.0 backfills mostly v18/v26 records
        // where gravity is clumped (~25% coverage), so the gravity-only spine fragments the night.
        // ONLY when sparse do the three robustness branches engage; a dense 4.0 night is `false`
        // here and follows the exact original path (byte-identical).
        val sparse = isGravitySparse(grav, hrS)

        val deltas = gravityDeltas(grav)
        val flags = classifyStill(grav, deltas)
        var runs = buildRuns(grav, flags, sparse = sparse, hr = hrS, baseline = baseline)
        runs = mergePeriods(runs)
        // Re-stitch sleep runs fragmented by pure gravity dropouts (sparse only) before minSleepMin.
        val runsBeforeBridge = if (traceSink == null) 0 else runs.count { it.stage == "sleep" }
        runs = bridgeSparseSleep(runs, sparse = sparse, hr = hrS, baseline = baseline)
        // Sleep & Rest test mode (E10): record the sparse-gravity bridge result, so a sparse 5.0 night
        // rescued from fragmentation is visible. Only when gravity is sparse and only when tracing.
        if (traceSink != null && sparse) {
            val runsAfterBridge = runs.count { it.stage == "sleep" }
            traceSink(SleepStagerTrace.runLine(-1, 0, 0,
                if (runsAfterBridge < runsBeforeBridge) SleepStagerTrace.Verdict.KEPT else SleepStagerTrace.Verdict.DROPPED,
                "sparseBridge", "sparse=true gapMin=$sparseBridgeGapMin runsBefore=$runsBeforeBridge runsAfter=$runsAfterBridge"))
        }

        val minSleepS = (minSleepMin * 60).toLong()

        val sessions = ArrayList<DetectedSleep>()
        // Continuous-sleep chain tracking so a real overnight sleep that runs PAST the daytime-band
        // start (a late wake, or a brief morning stir then back to sleep that leaves the tail as its
        // own daytime-centered run) is NOT mistaken for an isolated daytime nap and rejected — which
        // truncated the displayed wake time to ~late morning. A daytime run skips the nap guard ONLY
        // when it directly continues (≤ nightContinuationGap) a chain that BEGAN overnight; isolated
        // daytime stillness (hours after waking) still faces the full guard.
        // Reimplemented from @vulnix0x4's PR #353.
        val continuationGapS = (nightContinuationGapMin * 60).toLong()
        var chainPrevEnd: Long? = null       // end of the last accepted sleep run
        var chainFromOvernight = false       // did the current contiguous chain begin overnight?
        // Sleep & Rest test mode (E10): each candidate sleep run emits ONE verdict line naming the gate
        // that kept or dropped it. The decisions below are byte-identical to the untraced path; the
        // traceSink calls are the only addition and never alter `sessions`. `runIndex` counts only
        // sleep-stage runs so the trace numbers match the candidate ordinal.
        var runIndex = -1
        // #737 follow-up: counters for the one-line detection summary emitted before `return` (below).
        // Trace-only — never read back into `sessions`, so the untraced path stays byte-identical. They
        // make the "slept 8h, app shows 1h" shape legible at a glance: a big detectedSpan with most runs
        // dropped by the 60-min gate is the fragmentation signature. Mirrors Swift.
        var sleepRunsSeen = 0
        var minSleepDrops = 0
        var firstSleepStart = Long.MAX_VALUE
        var lastSleepEnd = 0L
        for (p in runs) {
            if (p.stage != "sleep") continue
            runIndex += 1
            sleepRunsSeen += 1
            firstSleepStart = minOf(firstSleepStart, p.start)
            lastSleepEnd = maxOf(lastSleepEnd, p.end)
            val spanMin = ((p.end - p.start) / 60).toInt()
            if ((p.end - p.start) <= minSleepS) {
                minSleepDrops += 1
                traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                    SleepStagerTrace.Verdict.DROPPED, "minSleepMin", "spanMin=$spanMin minSleepMin=$minSleepMin"))
                continue
            }
            // H4 physiological in-bed span cap (#547/#531/#509 tail): a single assembled main-sleep run
            // longer than ~16 h is a bad-clock artefact (a frozen still stretch banked under a stale/wrong
            // clock), not a real night. Drop it rather than report (or truncate to) a 12 h+ "sleep" — an
            // over-long block can't be trusted to assert a span at all, and truncating would fabricate a
            // wake time. Checked before staging so the artefact never reaches the aggregate. Mirrors Swift.
            if ((p.end - p.start) > maxMainSleepSpanS) {
                traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                    SleepStagerTrace.Verdict.DROPPED, "maxMainSleepSpanS", "spanMin=$spanMin maxMainSleepSpanMin=${maxMainSleepSpanS / 60}"))
                continue
            }
            if (!confirmSleepWithHR(p, hrS, baseline, grav = grav, sleepHRBaseline = sleepHRBaseline)) {
                traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                    SleepStagerTrace.Verdict.DROPPED, "hrConfirm", "hrSleepBaselineMult=$hrSleepBaselineMult baseline=${baseline?.toInt() ?: -1}"))
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
            val offFrac = offWristFraction(p, hrS, wristOff)
            if (offFrac >= maxOffWristSleepFraction) {
                traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                    SleepStagerTrace.Verdict.DROPPED, "offWrist", "offWristFrac=${SleepStagerTrace.round2(offFrac)} max=$maxOffWristSleepFraction"))
                continue
            }
            // Daytime false-sleep guard (#90): a window centered in the local daytime band
            // must clear a stricter bar (≥daytimeMinSleepMin AND a real resting-HR dip).
            // Overnight windows skip this entirely. restingHR is computed here (reused below).
            val resting = sessionRestingHR(start = p.start, end = p.end, hr = hrS)
            val continuesChain = chainPrevEnd?.let { p.start - it <= continuationGapS } ?: false
            val isNightTail = continuesChain && chainFromOvernight   // the night's tail, not a nap
            // H7 (#531): when the prior accepted chain BEGAN overnight, its wake (chainPrevEnd) anchors the
            // morning-stillness window. A daytime block beginning within it that is NOT a night-tail must
            // clear the STRONGER re-onset bar — killing the 9 am phantom nap of residual post-wake stillness
            // while keeping a genuine second sleep. Outside the window the guard is the ordinary daytime bar.
            val morningWakeEnd = if (chainFromOvernight) chainPrevEnd else null
            val isDaytime = isDaytimeCenter(p, tzOffsetSeconds)
            // Evaluate the morning-stillness guard ONLY when the run is daytime-centered, preserving the
            // original short-circuit (overnight runs never call it). The boolean used to drop below is
            // identical to the original combined condition.
            val passesMorning = if (isDaytime)
                passesMorningStillnessGuard(p, resting, baseline, morningWakeEnd, bandSleepState)
            else true
            if (isDaytime && !passesMorning && !isNightTail) {
                val gateName = if (morningWakeEnd != null) "morningStillness" else "daytimeGuard"
                traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                    SleepStagerTrace.Verdict.DROPPED, gateName,
                    "daytime=true restingHR=${resting ?: -1} baseline=${baseline?.toInt() ?: -1} nightTail=false"))
                continue
            }
            val rawStages = if (useSleepStagerV2) {
                SleepStagerV2.stageSession(start = p.start, end = p.end, grav = grav,
                    hr = hrS, rr = rrS, resp = respS)
            } else {
                stageSession(start = p.start, end = p.end, grav = grav,
                    hr = hrS, rr = rrS, resp = respS)
            }
            // Band sleep_state WAKE-veto: recover INTERIOR false-wake epochs the strap's OWN band
            // ([bandSleepState]) scored "asleep". No-op when the band is absent (WHOOP 4.0) or the flag is
            // off; stager-agnostic (corrects whichever hypnogram V1/V2 produced). Efficiency below is then
            // computed on the corrected stages, so a night NOOP over-called wake on reports true efficiency.
            val stages = applyBandStateWakeVeto(rawStages, start = p.start, end = p.end,
                bandSleepState = bandSleepState)
            val eff = efficiency(start = p.start, end = p.end, stages = stages)
            val avgHrv = sessionAvgHRV(start = p.start, end = p.end, rr = rrS)
            sessions.add(
                DetectedSleep(
                    start = p.start, end = p.end, efficiency = eff,
                    stages = stages, restingHR = resting, avgHRV = avgHrv,
                )
            )
            traceSink?.invoke(SleepStagerTrace.runLine(runIndex, p.start, p.end,
                SleepStagerTrace.Verdict.KEPT, "accepted",
                "spanMin=$spanMin eff=${SleepStagerTrace.round2(eff)} restingHR=${resting ?: -1} daytime=$isDaytime"))
            // #1210 shadow: the band wake-veto is dormant (default-off), but its recovered-vs-reverse ratio
            // can only come from banded nights. When a band stream is present, compute what the veto WOULD
            // recover and trace it — OUTPUT-NEUTRAL: `stages`/`eff` persisted above are the flag-gated
            // (unchanged) values and nothing reads `shadowStages`. Guarded on `traceSink`, so it fires ONLY
            // while a diagnostic is collecting (zero production cost). Retire once the flip (#1210) lands.
            if (traceSink != null && !bandStateWakeVetoEnabled && bandSleepState.isNotEmpty()) {
                // cutoffTs = 0 on purpose: the shadow measures the FULL veto potential across EVERY banded
                // night (history included) to build the validation distribution, independent of whatever
                // new-nights cutoff the eventual flip uses.
                val shadowStages = applyBandStateWakeVeto(rawStages, start = p.start, end = p.end,
                    bandSleepState = bandSleepState, enabled = true, cutoffTs = 0L)
                val shadowEff = efficiency(start = p.start, end = p.end, stages = shadowStages)
                val recoveredMin = (shadowEff - eff) * (p.end - p.start).toDouble() / 60.0
                if (recoveredMin >= 1.0) {
                    traceSink(bandVetoShadowLine(startTs = p.start, recoveredMin = recoveredMin,
                        rawEff = eff, shadowEff = shadowEff))
                }
            }
            // A run that does NOT continue the chain re-anchors it on this run's onset.
            if (!continuesChain) chainFromOvernight = isOvernightOnset(p.start, tzOffsetSeconds)
            chainPrevEnd = p.end
        }
        sessions.sortBy { it.start }
        // #737 follow-up: one glanceable line summarising the whole detection pass. A large
        // detectedSpanMin with most runs droppedMinSleep and a small survivingSpanMin is exactly the
        // "slept ~8h, only ~1h confirmed" fragmentation the field reports describe. Trace-only. Byte-
        // identical string to Swift's summary line.
        if (traceSink != null) {
            val detectedSpanMin = if (lastSleepEnd > firstSleepStart) ((lastSleepEnd - firstSleepStart) / 60).toInt() else 0
            val survivingSpanMin = (sessions.sumOf { it.end - it.start } / 60).toInt()
            traceSink(
                "sleep-detect summary: sleepRuns=$sleepRunsSeen droppedMinSleep=$minSleepDrops " +
                    "kept=${sessions.size} detectedSpanMin=$detectedSpanMin survivingSpanMin=$survivingSpanMin " +
                    "sparse=$sparse grav=${grav.size} hr=${hrS.size}"
            )
        }
        return sessions
    }

    /** asleep / in-bed in [0, 1]; asleep = in-bed − wake. */
    internal fun efficiency(start: Long, end: Long, stages: List<StageSegment>): Double {
        val inBed = (end - start).toDouble()
        if (inBed <= 0) return 0.0
        val wake = stages.filter { SleepStageVocabulary.isWake(it.stage) }.sumOf { (it.end - it.start).toDouble() }
        val asleep = maxOf(0.0, inBed - wake)
        return minOf(1.0, asleep / inBed)
    }

    // ── Stage 1–3: staging over a 30 s epoch grid ────────────────────────────

    /** First persistent-sleep epoch (onset) and last sleep epoch (final wake). */
    internal fun onsetAndFinalWake(ckFlags: List<Boolean>): Pair<Int, Int> {
        val n = ckFlags.size
        if (n == 0) return Pair(0, 0)
        var onset: Int? = null
        var run = 0
        for ((i, s) in ckFlags.withIndex()) {
            run = if (s) run + 1 else 0
            if (run >= onsetPersistEpochs) {
                onset = i - onsetPersistEpochs + 1
                break
            }
        }
        var final: Int? = null
        for (i in n - 1 downTo 0) {
            if (ckFlags[i]) {
                final = i
                break
            }
        }
        val o = onset ?: 0
        var f = final ?: (n - 1)
        if (f < o) f = n - 1
        return Pair(o, f)
    }

    /**
     * Build a 30 s hypnogram for [start, end] and return StageSegments.
     *
     * PERF (v7.0.2 / #707): staging is the heaviest per-night step on the model path and it was being
     * re-run for EVERY detected night on EVERY [IntelligenceEngine.analyzeRecent] — ~21× per post-sync
     * pass, again per sleep edit, and up to thousands of nights on the one-shot full-history Effort rescore
     * (maxDays=4000). It is a pure function of (start, end, samples), so this is a thin cache veneer over
     * [stageSessionUncached]: each distinct night stages AT MOST ONCE, peak heap stays flat across repeated
     * passes, and the output is byte-identical (the cached list is the same one the recipe produced, handed
     * back as a fresh copy so a caller extending a segment in place can never poison the cache). Edits
     * invalidate naturally — a moved bed/wake time changes start/end → new key; newly-banked samples change
     * the per-stream count/edge-ts/checksum → new key (see [StagerCache.fingerprint]).
     */
    internal fun stageSession(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): List<StageSegment> {
        val key = StagerCache.fingerprint(StagerCache.Version.V1, start, end, grav, hr, rr, resp)
        StagerCache.get(key)?.let { return StagerCache.copyOf(it) }
        val segments = stageSessionUncached(start, end, grav, hr, rr, resp)
        StagerCache.put(key, segments)
        return StagerCache.copyOf(segments)
    }

    /** The pure recipe, exactly as before — extracted so [stageSession] can memoize it. */
    private fun stageSessionUncached(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): List<StageSegment> {
        val gSeg = rowsBetween(grav, start, end) { it.ts }
        if (gSeg.size < 2) return listOf(StageSegment(start = start, end = end, stage = "light"))

        val gDeltas = gravityDeltas(gSeg)
        val gTimes = gSeg.map { it.ts }

        val hrSeg = rowsBetween(hr, start, end) { it.ts }
        val rrSeg = rowsBetween(rr, start, end) { it.ts }
        val respSeg = rowsBetween(resp, start, end) { it.ts }

        val grid = buildEpochGrid(
            start = start.toDouble(), end = end.toDouble(),
            gravTimes = gTimes, gravDeltas = gDeltas,
            hr = hrSeg, rr = rrSeg, resp = respSeg,
        )
        if (grid.nEpochs == 0) return listOf(StageSegment(start = start, end = end, stage = "light"))

        val rescaled = rescaleCounts(grid.counts)
        val ckFlags = coleKripke(rescaled)
        val (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)

        val dogHR = dogHRVariability(grid.hr)
        val feats = extractFeatures(grid = grid, ckFlags = ckFlags, dogHR = dogHR,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)

        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, features = feats,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)
        // Conservative fragment merge (#274): absorb sub-3-min stage flecks (the WHOOP 5/MG
        // sparse-motion artefact) so the hypnogram stops reading choppier than WHOOP's,
        // without erasing genuine multi-minute transitions. Display/scoring only — the
        // per-epoch detection above is unchanged.
        labels = mergeFragments(labels)

        // Pre-onset and post-final-wake epochs are not sleep → force wake.
        val mutLabels = labels.toMutableList()
        for (i in mutLabels.indices) {
            if (i < onsetIdx || i > finalWakeIdx) mutLabels[i] = "wake"
        }

        // Merge consecutive same-stage epochs into segments tiling [start, end].
        val segments = ArrayList<StageSegment>()
        for ((i, stage) in mutLabels.withIndex()) {
            val segStart = grid.edges[i].roundToLong()
            val segEnd = grid.edges[i + 1].roundToLong()
            val last = segments.lastOrNull()
            if (last != null && last.stage == stage) {
                segments[segments.size - 1].end = segEnd
            } else {
                segments.add(StageSegment(start = segStart, end = segEnd, stage = stage))
            }
        }
        if (segments.isNotEmpty()) segments[segments.size - 1].end = end
        return segments
    }

    // ── Per-epoch motion (H8 — persisted beside stagesJSON) ───────────────────

    /**
     * The per-epoch MOTION magnitudes for a session window, on the SAME 30 s epoch grid as [stageSession]'s
     * `stagesJSON` (one entry per epoch, in order). Each value is the epoch's summed |Δgravity| (the raw
     * pre-rescale Cole–Kripke activity count) — the strap's own motion signal, banked so later passes and
     * the UI can read per-epoch movement without re-reading the raw gravity stream. Returns `[]` when the
     * window has too little gravity to grid (mirrors [stageSession]'s degenerate fallback), so the caller
     * persists NULL (no fabricated zero series). Pure + deterministic; shares [buildEpochGrid] with staging
     * so the grids align epoch-for-epoch. Mirrors Swift `sessionEpochMotion`. (H8)
     */
    fun sessionEpochMotion(start: Long, end: Long, grav: List<GravitySample>): List<Double> {
        val gSeg = rowsBetween(grav, start, end) { it.ts }
        if (gSeg.size < 2) return emptyList()
        val gDeltas = gravityDeltas(gSeg)
        val gTimes = gSeg.map { it.ts }
        val grid = buildEpochGrid(
            start = start.toDouble(), end = end.toDouble(),
            gravTimes = gTimes, gravDeltas = gDeltas,
            hr = emptyList(), rr = emptyList(), resp = emptyList(),
        )
        return grid.counts
    }

    /**
     * #175: the strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up) gridded onto the SAME 30 s epoch
     * grid `stagesJSON` / [sessionEpochMotion] use, so the caller can persist it via
     * [com.noop.data.WhoopRepository.persistSessionSleepState] and the H7 re-onset CONFIRM guard can read it
     * back as timestamped `(startTs + i*epochS, state)` samples. Returns EMPTY when the session carries no
     * band-state samples (a WHOOP 4.0, or an unbanded window) — an absent signal stays absent, never a
     * fabricated array. When present, each epoch takes the band's LAST reported state within its
     * `[start + i*30, start + (i+1)*30)` window; an epoch with no sample of its own CARRIES FORWARD the
     * previous epoch's state (band state is a step function). Leading epochs before the first sample take the
     * first sample's state. The band code is carried VERBATIM — this never converts an unproven code into a
     * derived stage; consumers decide meaning. Mirrors Swift `sessionEpochSleepState`. (#175)
     */
    fun sessionEpochSleepState(start: Long, end: Long, sleepState: List<Pair<Long, Int>>): List<Int> {
        val seg = rowsBetween(sleepState, start, end) { it.first }.sortedBy { it.first }
        if (seg.isEmpty() || end <= start) return emptyList()
        val nEpochs = maxOf(1, kotlin.math.ceil((end - start).toDouble() / epochS).toInt())
        val out = IntArray(nEpochs) { seg[0].second }   // lead-in = first sample's state
        var last = seg[0].second
        var si = 0
        for (i in 0 until nEpochs) {
            val epochEnd = start + ((i + 1) * epochS).toLong()
            // Advance through every sample that falls in/at-or-before this epoch's window; the LAST one wins.
            while (si < seg.size && seg[si].first < epochEnd) {
                last = seg[si].second
                si++
            }
            out[i] = last   // carry-forward when the epoch had no sample of its own
        }
        return out.toList()
    }

    // ── Epoch grid ────────────────────────────────────────────────────────────

    internal class EpochGrid(
        val start: Double,
        val end: Double,
        val edges: List<Double>,
        /** per-epoch summed |Δgravity| (raw, pre-rescale). */
        val counts: List<Double>,
        /** scale-robust per-epoch moving-sample fraction. */
        val moveFrac: List<Double>,
        /** per-epoch mean HR (bpm) or NaN. */
        val hr: List<Double>,
        /** per-epoch RR intervals (ms). */
        val rr: List<List<Double>>,
        /** per-epoch raw respiration samples. */
        val resp: List<List<Double>>,
    ) {
        val nEpochs: Int get() = counts.size
        fun epochMid(i: Int): Double = edges[i] + epochS / 2.0
    }

    internal fun buildEpochGrid(
        start: Double, end: Double,
        gravTimes: List<Long>, gravDeltas: List<Double>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): EpochGrid {
        if (end <= start) {
            return EpochGrid(
                start = start, end = end, edges = listOf(start), counts = emptyList(),
                moveFrac = emptyList(), hr = emptyList(), rr = emptyList(), resp = emptyList(),
            )
        }
        val nEpochs = maxOf(1, ceil((end - start) / epochS).toInt())
        val edges = DoubleArray(nEpochs + 1) { start + it.toDouble() * epochS }
        edges[nEpochs] = maxOf(edges[nEpochs], end)

        val counts = DoubleArray(nEpochs)
        val moveN = IntArray(nEpochs)
        val gravN = IntArray(nEpochs)
        val hrSum = DoubleArray(nEpochs)
        val hrCnt = IntArray(nEpochs)
        val rrBuckets = Array(nEpochs) { ArrayList<Double>() }
        val respBuckets = Array(nEpochs) { ArrayList<Double>() }

        fun idx(ts: Double): Int? {
            if (ts < start || ts >= end) {
                if (ts == end) return nEpochs - 1
                return null
            }
            val i = ((ts - start) / epochS).toInt()
            return minOf(i, nEpochs - 1)
        }

        for (k in gravTimes.indices) {
            val i = idx(gravTimes[k].toDouble()) ?: continue
            counts[i] += gravDeltas[k]
            gravN[i] += 1
            if (gravDeltas[k] >= moveDeltaThresholdG) moveN[i] += 1
        }
        for (r in hr) {
            val i = idx(r.ts.toDouble()) ?: continue
            hrSum[i] += r.bpm.toDouble()
            hrCnt[i] += 1
        }
        for (r in rr) {
            val i = idx(r.ts.toDouble()) ?: continue
            rrBuckets[i].add(r.rrMs.toDouble())
        }
        for (r in resp) {
            val i = idx(r.ts.toDouble()) ?: continue
            respBuckets[i].add(r.raw.toDouble())
        }

        val hrMean = List(nEpochs) { if (hrCnt[it] > 0) hrSum[it] / hrCnt[it].toDouble() else Double.NaN }
        // No gravity coverage → 1.0 (treat as moving; conservative).
        val moveFrac = List(nEpochs) { if (gravN[it] > 0) moveN[it].toDouble() / gravN[it].toDouble() else 1.0 }

        return EpochGrid(
            start = start, end = end, edges = edges.toList(), counts = counts.toList(),
            moveFrac = moveFrac, hr = hrMean,
            rr = rrBuckets.map { it.toList() }, resp = respBuckets.map { it.toList() },
        )
    }

    // ── Cole–Kripke ────────────────────────────────────────────────────────────

    internal fun rescaleCounts(counts: List<Double>): List<Double> =
        counts.map { minOf(it / ckCountDivisor, ckCountClip) }

    internal fun coleKripke(rescaled: List<Double>): List<Boolean> {
        val n = rescaled.size
        val flags = ArrayList<Boolean>(n)
        for (i in 0 until n) {
            var si = 0.0
            for ((k, w) in ckWeights.withIndex()) {
                val j = i - ckBack + k
                val a = if (j in 0 until n) rescaled[j] else 0.0
                si += w * a
            }
            si *= ckScale
            flags.add(si < 1.0)
        }
        return flags
    }

    // ── Walch difference-of-Gaussians HR variability ─────────────────────────

    internal fun gaussianKernel(sigmaS: Double, dtS: Double = epochS): List<Double> {
        val sigma = maxOf(sigmaS / dtS, 1e-6) // σ in epochs
        val radius = maxOf(1, ceil(3 * sigma).toInt())
        val k = ArrayList<Double>(2 * radius + 1)
        for (x in -radius..radius) {
            k.add(exp(-0.5 * (x.toDouble() / sigma).pow(2)))
        }
        val sum = k.sum()
        return k.map { it / sum }
    }

    /** Same-length convolution with reflect padding (edge-stable). */
    internal fun convolveReflect(x: List<Double>, kernel: List<Double>): List<Double> {
        val r = kernel.size / 2
        // A signal shorter than the kernel radius can't be reflect-padded (the mirror reads x[r]
        // and x[x.size-2-i]) — return it unchanged rather than indexing out of bounds. In practice
        // the only caller is gated by the 60-min session floor, so this is defensive.
        if (r == 0 || x.size <= r) return x
        // Reflect padding: numpy 'reflect' mirrors WITHOUT repeating the edge sample.
        val padded = ArrayList<Double>(x.size + 2 * r)
        for (i in 0 until r) padded.add(x[r - i]) // x[r], x[r-1], ... x[1]
        padded.addAll(x)
        for (i in 0 until r) padded.add(x[x.size - 2 - i]) // x[n-2], x[n-3], ...
        // Valid convolution, then take the first x.count outputs.
        val out = ArrayList<Double>(x.size)
        val m = kernel.size
        // np.convolve(padded, kernel, 'valid') has length padded.count - m + 1.
        for (i in 0..(padded.size - m)) {
            var acc = 0.0
            for (j in 0 until m) acc += padded[i + j] * kernel[m - 1 - j]
            out.add(acc)
            if (out.size == x.size) break
        }
        return out
    }

    /**
     * DoG-filtered HR (σ1=120 s minus σ2=600 s). NaNs linearly interpolated first;
     * all-NaN → zeros.
     */
    internal fun dogHRVariability(hrPerEpoch: List<Double>): List<Double> {
        val n = hrPerEpoch.size
        if (n == 0) return emptyList()
        val maskIdx = (0 until n).filter { !hrPerEpoch[it].isNaN() }
        if (maskIdx.isEmpty()) return List(n) { 0.0 }

        // Linear interpolation over the grid (numpy.interp semantics: clamp at edges).
        val filled = DoubleArray(n)
        val first = maskIdx.first()
        val last = maskIdx.last()
        for (i in 0 until n) {
            if (!hrPerEpoch[i].isNaN()) {
                filled[i] = hrPerEpoch[i]
                continue
            }
            // find surrounding known points
            if (i <= first) {
                filled[i] = hrPerEpoch[first]
                continue
            }
            if (i >= last) {
                filled[i] = hrPerEpoch[last]
                continue
            }
            var lo = first
            var hi = last
            for (m in maskIdx) {
                if (m <= i) lo = m
                if (m >= i) {
                    hi = m
                    break
                }
            }
            if (hi == lo) {
                filled[i] = hrPerEpoch[lo]
            } else {
                val frac = (i - lo).toDouble() / (hi - lo).toDouble()
                filled[i] = hrPerEpoch[lo] + frac * (hrPerEpoch[hi] - hrPerEpoch[lo])
            }
        }

        val k1 = gaussianKernel(sigmaS = hrDogSigma1S)
        val k2 = gaussianKernel(sigmaS = hrDogSigma2S)
        val g1 = convolveReflect(filled.toList(), k1)
        val g2 = convolveReflect(filled.toList(), k2)
        return List(n) { g1[it] - g2[it] }
    }

    // ── Respiration rate + RRV (raw 1 Hz) ────────────────────────────────────

    /**
     * Estimate respiratory rate (breaths/min) and RRV (s) from a raw resp window.
     * Detrend → peak-pick (≥2 s apart) → breath intervals (1.5–12 s) → rate =
     * 60/median interval, RRV = std of intervals. (NaN, NaN) when too few samples.
     *
     * Faithful port of sleep_features.resp_rate_and_rrv using a simple local-maxima
     * peak finder. Returned as a Pair(rate, rrv).
     */
    internal fun respRateAndRRV(respRaw: List<Double>, dtS: Double = 1.0): Pair<Double, Double> {
        val nan = Double.NaN
        if (respRaw.size < 8) return Pair(nan, nan)
        val mean = respRaw.sum() / respRaw.size.toDouble()
        val x = respRaw.map { it - mean }
        if (x.all { abs(it) < 1e-12 }) return Pair(nan, nan)

        val std = standardDeviation(x)
        if (std <= 0) return Pair(nan, nan)

        val minDistance = maxOf(2, (2.0 / dtS).roundToInt())
        val peaks = findPeaks(x, distance = minDistance, height = 0.0)
        if (peaks.size < 3) return Pair(nan, nan)

        val intervals = ArrayList<Double>()
        for (i in 1 until peaks.size) {
            val iv = (peaks[i] - peaks[i - 1]).toDouble() * dtS
            if (iv in 1.5..12.0) intervals.add(iv)
        }
        if (intervals.size < 2) return Pair(nan, nan)
        val rate = 60.0 / HrvAnalyzer.median(intervals)
        val rrv = standardDeviation(intervals) // population std (numpy default)
        return Pair(rate, rrv)
    }

    // ── Respiration rate from R-R (RSA) — WHOOP5 on-wire path ────────────────

    /** RSA tachogram resample rate (Hz). 4 Hz is the standard HRV resample grid. */
    private const val rsaResampleHz: Double = 4.0

    /** Moving-mean detrend window for the RSA tachogram (seconds). */
    private const val rsaDetrendWindowS: Double = 8.0

    /** Minimum spacing between breath peaks on the tachogram (seconds) → ≤24 bpm. */
    private const val rsaMinPeakDistanceS: Double = 2.5

    /** Per-window length for the per-window rate estimate (seconds). */
    private const val rsaWindowS: Double = 300.0

    /**
     * #977: wall-clock seconds a beat-to-beat step may exceed its own RR before the series is treated
     * as SPLICED there. `ts` is whole seconds, so a 1 s discrepancy is quantisation, not a gap; the
     * blocks that prompted this were 30-45 s. PROVISIONAL, like COVERAGE_PLAUSIBLE_CEILING - wide
     * enough that only an unambiguous dropout trips it, and deliberately not tuned to a corpus.
     * Byte-parity twin of Swift `rsaGapToleranceS`.
     */
    internal const val rsaGapToleranceS: Double = 3.0

    /** Physiologic breath-interval band (seconds): 0.1–0.4 Hz = 6–24 breaths/min. */
    private const val rsaMinBreathIntervalS: Double = 2.5  // 24 bpm
    private const val rsaMaxBreathIntervalS: Double = 10.0 // 6 bpm

    /**
     * THE canonical plausible sleeping-respiratory-rate band (bpm). The RSA peak-pick above can yield
     * 6–8 bpm at its noise floor, but every consumer (ReadinessEngine illness/readiness) only acts on
     * 8–25 — so a sub-8 estimate used to be persisted-then-silently-ignored. respRateFromRR now clamps
     * its output to this band (NaN outside it), and ReadinessEngine references this same range, so the
     * stored value can never disagree with what's acted on. (#78) */
    val respPlausibleRangeBpm: ClosedFloatingPointRange<Double> = 8.0..25.0

    /**
     * APPROXIMATE respiratory rate (breaths/min) from the R-R interval stream via
     * respiratory sinus arrhythmia (RSA), for use when no raw resp ADC channel is
     * available (WHOOP5 v18 wire is RR-only; resp ADC is WHOOP4 / cloud-only).
     *
     * This is an ON-DEVICE ESTIMATE, NOT a cloud/clinical respiration measurement.
     * It recovers the breathing-modulation of beat-to-beat timing, which tracks but
     * does not equal a chest-band / capnography rate.
     *
     * Pipeline (per matched in-bed session [start, end], unix SECONDS):
     *   1. Restrict RR ROWS to ts in [start, end] and apply the same range test
     *      HrvAnalyzer.rangeFilter applies, keeping the rows so `ts` survives (#977).
     *   2. Reconstruct beat times by cumulatively summing the kept RR intervals
     *      from the first in-bed beat, yielding an (irregular) tachogram, and note
     *      where the wall clock outran the beats (#977) - the cumulative sum cannot
     *      represent a dropout, so those points are splices, not elapsed time.
     *   3. Resample the tachogram onto a uniform ~4 Hz grid by linear interpolation.
     *   4. Detrend: subtract a centered moving mean (rsaDetrendWindowS).
     *   5. Per ~5-min window, SKIPPING any window containing a splice: findPeaks
     *      (min distance rsaMinPeakDistanceS) on the detrended grid, keep peak-to-peak
     *      intervals in the 6-24 bpm band, rate = 60 / median(intervals). Take the
     *      median across windows.
     *
     * Known bound on the splice skip (#977): step 4's centered mean spans +/-rsaDetrendWindowS/2, so a
     * splice just inside one window's edge leaves ~4 s of contaminated samples at the neighbouring
     * window's edge. That window is KEPT deliberately - discarding five minutes to avoid four seconds
     * costs far more data than it saves, and both medians (over intervals, then over windows) dilute a
     * single spurious peak among a five-minute window's worth.
     * Returns NaN when too few intervals survive (honest no-data).
     */
    internal fun respRateFromRR(rr: List<RrInterval>, start: Long, end: Long): Double {
        val nan = Double.NaN
        if (end <= start) return nan

        // 1. In-bed RR ROWS in chronological order, range-filtered.
        //
        // #977: the rows are kept, not just their values, because `ts` is the only signal that a beat is
        // missing. Beats lost before storage never enter the list, so contiguity derived from rejection
        // (cleanRRGapAware) cannot see them - it takes only a List<Double> and has no clock. Filtering the
        // rows by the same predicate HrvAnalyzer.rangeFilter applies keeps the surviving VALUES identical
        // (it is an order-preserving range test), which RespRateGapAwareTest pins.
        val inBedRows = rr.asSequence()
            .filter { it.ts in start..end }
            .sortedBy { it.ts }
            .filter { it.rrMs.toDouble() >= HrvAnalyzer.RR_MIN_MS && it.rrMs.toDouble() <= HrvAnalyzer.RR_MAX_MS }
            .toList()

        // Beat-accuracy gate (#882/#883): RSA needs per-beat-accurate TIMING - each row's wall-clock gap
        // must be ≈ its own R-R value. A BANKED stream (an Oura overnight IBI stamps a whole record of
        // intervals on one coarse ring-time) fails this, and the estimate it produces is not physiology;
        // return NaN instead. Beat-accurate callers (WHOOP R-R, the synthetic RSA fixtures) measure ~100%
        // and pass unchanged. Needs a few beats to judge; below that the count gate below handles it.
        //
        // Shares HrvAnalyzer's ONE definition of the judgement (#1108) rather than keeping a second copy:
        // "is each stored interval a real beat-to-beat measurement?" is the same question SDNN asks, and
        // one boundary deserves one set of constants. The range filter has already run, so an out-of-range
        // R-R cannot fail the accuracy test spuriously.
        //
        // WHAT THIS ACTUALLY CATCHES, measured (2026-08-07, two Oura nights, 31,460 and 30,754 in-bed
        // beats, fraction 0.0246 / 0.0235): NOT a corrupted time AXIS - the ring's records tile the night,
        // sum(R-R) over wall span is 1.030 / 1.008, so beat-time reconstructs the night to 1-3%. What is
        // unusable is the interval VALUES: the ring decomposes each ~6.6 s record into ~6 intervals whose
        // SUM is right to ~1% while the individual values are not beat-to-beat measurements (the same
        // decomposition documented on HrvAnalyzer.beatValuesAreTrustworthy). RSA reads the beat-to-beat
        // variation, so it has nothing to read, and the peak-picker returns its own floor: on both nights
        // the ungated estimate is 13.33 bpm, and SHUFFLING or REVERSING the night's R-R values returns the
        // SAME 13.3333 to four decimals. It is a plausible-looking number carrying zero information -
        // squarely inside respPlausibleRangeBpm, so the range clamp below never sees it. That is why the
        // gate is on BANKED-ness rather than on the output value.
        //
        // DISTINCT FROM #977's splice skip below, and BOTH are needed - they catch opposite banking
        // GEOMETRIES. #977 catches banking that TILES time (the real ring: a ~7 s record boundary against a
        // ~1.1 s interval reads as a splice, and on those two nights it independently discards 113/113 and
        // 114/114 windows). This catches banking that COMPRESSES time - respRateFromRR_batchedTimestampsIsNaN
        // stamps 6 beats per single second, so no gap ever exceeds rsaGapToleranceS and the splice skip
        // never fires. Neither subsumes the other; a firmware that changes its record period moves a stream
        // from one geometry to the other without warning. Byte-identical twin of the Swift gate.
        if (inBedRows.size >= 30) {
            val fraction = HrvAnalyzer.beatAccurateFraction(
                inBedRows.map { it.ts }, inBedRows.map { it.rrMs.toDouble() })
            if (!HrvAnalyzer.beatValuesAreTrustworthy(fraction)) return nan
        }

        val filtered = inBedRows.map { it.rrMs.toDouble() }
        if (filtered.size < 30) return nan // need enough beats for any RSA estimate

        // 2. Reconstruct beat times (seconds from session start) by cumulative sum.
        // #977: a dropout is where the WALL CLOCK outran the beat - ts jumps 30-45 s while the RR only
        // accounts for ~1 s. The cumulative sum cannot represent that, so it stitches the two sides
        // together and the tachogram gets a discontinuity the peak-picker reads as breathing. Record the
        // beat-time of each splice; step 5 drops the windows containing one. Beat times are NOT shifted
        // by the gap: within a run the relative timing is right, and that is all a kept window uses.
        //
        // This fires on a beat REJECTED just above too, not only one lost before storage: the range
        // test drops out-of-range intervals, so `ts` steps across them exactly as it does across a
        // dropout. That is the intent - both genuinely splice the tachogram, which is the same reason
        // #204/#195 made RMSSD skip differences across a removed beat - but it does mean a night with
        // heavy ectopic rejection now loses windows it used to keep.
        val beatTimes = DoubleArray(filtered.size)
        val spliceAtS = mutableListOf<Double>()
        var acc = 0.0
        for (i in filtered.indices) {
            if (i > 0) {
                val wallStepS = (inBedRows[i].ts - inBedRows[i - 1].ts).toDouble()
                if (wallStepS - filtered[i] / 1000.0 > rsaGapToleranceS) spliceAtS.add(acc)
            }
            acc += filtered[i] / 1000.0
            beatTimes[i] = acc
        }
        val totalSpanS = beatTimes[beatTimes.size - 1]
        if (totalSpanS < rsaWindowS / 2.0) return nan // < ~2.5 min of beats

        // 3. Resample onto a uniform grid by linear interpolation.
        val dt = 1.0 / rsaResampleHz
        val nGrid = (totalSpanS / dt).toInt() + 1
        if (nGrid < 8) return nan
        val grid = DoubleArray(nGrid)
        var seg = 0
        for (g in 0 until nGrid) {
            val t = g * dt
            // advance segment so beatTimes[seg] <= t <= beatTimes[seg+1]
            while (seg < beatTimes.size - 2 && beatTimes[seg + 1] < t) seg += 1
            val t0 = beatTimes[seg]
            val t1 = beatTimes[seg + 1]
            val v0 = filtered[seg]
            val v1 = filtered[seg + 1]
            grid[g] = if (t1 <= t0) v0 else {
                val frac = ((t - t0) / (t1 - t0)).coerceIn(0.0, 1.0)
                v0 + frac * (v1 - v0)
            }
        }

        // 4. Detrend: subtract a centered moving mean (removes slow LF/baseline drift).
        val halfW = maxOf(1, (rsaDetrendWindowS * rsaResampleHz / 2.0).roundToInt())
        val detrended = DoubleArray(nGrid)
        for (i in 0 until nGrid) {
            val lo = maxOf(0, i - halfW)
            val hi = minOf(nGrid - 1, i + halfW)
            var sum = 0.0
            for (j in lo..hi) sum += grid[j]
            val mean = sum / (hi - lo + 1).toDouble()
            detrended[i] = grid[i] - mean
        }
        if (standardDeviation(detrended.toList()) <= 1e-9) return nan // flat → no RSA

        // 5. Per ~5-min window peak-pick → 60/median(breath interval); median across.
        val spliceGrid = spliceAtS.map { (it / dt).toInt() }
        val minDistSamples = maxOf(2, (rsaMinPeakDistanceS * rsaResampleHz).roundToInt())
        val windowSamples = maxOf(minDistSamples * 3, (rsaWindowS * rsaResampleHz).roundToInt())
        val perWindowRates = ArrayList<Double>()
        var w = 0
        while (w < nGrid) {
            val wEnd = minOf(nGrid, w + windowSamples)
            // #977: a window straddling a splice is measuring a discontinuity, not a breath. Dropping it
            // costs one window; keeping it puts a fabricated interval into the median. All windows spliced
            // leaves perWindowRates empty and the function returns NaN, which is the honest answer.
            val spliced = spliceGrid.any { it >= w && it < wEnd }
            if (!spliced && wEnd - w >= minDistSamples * 3) {
                val winSeg = ArrayList<Double>(wEnd - w)
                for (k in w until wEnd) winSeg.add(detrended[k])
                // findPeaks with height = 0.0 selects the positive RSA peaks (one per
                // breath) on the zero-mean detrended tachogram.
                val peaks = findPeaks(winSeg, distance = minDistSamples, height = 0.0)
                if (peaks.size >= 3) {
                    val intervals = ArrayList<Double>(peaks.size - 1)
                    for (i in 1 until peaks.size) {
                        val ivS = (peaks[i] - peaks[i - 1]).toDouble() * dt
                        if (ivS in rsaMinBreathIntervalS..rsaMaxBreathIntervalS) intervals.add(ivS)
                    }
                    if (intervals.size >= 2) {
                        val med = HrvAnalyzer.median(intervals)
                        if (med > 0.0) perWindowRates.add(60.0 / med)
                    }
                }
            }
            w += windowSamples
        }
        if (perWindowRates.isEmpty()) return nan
        // Reject estimates outside the canonical consumer band (NaN = "no usable estimate") so the
        // persisted value never silently disagrees with ReadinessEngine's plausibility gate. (#78)
        val median = HrvAnalyzer.median(perWindowRates)
        return if (median in respPlausibleRangeBpm) median else nan
    }

    /**
     * Local-maxima peak finder mirroring scipy.find_peaks(distance, height):
     * a sample is a peak if strictly greater than both neighbours and ≥ height;
     * peaks closer than `distance` are resolved by keeping the taller.
     */
    internal fun findPeaks(x: List<Double>, distance: Int, height: Double): List<Int> {
        val n = x.size
        if (n < 3) return emptyList()
        val candidates = ArrayList<Int>()
        var i = 1
        while (i < n - 1) {
            if (x[i] > x[i - 1] && x[i] >= height) {
                // handle flat plateaus: find right edge of the plateau
                var j = i
                while (j + 1 < n && x[j + 1] == x[i]) j += 1
                if (j + 1 < n && x[j + 1] < x[i]) {
                    candidates.add((i + j) / 2) // plateau midpoint
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        if (distance <= 1 || candidates.isEmpty()) return candidates
        // Enforce minimum distance: greedily keep tallest, scipy-style.
        val byHeight = candidates.sortedByDescending { x[it] }
        val keep = BooleanArray(candidates.size) { true }
        val indexOf = HashMap<Int, Int>(candidates.size)
        for ((off, c) in candidates.withIndex()) indexOf[c] = off
        for (p in byHeight) {
            val pi = indexOf[p] ?: continue
            if (!keep[pi]) continue
            for ((qi, q) in candidates.withIndex()) {
                if (qi != pi && keep[qi]) {
                    if (abs(q - p) < distance) keep[qi] = false
                }
            }
        }
        return candidates.filterIndexed { off, _ -> keep[off] }.sorted()
    }

    // ── Per-epoch features ──────────────────────────────────────────────────

    internal class EpochFeatures(
        val index: Int,
        val midTs: Double,
        /** rescaled Cole–Kripke activity count. */
        val count: Double,
        val moveFrac: Double,
        val ckSleep: Boolean,
        /** mean HR over the feature window. */
        val hr: Double,
        /** Walch DoG-HR windowed std. */
        val hrVar: Double,
        /** ms. */
        val rmssd: Double,
        /** ms. */
        val sdnn: Double,
        /** breaths/min. */
        val respRate: Double,
        /** respiratory-rate variability (s). */
        val rrv: Double,
        /** normalized time since onset, 0..1. */
        val clock: Double,
    )

    internal fun extractFeatures(
        grid: EpochGrid, ckFlags: List<Boolean>, dogHR: List<Double>,
        onsetIdx: Int, finalWakeIdx: Int,
    ): List<EpochFeatures> {
        val n = grid.nEpochs
        val rescaled = rescaleCounts(grid.counts)
        val halfW = (featureWindowS / epochS / 2).roundToInt()
        val span = maxOf(1, finalWakeIdx - onsetIdx).toDouble()

        val feats = ArrayList<EpochFeatures>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - halfW)
            val hi = minOf(n, i + halfW + 1)

            val winHR = (lo until hi).map { grid.hr[it] }.filter { !it.isNaN() }
            val hrMean = if (winHR.isEmpty()) Double.NaN else winHR.sum() / winHR.size.toDouble()

            val winDog = (lo until hi).map { if (dogHR.isEmpty()) 0.0 else dogHR[it] }
            val hrVar = if (winDog.size >= 2) standardDeviation(winDog) else Double.NaN

            // RMSSD/SDNN over the pooled RR window (range-filtered, like the
            // Python per-epoch hrv_from_rr which uses RAW range-filtered RR).
            val winRR = ArrayList<Double>()
            for (j in lo until hi) winRR.addAll(grid.rr[j])
            val filteredRR = HrvAnalyzer.rangeFilter(winRR)
            val rmssd = if (filteredRR.size >= 5) (HrvAnalyzer.rmssdRaw(filteredRR) ?: Double.NaN) else Double.NaN
            val sdnn = if (filteredRR.size >= 5) (HrvAnalyzer.sdnnRaw(filteredRR) ?: Double.NaN) else Double.NaN

            val winResp = ArrayList<Double>()
            for (j in lo until hi) winResp.addAll(grid.resp[j])
            val (respRate, rrv) = respRateAndRRV(winResp)

            val clock = minOf(1.0, maxOf(0.0, (i - onsetIdx).toDouble() / span))

            feats.add(
                EpochFeatures(
                    index = i, midTs = grid.epochMid(i), count = rescaled[i],
                    moveFrac = grid.moveFrac[i],
                    ckSleep = if (i < ckFlags.size) ckFlags[i] else true,
                    hr = hrMean, hrVar = hrVar, rmssd = rmssd, sdnn = sdnn,
                    respRate = respRate, rrv = rrv, clock = clock,
                )
            )
        }
        return feats
    }

    // ── Percentile helper ─────────────────────────────────────────────────────

    /** numpy-style linear-interpolated percentile over finite values; null if none. */
    internal fun percentile(values: List<Double>, pct: Double): Double? {
        val vals = values.filter { it.isFinite() }.sorted()
        if (vals.isEmpty()) return null
        return percentileSorted(vals, pct)
    }

    /**
     * Linear-interpolated percentile of an already-sorted sequence (numpy-style).
     * Inlined from Swift `StrainScorer.percentile` (not yet ported to Kotlin); same
     * algorithm so a later StrainScorer port stays consistent.
     */
    private fun percentileSorted(sortedValues: List<Double>, pct: Double): Double {
        val n = sortedValues.size
        if (n == 0) return 0.0
        if (n == 1) return sortedValues[0]
        val position = (pct / 100.0) * (n - 1).toDouble()
        val lower = position.toInt()
        val upper = minOf(lower + 1, n - 1)
        val frac = position - lower.toDouble()
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    // ── Classifier seam (Stage 2) ─────────────────────────────────────────────

    internal fun classifyEpochs(features: List<EpochFeatures>): List<String> {
        val n = features.size
        if (n == 0) return emptyList()

        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        val sleepFeats = if (features.any { it.ckSleep }) features.filter { it.ckSleep } else features
        val hrLo = percentile(sleepFeats.map { it.hr }, stageHRLowPct)
        val hrHi = percentile(sleepFeats.map { it.hr }, stageHRHighPct)
        val rmssdHi = percentile(sleepFeats.map { it.rmssd }, stageHRVHighPct)
        val hrvarHi = percentile(sleepFeats.map { it.hrVar }, stageHRVarHighPct)
        val rrvHi = percentile(sleepFeats.map { it.rrv }, stageRRVHighPct)
        val rrvLo = percentile(sleepFeats.map { it.rrv }, stageRRVLowPct)
        val cardiacSparse = isCardiacSparse(sleepFeats)

        return features.map {
            classifyOne(it, hrLo = hrLo, hrHi = hrHi, rmssdHi = rmssdHi,
                hrvarHi = hrvarHi, rrvHi = rrvHi, rrvLo = rrvLo,
                cardiacSparse = cardiacSparse)
        }
    }

    /**
     * Session-level PPG-derived / sparse-cardiac tell: most sleep-period epochs carry NO finite
     * per-epoch RMSSD (sparse R-R). On those nights the HR is PPG-derived and its windowed variance
     * (`hrVar`) is noisier, so the percentile `hrvarHigh` bar fires on genuinely still, low-HR sleep —
     * which the WAKE rule must NOT treat as cardiac activation. Same `!rmssd.isFinite()` signal already
     * trusted for the pro-deep RMSSD handling (#127/#129), aggregated across the night. (#705)
     */
    internal fun isCardiacSparse(sleepFeats: List<EpochFeatures>): Boolean {
        if (sleepFeats.isEmpty()) return false
        val sparse = sleepFeats.count { !it.rmssd.isFinite() }
        return sparse.toDouble() >= cardiacSparseEpochFrac * sleepFeats.size.toDouble()
    }

    /**
     * What one epoch's respiration says about depth — FIVE states, because "we did not measure it" is not
     * an observation and must not be spendable as one.
     *
     * This used to be two booleans over a NaN RRV, and the `regular` one read
     * `(!f.rrv.isFinite()) || (f.rrv <= rrvLo)`: a MISSING respiration reading was converted into a
     * positive assertion that breathing was regular, which is pro-deep. On a WHOOP 5/MG that is not an
     * edge case, it is the only code path — the v18 layout emits no `resp_rate_raw` at all (pinned by
     * `Whoop5HistoricalDecodeTest`), so `respSample` has zero rows, every epoch's RRV is NaN, and the
     * fabricated "regular" fires on 100% of epochs. Where a night with real respiration data has ~50% of
     * its epochs clear the `regular` bar (it is the MEDIAN — `stageRRVLowPct` = 50), a 5/MG night has
     * 100% clear it, on no measurement whatsoever.
     *
     * The five cases are the exact CROSS-PRODUCT of the two predicates this replaced, so the mapping is
     * total and no case is decided by which bar `of` happens to test first:
     *
     * | pre-fix `rrvIrregular` | pre-fix `rrvRegular`     | case                |
     * |------------------------|--------------------------|---------------------|
     * | false                  | true (via `!isFinite()`) | [UNMEASURED]        |
     * | false                  | true (via the low bar)   | [REGULAR]           |
     * | true                   | false                    | [IRREGULAR]         |
     * | false                  | false                    | [MEASURED_MID_BAND] |
     * | true                   | true                     | [BARS_DEGENERATE]   |
     *
     * [UNMEASURED] and [MEASURED_MID_BAND] are deliberately DISTINCT. Both fail the regular and irregular
     * bars, but they mean opposite things — one is "no reading", the other is a real reading that simply
     * sits between the bars — and the classifier already treats them differently (the REM fallback fires
     * only on a missing reading). Collapsing them would silently change the hypnogram.
     *
     * Mirror of the Swift `SleepStager.RespEvidence`.
     */
    internal enum class RespEvidence {
        /** A finite RRV at or below the session's low bar — breathing measured as regular. */
        REGULAR,

        /** A finite RRV at or above the session's high bar — breathing measured as irregular. */
        IRREGULAR,

        /** A finite RRV between the bars: measured, but neither notably regular nor notably irregular. */
        MEASURED_MID_BAND,

        /**
         * No usable RRV for this epoch. Either the strap has no respiration channel at all (every 5/MG),
         * or this epoch's window had too few / too flat samples to derive one (`respRateAndRRV` returns
         * NaN below 8 samples, on a flat signal, under 3 peaks, or under 2 in-band breath intervals).
         */
        UNMEASURED,

        /**
         * A finite RRV that clears BOTH bars at once — at or above the high bar AND at or below the low
         * bar. The session's two percentile bars have collapsed onto this reading, so it satisfies each
         * of them and the pair carries no information at this value.
         *
         * Reachable, not hypothetical, and for a structural reason: RRV is the population std of breath
         * intervals measured in WHOLE SECONDS (`respRateAndRRV`, `dtS` = 1), so it is quantised onto a
         * small discrete lattice and exact ties between epochs are ordinary. `percentile` interpolates
         * between order statistics, so p50 and p65 coincide whenever the tie run spans them — and when
         * only ONE sleep epoch has a finite RRV (the rest NaN, which that same function returns freely
         * on short, flat or low-peak windows) `percentile` returns that single value for both, so the
         * epoch that SET the bars necessarily sits on both of them.
         *
         * Kept as its own case because a four-state enum cannot represent it: both pre-fix booleans were
         * true here, so whichever bar the factory tested first would silently decide the label.
         * Behaviour is pinned to the pre-fix outcome — waived for depth (`rrvRegular` was true, see
         * [contradictsDepth]) and clearing the REM irregular bar (`rrvIrregular` was true, see
         * [meetsIrregularBar]) — which keeps this change a representation fix.
         *
         * That pre-fix outcome resolves to DEEP only because the deep rule is written before the REM
         * rule in [classifyOne]; statement order is not a reason, and re-deciding it is a live question.
         * It is deliberately NOT re-decided here: doing so is a scoring change on the
         * degenerate-distribution nights, and this repo has no staged nights of that shape to validate
         * it against (CLAUDE.md, "validate against the artifact, not one match"). The point of naming
         * the case is that the decision is now a one-line edit in [contradictsDepth] /
         * [meetsIrregularBar] with a test that fails loudly, instead of an invisible consequence of
         * statement order.
         */
        BARS_DEGENERATE,
        ;

        /**
         * Whether respiration CONTRADICTS depth. The deep rule reads this rather than a "regular" flag,
         * because [UNMEASURED] is not evidence of regular breathing — it is the absence of evidence, and
         * the rule it feeds is "respiration must not rule depth out".
         *
         * [UNMEASURED] is WAIVED here, not because missing respiration is reassuring, but because
         * blocking on it would decode 0 m of deep on every 5/MG night — the exact regression #127/#129
         * fixed for the parallel missing-RMSSD case, whose rule statement already carries the same
         * qualifier ("with high parasympathetic tone WHEN MEASURABLE"). This makes the respiration waiver
         * explicit and equally qualified instead of leaving it implied by a NaN short-circuit.
         *
         * [BARS_DEGENERATE] is waived too, matching the pre-fix `rrvRegular`; see its doc for why that is
         * preserved rather than re-decided.
         *
         * KNOWN LIMITATION, deliberately not changed here: on a 5/MG BOTH waivers can fire at once
         * (sparse R-R leaves RMSSD NaN too), and the deep rule then reduces to stillness + a low HR with
         * no physiological corroboration at all. That is a real weakness, but it is bounded — `hrLow` is
         * a PERCENTILE bar (`stageHRLowPct` = 25), so at most ~25% of sleep epochs can clear it however
         * the respiration term resolves. Narrowing the waiver is a scoring change that needs validation
         * data this repo does not have; `SleepStagerRespEvidenceTest` pins the current behaviour and
         * quantifies the bias so that decision can be made on numbers.
         */
        val contradictsDepth: Boolean
            get() = when (this) {
                REGULAR, UNMEASURED, BARS_DEGENERATE -> false
                IRREGULAR, MEASURED_MID_BAND -> true
            }

        /**
         * Whether this epoch clears the session's IRREGULAR bar — the pre-fix `rrvIrregular` predicate,
         * which the main REM rule reads. [BARS_DEGENERATE] clears it (it IS at or above the high bar)
         * even though [contradictsDepth] also waives it; that pair of answers is precisely the pre-fix
         * state where both booleans were true, and it is preserved deliberately.
         */
        val meetsIrregularBar: Boolean
            get() = when (this) {
                IRREGULAR, BARS_DEGENERATE -> true
                REGULAR, MEASURED_MID_BAND, UNMEASURED -> false
            }

        companion object {
            /**
             * Total mapping of the two pre-fix predicates. Written as an exhaustive branch on the pair
             * rather than an ordered `if` chain, because an ordered chain is exactly how the
             * [BARS_DEGENERATE] case used to be decided by accident.
             */
            fun of(rrv: Double, lowBar: Double?, highBar: Double?): RespEvidence {
                if (!rrv.isFinite()) return UNMEASURED
                val atOrAboveHigh = highBar != null && rrv >= highBar
                val atOrBelowLow = lowBar != null && rrv <= lowBar
                return when {
                    atOrAboveHigh && atOrBelowLow -> BARS_DEGENERATE
                    atOrAboveHigh -> IRREGULAR
                    atOrBelowLow -> REGULAR
                    else -> MEASURED_MID_BAND
                }
            }
        }
    }

    internal fun classifyOne(
        f: EpochFeatures, hrLo: Double?, hrHi: Double?,
        rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
        cardiacSparse: Boolean = false,
    ): String {
        val hasHR = f.hr.isFinite()
        val hrLow = hasHR && hrLo != null && f.hr <= hrLo
        val hrHigh = hasHR && hrHi != null && f.hr >= hrHi

        // NOTE: HF omitted (no neurokit2). Parasympathetic tone = RMSSD only. A MISSING per-epoch
        // RMSSD (sparse R-R, common on BLE-offloaded nights and especially 5/MG) is treated as
        // pro-deep rather than deep-blocking — mirroring how a missing respiration value is handled
        // below — so those nights stop decoding 0 m of deep sleep despite a real depth signature
        // (still + low HR + regular breathing). An epoch WITH a finite RMSSD must still clear the
        // high-tone bar. (#127, #129)
        val parasympOK = (!f.rmssd.isFinite()) || (rmssdHi != null && f.rmssd >= rmssdHi)

        val hrvarHigh = f.hrVar.isFinite() && hrvarHi != null && f.hrVar >= hrvarHi
        val cardiacActivated = hrHigh || hrvarHigh

        // WAKE-specific cardiac vetting. On a PPG-derived / sparse-cardiac night the per-epoch HR-variance
        // is noisy, so `hrvarHigh` fires on still, low-HR sleep and used to flip those epochs to WAKE. When
        // the session is sparse we DOWN-WEIGHT hrVar for the wake promotion and require a real elevated HR
        // (`hrHigh`) — the down-weighting mirrors how sparse R-R is trusted for the pro-deep RMSSD handling.
        // Dense 4.0 nights keep the full `hrHigh || hrvarHigh` signal, so their behaviour is unchanged. (#705)
        val cardiacActivatedForWake = if (cardiacSparse) hrHigh else cardiacActivated

        val resp = RespEvidence.of(f.rrv, lowBar = rrvLo, highBar = rrvHi)

        val still = f.moveFrac <= stageStillMoveFrac
        val moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion). On a sparse/PPG night the
        // cardiac half is vetted by HR only (see `cardiacActivatedForWake`), so noisy hrVar no longer
        // over-promotes still sleep to wake. (#705)
        if (moving && (cardiacActivatedForWake || !hasHR)) return "wake"
        // DEEP: still + low HR + respiration that does not RULE OUT depth, with high parasympathetic tone
        // when measurable. [RespEvidence.contradictsDepth] is where an unmeasured respiration is waived —
        // see its doc for why the waiver stays and what it costs.
        if (still && parasympOK && hrLow && !resp.contradictsDepth) return "deep"
        // REM: still body + activated cardiac + respiration clearing the irregular bar.
        if (still && cardiacActivated && resp.meetsIrregularBar) return "rem"
        // REM fallback when respiration was never MEASURED (not merely mid-band): require BOTH cardiac
        // signals. A mid-band reading is real evidence and does not earn the fallback.
        if (still && hrHigh && hrvarHigh && resp == RespEvidence.UNMEASURED) return "rem"
        return "light"
    }

    // ── Post-processing (Stage 3) ─────────────────────────────────────────────

    internal fun smoothLabels(labels: List<String>, window: Int = smoothEpochs): List<String> {
        val n = labels.size
        if (n == 0 || window <= 1) return labels
        var w = window
        if (w % 2 == 0) w += 1
        val half = w / 2
        val out = ArrayList<String>(n)
        for (i in 0 until n) {
            val lo = maxOf(0, i - half)
            val hi = minOf(n, i + half + 1)
            val counts = HashMap<String, Int>()
            val order = ArrayList<String>()
            for (idx in lo until hi) {
                val s = labels[idx]
                if (counts[s] == null) order.add(s)
                counts[s] = (counts[s] ?: 0) + 1
            }
            val best = counts.values.maxOrNull()
            if (best == null) { out.add(labels[i]); continue }
            val winners = order.filter { counts[it] == best } // insertion order preserved
            out.add(if (winners.contains(labels[i])) labels[i] else winners[0])
        }
        return out
    }

    internal fun reimposePhysiology(
        labels: List<String>, features: List<EpochFeatures>,
        onsetIdx: Int, finalWakeIdx: Int,
    ): List<String> {
        val out = labels.toMutableList()
        val noREMEpochs = (noREMAfterOnsetMin * 60.0 / epochS).roundToInt()
        // "Deep is front-loaded" re-imposes scattered late "deep" back to light — BUT only when there's
        // deep in the first third to anchor that prior. If the whole detected deep block lands later
        // (individual variation, or HR/HRV-only staging without respiration placing the deepest, lowest-HR
        // window later), zeroing it out gives a wrong "0 m deep"; keeping the best estimate is better. (#127)
        val hasEarlyDeep = labels.indices.any { labels[it] == "deep" && features[it].clock <= deepFirstFraction }
        for ((i, f) in features.withIndex()) {
            if (i < onsetIdx || i > finalWakeIdx) continue
            if (out[i] == "rem" && (i - onsetIdx) < noREMEpochs) out[i] = "light"
            if (out[i] == "deep" && f.clock > deepFirstFraction && hasEarlyDeep) out[i] = "light"
        }
        return out
    }

    // ── REM-funnel diagnostic (#688) ──────────────────────────────────────────

    // 0% REM over a whole night is physiologically implausible (healthy adults cycle ~20–25% REM),
    // so a 0%-REM hypnogram — common on WHOOP 4.0 nights staged WITHOUT a respiration channel —
    // points at the STAGER, not the sleeper. The REM path in [classifyOne] is gated by three
    // predicates (still body + activated cardiac + irregular respiration), with a no-resp fallback
    // (still + high HR + high HR-variability), and any surviving early-REM is then stripped by the
    // no-REM-after-onset re-imposition. This pure, READ-ONLY diagnostic re-runs that exact funnel and
    // counts where REM was lost — WITHOUT changing a single label or score. It is a triage surface,
    // logged by the caller, never a scoring change. Mirrors Swift `remFunnelDiagnostic`. (#688)

    /**
     * Why REM funneled toward zero for one staged session window. Counts are over the SLEEP-PERIOD
     * epochs (onset…finalWake) the classifier actually ranges; pure + deterministic; shares the exact
     * classifier seam with [stageSession]. Mirrors Swift `SleepStager.REMFunnelDiagnostic`. (#688)
     */
    data class REMFunnelDiagnostic(
        /** Sleep-period epochs considered (onset…finalWake inclusive). */
        val sleepEpochs: Int,
        /** Epochs the classifier labelled "rem" BEFORE smoothing / re-imposition. */
        val remAtClassify: Int,
        /** "rem" epochs surviving the no-REM-after-onset re-imposition (the final hypnogram's REM). */
        val remAfterReimpose: Int,
        /** Classified-REM epochs stripped specifically by the 15-min onset guard. */
        val remStrippedByOnsetGuard: Int,
        /**
         * Whether ANY epoch carried a finite respiration-variability feature (the resp channel was
         * usable). False ⇒ the whole night ran the no-resp REM fallback — the dominant 4.0 cause.
         */
        val respChannelPresent: Boolean,
        /** Body not still enough (moveFrac above the still bar). */
        val blockedNotStill: Int,
        /** Neither HR-high nor HR-variability-high. */
        val blockedNoCardiacActivation: Int,
        /** Resp present but NOT irregular (regular breathing). */
        val blockedRespRegular: Int,
        /** Resp absent and the stricter no-resp REM bar unmet. */
        val blockedNoRespFallbackBar: Int,
        /** Won a non-REM stage outright (wake/deep/light) before any REM gate — not a REM rejection. */
        val wonOtherStage: Int,
    ) {
        /** True when the final hypnogram carries no REM at all — the case this diagnostic triages. */
        val isZeroREM: Boolean get() = remAfterReimpose == 0

        /** One human-readable line for the caller to LOG. No I/O here — the engine stays pure. */
        val summary: String
            get() = "REM-funnel: $sleepEpochs sleep-epochs, classify=$remAtClassify rem, " +
                "final=$remAfterReimpose rem (onset-guard stripped $remStrippedByOnsetGuard); " +
                "resp=${if (respChannelPresent) "present" else "ABSENT"}; " +
                "blocked[notStill=$blockedNotStill, noCardiac=$blockedNoCardiacActivation, " +
                "respRegular=$blockedRespRegular, noRespBar=$blockedNoRespFallbackBar], " +
                "otherStage=$wonOtherStage"
    }

    /**
     * Per-epoch reason REM was rejected, evaluated in classifier precedence order. `REM_ELIGIBLE`
     * means the epoch WOULD be labelled REM. Internal — drives [remFunnelDiagnostic].
     */
    internal enum class REMRejectReason {
        REM_ELIGIBLE, WON_OTHER_STAGE, NOT_STILL, NO_CARDIAC_ACTIVATION, RESP_REGULAR, NO_RESP_FALLBACK_BAR
    }

    /**
     * Classify a single epoch's REM-eligibility AND, when not eligible, the FIRST reason it failed —
     * using the exact predicates and precedence of [classifyOne] so the diagnostic can never diverge
     * from the real classifier. Read-only. Mirrors Swift `remRejectReason`. (#688)
     */
    internal fun remRejectReason(
        f: EpochFeatures, hrLo: Double?, hrHi: Double?,
        rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
        cardiacSparse: Boolean = false,
    ): REMRejectReason {
        // Mirror classifyOne's derived predicates exactly.
        val hasHR = f.hr.isFinite()
        val hrLow = hasHR && hrLo != null && f.hr <= hrLo
        val hrHigh = hasHR && hrHi != null && f.hr >= hrHi
        val parasympOK = (!f.rmssd.isFinite()) || (rmssdHi != null && f.rmssd >= rmssdHi)
        val hrvarHigh = f.hrVar.isFinite() && hrvarHi != null && f.hrVar >= hrvarHi
        val cardiacActivated = hrHigh || hrvarHigh
        val cardiacActivatedForWake = if (cardiacSparse) hrHigh else cardiacActivated
        // Same respiration evidence the classifier uses, from the same factory — so the diagnostic cannot
        // drift from the rule it explains (these predicates were duplicated by hand).
        val resp = RespEvidence.of(f.rrv, lowBar = rrvLo, highBar = rrvHi)
        val still = f.moveFrac <= stageStillMoveFrac
        val moving = f.moveFrac >= stageWakeMoveFrac

        // classifyOne precedence: WAKE, then DEEP, then REM (then REM fallback), else LIGHT.
        // An epoch that wins WAKE or DEEP was never a REM candidate.
        if (moving && (cardiacActivatedForWake || !hasHR)) return REMRejectReason.WON_OTHER_STAGE  // → wake
        if (still && parasympOK && hrLow && !resp.contradictsDepth) return REMRejectReason.WON_OTHER_STAGE // → deep
        // From here the epoch did NOT win wake/deep; it is either REM or falls through to LIGHT.
        if (still && cardiacActivated && resp.meetsIrregularBar) return REMRejectReason.REM_ELIGIBLE
        if (still && hrHigh && hrvarHigh && resp == RespEvidence.UNMEASURED) return REMRejectReason.REM_ELIGIBLE
        // Not REM → attribute to the FIRST unmet REM precondition (in REM-rule order).
        if (!still) return REMRejectReason.NOT_STILL
        if (!cardiacActivated) return REMRejectReason.NO_CARDIAC_ACTIVATION
        if (resp != RespEvidence.UNMEASURED) return REMRejectReason.RESP_REGULAR  // measured, not irregular
        return REMRejectReason.NO_RESP_FALLBACK_BAR                 // never measured and no-resp bar unmet
    }

    /**
     * Read-only REM-funnel triage for ONE in-bed window [start, end] (#688). Re-runs the SAME
     * Stage-0→3 staging seam [stageSession] uses (epoch grid → Cole–Kripke → features → classify →
     * smooth → re-impose), but instead of emitting a hypnogram it COUNTS where REM was lost. Changes
     * NOTHING: no label, no score, no session. Returns null only when the window has too little gravity
     * to grid (mirroring [stageSession]'s degenerate fallback, which carries no REM to explain). The
     * caller logs `.summary`; tests assert the counts. Pure + deterministic. Mirrors Swift. (#688)
     */
    fun remFunnelDiagnostic(
        start: Long, end: Long, grav: List<GravitySample>,
        hr: List<HrSample>, rr: List<RrInterval>, resp: List<RespSample>,
    ): REMFunnelDiagnostic? {
        val gSeg = rowsBetween(grav, start, end) { it.ts }
        if (gSeg.size < 2) return null
        val gDeltas = gravityDeltas(gSeg)
        val gTimes = gSeg.map { it.ts }
        val hrSeg = rowsBetween(hr, start, end) { it.ts }
        val rrSeg = rowsBetween(rr, start, end) { it.ts }
        val respSeg = rowsBetween(resp, start, end) { it.ts }

        val grid = buildEpochGrid(
            start = start.toDouble(), end = end.toDouble(),
            gravTimes = gTimes, gravDeltas = gDeltas,
            hr = hrSeg, rr = rrSeg, resp = respSeg,
        )
        if (grid.nEpochs == 0) return null

        val rescaled = rescaleCounts(grid.counts)
        val ckFlags = coleKripke(rescaled)
        val (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)
        val dogHR = dogHRVariability(grid.hr)
        val feats = extractFeatures(grid = grid, ckFlags = ckFlags, dogHR = dogHR,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)

        // The SAME session-relative reference percentiles classifyEpochs derives.
        val sleepFeats = if (feats.any { it.ckSleep }) feats.filter { it.ckSleep } else feats
        val hrLo = percentile(sleepFeats.map { it.hr }, stageHRLowPct)
        val hrHi = percentile(sleepFeats.map { it.hr }, stageHRHighPct)
        val rmssdHi = percentile(sleepFeats.map { it.rmssd }, stageHRVHighPct)
        val hrvarHi = percentile(sleepFeats.map { it.hrVar }, stageHRVarHighPct)
        val rrvHi = percentile(sleepFeats.map { it.rrv }, stageRRVHighPct)
        val rrvLo = percentile(sleepFeats.map { it.rrv }, stageRRVLowPct)
        val cardiacSparse = isCardiacSparse(sleepFeats)

        // Classify + post-process exactly as stageSession does, so we explain the SAME hypnogram.
        val labels = classifyEpochs(feats)
        val smoothed = smoothLabels(labels)
        val reimposed = reimposePhysiology(smoothed, features = feats,
            onsetIdx = onsetIdx, finalWakeIdx = finalWakeIdx)

        val noREMEpochs = (noREMAfterOnsetMin * 60.0 / epochS).roundToInt()
        var sleepEpochs = 0; var remAtClassify = 0; var remAfterReimpose = 0; var remStrippedByOnsetGuard = 0
        var blockedNotStill = 0; var blockedNoCardiacActivation = 0; var blockedRespRegular = 0
        var blockedNoRespFallbackBar = 0; var wonOtherStage = 0
        var respChannelPresent = false

        for (i in onsetIdx..maxOf(onsetIdx, finalWakeIdx)) {
            if (i >= feats.size) break
            val f = feats[i]
            sleepEpochs += 1
            if (f.rrv.isFinite()) respChannelPresent = true
            // Per-epoch REM reason at the raw classifier seam (pre-smoothing) — the funnel's mouth.
            when (remRejectReason(f, hrLo = hrLo, hrHi = hrHi, rmssdHi = rmssdHi,
                hrvarHi = hrvarHi, rrvHi = rrvHi, rrvLo = rrvLo,
                cardiacSparse = cardiacSparse)) {
                REMRejectReason.REM_ELIGIBLE -> remAtClassify += 1
                REMRejectReason.WON_OTHER_STAGE -> wonOtherStage += 1
                REMRejectReason.NOT_STILL -> blockedNotStill += 1
                REMRejectReason.NO_CARDIAC_ACTIVATION -> blockedNoCardiacActivation += 1
                REMRejectReason.RESP_REGULAR -> blockedRespRegular += 1
                REMRejectReason.NO_RESP_FALLBACK_BAR -> blockedNoRespFallbackBar += 1
            }
            // Final-hypnogram REM (post smooth + re-impose) and the onset-guard strip.
            if (reimposed[i] == "rem") remAfterReimpose += 1
            // The re-imposition strips a SMOOTHED "rem" epoch inside the onset guard → light; count
            // the strip off the smoothed labels reimpose actually sees (exact, not the raw seam).
            if (smoothed[i] == "rem" && (i - onsetIdx) < noREMEpochs) remStrippedByOnsetGuard += 1
        }

        return REMFunnelDiagnostic(
            sleepEpochs = sleepEpochs, remAtClassify = remAtClassify, remAfterReimpose = remAfterReimpose,
            remStrippedByOnsetGuard = remStrippedByOnsetGuard, respChannelPresent = respChannelPresent,
            blockedNotStill = blockedNotStill, blockedNoCardiacActivation = blockedNoCardiacActivation,
            blockedRespRegular = blockedRespRegular, blockedNoRespFallbackBar = blockedNoRespFallbackBar,
            wonOtherStage = wonOtherStage,
        )
    }

    /**
     * Sleep-depth rank, lighter → deeper: wake 0, light 1, rem 2, deep 3. Used by
     * mergeFragments to bias an ambiguous merge toward the LIGHTER stage so smoothing
     * can never inflate deep/REM. Unknown labels rank lightest (0) — they never win deep.
     */
    internal fun stageDepthRank(stage: String): Int = when (stage) {
        "light" -> 1
        "rem" -> 2
        "deep" -> 3
        else -> 0 // "wake" and any unexpected label
    }

    /** A contiguous run of one stage spanning [len] epochs. */
    private data class StageRun(val stage: String, var len: Int)

    /**
     * Display/scoring smoothing of the staged label sequence (#274). Absorbs sub-threshold
     * "noise" runs WITHOUT erasing real transitions — applied AFTER staging, it never
     * touches the underlying per-epoch detection.
     *
     * Per run shorter than [thresholdEpochs]:
     *   • bridged by two SAME-stage neighbours → absorbed into them (the fleck was a blip
     *     inside one continuous stage);
     *   • between DIFFERENT stages → relabelled to the dominant (longer) neighbour. On a tie
     *     — or when the longer neighbour is the deeper one and the shorter is lighter and of
     *     comparable length — it biases toward the LIGHTER neighbour so a stray fleck can
     *     never inflate deep/REM (the least-reliable, most-overcountable classes).
     *
     * Single left-to-right pass over runs, mirroring mergePeriods' control flow so the
     * Swift and Kotlin ports stay byte-identical. A run already ≥ threshold is a real
     * transition and is always preserved.
     */
    internal fun mergeFragments(labels: List<String>, thresholdEpochs: Int = fragmentMergeEpochs): List<String> {
        val n = labels.size
        if (n == 0 || thresholdEpochs <= 1) return labels

        // Collapse the per-epoch labels into contiguous runs of (stage, length).
        val runs = ArrayList<StageRun>()
        for (s in labels) {
            val last = runs.lastOrNull()
            if (last != null && last.stage == s) last.len += 1
            else runs.add(StageRun(s, 1))
        }
        if (runs.size < 2) return labels

        val merged = ArrayList<StageRun>()
        var i = 0
        while (i < runs.size) {
            val current = runs[i]
            if (current.len >= thresholdEpochs) {
                merged.add(StageRun(current.stage, current.len))
                i += 1
                continue
            }

            val hasPrev = merged.isNotEmpty()
            val hasNext = i + 1 < runs.size

            if (hasPrev && hasNext && merged[merged.size - 1].stage == runs[i + 1].stage) {
                // Same-stage bridge: absorb the fleck and the next run into the previous one.
                merged[merged.size - 1].len += current.len + runs[i + 1].len
                i += 2
            } else if (hasPrev && hasNext) {
                // Between two DIFFERENT stages: relabel to the dominant neighbour, biasing
                // toward the lighter stage when the two neighbours are tied in length.
                val prev = merged[merged.size - 1]
                val next = runs[i + 1]
                val winner: String = when {
                    prev.len > next.len -> prev.stage
                    next.len > prev.len -> next.stage
                    // Tie → lighter (smaller depth rank) wins; never inflate deep/REM.
                    else -> if (stageDepthRank(prev.stage) <= stageDepthRank(next.stage)) prev.stage else next.stage
                }
                if (winner == prev.stage) {
                    merged[merged.size - 1].len += current.len
                    i += 1
                } else {
                    // Becomes part of the NEXT run: extend next, drop current.
                    runs[i + 1] = StageRun(next.stage, next.len + current.len)
                    i += 1
                }
            } else if (hasNext) {
                // No previous run (leading fleck): fold forward into the next run.
                runs[i + 1] = StageRun(runs[i + 1].stage, runs[i + 1].len + current.len)
                i += 1
            } else if (hasPrev) {
                // No next run (trailing fleck): fold back into the previous run.
                merged[merged.size - 1].len += current.len
                i += 1
            } else {
                // Single sub-threshold run with no neighbours — nothing to merge into.
                merged.add(StageRun(current.stage, current.len))
                i += 1
            }
        }

        // Re-expand the runs back into a per-epoch label sequence of the same length.
        val out = ArrayList<String>(n)
        for (r in merged) {
            for (k in 0 until r.len) out.add(r.stage)
        }
        return out
    }

    // ── Per-session HR / HRV ─────────────────────────────────────────────────

    /** Lowest 5-min rolling-mean HR during the session (bpm), or null. */
    internal fun sessionRestingHR(start: Long, end: Long, hr: List<HrSample>): Int? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null
        val windowS = 5 * 60L
        val means = ArrayList<Double>()
        var t = start
        while (t < end) {
            val win = seg.filter { it.ts >= t && it.ts < t + windowS }
            if (win.isNotEmpty()) means.add(win.sumOf { it.bpm }.toDouble() / win.size.toDouble())
            t += windowS
        }
        val m = means.minOrNull()
        if (m != null) return m.roundToInt()
        val all = seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble()
        return all.roundToInt()
    }

    /** One 5-min HRV window: its start ts, the sleep stage at its center, the clean-beat count, and the
     *  window RMSSD (null when fewer than 2 clean beats, or when every successive pair straddles a dropped
     *  beat). Drives both [sessionAvgHRV] and the HRV test-mode trace. */
    data class HrvWindow(val startTs: Long, val stage: String, val cleanBeats: Int, val rmssd: Double?)

    /**
     * Mean RMSSD over 5-min tumbling windows across the session (ms), or null.
     * Uses the same range-filter + ≥2-valid-interval rule as hrv.rmssd().
     */
    internal fun sessionAvgHRV(start: Long, end: Long, rr: List<RrInterval>): Double? {
        val vals = sessionHrvWindows(start, end, rr, emptyList()).mapNotNull { it.rmssd }
        return if (vals.isEmpty()) null else vals.sum() / vals.size.toDouble()
    }

    /**
     * Per-5-min-window RMSSD across a session, each window tagged with the sleep stage at its CENTER (from
     * [stages]) — the SINGLE source [sessionAvgHRV] averages, and the HRV test-mode nightly trace reads.
     * Passing `emptyList()` for [stages] tags every window "?" (the plain-average path doesn't need stages).
     */
    internal fun sessionHrvWindows(
        start: Long, end: Long, rr: List<RrInterval>, stages: List<StageSegment>,
    ): List<HrvWindow> {
        // CONTRACT: `rr` MUST already be ts-sorted (RMSSD is built from SUCCESSIVE differences, so a bucket
        // has to be chronological). The value path passes the loop's pre-sorted `rrS`; the trace caller sorts
        // its own copy. Not sorted here on purpose — re-sorting the value path could reorder same-second RR
        // under an unstable sort and shift the shipped avgHrv. Same contract the original sessionAvgHRV had.
        val seg = rr.filter { it.ts in start..end }
        if (seg.isEmpty()) return emptyList()
        val windowS = 5 * 60L
        val out = ArrayList<HrvWindow>()
        var t = start
        while (t < end) {
            val bucket = seg.filter { it.ts >= t && it.ts < t + windowS }.map { it.rrMs.toDouble() }
            // Full clean (range + Malik ectopic rejection), not just range — matches the
            // analyze() pipeline. The 0x2A37 RR on a WHOOP 5/MG is PPG-derived and noisier
            // than a 4.0's; rMSSD is built from SUCCESSIVE differences, so an un-rejected
            // jitter spike inflates the session HRV. Ectopic rejection drops those (#262/#235).
            // Gap-aware: a dropped ectopic/out-of-range beat must not splice its two neighbours into a
            // spurious successive difference, which is the exact spike the rejection above is meant to
            // remove. See HrvAnalyzer.rmssdGapAware.
            val cleaned = HrvAnalyzer.cleanRRGapAware(bucket)
            val rmssd = if (cleaned.nn.size >= 2) HrvAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) else null
            val center = t + windowS / 2
            val stage = stages.firstOrNull { center >= it.start && center < it.end }?.stage ?: "?"
            out.add(HrvWindow(startTs = t, stage = stage, cleanBeats = cleaned.nn.size, rmssd = rmssd))
            t += windowS
        }
        return out
    }

    /** The LAST contiguous run of deep-stage windows in [windows] — the WHOOP-style "last slow-wave-sleep"
     *  comparator for the HRV nightly trace. Empty when no deep window is present. */
    internal fun lastDeepRun(windows: List<HrvWindow>): List<HrvWindow> {
        var lastRun: List<HrvWindow> = emptyList()
        val cur = ArrayList<HrvWindow>()
        for (w in windows) {
            if (w.stage == "deep") {
                cur.add(w)
            } else if (cur.isNotEmpty()) {
                lastRun = ArrayList(cur); cur.clear()
            }
        }
        if (cur.isNotEmpty()) lastRun = cur
        return lastRun
    }

    // ── AASM hypnogram metrics ───────────────────────────────────────────────

    /** AASM-style metrics from a session's stage segments. */
    fun hypnogramMetrics(session: DetectedSleep): HypnogramMetrics {
        val segs = session.stages.sortedBy { it.start }
        val tib = maxOf(0.0, (session.end - session.start).toDouble())

        fun dur(s: StageSegment): Double = (s.end - s.start).toDouble()
        val sleepSegs = segs.filter { it.stage == "light" || it.stage == "deep" || it.stage == "rem" }
        val tst = sleepSegs.sumOf { dur(it) }
        val deepS = segs.filter { it.stage == "deep" }.sumOf { dur(it) }
        val remS = segs.filter { it.stage == "rem" }.sumOf { dur(it) }
        val lightS = segs.filter { it.stage == "light" }.sumOf { dur(it) }

        val onset: Double
        val sptEnd: Double
        val sol: Double
        val first = sleepSegs.firstOrNull()
        val last = sleepSegs.lastOrNull()
        if (first != null && last != null) {
            onset = first.start.toDouble()
            sptEnd = last.end.toDouble()
            sol = maxOf(0.0, onset - session.start.toDouble())
        } else {
            onset = session.end.toDouble()
            sptEnd = session.end.toDouble()
            sol = tib
        }

        val remSegs = segs.filter { it.stage == "rem" }
        val remLatency = remSegs.firstOrNull()?.let { it.start.toDouble() - onset } ?: Double.NaN

        var waso = 0.0
        var disturbances = 0
        for (s in segs) {
            if (!SleepStageVocabulary.isWake(s.stage)) continue
            val w0 = maxOf(s.start.toDouble(), onset)
            val w1 = minOf(s.end.toDouble(), sptEnd)
            if (w1 > w0) {
                waso += (w1 - w0)
                disturbances += 1
            }
        }

        val se = if (tib > 0) tst / tib else 0.0
        fun pct(x: Double): Double = if (tst > 0) x / tst * 100.0 else 0.0

        return HypnogramMetrics(
            tibS = tib, tstS = tst, sptS = maxOf(0.0, sptEnd - onset), solS = sol,
            remLatencyS = remLatency, wasoS = waso, efficiency = minOf(1.0, se),
            disturbances = disturbances, deepMin = deepS / 60.0, remMin = remS / 60.0,
            lightMin = lightS / 60.0, deepPct = pct(deepS), remPct = pct(remS), lightPct = pct(lightS),
        )
    }

    // ── Small stats helpers ───────────────────────────────────────────────────

    /** Population standard deviation (numpy default, ddof=0). */
    internal fun standardDeviation(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        val mean = values.sum() / values.size.toDouble()
        var ss = 0.0
        for (v in values) {
            val d = v - mean
            ss += d * d
        }
        return sqrt(ss / values.size.toDouble())
    }
}
