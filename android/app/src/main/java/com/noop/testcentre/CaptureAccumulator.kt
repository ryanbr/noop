package com.noop.testcentre

import com.noop.analytics.AnalyticsEngine

/**
 * The per-mode day/night capture accumulator (Kotlin twin of the Swift CaptureAccumulator, #965).
 *
 * #965 taught us the Test Centre "Capturing K of N" row was lying: K came from ceil(elapsedDays), a pure
 * wall-clock proxy that advances (or sits) regardless of whether the mode actually captured anything. A
 * tester running Sleep + Battery + Steps together saw every row stuck at "1 of 3" because the count was
 * never tied to real captured data: it counted elapsed time, not distinct days each mode produced its own
 * trace on. A shared clock also meant the three modes could never diverge - one number drove them all.
 *
 * This is the honest replacement: for a given domain, count the DISTINCT local calendar days that domain's
 * own tagged trace lines carry, so each active mode INDEPENDENTLY accumulates its own count off the
 * shareable strap log. Sleep counts nights (its `sleep day=` / `gate run=` lines), Battery counts days
 * (its `bank soc=... t=<unix>s` samples, folded to a local day), Steps counts days (`stepsRaw day=`), and
 * the universal `dayOwner day=` line accumulates once per scored day for the universal row.
 *
 * Pure + side-effect-free: it takes the domain, the already-redacted report text and a timezone offset and
 * returns an Int. No IO, no live clock, no PII. Byte-aligned with the Swift twin's day-token map + fold,
 * pinned by a parity test. No em-dashes.
 */
object CaptureAccumulator {

    /**
     * Per-domain "how a captured day shows up in the log". [DayKey] domains write an explicit
     * `day=YYYY-MM-DD` on their trace line; [Epoch] domains write a `t=<unix>s` wall stamp (battery banks a
     * SoC sample per reading, not a day-keyed row) that we fold to a LOCAL calendar day. The token(s) SCOPE
     * the scan so an unrelated `day=` line is not counted toward the wrong mode.
     */
    sealed interface DayMarker {
        val tokens: List<String>
        data class DayKey(override val tokens: List<String>) : DayMarker
        data class Epoch(override val tokens: List<String>) : DayMarker
    }

    /**
     * The declarative {domain -> day-marker} map. Tokens are the verbatim leading text the live emitters
     * write (mirroring ReportCompleteness), so a captured-day count is scoped to that mode's own lines. A
     * domain absent from the map accumulates 0 (no day-bearing trace).
     */
    val markers: Map<TestDomain, DayMarker> = linkedMapOf(
        TestDomain.SLEEP to DayMarker.DayKey(listOf("sleep day=", "gate run=")),
        TestDomain.STEPS to DayMarker.DayKey(listOf("stepsRaw", "stepsEst day=")),
        TestDomain.RECOVERY to DayMarker.DayKey(listOf("charge ")),
        TestDomain.BATTERY to DayMarker.Epoch(listOf("bank soc=")),
        TestDomain.UNIVERSAL to DayMarker.DayKey(listOf("dayOwner ")),
    )

    private val dayKeyRegex = Regex("day=([0-9]{4}-[0-9]{2}-[0-9]{2})")
    private val epochRegex = Regex("""\bt=([0-9]{6,})s""")

    /**
     * The count of DISTINCT local calendar days [domain] captured, read from [reportText]. DayKey domains
     * contribute the set of `day=` keys on their tagged lines; Epoch domains fold each `t=<unix>s` sample to
     * a local day via [tzOffsetSeconds] (seconds EAST of UTC, the same convention
     * [AnalyticsEngine.dayString] uses). A domain with no marker, or whose trace never landed, returns 0.
     */
    fun capturedDays(domain: TestDomain, reportText: String, tzOffsetSeconds: Long): Int =
        capturedDayKeys(domain, reportText, tzOffsetSeconds).size

    /** Line-form twin of [capturedDays]. */
    fun capturedDays(domain: TestDomain, reportLines: List<String>, tzOffsetSeconds: Long): Int =
        capturedDayKeys(domain, reportLines, tzOffsetSeconds).size

    /** The SET of distinct local day keys [domain] captured (yyyy-MM-dd). Empty when the mode has no
     *  day-bearing trace / captured none. */
    fun capturedDayKeys(domain: TestDomain, reportText: String, tzOffsetSeconds: Long): Set<String> =
        capturedDayKeys(domain, reportText.split("\n"), tzOffsetSeconds)

    /** #1468 follow-up: the same scan over lines the caller already has. The string form splits and
     *  delegates here, so both paths walk identical content — callers holding a line list no longer join
     *  it just so this can split it again. */
    fun capturedDayKeys(domain: TestDomain, reportLines: List<String>, tzOffsetSeconds: Long): Set<String> {
        val marker = markers[domain] ?: return emptySet()
        val days = HashSet<String>()
        for (line in reportLines) {
            if (marker.tokens.none { line.contains(it) }) continue
            when (marker) {
                is DayMarker.DayKey ->
                    dayKeyRegex.find(line)?.groupValues?.get(1)?.let { days.add(it) }
                is DayMarker.Epoch ->
                    epochRegex.find(line)?.groupValues?.get(1)?.toLongOrNull()?.let { unix ->
                        days.add(AnalyticsEngine.dayString(unix, tzOffsetSeconds))
                    }
            }
        }
        return days
    }
}
