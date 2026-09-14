package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class WhoopRepositoryTransactionTest {

    @Test
    fun emptyBackfillPassPreservesSeededDetectedHistory() = runBlocking {
        val seededDetected = WorkoutRow(
            deviceId = "my-whoop-noop", startTs = 1_000L, endTs = 2_000L,
            sport = "detected", source = "my-whoop-noop", avgHr = 145,
        )
        val stored = mutableListOf(seededDetected)
        val daoCalls = mutableListOf<String>()
        val dao = workoutBackfillDao(stored, daoCalls)
        val repo = WhoopRepository(dao)

        repo.persistWorkoutBackfills(emptyList())

        assertTrue("an empty analytics pass must perform no workout write", daoCalls.isEmpty())
        assertEquals(listOf(seededDetected), stored)
    }

    @Test
    fun backfillUpsertsRealRowWithoutTouchingSeededDetectedHistory() = runBlocking {
        val seededDetected = WorkoutRow(
            deviceId = "my-whoop-noop", startTs = 1_000L, endTs = 2_000L,
            sport = "detected", source = "my-whoop-noop", avgHr = 145,
        )
        val originalManual = WorkoutRow(
            deviceId = "my-whoop", startTs = 1_100L, endTs = 1_900L,
            sport = "Cycling", source = "manual",
        )
        val enrichedManual = originalManual.copy(avgHr = 150, maxHr = 170, energyKcal = 80.0, strain = 9.5)
        val stored = mutableListOf(seededDetected, originalManual)
        val daoCalls = mutableListOf<String>()
        val repo = WhoopRepository(workoutBackfillDao(stored, daoCalls))

        repo.persistWorkoutBackfills(listOf(enrichedManual))

        assertEquals(listOf("upsertWorkouts"), daoCalls)
        assertEquals(seededDetected, stored.single { it.source.endsWith("-noop") })
        assertEquals(enrichedManual, stored.single { it.source == "manual" })
    }

    private fun workoutBackfillDao(
        stored: MutableList<WorkoutRow>,
        calls: MutableList<String>,
    ): WhoopDao = Proxy.newProxyInstance(
        WhoopDao::class.java.classLoader,
        arrayOf(WhoopDao::class.java),
    ) { _, method, args ->
        when (method.name) {
            "upsertWorkouts" -> {
                calls += method.name
                @Suppress("UNCHECKED_CAST")
                val rows = args?.firstOrNull() as? List<WorkoutRow> ?: emptyList()
                for (row in rows) {
                    stored.removeAll {
                        it.deviceId == row.deviceId && it.startTs == row.startTs && it.sport == row.sport
                    }
                    stored += row
                }
                Unit
            }
            else -> throw AssertionError("unexpected DAO call ${method.name}")
        }
    } as WhoopDao

    @Test
    fun mixedStreamBatchUsesOneTransactionForEveryDaoWrite() = runBlocking {
        var transactionCalls = 0
        var inTransaction = false
        val daoCalls = mutableListOf<String>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            assertTrue("${method.name} must run inside the batch transaction", inTransaction)
            daoCalls += method.name
            listOf(1L)
        } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                transactionCalls += 1
                assertFalse("transactions must not nest", inTransaction)
                inTransaction = true
                return try {
                    block()
                } finally {
                    inTransaction = false
                }
            }
        }

        val counts = WhoopRepository(dao, transactor).insert(
            streams = StreamBatch(
                hr = listOf(HrRow(ts = 100L, bpm = 60)),
                rr = listOf(RrRow(ts = 100L, rrMs = 1_000)),
                events = listOf(EventEntry(ts = 100L, kind = "test", payloadJSON = "{}")),
            ),
            deviceId = "my-whoop",
        )

        assertEquals(1, transactionCalls)
        assertEquals(listOf("insertHr", "insertRr", "insertEvents"), daoCalls)
        assertEquals(1, counts.hr)
        assertEquals(1, counts.rr)
        assertEquals(1, counts.events)
        assertFalse(inTransaction)
    }

    @Test
    fun emptyBatchSkipsTransactionAndDao() = runBlocking {
        var transactionCalls = 0
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw AssertionError("empty batch must not call ${method.name}")
        } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                transactionCalls += 1
                return block()
            }
        }

        assertEquals(InsertCounts(), WhoopRepository(dao, transactor).insert(StreamBatch(), "my-whoop"))
        assertEquals(0, transactionCalls)
    }
}
