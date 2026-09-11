package com.noop.ui

import com.noop.testcentre.TestDomain
import com.noop.testcentre.TestModeRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TestCentreLiveReadoutsTest {

    @Test fun activeRecoveryRowRendersChargeLabelAndParsedValueFromExportLog() {
        val mode = requireNotNull(TestModeRegistry.mode(TestDomain.RECOVERY))
        val rows = TestCentreLiveReadouts.rows(
            mode = mode,
            active = true,
            snapshot = TestCentreLiveSnapshot(
                logLines = listOf("[recovery] charge day=2026-08-19 score=62.5 band=yellow"),
            ),
        )

        assertEquals(
            listOf(LiveReadoutRow("lastChargeBreakdown", "Last Charge breakdown", "score=62.5 band=yellow")),
            rows,
        )
    }

    @Test fun recoveryUsesTheFirstRealDomainTagAndRejectsEmbeddedTagSpoofing() {
        val mode = requireNotNull(TestModeRegistry.mode(TestDomain.RECOVERY))
        val rows = TestCentreLiveReadouts.rows(
            mode = mode,
            active = true,
            snapshot = TestCentreLiveSnapshot(
                logLines = listOf(
                    "2026-08-19 12:00:00 [recovery] charge day=2026-08-19 score=62.5 band=yellow",
                    "[connection] payload=[recovery] charge day=2026-08-20 score=99.0 band=green",
                    "message payload=[recovery] charge day=2026-08-21 score=100.0 band=green",
                ),
            ),
        )

        assertEquals("score=62.5 band=yellow", rows.single().value)
    }

    @Test fun everyRegistryDeclaredIdHasExactlyOnePresentationMapping() {
        val declared = TestModeRegistry.all.flatMap { it.liveReadout }.toSet()
        assertEquals(16, declared.size)
        assertEquals(declared, TestCentreLiveReadouts.mappedIds)

        TestModeRegistry.all.forEach { mode ->
            assertEquals(
                mode.liveReadout,
                TestCentreLiveReadouts.rows(
                    mode = mode,
                    active = true,
                    snapshot = TestCentreLiveSnapshot(),
                ).map { it.id },
            )
        }
    }

    @Test fun inactiveRowIsCompactAndDoesNotResolveEvenAnUnknownReadout() {
        val futureMode = requireNotNull(TestModeRegistry.mode(TestDomain.RECOVERY))
            .copy(liveReadout = listOf("futureReadout"))

        assertTrue(
            TestCentreLiveReadouts.rows(
                mode = futureMode,
                active = false,
                snapshot = TestCentreLiveSnapshot(),
            ).isEmpty(),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun activeUnknownReadoutFailsVisiblyInsteadOfDisappearing() {
        val futureMode = requireNotNull(TestModeRegistry.mode(TestDomain.RECOVERY))
            .copy(liveReadout = listOf("futureReadout"))

        TestCentreLiveReadouts.rows(
            mode = futureMode,
            active = true,
            snapshot = TestCentreLiveSnapshot(),
        )
    }

    @Test fun refreshPolicyIsActiveOnlyAndObservesOnlyRelevantSourceRevisions() {
        val recovery = requireNotNull(TestModeRegistry.mode(TestDomain.RECOVERY))
        val connection = requireNotNull(TestModeRegistry.mode(TestDomain.CONNECTION))
        val sleep = requireNotNull(TestModeRegistry.mode(TestDomain.SLEEP))
        val battery = requireNotNull(TestModeRegistry.mode(TestDomain.BATTERY))

        assertEquals(LiveReadoutRefreshSources(), TestCentreLiveRefreshPolicy.sources(recovery, active = false))
        assertEquals(
            LiveReadoutRefreshSources(observeLogRevision = true),
            TestCentreLiveRefreshPolicy.sources(recovery, active = true),
        )
        assertEquals(
            LiveReadoutRefreshSources(observeLogRevision = true, connectionClockEveryMs = 1_000),
            TestCentreLiveRefreshPolicy.sources(connection, active = true),
        )
        assertEquals(
            LiveReadoutRefreshSources(observeLogRevision = true, observeSleepSampleRevision = true),
            TestCentreLiveRefreshPolicy.sources(sleep, active = true),
        )
        assertEquals(
            LiveReadoutRefreshSources(observeLogRevision = true, observeBatteryRevision = true),
            TestCentreLiveRefreshPolicy.sources(battery, active = true),
        )
    }

    // -- #987/#1823: the clock half of the Connection readout, computed here and never shown ---------
    //
    // ConnectionReadout.clockLatchedLabel and rtcWarning were both implemented AND unit-tested on this
    // platform with NO production caller, so an Android user could only learn their strap's clock was
    // never set by exporting a log and reading it themselves. iOS has shown both on Test Centre and
    // Devices throughout. These pin the wiring; the rules themselves are pinned in ConnectionReadoutTest.

    /** The reported shape: a WHOOP 5/MG whose banked records are epoch-era. Its GET_CLOCK reply is not
     *  served on that family, so how the strap DATED its records is the only evidence there is. */
    @Test fun anEpochDatedStrapReadsNotLatchedAndWarns() {
        val (row, warning) = connectionClockReadout(emptyList(), strapNewestUnix = 40_000_000L, batteryPct = 50.0)
        assertEquals(LiveReadoutRow("clockLatched", "Clock latched", "no (records dated 1970/71)"), row)
        assertTrue(requireNotNull(warning).contains("not banking history"))
    }

    @Test fun aSanelyDatedStrapReadsLatchedAndDoesNotWarn() {
        val (row, warning) = connectionClockReadout(emptyList(), strapNewestUnix = 1_782_475_000L, batteryPct = 50.0)
        assertEquals("yes", row.value)
        assertEquals(null, warning)
    }

    /** Before any range lands there is nothing to judge. The row says so rather than inventing a
     *  verdict, and no warning is raised on an absence. */
    @Test fun noEvidenceYetSaysWaitingAndRaisesNoWarning() {
        val (row, warning) = connectionClockReadout(emptyList(), strapNewestUnix = null, batteryPct = null)
        assertEquals("no (waiting for the strap clock)", row.value)
        assertEquals(null, warning)
    }

    /** #1818: the remedy is battery-dependent, and an already-charged strap must not be sent round the
     *  loop it has just run. Wiring the battery through is the whole point of passing it. */
    @Test fun anAlreadyChargedStrapIsNotToldToChargeAgain() {
        val flat = requireNotNull(
            connectionClockReadout(emptyList(), strapNewestUnix = 40_000_000L, batteryPct = 40.0).second
        )
        val charged = requireNotNull(
            connectionClockReadout(emptyList(), strapNewestUnix = 40_000_000L, batteryPct = 100.0).second
        )
        assertTrue(flat.contains("Charge the strap"))
        assertTrue(charged.contains("already charged"))
    }
}
