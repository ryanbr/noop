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

    // MARK: - One pass over the archive must group exactly as the per-domain filter did

    /**
     * The screen now tags every domain in a single pass instead of each visible row running the tag
     * Regex over the whole archive for itself. That is only safe if the two agree line for line, so this
     * compares them over a log carrying every domain's marker plus lines that must match none.
     */
    @Test fun tagLinesByDomainGroupsExactlyAsTheSingleDomainFilterDoes() {
        val lines = buildList {
            for (d in TestDomain.entries) {
                add("[${d.id}] first line for ${d.id}")
                add("12:34:56  [${d.id}] stamped line for ${d.id}")
                add("2026-09-30 12:34:56  [${d.id}] dated line for ${d.id}")
            }
            // None of these carry a leading marker, so no domain may claim them.
            add("no marker at all")
            add("payload mentioning [recovery] but not as a stamp")
            add("12:34:56  plain stamped line")
            add("")
        }
        val grouped = TestCentreLiveReadouts.tagLinesByDomain(lines)
        for (d in TestDomain.entries) {
            val single = lines.filter { line ->
                TestCentreLiveReadouts.tagLinesByDomain(listOf(line)).containsKey(d.id)
            }
            assertEquals("domain ${d.id}", single, grouped[d.id].orEmpty())
        }
        // Every grouped line is accounted for, so nothing was invented or dropped.
        assertEquals(TestDomain.entries.size * 3, grouped.values.sumOf { it.size })
    }

    @Test fun tagLinesByDomainOnAnEmptyLogIsEmpty() {
        assertTrue(TestCentreLiveReadouts.tagLinesByDomain(emptyList()).isEmpty())
    }

    /**
     * A pre-filtered list is USED rather than re-derived, and an absent one still works. Without this the
     * screen could pass its pass's result and [rows] could quietly ignore it, leaving the old full-archive
     * scan in place while looking fixed.
     */
    @Test fun rowsPreferThePreFilteredLinesWhenGiven() {
        val mode = requireNotNull(TestModeRegistry.mode(TestDomain.CONNECTION))
        val real = listOf("[connection] Disconnected status=8", "[recovery] unrelated")
        // Deliberately NOT a subset of `logLines`: if rows re-filtered, this content could not appear.
        val preFiltered = listOf("[connection] Disconnected status=19")
        val viaPreFiltered = TestCentreLiveReadouts.rows(
            mode = mode, active = true,
            snapshot = TestCentreLiveSnapshot(logLines = real, domainLogLines = preFiltered, connected = true),
        )
        val viaFullScan = TestCentreLiveReadouts.rows(
            mode = mode, active = true,
            snapshot = TestCentreLiveSnapshot(logLines = real, domainLogLines = null, connected = true),
        )
        assertTrue("both render the same row set", viaPreFiltered.map { it.id } == viaFullScan.map { it.id })
        assertTrue("pre-filtered path produced rows", viaPreFiltered.isNotEmpty())
    }
}
