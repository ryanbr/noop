package com.noop.analytics

/*
 * ResonanceEngine.kt — find a user's personal resonance-frequency breathing pace by sweeping candidate
 * paces and measuring which one maximises respiratory sinus arrhythmia (RSA) amplitude. PURE + DB-free;
 * the live session controller paces each candidate via [BreathPacer] + the buzz path, feeds the clean R-R
 * it ingested per pace back in here, and persists the locked pace as a pref.
 *
 * Faithful Kotlin mirror of StrandAnalytics/ResonanceEngine.swift — keep the per-pace RSA score and the
 * locked-pace selection byte-identical to Swift (cross-platform parity is the contract, pinned by matching
 * golden-vector tests). See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L1).
 *
 * THEORY (Lehrer/Gevirtz, approach not code): there is a personal pace — usually 4.5–7 br/min — at which
 * the 0.1 Hz baroreflex and RSA align and the heart-rate oscillation amplitude peaks. We find it by
 * pacing the user through candidate paces and reading the RSA response at each.
 *
 * RSA amplitude (per pace): the heart speeds up on the inhale and slows on the exhale; once-per-breath
 * that produces a peak-to-trough swing in the instantaneous HR (60000/RR). We know each breath cycle's
 * boundaries because WE paced them (from the pace's cycle length), so we measure the mean peak-to-trough
 * swing of instantaneous HR WITHIN each paced breath cycle. That mean swing is the RSA amplitude; it
 * peaks at the resonance pace. RMSSD (via the shared [HrvAnalyzer]) corroborates / breaks ties.
 *
 * HONEST LIMITS: WHOOP R-R is PPG-derived, not ECG — RSA amplitude / HF-HRV are ESTIMATES, never clinical
 * readings. A pace with too few clean beats is left UNSCORED rather than guessed; if fewer than
 * [MIN_SCORED_PACES] score, we report "no lock" and fall back to the 5.5 br/min coherence pace. We never
 * claim the pace is permanent — the caller dates it; it drifts.
 */
object ResonanceEngine {

    // ── Candidate paces ───────────────────────────────────────────────────────
    /** The full sweep candidate paces (br/min), 4.5–7.0 in 0.5 steps — the resonance band. */
    val FULL_SWEEP_PACES: List<Double> = listOf(4.5, 5.0, 5.5, 6.0, 6.5, 7.0)

    /** The quick sweep (≈7 min) — the band's ends + centre. */
    val QUICK_SWEEP_PACES: List<Double> = listOf(4.5, 5.5, 6.5)

    /** The coherence fallback pace used when no resonance pace can be locked. */
    const val FALLBACK_BPM: Double = 5.5

    // ── Tunables ──────────────────────────────────────────────────────────────
    /** Drop this many leading seconds of each pace as a settling transient before scoring (spec ~30 s). */
    const val TRANSIENT_DROP_SECONDS: Int = 30

    /** Minimum clean beats over a pace's steady window before its RSA/RMSSD are trusted (mirrors
     *  [HrvAnalyzer.MIN_BEATS]). */
    val MIN_BEATS_PER_PACE: Int = HrvAnalyzer.MIN_BEATS

    /** Minimum breath cycles with a measurable swing before a pace is scorable. */
    const val MIN_CYCLES_PER_PACE: Int = 3

    /** Fewer than this many SCORED paces → no confident lock; fall back to [FALLBACK_BPM]. */
    const val MIN_SCORED_PACES: Int = 3

    // ── Inputs / outputs ──────────────────────────────────────────────────────

    /**
     * One beat — a plain (ts, rrMs) pair, decoupled from the storage entities so the engine takes pure
     * inputs (the Swift twin carries the identical shape). ts is wall-clock unix SECONDS; rrMs the R-R
     * interval in ms. The caller maps its [com.noop.data.RrInterval] rows onto these.
     */
    data class RrBeat(val ts: Int, val rrMs: Int)

    /**
     * The clean R-R a single paced candidate produced, with the pace it was paced at. [rr] are the R-R
     * beats ingested while pacing at [bpm]; [startTs] / [endTs] bound the paced window (the transient
     * drop is applied relative to [startTs]).
     */
    data class PaceSample(val bpm: Double, val rr: List<RrBeat>, val startTs: Int, val endTs: Int)

    /**
     * The RSA / RMSSD response measured at one swept pace. [rsaAmplitude] is null (the pace is UNSCORED)
     * when the steady window had too few clean beats / cycles to measure honestly.
     */
    data class PaceScore(
        /** The paced breaths/min this score is for. */
        val bpm: Double,
        /** Mean peak-to-trough instantaneous-HR swing per breath cycle (bpm), or null if unscored. */
        val rsaAmplitude: Double?,
        /** RMSSD over the pace's steady-window clean beats (ms), or null. */
        val rmssd: Double?,
        /** Clean beats used in the steady window. */
        val cleanBeats: Int,
        /** Breath cycles that yielded a measurable swing. */
        val scoredCycles: Int,
    ) {
        /** Convenience: was this pace scored (RSA present)? */
        val scored: Boolean get() = rsaAmplitude != null
    }

    /**
     * The whole sweep result: every pace's score plus the locked pace (and whether it's a real lock or
     * the honest fallback). [lockedBpm] is always finite (the fallback when not locked) so the UI can use
     * it directly; [didLock] tells the copy whether to say "your pace" vs "couldn't lock today".
     */
    data class SweepResult(
        /** Per-pace scores in the order the candidates were swept. */
        val scores: List<PaceScore>,
        /** The selected pace (the RSA-max scored pace, or [FALLBACK_BPM] when no confident lock). */
        val lockedBpm: Double,
        /** True when a resonance pace was confidently locked; false when we fell back to coherence. */
        val didLock: Boolean,
    )

