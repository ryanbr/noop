package com.noop.analytics

import kotlin.math.abs

/**
 * The per-night BASELINE FOLD diagnostic (Recovery test mode). Twin of the Swift `Baselines+Trace`.
 *
 * Every other core analytics component has a trace; the fold did not, so a strap log could show what a
 * baseline IS (RecoveryScorerTrace prints mean / spread / nValid / status) but never how it got there.
 * That gap costs real triage time, because the fold's decisions are the ones that go wrong quietly: a
 * night rejected as a hard outlier is "seen, but not folded" and leaves no trace at all, and a spread
 * pinned on its floor looks identical to a spread that has genuinely settled.
 *
 * Returns the state from [Baselines.update] VERBATIM and recomputes only the intermediate decisions for
 * the lines, so the trace can never disagree with the baseline the scorer reads. Pure and
 * side-effect-free: no clock, no I/O, so a fixture night pins the exact lines. Gated at the call site
 * behind the Recovery test mode; when it is off this is never called, so there is zero cost. No
 * em-dashes. Values, counts and thresholds only, no PII.
 */
object BaselinesTrace {

    /** One folded night: the real next state, plus the line describing which branch it took. */
    data class Step(val state: BaselineState, val lines: List<String>)

    /** Nearest with half-ties AWAY FROM ZERO, matching Swift's `.rounded(.toNearestOrAwayFromZero)`.
     *  A plain `Math.round` is half-UP and diverges from Swift on negative ties, which the Winsor band's
     *  lower edge can reach on a low-centred metric. Same expression as [RecoveryScorerTrace]. */
    private fun r2(x: Double): Double {
        val scaled = x * 100.0
        return Math.copySign(Math.round(abs(scaled)) / 100.0, scaled)
    }
    private fun yn(b: Boolean): String = if (b) "yes" else "no"

    /**
     * Side-effect-free diagnostic twin of [Baselines.update]: returns the SAME state it would, plus a
     * line naming which branch the night took and why.
     *
     * The branches, in the order [Baselines.update] tests them:
     *  - `seed` / `seed-empty` - the first ever night; it FIXES the centre and starts spread at the floor.
     *  - `missing`     - no value for the night; skip-and-hold, `nightsSinceUpdate` climbs.
     *  - `implausible` - outside the metric's physiological bounds; skip-and-hold.
     *  - `rejected`    - a hard outlier once seeded and no longer young; seen, but not folded.
     *  - `folded`      - the normal Winsorized-EWMA path.
     *
     * The `folded` line reports `young`, the effective spread and half-life actually used, the Winsor
     * band and whether the value was clamped, and spread before/after WITH whether it landed on
     * [MetricCfg.floorSpread]. That last flag is the point of the whole file: `atFloor=yes` many nights
     * in means the z-scores the score divides by are still being computed against the floor.
     *
     * [metric] is the metric key ("hrv", "resting_hr", ...) so one log can carry several folds.
     */
    fun updateTrace(
        state: BaselineState?,
        value: Double?,
        cfg: MetricCfg,
        metric: String,
        rejectHardOutliers: Boolean = true,
    ): Step {
        // The returned state is the REAL fold's, always. Nothing below recomputes it.
        val next = Baselines.update(state, value, cfg, rejectHardOutliers)
        val head = "baseline $metric"
        // `.raw`, not `.name.lowercase()`: raw is the declared wire string and the exact twin of Swift's
        // `.rawValue`, so the two platforms' lines stay identical even if a case is ever renamed or a
        // multi-word case is added.
        val stateSuffix = "-> mean=${r2(next.baseline)} spread=${r2(next.spread)} " +
            "nValid=${next.nValid} status=${next.status.raw}"

        // Branch order MIRRORS update exactly: it tests state == null FIRST and that branch decides the
        // value's validity itself, so a first night with a missing or out-of-range value is a seed case
        // and not a skip. Testing value-ness first here would label those two lines wrongly while still
        // returning the right state, which is the worst kind of diagnostic.
        if (state == null) {
            val v = value
            if (v == null || !(cfg.minVal <= v && v <= cfg.maxVal)) {
                return Step(
                    next,
                    listOf(
                        "$head night=seed-empty no usable first value " +
                            "(bounds=${r2(cfg.minVal)}..${r2(cfg.maxVal)}) " +
                            "seeded at midpoint, nValid stays 0 $stateSuffix",
                    ),
                )
            }
            return Step(
                next,
                listOf(
                    "$head night=seed value=${r2(v)} " +
                        "spread starts at floor=${r2(cfg.floorSpread)} " +
                        "(this ONE night fixes the centre) $stateSuffix",
                ),
            )
        }

        if (value == null) {
            return Step(
                next,
                listOf("$head night=missing skip-and-hold nightsSinceUpdate=${next.nightsSinceUpdate} $stateSuffix"),
            )
        }

        if (!(cfg.minVal <= value && value <= cfg.maxVal)) {
            return Step(
                next,
                listOf(
                    "$head night=implausible value=${r2(value)} " +
                        "bounds=${r2(cfg.minVal)}..${r2(cfg.maxVal)} skip-and-hold " +
                        "nightsSinceUpdate=${next.nightsSinceUpdate} $stateSuffix",
                ),
            )
        }

        // Same predicate update uses: tied to the valid-night count, not to spread.
        val isYoung = state.nValid < Baselines.earlyAdaptNights

        if (rejectHardOutliers && state.nValid >= Baselines.minNightsSeed && !isYoung) {
            val dev = abs(value - state.baseline)
            if (dev > Baselines.hardOutlierK * state.spread) {
                return Step(
                    next,
                    listOf(
                        "$head night=rejected value=${r2(value)} " +
                            "dev=${r2(dev)} > k=${r2(Baselines.hardOutlierK)}*spread=${r2(state.spread)} " +
                            "(seen, NOT folded) $stateSuffix",
                    ),
                )
            }
        }

        val effSpread = if (isYoung) state.spread * Baselines.earlySpreadInflate else state.spread
        val effHalfLifeB = if (isYoung) Baselines.earlyHalfLifeB else cfg.halfLifeB
        val lo = state.baseline - Baselines.winsorK * effSpread
        val hi = state.baseline + Baselines.winsorK * effSpread
        val clamped = maxOf(lo, minOf(hi, value))
        val wasClamped = clamped != value
        // update floors the spread with max(cfg.floorSpread, ...); report when that floor is what won,
        // since a spread sitting on its floor is indistinguishable from a settled one in every other log.
        val atFloor = next.spread <= cfg.floorSpread

        return Step(
            next,
            listOf(
                "$head night=folded value=${r2(value)} young=${yn(isYoung)} " +
                    "effSpread=${r2(effSpread)} halfLifeB=${r2(effHalfLifeB)} " +
                    "winsor=${r2(lo)}..${r2(hi)} clamped=${yn(wasClamped)}" +
                    (if (wasClamped) " to=${r2(clamped)}" else "") +
                    " spread ${r2(state.spread)}->${r2(next.spread)} atFloor=${yn(atFloor)} $stateSuffix",
            ),
        )
    }

