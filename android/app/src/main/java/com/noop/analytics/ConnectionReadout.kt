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
     * are different diagnoses. Integer half-up quantization makes exact 50 ms ties deterministic, and
     * rendering the whole and fractional digits directly keeps locale out of pasted logs. Twin of the
     * Swift `ConnectionTrace.sessionHeldSuffix`.
     */
    fun sessionHeldSuffix(millis: Long): String {
        if (millis < 0L) return ""
        val tenths = millis / 100L + if (millis % 100L >= 50L) 1L else 0L
        return " after ${tenths / 10L}.${tenths % 10L}s"
    }


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
        // #1823: this branch has NOT read a clock - it is reached when no correlation exists, which is
        // every 5/MG. The only evidence is how the strap DATED its records, so say that rather than
        // claiming a clock reading we never took. Twin of the Swift wording.
        if (strapNewestUnix != null) return if (strapNewestUnix < ceiling) "no (records dated 1970/71)" else "yes"
        return "no (waiting for the strap clock)"
    }

    /** #1818: at or above this charge the "charge it" remedy is already satisfied, so repeating it is
     *  noise. Twin of the Swift constant - the two must move together or the platforms give different
     *  advice for the same strap. */
    const val RTC_ALREADY_CHARGED_PCT: Double = 95.0

    /** #987: a plain-words warning when the strap RTC reads epoch-era (~1970/71), from EITHER signal we
     *  hold (the correlated device clock or the strap's newest banked-record timestamp). null when both
     *  look sane or neither was seen yet - we never fabricate a fault. Twin of the Swift warning.
     *
     *  #1818: the remedy is battery-dependent. A flat battery resets the RTC, so on a low strap
     *  "charge it" is real advice. On an ALREADY-charged strap it is not, and the old copy sent users
     *  at 100% round a loop they had already run.
     *
     *  The charged branch deliberately states only what holds for EVERY strap - that charging again
     *  will not change it - and asks for a log. It must NOT claim NOOP re-sends the clock on every
     *  connect: that is true on WHOOP4 (runConnectHandshake calls SET_CLOCK unconditionally, both
     *  payload forms, #120) but FALSE on a 5/MG, where the clock write is gated behind didBond, and an
     *  unbondable 5/MG (#1635) is never clocked at all - precisely the strap most likely to be showing
     *  this warning. Explaining the mechanism in the sentence is how the original bug happened.
     *  [batteryPct] null (not yet read) keeps the charge advice - we only withdraw it on evidence.
     *  Callers MUST pass a reading from the CURRENT link and not a last-known charge that outlives it -
     *  a stale 100% would suppress the advice in the one case it is right, a strap that ran flat and
     *  reset its RTC. */
    fun rtcWarning(deviceClockUnix: Long?, strapNewestUnix: Long?, batteryPct: Double? = null): String? {
        val ceiling = ConnectionTrace.RTC_EPOCH_CEILING_UNIX
        val clockBad = deviceClockUnix != null && deviceClockUnix > 0L && deviceClockUnix < ceiling
        val newestBad = strapNewestUnix != null && strapNewestUnix > 0L && strapNewestUnix < ceiling
        if (!clockBad && !newestBad) return null
        val lead = "Strap clock reads 1970/71 (never set since its last reset), so it is not banking history. "
        if (batteryPct != null && batteryPct >= RTC_ALREADY_CHARGED_PCT) {
            return lead +
                "The strap is already charged, so charging again will not change this. Export a strap " +
                "log from Test Centre so the clock exchange can be read."
        }
        return lead + "Charge the strap to 100% and reconnect so the clock latches."
    }

    /** #1809: one-line account of a finished BLE link, logged on every disconnect. Twin of the Swift
     *  formatter.
     *
     *  A strap log could not previously answer "did the strap send anything?". Inbound notifications only
     *  stamped a liveness timestamp that was then discarded, so a reporter chasing a silent strap had to
     *  infer silence from the fact that every LOGGED line happened to be outgoing - which measures NOOP's
     *  logging, not the strap. This measures the strap.
     *
     *  [realtimeArmed] matters because the #80 marginal-radio fallback only counts a drop when the R10/R11
     *  burst was actually armed; armed=no says up front that the detector cannot trip for this link,
     *  however many times the loop repeats.
     *
     *  Milliseconds are printed raw: no float formatting, so the two platforms cannot round apart.
     *  [upMillis] is Long, not Int: Swift's Int is 64-bit, so an Int here would be the NARROWER type and
     *  a link held past ~24.8 days would wrap negative and print "up 0ms" - a dead-looking link that was
     *  in fact the healthiest one we ever had. Rare, silent, and exactly backwards, so use the real twin. */
    fun linkEpitaph(upMillis: Long, inboundFrames: Int, inboundBytes: Int, cmdChannelFrames: Int,
                    realtimeArmed: Boolean, ended: String): String {
        var line = "Link epitaph: up ${maxOf(0L, upMillis)}ms, inbound ${maxOf(0, inboundFrames)} frames / " +
            "${maxOf(0, inboundBytes)} bytes (cmd-channel ${maxOf(0, cmdChannelFrames)}), " +
            "realtime armed=${if (realtimeArmed) "yes" else "no"}, ended=$ended"
        if (inboundFrames <= 0) {
            line += " - the strap sent NOTHING on this link"
        }
        return line
    }

    /**
     * #1635: what a finished link actually stored, split by PATH.
     *
     * The epitaph counts frames. That is right for a silent strap and wrong for one talking over only part
     * of its surface: an unbonded 5/MG streams heart rate and R-R all night while nothing bond-gated
     * lands, and the epitaph reports hundreds of healthy inbound frames.
     *
     * The split has to be by PATH, not by stream, and an earlier live-only version of this line got that
     * wrong. `extractStreams` — the realtime decoder — produces only hr, rr, events and battery. Gravity,
     * respiratory, skin temperature, SpO2 and steps come exclusively from the historical decoder behind
     * the offload. A live-only tally therefore printed "nothing banked live for: gravity, resp, …" on
     * EVERY link, bonded or not: a constant wearing the costume of a finding.
     *
     * So both paths are counted and named. The offload is where the bond shows: an unbonded strap defers
     * backfill entirely, so `offload none` is the real signal, and a healthy sync fills it.
     *
     * Battery is absent on purpose. It rides the standard 0x2A19 profile, so it banks with or without the
     * bond and answers nothing here. [offloadSteps] is nullable for the same reason it is on Apple: a
     * platform that cannot measure a stream omits it rather than reporting a zero that reads as a fault.
     *
     * Counts are rows ACCEPTED, so a re-offload of already-stored records reads zero — correct, since the
     * question is what the database gained. Pure, total and clamped: it runs on the teardown path, where
     * throwing would cost the report it exists to produce. Twin of the Swift formatter.
     */
    fun linkBankedSummary(
        liveHr: Int, liveRr: Int, offloadChunks: Int,
        offloadHr: Int, offloadRr: Int, offloadGravity: Int, offloadResp: Int,
        offloadSkinTemp: Int, offloadSpo2: Int, offloadSteps: Int?,
    ): String {
        val live = "live hr=${maxOf(0, liveHr)} rr=${maxOf(0, liveRr)}"
        val offload = (listOf(
            "hr" to offloadHr, "rr" to offloadRr, "gravity" to offloadGravity, "resp" to offloadResp,
            "skinTemp" to offloadSkinTemp, "spo2" to offloadSpo2,
        ) + listOfNotNull(offloadSteps?.let { "steps" to it })).map { (k, v) -> k to maxOf(0, v) }
        val offloadTotal = offload.sumOf { it.second }
        // Three distinguishable states, reported as FACTS rather than verdicts. "No chunks" is not
        // evidence of a fault on its own: a short or command-only link never reaches backfill, and the
        // reason it was skipped is already logged next to it ("Backfill: deferred — connect handshake not
        // done yet (didBond=…)"). Editorialising here — an earlier draft said "offload did NOT run on this
        // link" — reads as an accusation on a healthy 16-second connect. The epitaph above supplies the
        // uptime a reader needs to weigh it.
        //
        // "Never ran" and "ran with nothing new" are still DIFFERENT and must not share a sentence.
        // Rows are counted as ACCEPTED, so a reconnect that re-offloads already-stored records banks zero
        // while the strap plainly handed its history over — `classifyCompletedOffload` already treats that
        // as `bankedSensorRecords`, not a fault. Only the first case speaks to the bond.
        if (maxOf(0, offloadChunks) == 0) {
            return "banked this link: $live | offload none"
        }
        if (offloadTotal == 0) {
            return "banked this link: $live | offload ran ${maxOf(0, offloadChunks)} chunk(s), no new rows"
        }
        val body = offload.joinToString(" ") { (k, v) -> "$k=$v" }
        val empty = offload.filter { it.second == 0 }.map { it.first }
        if (empty.isEmpty()) return "banked this link: $live | offload $body"
        return "banked this link: $live | offload $body - nothing banked from the offload for: " +
            empty.joinToString(", ")
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
