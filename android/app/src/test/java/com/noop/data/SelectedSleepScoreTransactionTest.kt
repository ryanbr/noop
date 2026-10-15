package com.noop.data

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SelectedSleepScoreTransactionTest {
    private val source = "my-whoop-noop"
    private val day = "2021-06-15"
    private fun sleep(start: Long = 1_623_711_600, end: Long = start + 25_200,
                      device: String = source, edited: Boolean = false) =
        SleepSession(device, start, end, 0.9, 50, 60.0,
            """[{"start":$start,"end":$end,"stage":"deep"}]""", userEdited = edited)

    /** DAO queries are in-memory test storage; the transaction and DAO default method are production code. */
    private class Fixture {
        val sleeps = linkedMapOf<Pair<String, Long>, SleepSession>()
        val days = linkedMapOf<Pair<String, String>, DailyMetric>()
        val provenance = linkedMapOf<Triple<String, String, String>, ScoreInputProvenanceRow>()
        val metrics = linkedMapOf<Triple<String, String, String>, MetricSeriesRow>()
        var failDailyWrite = false
        var failDependentWrite = false
        var failSleepDetails = false
        var legacyRrWithheld = false
        var transactions = 0
        var rawHr: List<HrSample> = emptyList()
        var rawGravity: List<GravitySample> = emptyList()
        val rawReads = mutableListOf<Pair<Long, Long>>()
        private var depth = 0
        val dao = Proxy.newProxyInstance(WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java)) { proxy, method, arguments ->
            val args = arguments ?: emptyArray()
            if (method.name.startsWith("upsert") || method.name.startsWith("delete") || method.name.startsWith("insert") || method.name.startsWith("update") || method.name == "replaceComputedScoreWindow")
                check(depth > 0) { "Every selected write must share the transaction" }
            when (method.name) {
                "countHrInWindow" -> rawHr.count { it.deviceId == args[0] && it.ts in (args[1] as Long)..(args[2] as Long) }
                "maxHrTsInWindow" -> rawHr.filter { it.deviceId == args[0] && it.ts in (args[1] as Long)..(args[2] as Long) }.maxOfOrNull { it.ts } ?: 0L
                "firstStepTimestamp", "lastStepTimestamp", "stepSampleBefore" -> null
                "hasStepActivityClasses" -> false
                "hrSamples" -> {
                    val from = args[1] as Long; val to = args[2] as Long
                    rawReads.add(from to to)
                    rawHr.filter { it.deviceId == args[0] && it.ts in from..to }.take(args[3] as Int)
                }
                "gravitySamples" -> rawGravity.filter { it.deviceId == args[0] && it.ts in (args[1] as Long)..(args[2] as Long) }.take(args[3] as Int)
                "sleepSessions" -> sleeps.values.filter { it.deviceId == args[0] && it.endTs >= args[1] as Long && it.startTs <= args[2] as Long }
                "dailyMetricsRange" -> days.values.filter { it.deviceId == args[0] && it.day >= args[1] as String && it.day <= args[2] as String }
                "days" -> days.values.filter { it.deviceId == args[0] }
                "scoreInputSource" -> provenance[Triple(args[0] as String, args[1] as String, args[2] as String)]?.sourceId
                "pairedDevice", "activePairedDevice", "activeDeviceId", "latestHrSampleTs", "sessionSleepStateJson", "sessionMotionJson" -> null
                "updateSessionMotion", "updateSessionSleepState" -> {
                    if (failSleepDetails) error("sleep detail failure")
                    val key = args[0] as String to args[1] as Long
                    sleeps[key]?.let { row -> sleeps[key] = if (method.name == "updateSessionMotion") row.copy(motionJSON = args[2] as String?) else row.copy(sleepStateJSON = args[2] as String?) }; 1
                }
                "deleteSleepSession" -> { sleeps.remove(args[0] as String to args[1] as Long); Unit }
                "hasHrInWindow" -> rawHr.any { it.deviceId == args[0] && it.ts in (args[1] as Long)..(args[2] as Long) }
                "hasWhoop5RrSource", "legacyWhoop5RrWithheld" -> legacyRrWithheld
                "hasWhoop4HistoricalRrSource" -> false
                "dayStreamFingerprint", "hrFingerprintWindow" -> "fixture"
                "pairedDevices", "dayOwnerships", "appleDaily", "rrIntervals", "rawRrIntervals", "whoop5RrIntervals", "whoop4RrIntervals", "respSamples", "stepSamples", "skinTempSamples", "spo2Samples", "events", "sleepStateSamples", "v18AuxSamples", "workouts", "dismissedSleeps", "editedSleepSessions", "metricSeries", "detectedWorkouts", "stepSamplesPage" -> emptyList<Any>()
                "sleepSession" -> sleeps[args[0] as String to args[1] as Long]
                "insertSleepSession", "updateSleepSession" -> {
                    val row = args[0] as SleepSession
                    sleeps[row.deviceId to row.startTs] = row
                    if (method.name == "insertSleepSession") 1L else 1
                }
                "replaceComputedScoreWindow" -> {
                    val implementation = Class.forName("com.noop.data.WhoopDao\$DefaultImpls")
                        .methods.single { it.name == method.name }
                    try { implementation.invoke(null, proxy, *args) }
                    catch (error: InvocationTargetException) { throw error.cause!! }
                }
                "deleteDailyMetricsInRange" -> {
                    days.keys.removeAll { it.first == args[0] && it.second >= args[1] as String && it.second <= args[2] as String }; Unit
                }
                "deleteScoreInputProvenanceInRange" -> {
                    provenance.keys.removeAll { it.first == args[0] && it.second >= args[1] as String && it.second <= args[2] as String && it.third != "vo2max_est" }; Unit
                }
                "deleteMetricSeriesKeyInRange" -> {
                    metrics.keys.removeAll { it.first == args[0] && it.third == args[1] && it.second >= args[2] as String && it.second <= args[3] as String }; Unit
                }
                "upsertMetricSeries" -> {
                    @Suppress("UNCHECKED_CAST") val rows = args[0] as List<MetricSeriesRow>
                    rows.forEach { metrics[Triple(it.deviceId, it.day, it.key)] = it }; Unit
                }
                "upsertDailyMetrics" -> {
                    if (failDailyWrite) error("test write failure")
                    @Suppress("UNCHECKED_CAST") val rows = args[0] as List<DailyMetric>
                    rows.forEach { days[it.deviceId to it.day] = it }; Unit
                }

                "updateSleepDependentRecovery" -> {
                    if (failDependentWrite) error("dependent failure")
                    val key = args[0] as String to args[1] as String
                    days[key]?.let { days[key] = it.copy(recovery = args[2] as Double?, skinTempDevC = args[3] as Double?) }; Unit
                }
                "deleteRecoveryProvenance" -> { provenance.remove(Triple(args[0] as String, args[1] as String, "recovery")); Unit }
                "upsertScoreInputProvenance" -> {
                    @Suppress("UNCHECKED_CAST") val rows = args[0] as List<ScoreInputProvenanceRow>
                    rows.forEach { provenance[Triple(it.deviceId, it.day, it.key)] = it }; Unit
                }
                else -> error("Unexpected DAO call: ${method.name}")
            }
        } as WhoopDao
        val repo = WhoopRepository(dao, object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                check(depth == 0)
                transactions++
                val beforeSleep = sleeps.toMap(); val beforeDays = days.toMap(); val beforeProvenance = provenance.toMap(); val beforeMetrics = metrics.toMap()
                depth++
                try { return block() }
                catch (error: Throwable) {
                    sleeps.clear(); sleeps.putAll(beforeSleep)
                    days.clear(); days.putAll(beforeDays)
                    provenance.clear(); provenance.putAll(beforeProvenance)
                    metrics.clear(); metrics.putAll(beforeMetrics)
                    throw error
                } finally { depth-- }
            }
        })
    }

    private suspend fun commit(f: Fixture, sleeps: List<SleepSession>, recovery: Double = 70.0) {
        f.repo.replaceComputedScoreWindow(source, day, day,
            listOf(DailyMetric(source, day, totalSleepMin = 420.0, recovery = recovery)), emptyList(),
            listOf(ScoreInputProvenanceRow(source, day, "recovery", "active-strap")), sleepSessions = sleeps)
    }

    @Test fun missingOldNightAndScoresBankTogetherWithoutChangingOtherRows() = runBlocking {
        val f = Fixture(); val selected = sleep()
        val other = listOf(sleep(start = selected.startTs - 86400), sleep(start = selected.endTs + 3600, edited = true), sleep(device = "my-whoop"))
        other.forEach { f.sleeps[it.deviceId to it.startTs] = it }
        commit(f, listOf(selected))
        assertEquals(1, f.transactions)
        other.forEach { assertEquals(it, f.sleeps[it.deviceId to it.startTs]) }
        assertEquals(selected, f.sleeps[source to selected.startTs])
        assertEquals(420.0, f.days[source to day]!!.totalSleepMin!!, 0.0)
        assertEquals("active-strap", f.provenance[Triple(source, day, "recovery")]!!.sourceId)
    }

    @Test fun incompleteDetectedNightRefreshesAtItsStableKey() = runBlocking {
        val f = Fixture(); val complete = sleep()
        f.sleeps[source to complete.startTs] = sleep(end = complete.startTs + 5400)
        commit(f, listOf(complete))
        assertEquals(listOf(complete), f.sleeps.values.toList())
    }

    @Test fun dailyWriteFailureRollsBackSleepAndScores() = runBlocking {
        val f = Fixture(); commit(f, emptyList(), 10.0)
        val old = f.days.toMap(); val oldProvenance = f.provenance.toMap(); f.failDailyWrite = true
        try { commit(f, listOf(sleep())); fail("write must fail") } catch (_: IllegalStateException) { }
        assertTrue(f.sleeps.isEmpty())
        assertEquals(old, f.days)
        assertEquals(oldProvenance, f.provenance)
    }

    @Test fun cancellationBeforeWriteBanksNothing() = runBlocking {
        val f = Fixture(); val gate = CompletableDeferred<Unit>(); val started = CompletableDeferred<Unit>()
        val task = async {
            started.complete(Unit)
            try { gate.await() } catch (_: CancellationException) { }
            commit(f, listOf(sleep()))
        }
        started.await(); task.cancel(); gate.complete(Unit)
        try { task.await(); fail("cancellation must propagate") } catch (_: CancellationException) { }
        assertEquals(1, f.transactions)
        assertTrue(f.sleeps.isEmpty()); assertTrue(f.days.isEmpty())
    }
    @Test fun dependentUpdatePreservesOtherFieldsAndRollsBackWithSelectedNight() = runBlocking {
        val f = Fixture(); val next = "2021-06-16"
        val neighbor = DailyMetric(source, next, totalSleepMin = 360.0, strain = 8.0, recovery = 10.0)
        f.days[source to next] = neighbor
        suspend fun update(recovery: Double, end: Long = sleep().endTs) {
            f.repo.replaceComputedScoreWindow(source, day, day,
                listOf(DailyMetric(source, day, totalSleepMin = 420.0, recovery = recovery)), emptyList(), emptyList(),
                sleepSessions = listOf(sleep(end = end)),
                dependentRecoveryUpdates = listOf(SleepRecoveryUpdate(next, 60.0, 0.2, "active-strap")))
        }
        update(70.0)
        assertEquals(neighbor.totalSleepMin, f.days[source to next]!!.totalSleepMin)
        assertEquals(neighbor.strain, f.days[source to next]!!.strain)
        assertEquals("active-strap", f.provenance[Triple(source, next, "recovery")]!!.sourceId)
        val beforeSleep = f.sleeps.toMap(); val beforeDays = f.days.toMap(); val beforeSources = f.provenance.toMap()
        f.failDependentWrite = true
        try { update(90.0, sleep().endTs + 3600); fail("must fail") } catch (_: IllegalStateException) { }
        assertEquals(beforeSleep, f.sleeps); assertEquals(beforeDays, f.days); assertEquals(beforeSources, f.provenance)
    }

    private suspend fun scan(f: Fixture, window: com.noop.analytics.SleepRecalculationWindow = com.noop.analytics.SleepRecalculationWindow.make(day, java.time.ZoneId.of("UTC"), 1_800_000_000)!!): List<com.noop.analytics.IntelligenceEngine.Computed> {
        return com.noop.analytics.IntelligenceEngine.analyzeRecent(f.repo, maxDays = 1,
            nowSeconds = window.end - 1, selectedNight = window, useExperimentalSleepV2 = true)
    }

    private fun rawNight(f: Fixture, window: com.noop.analytics.SleepRecalculationWindow = com.noop.analytics.SleepRecalculationWindow.make(day, java.time.ZoneId.of("UTC"), 1_800_000_000)!!) {
        val from = window.start - 3600; val to = window.start + 6 * 3600
        f.rawHr = (from until to).map { HrSample("my-whoop", it, 50) }
        f.rawGravity = (from until to).map { GravitySample("my-whoop", it, 0.0, 0.0, 1.0) }
    }

    @Test fun realEngineRecoversOldMissingNightAndRefreshesIncompleteNight() = runBlocking {
        val f = Fixture(); rawNight(f)
        val otherDay = DailyMetric(source, "2021-06-14", totalSleepMin = 360.0, recovery = 20.0)
        f.days[source to otherDay.day] = otherDay
        val result = scan(f).single()
        assertEquals(day, result.day); assertTrue(result.sleepMin!! > 120)
        assertTrue(f.rawReads.any { it.first < 1_623_715_200 && it.second > 1_623_715_200 })
        val saved = f.sleeps.values.single { it.deviceId == source }
        f.sleeps[source to saved.startTs] = saved.copy(endTs = saved.startTs + 5400)
        scan(f)
        assertEquals(saved.endTs, f.sleeps[source to saved.startTs]!!.endTs)
        assertEquals(otherDay, f.days[source to otherDay.day])
    }

    @Test fun realEngineNoDataPreservesPreviouslySavedNightAndTotals() = runBlocking {
        val f = Fixture(); val old = sleep()
        f.sleeps[source to old.startTs] = old
        val daily = DailyMetric(source, day, totalSleepMin = 420.0, recovery = 30.0)
        f.days[source to day] = daily
        assertTrue(scan(f).isEmpty())
        assertEquals(old, f.sleeps[source to old.startTs]); assertEquals(daily, f.days[source to day])
    }

    @Test fun realEnginePreservesManualWindowAndReportsPersistenceFailure() = runBlocking {
        val f = Fixture(); rawNight(f)
        val window = com.noop.analytics.SleepRecalculationWindow.make(day, java.time.ZoneId.of("UTC"), 1_800_000_000)!!
        val bed = window.start + 3600; val wake = bed + 7200
        val manual = sleep(start = window.start - 3630, end = wake, edited = true).copy(
            startTsAdjusted = bed, stagesJSON = "[{\"start\":$bed,\"end\":$wake,\"stage\":\"deep\"}]")
        f.sleeps[source to manual.startTs] = manual
        assertEquals(120.0, scan(f).single().sleepMin!!, 0.0)
        assertEquals(listOf(manual), f.sleeps.values.toList())
        val other = Fixture(); rawNight(other); other.failDailyWrite = true
        try { scan(other); fail("failed selected persistence must propagate") } catch (_: IllegalStateException) { }
        assertTrue(other.sleeps.isEmpty()); assertTrue(other.days.isEmpty())
    }

    @Test fun realEngineNoDetectionPreservesExistingNightAndTotals() = runBlocking {
        val f = Fixture(); rawNight(f)
        f.rawGravity = f.rawGravity.mapIndexed { index, row -> row.copy(x = if (index % 2 == 0) 1.0 else -1.0) }
        val old = sleep(); val daily = DailyMetric(source, day, totalSleepMin = 420.0, recovery = 30.0)
        f.sleeps[source to old.startTs] = old; f.days[source to day] = daily
        assertEquals(0.0, scan(f).single().sleepMin ?: 0.0, 0.0)
        assertEquals(old, f.sleeps[source to old.startTs]); assertEquals(daily, f.days[source to day])
    }

    @Test fun selectedDetailsAndShiftedDuplicateCleanupShareTheAtomicCommit() = runBlocking {
        val f = Fixture(); val fresh = sleep(); val old = sleep(start = fresh.startTs - 60, end = fresh.endTs - 3600)
        f.sleeps[source to old.startTs] = old
        val neighbor = sleep(start = fresh.startTs - 86400, end = fresh.endTs - 86400)
        f.sleeps[source to neighbor.startTs] = neighbor
        suspend fun write() = f.repo.replaceComputedScoreWindow(source, day, day,
            listOf(DailyMetric(source, day, totalSleepMin = 420.0)), emptyList(), emptyList(), sleepSessions = listOf(fresh),
            sleepMotion = mapOf(fresh.startTs to listOf(0.1, 0.2)), sleepStates = mapOf(fresh.startTs to listOf(1, 2)),
            selectedSleepBounds = 1_623_715_200L until 1_623_801_600L)
        f.failSleepDetails = true
        try { write(); fail("details must fail") } catch (_: IllegalStateException) { }
        assertEquals(old, f.sleeps[source to old.startTs]); assertTrue(f.days.isEmpty())
        assertFalse(f.sleeps.containsKey(source to fresh.startTs))
        f.failSleepDetails = false; write()
        assertFalse(f.sleeps.containsKey(source to old.startTs))
        assertEquals(neighbor, f.sleeps[source to neighbor.startTs])
        assertEquals("[0.1,0.2]", f.sleeps[source to fresh.startTs]!!.motionJSON)
        assertEquals("[1,2]", f.sleeps[source to fresh.startTs]!!.sleepStateJSON)
    }

    @Test fun realEngineRetainsLegacyRrScoreAndItsActualSource() = runBlocking {
        val nowSeconds = System.currentTimeMillis() / 1000L
        val selectedDay = java.time.Instant.ofEpochSecond(nowSeconds).atZone(java.time.ZoneOffset.UTC).toLocalDate().minusDays(1).toString()
        val window = com.noop.analytics.SleepRecalculationWindow.make(selectedDay, java.time.ZoneId.of("UTC"), nowSeconds)!!
        val f = Fixture(); rawNight(f, window); f.legacyRrWithheld = true
        f.days[source to selectedDay] = DailyMetric(source, selectedDay, totalSleepMin = 420.0,
            avgHrv = 60.0, restingHr = 50, recovery = 44.0)
        f.provenance[Triple(source, selectedDay, "recovery")] = ScoreInputProvenanceRow(source, selectedDay, "recovery", "old-rr-source")
        scan(f, window)
        assertEquals(44.0, f.days[source to selectedDay]!!.recovery!!, 0.0)
        assertEquals(60.0, f.days[source to selectedDay]!!.avgHrv!!, 0.0)
        assertEquals("old-rr-source", f.provenance[Triple(source, selectedDay, "recovery")]!!.sourceId)
    }

    @Test fun selectedWriteDoesNotBankNeighboringContextMarkersOrSourceTags() = runBlocking {
        val f = Fixture(); val prior = "2021-06-14"
        val key = com.noop.analytics.DayCycleIntelligenceIntegration.ONSET_KEY
        val neighbor = MetricSeriesRow(source, prior, key, 123.0)
        f.metrics[Triple(source, prior, key)] = neighbor
        val tag = ScoreInputProvenanceRow(source, prior, key, "prior-source")
        f.provenance[Triple(source, prior, key)] = tag
        val selected = MetricSeriesRow(source, day, key, 456.0)
        f.repo.replaceComputedScoreWindow(source, day, day,
            listOf(DailyMetric(source, day, totalSleepMin = 420.0)), listOf(neighbor.copy(value = 999.0), selected),
            listOf(tag.copy(sourceId = "wrong-source")), replaceMetricKeys = listOf(key), sleepSessions = emptyList(),
            selectedSleepBounds = 1_623_715_200L until 1_623_801_600L)
        assertEquals(neighbor, f.metrics[Triple(source, prior, key)])
        assertEquals(tag, f.provenance[Triple(source, prior, key)])
        assertEquals(selected, f.metrics[Triple(source, day, key)])
    }

}
