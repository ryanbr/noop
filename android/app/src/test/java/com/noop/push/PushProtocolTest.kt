package com.noop.push

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushProtocolTest {
    @Test fun acknowledgementIgnoresUnknownOptionalMembersWithinTheNegotiatedMajor() {
        val batch = PushProtocol.appendBatch(
            PushAppendTable.HR_SAMPLE,
            SOURCE_A,
            "strap",
            null,
            listOf(hr(1, 10)),
        )
        val encoded = PushAck.fromBatch(batch).encode().toString(Charsets.UTF_8)
        val extended = encoded.dropLast(1) + ",\"futureOptional\":true}"

        assertTrue(PushAck.parse(extended.toByteArray()).exactlyMatches(batch))
    }

    @Test
    fun version11AddsOnlyTheExplicitDailySleepScoreProjections() {
        val score = PushMutableRecord(
            linkedMapOf("day" to "2026-08-18"),
            linkedMapOf(
                "totalSleepMin" to null, "efficiency" to null, "deepMin" to null, "remMin" to null,
                "lightMin" to null, "disturbances" to null, "restingHr" to null, "avgHrv" to null,
                "recovery" to null, "strain" to null, "exerciseCount" to null, "spo2Pct" to null,
                "skinTempDevC" to null, "respRateBpm" to null, "steps" to null, "activeKcalEst" to null,
                "spo2Red" to null, "spo2Ir" to null, "sleepPerformance" to 87.5,
                "sleepConsistency" to 82.0,
            ),
        )
        val batch = PushProtocol.mutableBatch(
            PushMutableTable.DAILY_METRIC, SOURCE_A, "strap-noop", testWindow(), listOf(score),
            PushProtocol.LATEST_VERSION,
        )
        val lines = batch.body.toString(Charsets.UTF_8).trimEnd().lines()
        assertEquals("1.1", JSONObject(lines.first()).getString("protocolVersion"))
        assertEquals(87.5, JSONObject(lines[1]).getJSONObject("data").getDouble("sleepPerformance"), 0.0)
        assertEquals(82.0, JSONObject(lines[1]).getJSONObject("data").getDouble("sleepConsistency"), 0.0)
        assertTrue(PushAck.parse(PushAck.fromBatch(batch).encode(), PushProtocol.LATEST_VERSION).exactlyMatches(batch))

        var rejectedByV10 = false
        try {
            PushProtocol.mutableBatch(
                PushMutableTable.DAILY_METRIC, SOURCE_A, "strap-noop", testWindow(), listOf(score),
                PushProtocol.VERSION,
            )
        } catch (_: PushProtocolException) {
            rejectedByV10 = true
        }
        assertTrue("protocol 1.0 must not emit the 1.1 member", rejectedByV10)

        var rejectedOutOfRangeScore = false
        try {
            PushProtocol.mutableBatch(
                PushMutableTable.DAILY_METRIC, SOURCE_A, "strap-noop", testWindow(),
                listOf(score.copy(data = score.data + ("sleepPerformance" to 101.0))),
                PushProtocol.LATEST_VERSION,
            )
        } catch (_: PushProtocolException) {
            rejectedOutOfRangeScore = true
        }
        assertTrue("sleepPerformance must be bounded to 0..100", rejectedOutOfRangeScore)

        var rejectedOutOfRangeConsistency = false
        try {
            PushProtocol.mutableBatch(
                PushMutableTable.DAILY_METRIC, SOURCE_A, "strap-noop", testWindow(),
                listOf(score.copy(data = score.data + ("sleepConsistency" to 101.0))),
                PushProtocol.LATEST_VERSION,
            )
        } catch (_: PushProtocolException) {
            rejectedOutOfRangeConsistency = true
        }
        assertTrue("sleepConsistency must be bounded to 0..100", rejectedOutOfRangeConsistency)
    }

    @Test
    fun appendRegistryIsExactlyTheEightDocumentedStreams() {
        assertEquals(
            listOf(
                "hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample",
                "respSample", "gravitySample",
            ),
            PushAppendTable.entries.map { it.wireName },
        )
    }

    @Test
    fun appendWireShapeIsExactDeterministicAndExcludesScopedAndLocalColumns() {
        val rows = listOf(hrRecord(41, 200, 61), hrRecord(42, 201, 62))

        val first = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE_A, "strap-a", null, rows)
        val retry = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE_A, "strap-a", null, rows)

        assertArrayEquals(first.body, retry.body)
        assertEquals(first.batchId, retry.batchId)
        assertTrue(first.batchId.matches(UUID_PATTERN))
        assertEquals(42L, first.endCursor?.rowId)
        val lines = first.body.toString(Charsets.UTF_8).trimEnd().lines()
        val header = JSONObject(lines[0])
        assertEquals(
            setOf(
                "type", "protocolVersion", "batchId", "sourceId", "deviceId", "stream", "delivery",
                "recordCount", "startCursor", "endCursor",
            ),
            header.keys().asSequence().toSet(),
        )
        assertEquals("batch", header.getString("type"))
        assertEquals("1.0", header.getString("protocolVersion"))
        assertEquals(SOURCE_A, header.getString("sourceId"))
        assertEquals("hrSample", header.getString("stream"))
        assertEquals("append", header.getString("delivery"))
        assertTrue(header.isNull("startCursor"))
        assertTrue(header.getJSONObject("endCursor").getString("keySha256").matches(Regex("[0-9a-f]{64}")))
        val record = JSONObject(lines[1])
        assertEquals(setOf("type", "key", "data"), record.keys().asSequence().toSet())
        assertEquals(setOf("ts"), record.getJSONObject("key").keys().asSequence().toSet())
        assertEquals(setOf("bpm"), record.getJSONObject("data").keys().asSequence().toSet())
        assertFalse(first.body.toString(Charsets.UTF_8).contains("synced"))
    }

    @Test
    fun sourceIdScopesStableBatchIdentity() {
        val rows = listOf(hrRecord(1, 100, 60))

        val a = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE_A, "same-device", null, rows)
        val b = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE_B, "same-device", null, rows)

        assertNotEquals(a.batchId, b.batchId)
        assertNotEquals(a.body.toList(), b.body.toList())
    }

    @Test
    fun appendBatchCapsRowsAtFiveThousand() {
        val rows = (1L..5_001L).map { hrRecord(it, it, 60) }

        val batch = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE_A, "strap-a", null, rows)

        assertEquals(PushProtocol.MAX_RECORDS, batch.recordCount)
        assertEquals(5_000L, batch.endCursor?.rowId)
        assertTrue(batch.body.size <= PushProtocol.MAX_BODY_BYTES)
    }

    @Test
    fun appendBatchStopsBeforeFourMiBDecodedNdjsonLimit() {
        val rows = (1L..5_000L).map { rowId ->
            PushAppendRecord(
                rowId = rowId,
                key = linkedMapOf("ts" to rowId, "kind" to "large"),
                data = linkedMapOf("payloadJSON" to "x".repeat(1_000)),
            )
        }

        val batch = PushProtocol.appendBatch(PushAppendTable.EVENT, SOURCE_A, "strap-a", null, rows)

        assertTrue(batch.recordCount < PushProtocol.MAX_RECORDS)
        assertTrue(batch.body.size <= 4 * 1024 * 1024)
        assertTrue(batch.body.size > 4 * 1024 * 1024 - 2_000)
    }

    @Test(expected = PushProtocolException::class)
    fun aSingleOversizedRecordIsRejectedWithoutAdvancing() {
        val row = PushAppendRecord(
            rowId = 1,
            key = linkedMapOf("ts" to 1L, "kind" to "huge"),
            data = linkedMapOf("payloadJSON" to "x".repeat(PushProtocol.MAX_BODY_BYTES)),
        )

        PushProtocol.appendBatch(PushAppendTable.EVENT, SOURCE_A, "strap-a", null, listOf(row))
    }

    @Test
    fun mutableEmptySnapshotIsAuthoritativeAndUsesDocumentedWindow() {
        val window = testWindow()

        val batch = PushProtocol.mutableBatch(PushMutableTable.JOURNAL, SOURCE_A, "device-a", window, emptyList())

        assertEquals(0, batch.recordCount)
        assertNull(batch.endCursor)
        val header = JSONObject(batch.body.toString(Charsets.UTF_8).trim())
        assertEquals("replace_window", header.getString("delivery"))
        val wireWindow = header.getJSONObject("window")
        assertEquals("day", wireWindow.getString("selector"))
        assertEquals("2026-08-05", wireWindow.getString("startInclusive"))
        assertEquals("2026-08-19", wireWindow.getString("endExclusive"))
        assertEquals(1, wireWindow.getInt("part"))
        assertEquals(1, wireWindow.getInt("parts"))
    }

    @Test
    fun mutableSnapshotIsDeterministicallySplitIntoBoundedParts() {
        val records = (1..5_001).map { index ->
            PushMutableRecord(
                linkedMapOf("day" to "2026-08-${(index % 14 + 5).toString().padStart(2, '0')}", "question" to "q$index"),
                linkedMapOf("answeredYes" to true, "notes" to null, "numericValue" to null),
            )
        }.sortedWith(compareBy({ it.key["day"] as String }, { it.key["question"] as String }))

        val first = PushProtocol.mutableBatches(PushMutableTable.JOURNAL, SOURCE_A, "device-a", testWindow(), records)
        val retry = PushProtocol.mutableBatches(PushMutableTable.JOURNAL, SOURCE_A, "device-a", testWindow(), records)

        assertEquals(2, first.size)
        assertTrue(first.all { it.recordCount <= PushProtocol.MAX_RECORDS && it.body.size <= PushProtocol.MAX_BODY_BYTES })
        assertEquals(first.map { it.batchId }, retry.map { it.batchId })
        assertEquals(1, first[0].part)
        assertEquals(2, first[1].part)
        assertEquals(first[0].replacementId, first[1].replacementId)
    }

    @Test
    fun mutableDayHashIsCanonicalAndDistinguishesChangesFromEmpty() {
        val first = journalRecord("2026-08-18", "coffee", "one")
        val same = journalRecord("2026-08-18", "coffee", "one")
        val changed = journalRecord("2026-08-18", "coffee", "two")

        assertEquals(
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(first)),
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(same)),
        )
        assertNotEquals(
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(first)),
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(changed)),
        )
        assertNotEquals(
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(first)),
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, emptyList()),
        )
        assertNotEquals(
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(first), PushProtocol.VERSION),
            PushProtocol.mutableSnapshotHash(PushMutableTable.JOURNAL, listOf(first), PushProtocol.LATEST_VERSION),
        )
    }

    private fun testWindow() = PushWindow("2026-08-05", "2026-08-18", 1_754_348_400L, 1_755_558_000L)
}

internal const val SOURCE_A = "3a3486dd-5030-4e17-a00d-a781399890f9"
internal const val SOURCE_B = "4b4597ee-6141-4f28-b11e-b8924a9a9010"
private val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

internal fun hrRecord(rowId: Long, ts: Long, bpm: Int = 60) = PushAppendRecord(
    rowId,
    linkedMapOf("ts" to ts),
    linkedMapOf("bpm" to bpm),
)

private fun journalRecord(day: String, question: String, notes: String?) = PushMutableRecord(
    linkedMapOf("day" to day, "question" to question),
    linkedMapOf("answeredYes" to true, "notes" to notes, "numericValue" to null),
)