    // ── Per-pace RSA scoring ──────────────────────────────────────────────────

    private data class CleanBeat(val ts: Int, val rrMs: Double)

    /**
     * Score ONE paced candidate: clean its R-R, drop the leading transient, slice the steady window into
     * the paced breath cycles, and measure the mean per-cycle peak-to-trough instantaneous-HR swing
     * (RSA amplitude). RMSSD (shared [HrvAnalyzer]) corroborates. Unscorable (too few beats/cycles) →
     * [PaceScore.rsaAmplitude] == null.
     */
    fun scorePace(sample: PaceSample): PaceScore {
        val cycleMs = 60_000.0 / maxOf(sample.bpm, BreathPacer.MIN_BPM)
        val cycleSec = cycleMs / 1000.0

        // Steady window: from startTs + transient to endTs.
        val windowStart = sample.startTs + TRANSIENT_DROP_SECONDS
        val steady = sample.rr
            .filter { it.ts in windowStart..sample.endTs }
            .sortedBy { it.ts }

        // Clean R-R (range + Malik) for both the RMSSD and the swing, so ectopic beats can't fabricate an
        // RSA swing. Cleaning operates on the rrMs values; we keep ts alongside for cycle bucketing.
        val cleanMs = HrvAnalyzer.cleanRR(steady.map { it.rrMs.toDouble() })
        if (cleanMs.size < MIN_BEATS_PER_PACE) {
            return PaceScore(sample.bpm, rsaAmplitude = null, rmssd = null,
                cleanBeats = cleanMs.size, scoredCycles = 0)
        }

        // Re-pair the cleaned values back to timestamps by matching them in order against `steady`
        // (cleaning preserves order and only drops beats), so each surviving beat keeps its ts.
        val cleanBeats = repairTimestamps(steady, cleanMs)
        val rmssd = HrvAnalyzer.rmssdRaw(cleanMs)

        // Bucket clean beats into paced breath cycles relative to windowStart; per cycle, take the
        // peak-to-trough swing of instantaneous HR (60000/RR).
        val swings = ArrayList<Double>()
        val firstTs = cleanBeats.firstOrNull()?.ts
        if (cycleSec > 0 && firstTs != null) {
            var cycleIdx = 0
            var cycleHRs = ArrayList<Double>()
            fun flush() {
                if (cycleHRs.size >= 2) {
                    val hi = cycleHRs.max()
                    val lo = cycleHRs.min()
                    swings.add(hi - lo)
                }
                cycleHRs = ArrayList()
            }
            for (beat in cleanBeats) {
                val idx = ((beat.ts - firstTs).toDouble() / cycleSec).toInt()
                if (idx != cycleIdx) {
                    flush(); cycleIdx = idx
                }
                cycleHRs.add(60_000.0 / beat.rrMs)
            }
            flush()
        }

        if (swings.size < MIN_CYCLES_PER_PACE) {
            return PaceScore(sample.bpm, rsaAmplitude = null, rmssd = rmssd,
                cleanBeats = cleanMs.size, scoredCycles = swings.size)
        }
        val rsa = swings.sum() / swings.size.toDouble()
        return PaceScore(sample.bpm, rsaAmplitude = rsa, rmssd = rmssd,
            cleanBeats = cleanMs.size, scoredCycles = swings.size)
    }

    // ── The sweep → locked pace ───────────────────────────────────────────────

    /**
     * Score every swept candidate and pick the resonance pace = the SCORED pace with the largest RSA
     * amplitude (RMSSD breaks ties — higher RMSSD wins, a sanity corroboration). When fewer than
     * [MIN_SCORED_PACES] candidates scored, no confident lock: fall back to [FALLBACK_BPM] (coherence).
     */
    fun sweep(samples: List<PaceSample>): SweepResult {
        val scores = samples.map { scorePace(it) }
        val scored = scores.filter { it.scored }

        if (scored.size < MIN_SCORED_PACES) {
            return SweepResult(scores = scores, lockedBpm = FALLBACK_BPM, didLock = false)
        }
        // Max RSA amplitude; tie → higher RMSSD; final tie → slower pace (lower bpm, the calmer choice).
        // Mirrors the Swift `max { a, b -> ... }` (a "less-than" comparator returning the greater).
        val best = scored.maxWithOrNull { a, b ->
            val ra = a.rsaAmplitude ?: 0.0
            val rb = b.rsaAmplitude ?: 0.0
            if (ra != rb) return@maxWithOrNull ra.compareTo(rb)
            val ma = a.rmssd ?: 0.0
            val mb = b.rmssd ?: 0.0
            if (ma != mb) return@maxWithOrNull ma.compareTo(mb)
            // final tie: prefer the SLOWER pace → it should compare as "greater" so maxWith picks it.
            b.bpm.compareTo(a.bpm)
        }
        return SweepResult(scores = scores, lockedBpm = best?.bpm ?: FALLBACK_BPM, didLock = true)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /**
     * Re-attach timestamps to the cleaned rrMs series. Cleaning ([HrvAnalyzer.cleanRR]) preserves order
     * and only DROPS beats, so we walk `steady` in order consuming the next match for each cleaned value.
     */
    private fun repairTimestamps(steady: List<RrBeat>, cleanMs: List<Double>): List<CleanBeat> {
        val out = ArrayList<CleanBeat>(cleanMs.size)
        var si = 0
        for (v in cleanMs) {
            while (si < steady.size && steady[si].rrMs.toDouble() != v) si++
            if (si < steady.size) {
                out.add(CleanBeat(steady[si].ts, v))
                si++
            }
        }
        return out
    }
}
