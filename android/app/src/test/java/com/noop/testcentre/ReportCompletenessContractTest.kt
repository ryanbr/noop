package com.noop.testcentre

import com.noop.analytics.ConnectionTrace
import com.noop.ble.taggedStrapLogLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract + behaviour test for the report-completeness guard.
 *
 * NOT a parity test, despite what this file was called until #1531 exposed the difference. It pins the
 * Kotlin {domain -> killer-token} map against literals held HERE; it never reads the Swift side, so it
 * cannot fail when the two platforms drift -- and it stayed green through a divergence in which three of
 * the ten tokens ended up with no Swift counterpart at all (import, steps, battery). Claiming otherwise
 * was worse than claiming nothing, because it invited a reader to trust a guarantee that did not exist.
 *
 * What it DOES guarantee is still worth having: that Android's own map, section ordering and
 * present/MISSING wording cannot change by accident. Identical tokens across platforms are neither the
 * contract nor achievable -- each side must key on the lines its own emitters write. See
 * ReportCompleteness's header for the per-domain breakdown.
 */
class ReportCompletenessContractTest {

    @Test fun killerTokenMapIsTheCanonicalContract() {
        // Android's own canonical map. UNIVERSAL plus the 9 wired domains;
        // the Phase-3 domains (notifications/sources/stress/longevity) are intentionally absent.
        assertEquals("dayOwner day=", ReportCompleteness.killerTokens[TestDomain.UNIVERSAL])
        assertEquals("gate run=", ReportCompleteness.killerTokens[TestDomain.SLEEP])
        assertEquals("clockDrift ", ReportCompleteness.killerTokens[TestDomain.CONNECTION])
        assertEquals("session event=", ReportCompleteness.killerTokens[TestDomain.WORKOUTS])
        assertEquals("dataVolume dbRows=", ReportCompleteness.killerTokens[TestDomain.DISPLAY])
        assertEquals("import parser=", ReportCompleteness.killerTokens[TestDomain.IMPORT])
        assertEquals("stepsEst ", ReportCompleteness.killerTokens[TestDomain.STEPS])
        assertEquals("battery series=", ReportCompleteness.killerTokens[TestDomain.BATTERY])
        // "charge day=", not "charge score=": the engine re-emits every recovery trace line with a day
        // prefix, so the old token could never match and this domain read MISSING on every capture.
        assertEquals("charge day=", ReportCompleteness.killerTokens[TestDomain.RECOVERY])
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

    /**
     * The recovery token could never match. Every trace line is re-emitted by
     * `IntelligenceEngine.recoveryTraceLines` as `charge day=<day> ` + the body, so the bare
     * "charge score=" this used to look for does not occur in any report, and the domain read MISSING
     * on every capture carrying a perfectly healthy trace. Two real bundles held 1020 and 816 of these.
     */
    @Test
    fun theRecoveryTokenMatchesTheLineTheEngineActuallyEmits() {
        val real = "[recovery] charge day=2026-08-31 term hrv z=0.58 w=0.55 (higher HRV is better)\n" +
            "[recovery] charge day=2026-08-31 score=77.12 band=green (logistic k=1.6 z0=-0.2)"
        assertEquals(
            ReportCompleteness.Status.PRESENT,
            ReportCompleteness.statuses(real, setOf(TestDomain.RECOVERY))[TestDomain.RECOVERY],
        )
        // The nilScore variant is the same trace running, and must count too.
        val nilScore = "[recovery] charge day=2026-09-07 nilScore reason=missingInput (hrv/rhr required)"
        assertEquals(
            ReportCompleteness.Status.PRESENT,
            ReportCompleteness.statuses(nilScore, setOf(TestDomain.RECOVERY))[TestDomain.RECOVERY],
        )
    }

    /** A report with no recovery trace at all must still read MISSING. */
    @Test
    fun theRecoveryTokenStillReportsAGenuinelyAbsentTrace() {
        assertEquals(
            ReportCompleteness.Status.MISSING,
            ReportCompleteness.statuses("nothing here", setOf(TestDomain.RECOVERY))[TestDomain.RECOVERY],
        )
    }

    /**
     * A capture younger than a scoring pass cannot evidence one, whatever its tokens say. A sleep
     * bundle arrived with a nine-second profile and no `[sleep]` lines at all, and this section told
     * the reporter it was "complete", which is why they sent it.
     */
    @Test
    fun aProfileTooYoungToHoldAPassSaysSoEvenWhenEveryTokenIsPresent() {
        val full = "charge day=2026-09-07 score=1"
        val short = ReportCompleteness.captureCheckSection(
            full, setOf(TestDomain.RECOVERY), profileRanSeconds = 9,
        )
        assertTrue(short, short.contains("complete: all active traces present"))
        assertTrue(short, short.contains("TOO SHORT"))
        assertTrue(short, short.contains("9s"))
    }

    /**
     * The short-profile note goes AFTER the verdict, deliberately.
     *
     * Three tests above assert the section ENDS with the verdict line, and that invariant now holds
     * only while no duration is passed. Keeping the note last is the right trade: it is the line that
     * invalidates the verdict a reader has just been given, so burying it above would put the weaker
     * statement in the more prominent place. Pinned here so the change of shape is a decision on the
     * record rather than something a future endsWith assertion discovers.
     */
    @Test
    fun theShortProfileNoteFollowsTheVerdictRatherThanReplacingIt() {
        val line = ReportCompleteness.captureCheckSection(
            "charge day=2026-09-07 score=1", setOf(TestDomain.RECOVERY), profileRanSeconds = 9,
        )
        val verdict = line.indexOf("complete: all active traces present")
        val note = line.indexOf("TOO SHORT")
        assertTrue(line, verdict in 0 until note)
        assertTrue("the note is the footer when it fires", line.trimEnd().endsWith("export again."))
    }

    /** Past the threshold it says nothing extra. */
    @Test
    fun aLongEnoughProfileAddsNoWarning() {
        val ok = ReportCompleteness.captureCheckSection(
            "charge day=2026-09-07 score=1", setOf(TestDomain.RECOVERY), 600,
        )
        assertFalse(ok, ok.contains("TOO SHORT"))
    }

    /**
     * An unknown start time must not manufacture a warning: guessing from a missing timestamp would be
     * its own false signal, and this section exists to stop those.
     */
    @Test
    fun anUnknownProfileAgeSaysNothing() {
        val unknown = ReportCompleteness.captureCheckSection(
            "charge day=2026-09-07 score=1", setOf(TestDomain.RECOVERY), null,
        )
        assertFalse(unknown, unknown.contains("TOO SHORT"))
    }

    /**
     * A clock moved backwards between starting the profile and exporting yields a negative age, and
     * "the profile ran -412s before this export" is a worse line than saying nothing. A nonsense age
     * is unknown, and unknown says nothing.
     */
    @Test
    fun aNegativeProfileAgeSaysNothingRatherThanPrintingNonsense() {
        val line = ReportCompleteness.captureCheckSection(
            "charge day=2026-09-07 score=1", setOf(TestDomain.RECOVERY), profileRanSeconds = -412,
        )
        assertFalse(line, line.contains("TOO SHORT"))
        assertFalse(line, line.contains("-412"))
    }

    /** Exactly at the threshold is long enough; the warning is for what falls short of it. */
    @Test
    fun theThresholdItselfIsLongEnough() {
        val line = ReportCompleteness.captureCheckSection(
            "charge day=2026-09-07 score=1", setOf(TestDomain.RECOVERY),
            ReportCompleteness.MIN_PROFILE_SECONDS,
        )
        assertFalse(line, line.contains("TOO SHORT"))
    }
}
