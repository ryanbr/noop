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
}
