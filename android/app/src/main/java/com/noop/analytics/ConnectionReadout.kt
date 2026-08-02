package com.noop.analytics

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ConnectionReadout.kt - Kotlin twin of ConnectionReadout.swift. Pure values + line formatters for the
// Connection & Sync test mode: the clock-drift summary line (strap-reported banked-record range vs wall
// clock with a future-date flag), the firmware-layout line, the no-cursor / trim sentinel line, and the
// tagged-tail parsers for the three liveReadout ids. No state, no IO, no em-dashes. Byte-aligned with the
// Swift line shapes so a shared report reads identically on either platform.

object ConnectionTrace {
    /**
     * The ` after <n>s` suffix on a `connect down` trace line, or empty when the session start is
     * unknown (#1020).
     *
     * A session's length separates the causes of a drop at a glance: a bond watchdog fires seconds in, a
     * keep-alive stall bounce minutes in, a radio drop anywhere. The bare `connect down (uptime ends)`
     * could not distinguish them, which is why a report of thousands of reconnects needed a round trip
     * before anyone could start on it.
     *
     * An unknown start yields NO suffix rather than `after 0.0s` — "instant drop" and "we do not know"
     * are different diagnoses. Locale-fixed so a decimal comma cannot follow the phone language into a
     * log people paste into issues. Twin of the Swift `ConnectionTrace.sessionHeldSuffix`.
     */
    fun sessionHeldSuffix(millis: Long): String =
        if (millis < 0L) "" else " after ${"%.1f".format(java.util.Locale.US, millis / 1000.0)}s"


    /**
     * The CLOCK-DRIFT summary line (#767 / #754 cluster): the strap-reported banked-record window
     * [oldest, newest] against the wall clock, ending in the shared clock VERDICT ([clockVerdict]):
     * FUTURE-DATED (ahead beyond [futureToleranceSeconds]), RTC-EPOCH (a never-set ~1970/71 clock, #987),
     * CLOCK-WARNING (behind beyond [behindToleranceSeconds] - #990: a -363 d drift used to read
     * "clockOk"), else clockOk. Promoted from the buried raw GET_DATA_RANGE frames to one upfront
     * .connection line. All timestamps are unix seconds in the same wall domain. [oldestUnix] is optional
     * (a half/short range reply gives only the upper bound). Mirrors the Swift formatter exactly.
     */
    fun clockDriftLine(
        oldestUnix: Long?,
        newestUnix: Long,
        wallNowUnix: Long,
        futureToleranceSeconds: Long = 120L,
        behindToleranceSeconds: Long = BEHIND_TOLERANCE_DEFAULT,
    ): String {
        val iso = isoDate(newestUnix)
        val aheadSeconds = newestUnix - wallNowUnix
        val sb = StringBuilder()
        sb.append("clockDrift newest=").append(iso)
            .append(" wall=").append(isoDate(wallNowUnix))
            .append(" newestVsWall=").append(signed(aheadSeconds)).append("s")
        if (oldestUnix != null) {
            val spanDays = maxOf(0L, newestUnix - oldestUnix) / 86_400L
            sb.append(" oldest=").append(isoDate(oldestUnix)).append(" spanDays=").append(spanDays)
        }
        sb.append(clockVerdict(aheadSeconds, newestUnix, futureToleranceSeconds, behindToleranceSeconds))
        return sb.toString()
    }

    // Strap-clock verdict (#990/#987) - shared by clockDriftLine on both its Connection and universal
    // emit sites, mirroring the Swift ConnectionTrace.clockVerdict byte for byte.

    /** 1972-01-01 unix. A strap RTC that was never set counts up from its 1970 epoch, so any strap-side
     *  timestamp below this ceiling means "the clock never latched" (the #77/#91/#987 cluster tell: the
     *  strap banks nothing to flash until its clock is set). Shared with the readout warning (#987). */
    const val RTC_EPOCH_CEILING_UNIX = 63_072_000L

    /** The default BEHIND drift tolerance (#990): +-48 h. A newest banked record a day or two behind is a
     *  strap that simply was not worn; beyond that the line must warn, never claim "clockOk". */
    const val BEHIND_TOLERANCE_DEFAULT = 48L * 3_600L

