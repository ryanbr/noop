package com.noop.testcentre

import com.noop.analytics.ConnectionTrace
import com.noop.ble.taggedStrapLogLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity + behaviour test for the report-completeness guard. The {domain -> killer-token} map and the
 * "Capture check" section labels MUST stay byte-identical to the Swift twin (the maintainer reads the
 * same section on every platform), so this pins the map, the section text, and the present/MISSING logic.
 */
class ReportCompletenessParityTest {

    @Test fun killerTokenMapIsTheCanonicalContract() {
        // Byte-identical to the Swift ReportCompleteness.killerTokens. UNIVERSAL plus the 9 wired domains;
        // the Phase-3 domains (notifications/sources/stress/longevity) are intentionally absent.
        assertEquals("dayOwner day=", ReportCompleteness.killerTokens[TestDomain.UNIVERSAL])
        assertEquals("gate run=", ReportCompleteness.killerTokens[TestDomain.SLEEP])
        assertEquals("clockDrift ", ReportCompleteness.killerTokens[TestDomain.CONNECTION])
        assertEquals("session event=", ReportCompleteness.killerTokens[TestDomain.WORKOUTS])
        assertEquals("dataVolume dbRows=", ReportCompleteness.killerTokens[TestDomain.DISPLAY])
        assertEquals("import parser=", ReportCompleteness.killerTokens[TestDomain.IMPORT])
        assertEquals("stepsEst ", ReportCompleteness.killerTokens[TestDomain.STEPS])
        assertEquals("battery series=", ReportCompleteness.killerTokens[TestDomain.BATTERY])
        assertEquals("charge score=", ReportCompleteness.killerTokens[TestDomain.RECOVERY])
        assertEquals("hrv rmssd=", ReportCompleteness.killerTokens[TestDomain.HRV])
        assertEquals(10, ReportCompleteness.killerTokens.size)
        // No Phase-3 token claims (we never report MISSING for a trace we never promised to emit).
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.NOTIFICATIONS))
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.SOURCES))
        assertFalse(ReportCompleteness.killerTokens.containsKey(TestDomain.MASTER))
    }

    @Test fun universalIsAlwaysCheckedEvenWithNoActiveMode() {
        val checked = ReportCompleteness.checkedDomains(active = emptySet())
        assertEquals(listOf(TestDomain.UNIVERSAL), checked)
    }

    @Test fun checkedDomainsKeepKillerTokenDeclarationOrder() {
        // Active set order must NOT leak into the section: it is always killerTokens declaration order so
        // the section reads identically on both platforms regardless of which modes are on.
        val active = setOf(TestDomain.HRV, TestDomain.SLEEP, TestDomain.CONNECTION)
        assertEquals(
            listOf(TestDomain.UNIVERSAL, TestDomain.SLEEP, TestDomain.CONNECTION, TestDomain.HRV),
            ReportCompleteness.checkedDomains(active),
        )
    }

    @Test fun statusesAreSubstringMatchesOverTheReport() {
        val report = buildString {
            appendLine("dayOwner day=2026-06-27 readId=my-whoop writeActiveId=my-whoop hrRows=900 provenance=measured")
            appendLine("[sleep] gate run=1 spanS=27000 KEPT gate=accepted detail=...")
            // connection NOT present -> MISSING when connection is active.
        }
        val active = setOf(TestDomain.SLEEP, TestDomain.CONNECTION)
        val s = ReportCompleteness.statuses(report, active)
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.UNIVERSAL])
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.SLEEP])
        assertEquals(ReportCompleteness.Status.MISSING, s[TestDomain.CONNECTION])
    }

    @Test fun sleepIsPresentFromComputedProvenanceLineWithoutGateRun() {
        // #127: `gate run=` only re-emits when the sleep-stager gate re-runs under the SLEEP trace sink; a
        // night scored on the backfill/post-sync pass (or already scored, so analyzeRecent(force=false)
        // skips the gate) won't re-fire it. The always-on per-day provenance line still proves sleep was
        // computed, so a valid capture must NOT read INCOMPLETE just because the deeper trace didn't re-run.
        val report = buildString {
            appendLine("dayOwner day=2026-07-09 readId=my-whoop writeActiveId=my-whoop hrRows=27001 provenance=measured")
            appendLine("sleep day=2026-07-09 totalSleepMin=426 matched=1 source=computed")
            // NOTE: no `gate run=` in this capture — exactly the #127 report.
        }
        val s = ReportCompleteness.statuses(report, active = setOf(TestDomain.SLEEP))
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.SLEEP])
        val section = ReportCompleteness.captureCheckSection(report, active = setOf(TestDomain.SLEEP))
        assertTrue("a computed-sleep capture must read complete, not INCOMPLETE",
            section.endsWith("complete: all active traces present"))
        // #386 mislabel: the parenthetical must name the token that MATCHED (the evidence line), never
        // the absent killer trace — `present (gate run=)` over an evidence-only match sent a maintainer
        // hunting for gate lines the report never contained.
        assertTrue("an evidence-only match must be labelled `via <evidence>`",
            section.contains("sleep: present (via \"sleep day=\")"))
    }

    @Test fun connectionIsPresentFromConnectChurnWhenTheLinkNeverReachesTheClockRead() {
        // #1040, reproduced verbatim: CONNECTION's killer token `clockDrift ` is emitted from the strap-clock
        // read, which a link that dies ~3 s after every connect never reaches. So the WORSE the connection
        // bug, the more certainly its own capture reads MISSING — the report arrived with 816 reconnects, a
        // log full of `[connection]` lines, and `INCOMPLETE: missing connection` stamped on exactly the
        // capture we needed.
        //
        // No `bondState` in this fixture ON PURPOSE: that line only fires on a COMPLETED encrypted bond, so
        // a loop whose bond never completes wouldn't emit it and the rescue would not fire.
        val report = buildString {
            appendLine("dayOwner day=2026-08-02 readId=whoop-D0 writeActiveId=whoop-D0 hrRows=2439 provenance=measured")
            appendLine("[connection] connect up gen=852 latencyMs=6120 uptimeStart=1785663906")
            appendLine("[connection] connect down (uptime ends after 3.0s)")
            appendLine("[connection] reconnect n=816 reason=localTerminate via=bondWatchdog")
            // NOTE: neither `clockDrift ` nor `bondState` — the link never got far enough for either.
        }
        val s = ReportCompleteness.statuses(report, active = setOf(TestDomain.CONNECTION))
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.CONNECTION])
        val section = ReportCompleteness.captureCheckSection(report, active = setOf(TestDomain.CONNECTION))
        assertTrue("a reconnect-loop capture must read complete, not INCOMPLETE",
            section.endsWith("complete: all active traces present"))
        assertTrue("an evidence-only match must be labelled `via <evidence>`",
            section.contains("connection: present (via \"reconnect n=\")"))
    }

    @Test fun connectionIsPresentWhenTheLinkNEVERConnectsAtAll() {
        // The other half of the same bug class, and the reason the token is `reconnect n=` rather than
        // `connect up gen=`: a strap that never reaches CONNECTED emits ONLY the failedConnect branch, so a
        // token keyed on a successful connect-up would leave "can't connect at all" reports still stamped
        // INCOMPLETE — a connection failure invalidating its own capture, exactly what #1040 was about.
        val report = buildString {
            appendLine("dayOwner day=2026-08-02 readId=my-whoop writeActiveId=my-whoop hrRows=0 provenance=measured")
            appendLine("[connection] reconnect n=42 failedConnect reason=connectionTimeout")
            // NOTE: no `connect up gen=` — the link never came up even once.
        }
        val s = ReportCompleteness.statuses(report, active = setOf(TestDomain.CONNECTION))
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.CONNECTION])
        assertTrue(ReportCompleteness.captureCheckSection(report, active = setOf(TestDomain.CONNECTION))
            .endsWith("complete: all active traces present"))
    }

    @Test fun connectionStillPrefersTheClockDriftKillerTraceWhenItIsPresent() {
        // The churn line is the rescue path, not a replacement: a capture that DID reach the strap-clock read
        // must still name the deeper trace, so `via` continues to mean "the killer trace is genuinely absent".
        val both = "clockDrift newest=2026-08-02 wall=2026-08-02 ok\nreconnect n=3 reason=connectionTimeout"
        assertEquals("clockDrift ", ReportCompleteness.matchedToken(both, TestDomain.CONNECTION))
        assertEquals("reconnect n=",
            ReportCompleteness.matchedToken("reconnect n=3 reason=connectionTimeout", TestDomain.CONNECTION))
        assertEquals(null, ReportCompleteness.matchedToken("no connection traces here", TestDomain.CONNECTION))
    }

    @Test fun matchedTokenPrefersTheKillerTraceOverTheEvidenceLine() {
        // When BOTH are present the deeper killer trace is the one named — `via` is reserved for the
        // rescue path, so its appearance always means "the killer trace is genuinely absent".
        val both = "[sleep] gate run=1 KEPT\nsleep day=2026-07-09 totalSleepMin=426 matched=1 source=computed"
        assertEquals("gate run=", ReportCompleteness.matchedToken(both, TestDomain.SLEEP))
        val evidenceOnly = "sleep day=2026-07-09 totalSleepMin=426 matched=1 source=computed"
        assertEquals("sleep day=", ReportCompleteness.matchedToken(evidenceOnly, TestDomain.SLEEP))
        assertEquals(null, ReportCompleteness.matchedToken("nothing sleepy here", TestDomain.SLEEP))
    }

    @Test fun sleepStillMissingWhenNoSleepDiagnosticAtAll() {
        // The guard still fires when the capture carries NO sleep evidence of any kind (neither the gate
        // trace nor a per-day provenance line) — a genuinely thin report.
        val report = "dayOwner day=2026-07-09 readId=x writeActiveId=x hrRows=0 provenance=none"
        val s = ReportCompleteness.statuses(report, active = setOf(TestDomain.SLEEP))
        assertEquals(ReportCompleteness.Status.MISSING, s[TestDomain.SLEEP])
    }

    @Test fun captureCheckSectionExactText_complete() {
        val report = "x dayOwner day=D y\nz [sleep] gate run=1 KEPT gate=accepted w"
        val section = ReportCompleteness.captureCheckSection(report, active = setOf(TestDomain.SLEEP))
        assertEquals(
            "=== Capture check ===\n" +
                "universal: present (\"dayOwner day=\")\n" +
                "sleep: present (\"gate run=\")\n" +
                "complete: all active traces present",
            section,
        )
    }

    /**
     * #950 — the capture check must not read its OWN output as evidence.
     *
     * The section renders a missing domain as `<id>: MISSING (expected \"<killer token>\")`, and that line
     * contains the killer token. meta.json's capture_check was computed over report.txt AFTER the section
     * was appended, so the re-scan found the token inside its own "expected …" text and recorded the
     * domain as present. Every missing trace flipped and `complete` went true while report.txt said
     * INCOMPLETE — a bug report that says it carries a workouts trace, attached to a report that says it
     * does not. Seen on #950.
     *
     * The Swift twin evaluates once and reuses that result, which is why only Android had it.
     */
    @Test fun metaMustNotBeComputedOverTextContainingTheSection() {
        val body = "header\ndayOwner day=D readId=x writeActiveId=x hrRows=0 provenance=none\nbody"
        val active = setOf(TestDomain.WORKOUTS)
        val section = ReportCompleteness.captureCheckSection(body, active)
        // The section itself carries the killer token, in the "expected …" label.
        assertTrue(section.contains("session event="))

        // Scanned over the body (correct): MISSING and not complete.
        val fromBody = ReportCompleteness.captureCheckMeta(body, active)
        assertEquals("MISSING", fromBody.traces["workouts"])
        assertEquals(false, fromBody.complete)

        // Scanned over body+section (the bug): the check reads its own words back as evidence.
        val poisoned = ReportCompleteness.captureCheckMeta(body + "\n" + section, active)
        assertEquals(
            "the section's own 'expected session event=' must not count as the trace landing",
            "present", poisoned.traces["workouts"],
        )
        // Pinned as the REASON the assembler must pass the pre-append body: if this ever stops being
        // "present", the self-poisoning is gone at the source and the assembler's argument can relax.
    }

    @Test fun captureCheckSectionExactText_incomplete() {
        // dayOwner present (universal informational), but the active sleep + connection traces never landed.
        val report = "header\ndayOwner day=D readId=x writeActiveId=x hrRows=0 provenance=none\nbody"
        val section = ReportCompleteness.captureCheckSection(
            report, active = setOf(TestDomain.SLEEP, TestDomain.CONNECTION),
        )
        assertEquals(
            "=== Capture check ===\n" +
                "universal: present (\"dayOwner day=\")\n" +
                "sleep: MISSING (expected \"gate run=\")\n" +
                "connection: MISSING (expected \"clockDrift \")\n" +
                "INCOMPLETE: missing sleep, connection",
            section,
        )
    }

    @Test fun missingUniversalAloneIsStillComplete() {
        // The universal line is informational: its absence does NOT mark a report incomplete (a brand-new
        // install with no scored day yet has no dayOwner line, but if no domain is active that is fine).
        val section = ReportCompleteness.captureCheckSection("nothing here", active = emptySet())
        assertEquals(
            "=== Capture check ===\n" +
                "universal: MISSING (expected \"dayOwner day=\")\n" +
                "complete: all active traces present",
            section,
        )
    }

    @Test fun metaTracesUseWireIdsAndCompleteFlag() {
        val report = "dayOwner day=D\nimport parser=whoopExport v=3 traceV=1"
        val meta = ReportCompleteness.captureCheckMeta(report, active = setOf(TestDomain.IMPORT))
        // IMPORT carries the wire id "import" (not "dataImport") - byte-aligned with the Swift twin.
        assertEquals("present", meta.traces["universal"])
        assertEquals("present", meta.traces["import"])
        assertTrue(meta.complete)
    }

    @Test fun metaCompleteFalseWhenActiveTraceMissing() {
        val report = "dayOwner day=D"
        val meta = ReportCompleteness.captureCheckMeta(report, active = setOf(TestDomain.BATTERY))
        assertEquals("MISSING", meta.traces["battery"])
        assertFalse(meta.complete)
    }

    @Test fun universalTaggedClockDriftSatisfiesConnectionCheck() {
        // CAPTURE-B parity invariant: the clock-drift line now rides the UNIVERSAL block (tagged .universal,
        // gated on any-mode-on), yet a Connection-active report still needs the CONNECTION killer token to
        // read PRESENT. Prove the universal-tagged line carries that exact token, so promoting clockDrift to
        // universal does NOT break the Connection completeness check. This is the cross-lane seam (the emit
        // is in WhoopBleClient; the guard is here), so we assert the two agree on the literal token.
        val line = ConnectionTrace.clockDriftLine(
            oldestUnix = 1_700_000_000L, newestUnix = 1_700_100_000L, wallNowUnix = 1_700_100_030L,
        )
        // Exactly as it lands in report.txt: redacted (no PII in this line) then tagged .universal.
        val asShipped = taggedStrapLogLine(line, TestDomain.UNIVERSAL)
        assertTrue("the universal-tagged line must carry the CONNECTION killer token",
            asShipped.contains(ReportCompleteness.killerTokens[TestDomain.CONNECTION]!!))
        // And it satisfies a Connection-active completeness check end-to-end.
        val s = ReportCompleteness.statuses(asShipped, active = setOf(TestDomain.CONNECTION))
        assertEquals(ReportCompleteness.Status.PRESENT, s[TestDomain.CONNECTION])
    }
}
