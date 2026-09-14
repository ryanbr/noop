package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class SleepSessionUpsertPolicyTest {
    private val deviceId = "whoop-test"
    private val start = 1_000L
    private val end = 2_000L

    private fun stages(from: Long, to: Long) =
        """[{"start":$from,"end":$to,"stage":"deep"}]"""

    private fun session(
        endTs: Long = end,
        stagesJSON: String? = stages(start, endTs),
        userEdited: Boolean = false,
        startTsAdjusted: Long? = null,
        efficiency: Double? = 0.8,
        restingHr: Int? = 55,
        avgHrv: Double? = 60.0,
        motionJSON: String? = "[0.1]",
        sleepStateJSON: String? = "[2]",
        stagingSparse: Boolean? = false,
    ) = SleepSession(
        deviceId = deviceId,
        startTs = start,
        endTs = endTs,
        efficiency = efficiency,
        restingHr = restingHr,
        avgHrv = avgHrv,
        stagesJSON = stagesJSON,
        userEdited = userEdited,
        startTsAdjusted = startTsAdjusted,
        motionJSON = motionJSON,
        sleepStateJSON = sleepStateJSON,
        stagingSparse = stagingSparse,
    )

    @Test
    fun poorerUneditedCandidateIsDroppedWhole() {
        val existing = session()
        val partial = session(
            endTs = 3_000L,
            stagesJSON = stages(start, start + 100L),
            efficiency = 0.1,
            restingHr = 99,
            avgHrv = 1.0,
        )

        assertEquals(2, SleepSessionUpsertPolicy.richness(existing))
        assertEquals(1, SleepSessionUpsertPolicy.richness(partial))
        assertNull(SleepSessionUpsertPolicy.merge(existing, partial))
    }

    @Test
    fun equallyRichRefreshReplacesDerivedFieldsButKeepsTargetedArrays() {
        val existing = session(motionJSON = "[0.2]", sleepStateJSON = "[3]")
        val candidate = session(
            efficiency = 0.91,
            restingHr = 48,
            avgHrv = 82.0,
            motionJSON = null,
            sleepStateJSON = null,
            stagingSparse = true,
        )

        val merged = SleepSessionUpsertPolicy.merge(existing, candidate)!!

        assertEquals(0.91, merged.efficiency!!, 0.0)
        assertEquals(48, merged.restingHr)
        assertEquals(82.0, merged.avgHrv!!, 0.0)
        assertEquals(true, merged.stagingSparse)
        assertEquals("[0.2]", merged.motionJSON)
        assertEquals("[3]", merged.sleepStateJSON)
    }

    @Test
    fun refreshPreservesUserEditedBoundsStagesAndFlag() {
        val editedStages = stages(900L, end)
        val existing = session(
            endTs = end + 200L,
            stagesJSON = editedStages,
            userEdited = true,
            startTsAdjusted = 900L,
            efficiency = 0.75,
        )
        val refresh = session(
            endTs = end + 500L,
            stagesJSON = null,
            efficiency = 0.88,
            restingHr = 50,
            avgHrv = 72.0,
            stagingSparse = true,
        )

        val merged = SleepSessionUpsertPolicy.merge(existing, refresh)!!

        assertEquals(existing.endTs, merged.endTs)
        assertEquals(editedStages, merged.stagesJSON)
        assertEquals(900L, merged.startTsAdjusted)
        assertTrue(merged.userEdited)
        assertEquals(0.88, merged.efficiency!!, 0.0)
        assertEquals(50, merged.restingHr)
        assertEquals(72.0, merged.avgHrv!!, 0.0)
        assertEquals(true, merged.stagingSparse)
    }

    @Test
    fun repositoryReadsAndWritesTheBatchInsideOneTransaction() = runBlocking {
        val stored = linkedMapOf<Pair<String, Long>, SleepSession>()
        val calls = mutableListOf<String>()
        var transactionCalls = 0
        var inTransaction = false
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            assertTrue("${method.name} must run inside the upsert transaction", inTransaction)
            calls += method.name
            when (method.name) {
                "sleepSession" -> stored[(args[0] as String) to (args[1] as Long)]
                "insertSleepSession" -> {
                    val row = args[0] as SleepSession
                    stored[row.deviceId to row.startTs] = row
                    1L
                }
                "updateSleepSession" -> {
                    val row = args[0] as SleepSession
                    stored[row.deviceId to row.startTs] = row
                    1
                }
                else -> error("Unexpected DAO call: ${method.name}")
            }
        } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                transactionCalls++
                assertFalse(inTransaction)
                inTransaction = true
                return try {
                    block()
                } finally {
                    inTransaction = false
                }
            }
        }
        val complete = session()
        val poorer = session(endTs = 3_000L, stagesJSON = stages(start, start + 100L))
        val refresh = session(efficiency = 0.9, restingHr = 51, motionJSON = null, sleepStateJSON = null)

        WhoopRepository(dao, transactor).upsertSleepSessions(listOf(complete, poorer, refresh))

        assertEquals(1, transactionCalls)
        assertEquals(
            listOf("sleepSession", "insertSleepSession", "sleepSession", "sleepSession", "updateSleepSession"),
            calls,
        )
        assertEquals(0.9, stored.getValue(deviceId to start).efficiency!!, 0.0)
        assertEquals(51, stored.getValue(deviceId to start).restingHr)
        assertEquals("[0.1]", stored.getValue(deviceId to start).motionJSON)
        assertEquals("[2]", stored.getValue(deviceId to start).sleepStateJSON)
        assertFalse(inTransaction)
    }

    @Test
    fun emptyBatchDoesNotOpenATransaction() = runBlocking {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ -> error("Empty batch must not call ${method.name}") } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R =
                error("Empty batch must not open a transaction")
        }

        WhoopRepository(dao, transactor).upsertSleepSessions(emptyList())
    }
}
