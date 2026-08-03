package com.noop.testcentre

/**
 * The report-completeness guard (Kotlin twin of the Swift ReportCompleteness). A report is only useful
 * if the active mode's KILLER TRACE actually landed in report.txt. The Test Centre's whole point is that
 * each domain emits one upfront, hard-to-miss line that settles the bug; if a tester toggles a mode but
 * the emitter never fires (strap never connected, no scored day, the import never ran), the .zip looks
 * full but carries nothing diagnostic. This guard reads report.txt back and reports, per active domain,
 * whether its killer-trace token is present, so a maintainer (and the tester, via the review sheet) sees
 * "Sleep: MISSING" before the report ships rather than after a round-trip.
 *
 * The {domain -> token} map below is the SINGLE source of truth and is byte-identical to the Swift twin
 * (same domains, same token substrings). Each token is the distinctive, stable leading fragment of that
 * domain's killer trace (verified against the trace emitters and their unit tests): a SUBSTRING match is
 * deliberate so the per-day / per-record suffix (counts, ids, ISO dates) can vary without breaking the
 * check. The UNIVERSAL token (`dayOwner day=`) rides every export, so it is checked on every report.
 *
 * Pure + side-effect-free (no clock, no IO): the assembler passes the assembled report.txt text and the
 * active-domain set, and gets back the lines to append. No PII (tokens are fixed format fragments). No
 * em-dashes. Tested directly on the JVM, and a parity test pins the map against the Swift twin.
 */
object ReportCompleteness {

    /** The status label written into the Capture check section + meta.json per checked domain. PRESENT
     *  when the killer trace landed, MISSING when the mode is on but its emitter never fired. */
    enum class Status(val token: String) { PRESENT("present"), MISSING("MISSING") }

    /**
     * domain -> the distinctive leading substring of that domain's killer trace. Byte-identical to the
     * Swift twin's map. UNIVERSAL's `dayOwner day=` rides every export (checked always); the rest are
     * checked only when their mode is active. NOTIFICATIONS / SOURCES / STRESS / LONGEVITY have no wired
     * emitter yet (Phase 3), so they are intentionally absent from the map and never claimed present.
     */
    val killerTokens: Map<TestDomain, String> = linkedMapOf(
        TestDomain.UNIVERSAL to "dayOwner day=",
        TestDomain.SLEEP to "gate run=",
        TestDomain.CONNECTION to "clockDrift ",
        TestDomain.WORKOUTS to "session event=",
        TestDomain.DISPLAY to "dataVolume dbRows=",
        TestDomain.IMPORT to "import parser=",
        TestDomain.STEPS to "stepsEst ",
        TestDomain.BATTERY to "battery series=",
        TestDomain.RECOVERY to "charge score=",
        TestDomain.HRV to "hrv rmssd=",
    )

    /**
     * The ordered set of domains to check for a report: the UNIVERSAL line (always), plus each active
     * domain that has a known killer token, in [killerTokens] declaration order so the Capture check
     * section reads identically on both platforms regardless of which modes are on. A domain active but
     * absent from the map (a Phase-3 mode with no emitter) is skipped, never reported MISSING for a trace
     * we never promised to emit.
     */
    fun checkedDomains(active: Set<TestDomain>): List<TestDomain> =
        killerTokens.keys.filter { it == TestDomain.UNIVERSAL || it in active }

    /**
     * Secondary EVIDENCE tokens: a domain also counts as PRESENT if one of these appears, for when its
     * primary killer TRACE legitimately didn't re-emit in this capture (#127). SLEEP's `gate run=` only
     * fires when the sleep-stager gate actually (re-)runs under the SLEEP-gated trace sink; a night scored
     * on the backfill/post-sync pass, or already scored so `analyzeRecent(force=false)` skips the gate,
     * won't re-emit it — yet the always-on per-day diagnostic line (`sleep day=… totalSleepMin=… source=…`)
     * IS in the report and proves the sleep pipeline evaluated the day. Accepting it mirrors the Swift
     * twin's multi-token `.sleep` and the same "the mode worked, even if the strap had nothing" rule the
     * steps domain already uses, so a valid capture is no longer flagged INCOMPLETE for a trace that just
     * didn't re-run. `gate run=` stays the preferred (deeper) trace; this only rescues the legit gap.
     */
    val evidenceTokens: Map<TestDomain, String> = linkedMapOf(
        TestDomain.SLEEP to "sleep day=",
        // #1040: CONNECTION's killer token `clockDrift ` is emitted from the strap-clock/history read, so a
        // connection that never stays up long enough to reach that read cannot produce it — i.e. the worse
        // the connection bug, the more certainly the Connection capture reads MISSING. #1040 arrived with
        // 816 reconnects, a log full of `[connection] connect up/down` lines, and `INCOMPLETE: missing
        // connection` stamped on it, which reads as an unusable capture when it is in fact the report we
        // want. `reconnect n=` is the token that survives every way a connection can fail: it is emitted
        // under TestDomain.CONNECTION on BOTH sides of the wasConnected branch — `reconnect n=<n>
        // reason=<…>` after a link that came up and dropped, and `reconnect n=<n> failedConnect reason=<…>`
        // when it never reached CONNECTED at all. So it is present precisely when the connection is broken,
        // in either failure mode.
        //
        // Deliberately NOT `bondState`, the Swift twin's second token
        // (`CaptureCompleteness.tokens[.connection] == ["clockDrift", "bondState"]`): that fires from only
        // two sites, both on a COMPLETED encrypted bond, so a loop whose bond never completes — a prime
        // suspect for a ~3 s bounce — would not emit it and the capture would still read MISSING. Nor
        // `connect up gen=`, which covers a link that comes up and drops but NOT one that never connects,
        // leaving a whole failure mode still self-invalidating. Swift wants the same widening; tracked with
        // #1040 rather than diverging its map from here.
        //
        // Residual, accepted: a HEALTHY session that never dropped and never synced history has neither
        // token. That capture reads MISSING as it always has — but it records no connection problem, so it
        // is not a bug report being obstructed, which is what this rescue exists to prevent.
        TestDomain.CONNECTION to "reconnect n=",
        // #141: the NIGHTLY HRV trace proves the HRV mode captured, even when the user never took a manual
        // (spot) reading — `hrv rmssd=` only fires on the Live-screen snapshot, but the overnight per-window
        // trace emits `hrv nightSummary …`. So a wear-overnight-and-export HRV capture reads complete.
        TestDomain.HRV to "hrv nightSummary",
    )

