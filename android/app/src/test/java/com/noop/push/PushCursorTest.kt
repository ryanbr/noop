package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Test

class PushCursorTest {
    /**
     * Pinned for the same reason as `PushCoordinatorTest`: `PushCoordinator` defaults to
     * `LocalDate.now()`, so an omitted clock makes a test depend on the date it runs. These cases
     * exercise cursor-based append tables rather than the day window, so they were not the ones that
     * broke on 2026-09-01 — but they are the same latent shape, and pinning costs nothing.
     */
    private val pinnedToday = { LocalDate.of(2026, 8, 18) }

    @Test
    fun olderTimestampWithHigherRowidIsNotStranded() = runBlocking {
        val old = hr(10, 200)
        val lateBackfill = hr(11, 100)
        val source = FakePushSource(append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(old, lateBackfill)))
        val progress = MemoryProgress().apply {
            cursors[key(PushAppendTable.HR_SAMPLE, "a")] = PushCursor(
                10,
                PushProtocol.keyFingerprint(PushAppendTable.HR_SAMPLE, "a", old.key),
            )
        }
        val transport = AckingTransport()
        val coordinator = PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))

        val result = coordinator.pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(result is PushResult.Accepted)
        assertTrue(transport.bodies.single().toString(Charsets.UTF_8).contains("\"ts\":100"))
        assertEquals(
            PushCursor(11, PushProtocol.keyFingerprint(PushAppendTable.HR_SAMPLE, "a", lateBackfill.key)),
            progress.cursors[key(PushAppendTable.HR_SAMPLE, "a")],
        )
    }

    @Test
    fun fullNaturalKeyMismatchResetsEffectiveCursorBeforeReading() = runBlocking {
        val first = hr(3, 50)
        val currentAtCursor = hr(10, 200)
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(first, currentAtCursor)),
        )
        val progress = MemoryProgress().apply {
            cursors[key(PushAppendTable.HR_SAMPLE, "a")] = PushCursor(10, "f".repeat(64))
        }
        val transport = AckingTransport()

        PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC")).pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertEquals(0L, source.afterCursors.single())
        assertTrue(transport.bodies.single().toString(Charsets.UTF_8).contains("\"ts\":50"))
    }

    @Test
    fun rrRowsSharingTimestampRemainDistinctByFullPrimaryKey() {
        val a = PushAppendRecord(
            1,
            linkedMapOf("ts" to 100L, "rrMs" to 900, "seq" to 0),
            linkedMapOf("ord" to null, "srcChannel" to null, "tsSuspect" to null),
        )
        val b = PushAppendRecord(
            2,
            linkedMapOf("ts" to 100L, "rrMs" to 900, "seq" to 1),
            linkedMapOf("ord" to null, "srcChannel" to null, "tsSuspect" to null),
        )

        assertNotEquals(
            PushProtocol.keyFingerprint(PushAppendTable.RR_INTERVAL, "a", a.key),
            PushProtocol.keyFingerprint(PushAppendTable.RR_INTERVAL, "a", b.key),
        )
        assertEquals(
            "3e8a1018cb24f2dcabd66750250c479fe981222da25785cfc78a20d84f1217bb",
            PushProtocol.keyFingerprint(PushAppendTable.RR_INTERVAL, "a", a.key),
        )
        assertEquals(
            2,
            PushProtocol.appendBatch(PushAppendTable.RR_INTERVAL, SOURCE_A, "a", null, listOf(a, b)).recordCount,
        )
    }

    @Test
    fun moreThanOnePageOfEqualTimestampRrRowsLosesNothing() = runBlocking {
        val rows = (0..5_000).map { seq ->
            PushAppendRecord(
                rowId = seq + 1L,
                key = linkedMapOf("ts" to 100L, "rrMs" to 900, "seq" to seq),
                data = linkedMapOf("ord" to seq, "srcChannel" to null, "tsSuspect" to null),
            )
        }.toMutableList()
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.RR_INTERVAL, "a") to rows),
        )
        val progress = MemoryProgress()
        val transport = AckingTransport()
        val coordinator = PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))

        val first = coordinator.pushAppend(PushAppendTable.RR_INTERVAL, "a")
        val second = coordinator.pushAppend(PushAppendTable.RR_INTERVAL, "a")

        assertTrue(first is PushResult.Accepted && first.recordCount == 5_000 && first.hasMore)
        assertTrue(second is PushResult.Accepted && second.recordCount == 1 && !second.hasMore)
        assertEquals(listOf(5_000, 1), transport.batches.map { it.recordCount })
        assertEquals(5_001L, progress.cursors[key(PushAppendTable.RR_INTERVAL, "a")]?.rowId)
    }

    @Test
    fun cursorProgressIsIsolatedPerDevice() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(
                key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 10)),
                key(PushAppendTable.HR_SAMPLE, "b") to mutableListOf(hr(1, 20)),
            ),
        )
        val progress = MemoryProgress()
        val coordinator = PushCoordinator(source, AckingTransport(), progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))

        coordinator.pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(progress.cursors.containsKey(key(PushAppendTable.HR_SAMPLE, "a")))
        assertTrue(!progress.cursors.containsKey(key(PushAppendTable.HR_SAMPLE, "b")))
    }
}