    /** The strap-clock VERDICT token the clock-drift line ends with, ordered most specific first:
     *  FUTURE (RTC ahead), RTC-EPOCH (never set, ~1970/71), CLOCK-WARNING (behind beyond the tolerance -
     *  #990: a -363 d drift used to read "clockOk"), else clockOk. Honest wording on the behind case: a
     *  reset clock and a long-unworn strap look identical from here, so the line names both. Twin of the
     *  Swift ConnectionTrace.clockVerdict. */
    internal fun clockVerdict(
        aheadSeconds: Long,
        newestUnix: Long,
        futureToleranceSeconds: Long,
        behindToleranceSeconds: Long,
    ): String {
        if (aheadSeconds > futureToleranceSeconds) return " FUTURE-DATED (strap clock ahead of wall)"
        if (newestUnix < RTC_EPOCH_CEILING_UNIX) {
            return " RTC-EPOCH (strap clock reads 1970/71, never set; charge to 100% and reconnect so it latches)"
        }
        if (aheadSeconds < -behindToleranceSeconds) {
            val days = -aheadSeconds / 86_400L
            return " CLOCK-WARNING (newest banked record ${days}d behind wall; strap clock reset or history stale)"
        }
        return " clockOk"
    }

    /** The firmware-layout line for a HEALTHY sync: which historical record layout the strap emits
     *  (v18/v24/v25/v26). Mirrors the Swift formatter. */
    fun firmwareLine(version: Int, decodable: Boolean): String =
        "firmware layout=v$version " +
            if (decodable) "decodable" else "UNMAPPED (no motion/HR decoded)"

    /** The trim / no-cursor sentinel line: the strap reported trim=0xFFFFFFFF, its "no valid flash
     *  cursor" marker (a clock/charge state, not a decode bug). Mirrors the Swift formatter. */
    fun noCursorLine(): String =
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"

    /** Compact ISO-8601 date-time (no fractional seconds), UTC, matching the Swift line. */
    internal fun isoDate(unix: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date(unix * 1000L))
    }

    /** Sign-prefixed integer so the newest-vs-wall delta reads as a signed offset. */
    internal fun signed(n: Long): String = if (n >= 0) "+$n" else "$n"
}

/**
 * Pure values for the Connection & Sync live-readout panel. Kotlin twin of the Swift ConnectionReadout.
 * Each parses the CONNECTION-tagged log tail the Connection emitters write. No state, no IO, no em-dashes.
 */
object ConnectionReadout {

    /** Connection uptime for the `connectionUptime` id, parsed from the most recent connect / disconnect
     *  line. [nowUnix] is injected so the readout is testable without a live clock. Mirrors the Swift parser. */
    fun uptimeLabel(taggedTail: List<String>, nowUnix: Long): String {
        for (line in taggedTail.asReversed()) {
            if (line.contains("connect down")) return "not connected"
            val start = longField(line, "uptimeStart=")
            if (start != null) {
                val secs = maxOf(0L, nowUnix - start)
                return durationLabel(secs)
            }
        }
        return "not connected"
    }

    /** Reconnect count for the `reconnectCount` id: the highest `reconnect n=<count>` seen in the tail.
     *  0 when no reconnect line is present. Mirrors the Swift parser. */
    fun reconnectCount(taggedTail: List<String>): Int {
        var maxN = 0
        for (line in taggedTail) {
            if (!line.contains("reconnect ")) continue
            val n = longField(line, "n=")
            if (n != null) maxN = maxOf(maxN, n.toInt())
        }
        return maxN
    }

