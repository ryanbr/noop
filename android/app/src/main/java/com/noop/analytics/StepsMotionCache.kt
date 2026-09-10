package com.noop.analytics

/**
 * Per-day reuse identity for the steps-calibration motion fold in [IntelligenceEngine.analyzeRecent].
 * Kotlin twin of the Swift `StepsMotionCache`.
 *
 * The drain this closes: the calibration fits one coefficient from sixty days of strap motion, and it
 * re-folded all sixty on EVERY pass. Each day meant a `gravitySamplesForDevice` read capped at
 * `STREAM_LIMIT` rows, so a worn library paid millions of materialised rows per pass to re-derive numbers
 * that had not moved. The phase does not scale with the days being re-scored — it always reads the same
 * sixty — so a two-day pass could cost more than a twenty-one-day one, which is what made it hard to see in
 * a cost line keyed on the day loop.
 *
 * [StepsEstimateEngine.dayMotionIntensity] is a pure fold over one day's gravity stream. Nothing else
 * reaches it: no profile field, no baseline, no toggle, no other stream. So unlike [AnalyzeRecentDayCache]
 * there is no pass-config signature to invalidate against — the value changes exactly when that one day's
 * gravity changes, and the key below is the whole story.
 *
 * Unlike the day-scan cache this one PERSISTS across launches, and the paragraph above is why it can. A
 * persisted day scan would have to carry `dayScanCacheConfigSig`, which folds in baselines1 and the habitual
 * sleep terms - and `sleepConsistency` (1-CV over 28 nights) and `habitualMidsleepSec` (a circular mean)
 * shift with ANY night moving, so it would invalidate wholesale on exactly the passes it would need to
 * survive. Nothing pass-global reaches this fold, so the payload stays valid while gravity stands still and
 * the sixty-day fold is paid once per install instead of once per launch: measured 32.9 s -> 3.3 s on a
 * worn 60-day library, which the cold pass otherwise repaid after every relaunch.
 *
 * It stays a DERIVED cache and nothing else reads it, so the whole failure surface is one re-fold: a payload
 * that is missing, unreadable, or written by an older fold is discarded rather than repaired.
 *
 * It still does NOT cross the `.noopbak` boundary, and must not start: the key is deliberately absent from
 * [com.noop.data.BackupSettingsCodec.WHITELIST] and its Apple twin. A restore carries the settings and the
 * record store, and this describes neither - it describes gravity rows AS THEY WERE ON ONE DEVICE. Shipping
 * it to another device would be the one way to serve a fold whose key no longer witnesses anything, which is
 * the failure every other guard here exists to prevent. A restored device simply re-folds once.
 */
object StepsMotionCache {
    /**
     * The per-day reuse key. Reuse a cached motion volume iff this string is unchanged.
     *
     * - [owner]: the resolved owning device the fold was measured against. A day whose owner flips between
     *   straps must re-fold, and the fingerprint below is device-scoped, so this makes that explicit rather
     *   than relying on two devices never producing an identical count and newest timestamp for one window.
     * - [gravityCount] / [gravityMaxTs]: the day window's gravity witness. Any gravity row added or removed
     *   moves one of the two. Deliberately NOT the wider `dayStreamFingerprint`: that also counts HR, R-R,
     *   respiration, SpO2, steps, skin temp and sleep state, so an ordinary HR offload would invalidate a
     *   motion volume that cannot have changed by it.
     */
    fun cacheKey(owner: String, gravityCount: Int, gravityMaxTs: Long): String =
        "$owner|$gravityCount|$gravityMaxTs"

    /**
     * The pass's one-line reuse readout, beside the phase cost line.
     *
     * [reused] and [folded] sum to the days scanned, so the ratio is readable without a second line. A pass
     * reporting `folded=60` every time means the key is moving when it should not, which is the failure this
     * cache can have and the reason the number is reported at all rather than assumed.
     */
    fun logLine(reused: Int, folded: Int, size: Int): String =
        "analyzeRecent stepsMotion reused=$reused/${reused + folded} size=$size"

    /**
     * The version of the FOLD the persisted values were produced by. Bump on any change to
     * [StepsEstimateEngine.dayMotionIntensity] that moves what it returns for the same samples.
     *
     * In memory this could not exist: a process cannot outlive the binary that filled it, so the fold that
     * produced a cached value is always the fold that would reproduce it. A persisted entry outlives its
     * build, and [cacheKey] witnesses the INPUTS only - a day whose gravity has not moved keys identically
     * across an app update, so without this the old volume would be served until that day's stream happened
     * to change. A bump discards every entry and costs one full re-fold, once, which is the cheap side.
     */
    const val FOLD_VERSION: Int = 1

    /**
     * Render the cache for storage. Days are emitted in sorted order so an unchanged cache renders to an
     * identical payload and the write is a no-op rather than churn.
     *
     * One line per day, `day\tkey\tmotion`, under a header naming [FOLD_VERSION]. Tab-separated because the
     * key itself contains `|`; the motion is written by raw bit pattern so it round-trips exactly and
     * locale-free, the same reason the Swift key encodes its skin anchor that way. The bits are rendered
     * UNSIGNED so the payload is byte-identical to the Swift twin's for the same cache, which is what makes
     * the shared-vector parity test meaningful - the two sides never read each other's storage.
     */
    fun serialize(entries: Map<String, Pair<String, Double>>): String {
        val sb = StringBuilder(header())
        for (day in entries.keys.sorted()) {
            val e = entries[day] ?: continue
            sb.append('\n').append(day).append('\t').append(e.first).append('\t')
                .append(e.second.toRawBits().toULong().toString())
        }
        return sb.toString()
    }

    /**
     * Parse a stored payload. Returns empty on anything it cannot vouch for - a wrong/absent header (an
     * older [FOLD_VERSION] included), a malformed line, or an implausible entry count. Every rejection costs
     * one re-fold, so this discards rather than salvages: a half-trusted cache is the one failure mode that
     * could feed a stale volume into the calibration fit.
     */
    fun deserialize(raw: String): HashMap<String, Pair<String, Double>> {
        val out = HashMap<String, Pair<String, Double>>()
        val lines = raw.split('\n')
        if (lines.firstOrNull() != header()) return out
        if (lines.size - 1 > MAX_ENTRIES) return out
        for (i in 1 until lines.size) {
            val f = lines[i].split('\t')
            if (f.size != 3 || f[0].isEmpty() || f[1].isEmpty()) continue
            val bits = f[2].toULongOrNull() ?: continue
            out[f[0]] = f[1] to Double.fromBits(bits.toLong())
        }
        return out
    }

    /** Payload header. Carries [FOLD_VERSION] so a fold change invalidates by failing the equality check. */
    private fun header(): String = "stepsMotion v$FOLD_VERSION"

    /** Upper bound on entries a payload may declare. The writer prunes to the calibration window every pass,
     *  so a payload far above it did not come from this cache and is not worth parsing. */
    private const val MAX_ENTRIES = 512
}