    /**
     * The token that actually satisfied [d]'s presence check in [reportText], or null when neither did.
     * The killer trace is preferred (it is the deeper diagnostic); the evidence token (#127) only answers
     * when the killer is absent. Exposed so the rendered section names the token that MATCHED rather than
     * the one we hoped for — #386's export read `sleep: present (gate run=)` off an evidence-only match,
     * and that label sent the review hunting for gate lines the report never contained.
     */
    fun matchedToken(reportText: String, d: TestDomain): String? {
        val killer = killerTokens[d] ?: return null
        if (reportText.contains(killer)) return killer
        return evidenceTokens[d]?.takeIf { reportText.contains(it) }
    }

    /** Per-domain presence map for [reportText], over [checkedDomains]. PRESENT iff the killer token OR the
     *  domain's evidence token (if any, #127) occurs anywhere in the report. Deterministic order. */
    fun statuses(reportText: String, active: Set<TestDomain>): LinkedHashMap<TestDomain, Status> {
        val out = LinkedHashMap<TestDomain, Status>()
        for (d in checkedDomains(active)) {
            if (killerTokens[d] == null) continue
            out[d] = if (matchedToken(reportText, d) != null) Status.PRESENT else Status.MISSING
        }
        return out
    }

    /**
     * The "Capture check" section appended to report.txt: a header, then one line per checked domain in
     * deterministic order, then a footer flag when any active domain's trace is MISSING (the at-a-glance
     * "this report carries no diagnostic for X" signal). The parenthetical names the token that ACTUALLY
     * matched, never the one we hoped for (#386's mislabel): a killer-trace match keeps the bare
     * `(<killer>)`, an evidence-only match (#127) reads `(via <evidence>)`, and MISSING reads
     * `(expected <killer>)` — the Swift renderer's "expected …" wording for the missing case. Returns
     * the section WITHOUT a leading newline; the assembler joins it.
     */
    fun captureCheckSection(reportText: String, active: Set<TestDomain>): String {
        val statuses = statuses(reportText, active)
        val sb = StringBuilder()
        sb.append("=== Capture check ===")
        for ((d, status) in statuses) {
            val matched = matchedToken(reportText, d)
            // #1040: QUOTE the token. These are raw grep literals — they end in `=` or a significant
            // trailing space (`clockDrift `), so unquoted they render as a dangling fragment: a real
            // report read `connection: MISSING (expected clockDrift )`, and an evidence match would read
            // `present (via reconnect n=)`. Quoting makes it unambiguous that the text IS the substring to
            // search for, which is the whole point of naming it (#386). Does not affect the #950
            // self-poisoning guard: the bare token still occurs inside the quotes, so the assembler must
            // keep passing the PRE-append body either way.
            val label = when {
                status == Status.MISSING -> "expected \"${killerTokens[d]}\""
                matched == killerTokens[d] -> "\"$matched\""
                else -> "via \"$matched\""
            }
            sb.append('\n')
                .append(d.id).append(": ").append(status.token)
                .append(" (").append(label).append(')')
        }
        // Only an ACTIVE domain going MISSING is a problem; the universal line is informational. If any
        // active, mapped domain is MISSING, flag it so the maintainer reads it without scanning the list.
        val missingActive = statuses.entries
            .filter { it.key != TestDomain.UNIVERSAL && it.value == Status.MISSING }
            .map { it.key.id }
        sb.append('\n')
        if (missingActive.isEmpty()) {
            sb.append("complete: all active traces present")
        } else {
            sb.append("INCOMPLETE: missing ").append(missingActive.joinToString(", "))
        }
        return sb.toString()
    }

    /** The meta.json `capture_check` value: a {domainId -> "present"|"MISSING"} map plus the `complete`
     *  flag, for the machine-readable tie. Keys are the wire ids; emitted in sorted order by TestBundleMeta
     *  so the JSON bytes line up with the Swift twin. */
    fun captureCheckMeta(reportText: String, active: Set<TestDomain>): CaptureCheckMeta {
        val statuses = statuses(reportText, active)
        val map = LinkedHashMap<String, String>()
        for ((d, status) in statuses) map[d.id] = status.token
        val complete = statuses.entries.none { it.key != TestDomain.UNIVERSAL && it.value == Status.MISSING }
        return CaptureCheckMeta(traces = map, complete = complete)
    }

    /** The meta.json capture_check block: per-domain trace presence + the overall complete flag. */
    data class CaptureCheckMeta(val traces: Map<String, String>, val complete: Boolean)
}