    /** Last offload result for the `lastOffloadResult` id: the most recent "offload result=<...>"
     *  fragment. null when no offload has finished this session. Mirrors the Swift parser. */
    fun lastOffloadResult(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("offload result=")
            if (i >= 0) {
                val frag = line.substring(i + "offload result=".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }

    /** Rows drained (persisted) THIS session (#990), beside the all-time tally: the newest
     *  `sessionRows=<n>` running total from the per-chunk progress emitter, or the final
     *  `offload result= ... rows=<n>`. An "empty" result carries no rows= and honestly means 0, never an
     *  older session's total. null when no offload drained anything this session. Twin of the Swift parser. */
    fun sessionRows(taggedTail: List<String>): Int? {
        for (line in taggedTail.asReversed()) {
            if (line.contains("offload result=")) return (longField(line, "rows=") ?: 0L).toInt()
            val n = longField(line, "sessionRows=")
            if (n != null) return n.toInt()
        }
        return null
    }

    /** #990: parse the Backfiller session summary ("Backfill: session persisted N rows (...) across K
     *  night(s).") back into its row count so the log sink can fold each session into the persisted
     *  ALL-TIME drained-rows tally. That summary is emitted UNCONDITIONALLY whenever rows landed (the
     *  #150 win-rate line), so the cumulative counter accrues on every session, not only while the
     *  Connection test mode is on. null for any other line. Twin of the Swift parser. */
    fun drainedRowsFromSummary(line: String): Int? {
        val marker = "session persisted "
        val i = line.indexOf(marker)
        if (i < 0) return null
        val rest = line.substring(i + marker.length)
        val digits = rest.takeWhile { it.isDigit() }
        if (digits.isEmpty() || !rest.substring(digits.length).startsWith(" rows")) return null
        return digits.toIntOrNull()
    }

    /** #987: the device-side clock value from the newest "Clock correlated: device=<d> wall=<w>" line, or
     *  null when no correlation happened this session. Parsed from the UNTAGGED log tail (correlation is
     *  not a test-mode emitter). Twin of the Swift parser. */
    fun clockCorrelatedDevice(logLines: List<String>): Long? {
        for (line in logLines.asReversed()) {
            if (line.contains("Clock correlated:")) return longField(line, "device=")
        }
        return null
    }

    /** #987/#261: the "clock latched" readout value: "yes" once EITHER signal lands with a plausible
     *  (post-1972) timestamp — a GET_CLOCK correlation (deviceClockUnix, the WHOOP4 path) or a
     *  GET_DATA_RANGE reply's newest banked record (strapNewestUnix, the fallback a WHOOP 5/MG needs
     *  since its GET_CLOCK reply never populates deviceClockUnix — see the Swift twin's doc comment for
     *  why). "no (RTC reads 1970/71)" on an epoch-era signal; "no (waiting for the strap clock)" before
     *  either replies. Twin of the Swift labeller. */
    fun clockLatchedLabel(deviceClockUnix: Long?, strapNewestUnix: Long? = null): String {
        val ceiling = ConnectionTrace.RTC_EPOCH_CEILING_UNIX
        if (deviceClockUnix != null) return if (deviceClockUnix < ceiling) "no (RTC reads 1970/71)" else "yes"
        if (strapNewestUnix != null) return if (strapNewestUnix < ceiling) "no (RTC reads 1970/71)" else "yes"
        return "no (waiting for the strap clock)"
    }

    /** #987: a plain-words warning when the strap RTC reads epoch-era (~1970/71), from EITHER signal we
     *  hold (the correlated device clock or the strap's newest banked-record timestamp). null when both
     *  look sane or neither was seen yet - we never fabricate a fault. Twin of the Swift warning. */
    fun rtcWarning(deviceClockUnix: Long?, strapNewestUnix: Long?): String? {
        val ceiling = ConnectionTrace.RTC_EPOCH_CEILING_UNIX
        val clockBad = deviceClockUnix != null && deviceClockUnix > 0L && deviceClockUnix < ceiling
        val newestBad = strapNewestUnix != null && strapNewestUnix > 0L && strapNewestUnix < ceiling
        if (!clockBad && !newestBad) return null
        return "Strap clock reads 1970/71 (never set since its last reset), so it is not banking history. " +
            "Charge the strap to 100% and reconnect so the clock latches."
    }

    /** #987: freshness label for the "last frame" readout row ("12s ago" / "no frames yet"). [nowUnix]
     *  injected for testability. Twin of the Swift labeller. */
    fun lastFrameLabel(lastFrameUnix: Long?, nowUnix: Long): String {
        if (lastFrameUnix == null) return "no frames yet"
        return durationLabel(maxOf(0L, nowUnix - lastFrameUnix)) + " ago"
    }

    /** Parse a `key=<long>` field out of a line (value runs to the next space). null when absent/non-numeric. */
    internal fun longField(line: String, key: String): Long? {
        val i = line.indexOf(key)
        if (i < 0) return null
        val token = line.substring(i + key.length).takeWhile { it != ' ' }
        return token.toLongOrNull()
    }

    /** Short "Xm Ys" / "Xs" / "Xh Ym" duration label for the uptime readout. Mirrors the Swift labeller. */
    internal fun durationLabel(seconds: Long): String = when {
        seconds < 60 -> "${seconds}s"
        seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
        else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
    }
}