    /**
     * Replay an ordered history (oldest first) through [updateTrace], returning the final state and one
     * line per night. The state threaded between nights is the real fold's, so this is
     * [Baselines.foldHistory] with commentary rather than a reimplementation of it.
     *
     * This is the shape that answers "how many nights until the spread lifted", which is unanswerable
     * from a single night's line.
     */
    fun foldHistoryTrace(
        values: List<Double?>,
        cfg: MetricCfg,
        metric: String,
        rejectHardOutliers: Boolean = true,
        tail: Int? = null,
    ): Step {
        var state: BaselineState? = null
        var lines = ArrayList<String>()
        for (v in values) {
            val step = updateTrace(state, v, cfg, metric, rejectHardOutliers)
            state = step.state
            lines.addAll(step.lines)
        }
        // [tail] keeps only the last N lines. The WHOLE history is still folded, so the state is
        // unchanged; this bounds the log, because an established user's history is hundreds of nights
        // and a diagnostic nobody can read is not a diagnostic. null keeps every line.
        if (tail != null && tail >= 0 && lines.size > tail) {
            val dropped = lines.size - tail
            val capped = ArrayList<String>()
            capped.add("baseline $metric (earlier $dropped night(s) omitted)")
            capped.addAll(lines.takeLast(tail))
            lines = capped
        }
        val final = state
            ?: return Step(
                // Empty history: mirror foldHistory's midpoint seed rather than inventing a different one.
                BaselineState(
                    baseline = (cfg.minVal + cfg.maxVal) / 2.0,
                    spread = cfg.floorSpread,
                    nValid = 0,
                    nightsSinceUpdate = 0,
                    status = Baselines.computeStatus(0, 0),
                ),
                listOf("baseline $metric history=empty"),
            )
        return Step(final, lines)
    }

    /**
     * The recalibration-aware fold, traced. Twin of [Baselines.foldHistory] with `dayKeys`, which DROPS
     * (rather than skip-and-holds) every night dated before the recalibration epoch.
     *
     * The drop is the point. A manual "Recalibrate baseline" discards the user's earlier nights and
     * restarts the count, and nothing in a log has ever said so - a reporter sat at "Calibrating, 3 of 4
     * nights" holding 15 valid nights, because each tap threw them away. The `dropped=` line names that
     * directly instead of leaving it to be inferred from a suspiciously low nValid.
     */
    fun foldHistoryTrace(
        values: List<Double?>,
        dayKeys: List<String>,
        cfg: MetricCfg,
        metric: String,
        baselineEpoch: Double,
        tail: Int? = null,
    ): Step {
        if (baselineEpoch <= 0.0) return foldHistoryTrace(values, cfg, metric, tail = tail)

        // Filter THEN fold, which is what the production loop does night by night; folding the kept
        // nights in order gives the identical state, and a test pins that against the real function.
        val kept = ArrayList<Double?>()
        var dropped = 0
        for (i in values.indices) {
            if (i < dayKeys.size) {
                val dayStart = runCatching {
                    java.time.LocalDate.parse(dayKeys[i])
                        .atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()
                }.getOrNull()
                if (dayStart != null && dayStart < baselineEpoch) { dropped++; continue }
            }
            kept.add(values[i])
        }
        val day = java.time.Instant.ofEpochSecond(baselineEpoch.toLong())
            .atZone(java.time.ZoneOffset.UTC).toLocalDate().toString()
        val head = "baseline $metric recalibrated=$day dropped=$dropped night(s) before it"
        val out = foldHistoryTrace(kept, cfg, metric, tail = tail)
        val lines = ArrayList<String>()
        lines.add(head)
        lines.addAll(out.lines)
        return Step(out.state, lines)
    }
}
