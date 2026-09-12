package com.noop.data

import com.noop.protocol.Whoop5RR
import com.noop.protocol.RrSourceChannel
import com.noop.ingest.RawSensorExport
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.DayCycleMode
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.RegistryDayOwnerSource
import com.noop.analytics.SleepStageHealer
import com.noop.analytics.StageSegment
import java.io.StringWriter
import java.lang.reflect.Proxy
import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*

/** Runs the production repository and shared Room query text against SQLite, without Android mocks
 *  deciding source policy. The adapter implements only Room's row mapping and INSERT OR IGNORE IDs;
 *  schema-oracle/KSP tests independently validate the generated Room schema and query signatures. */
class Whoop5RRSqliteTest {
    private lateinit var db: Connection
    private lateinit var repo: WhoopRepository
    private lateinit var dao: WhoopDao
    private val owners = linkedMapOf<String, PairedDeviceRow>()
    private val sleeps = linkedMapOf<Pair<String, Long>, SleepSession>()
    private val days = linkedMapOf<Pair<String, String>, DailyMetric>()
    private val provenance = linkedMapOf<Triple<String, String, String>, ScoreInputProvenanceRow>()
    private val gravity = mutableListOf<GravitySample>()
    private val id = "my-whoop"

    @Before fun open() {
        db = DriverManager.getConnection("jdbc:sqlite::memory:")
        sql("CREATE TABLE rrInterval(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL, " +
            "seq INTEGER NOT NULL, synced INTEGER NOT NULL, ord INTEGER, srcChannel INTEGER, tsSuspect INTEGER, " +
            "PRIMARY KEY(deviceId, ts, rrMs, seq))")
        sql(WhoopDatabase.RR_SOURCE_INDEX_SQL)
        sql("CREATE TABLE pairedDevice(id TEXT PRIMARY KEY, brand TEXT, model TEXT, status TEXT)")
        sql("CREATE TABLE hrSample(deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts))")
        listOf("ppgHrSample", "respSample", "gravitySample", "sleepStateSample", "event",
            "spo2Sample", "skinTempSample", "stepSample").forEach {
            sql("CREATE TABLE $it(deviceId TEXT, ts INTEGER)")
        }
        dao = Proxy.newProxyInstance(WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java)) { _, method, a ->
            val args = a ?: emptyArray()
            when (method.name) {
                "pairedDevice" -> owners[args[0] as String]
                "pairedDevices" -> owners.values.toList()
                "activeDeviceId" -> owners.values.singleOrNull { it.status == "active" }?.id
                "dayOwner" -> null
                "insertHr" -> (args[0] as List<*>).map { value ->
                    val row = value as HrSample
                    val inserted = statement("INSERT OR IGNORE INTO hrSample VALUES(:d,:t,:b)",
                        mapOf("d" to row.deviceId, "t" to row.ts, "b" to row.bpm)).use { it.executeUpdate() }
                    if (inserted == 0) -1L else query("SELECT last_insert_rowid()") { it.getLong(1) }.single()
                }
                "hrSamples", "rawHrSamples" -> hrRows(args)
                "hasHrInWindow" -> hrRows(args).isNotEmpty()
                "countHrInWindow" -> hrRows(args).size
                "maxHrTsInWindow" -> hrRows(args).maxOfOrNull { it.ts } ?: 0L
                "gravityWitnessInWindow" -> GravityWitness(0, 0L)
                "gravitySamples" -> gravity.filter {
                    it.deviceId == args[0] && it.ts in (args[1] as Long)..(args[2] as Long)
                }
                "sleepSessions" -> sleeps.values.filter {
                    it.deviceId == args[0] && it.startTs in (args[1] as Long)..(args[2] as Long)
                }
                "editedSleepSessions" -> sleeps.values.filter { it.deviceId == args[0] && it.userEdited }
                "days" -> days.values.filter { it.deviceId == args[0] }
                "dailyMetricsRange" -> days.values.filter {
                    it.deviceId == args[0] && it.day >= args[1] as String && it.day <= args[2] as String
                }
                "upsertSleepSessions" -> {
                    (args[0] as List<*>).filterIsInstance<SleepSession>().forEach { sleeps[it.deviceId to it.startTs] = it }
                    Unit
                }
                "sleepSession" -> sleeps[(args[0] as String) to (args[1] as Long)]
                "insertSleepSession" -> {
                    val row = args[0] as SleepSession
                    if (sleeps.putIfAbsent(row.deviceId to row.startTs, row) == null) 1L else -1L
                }
                "updateSleepSession" -> {
                    val row = args[0] as SleepSession
                    if (sleeps.replace(row.deviceId to row.startTs, row) != null) 1 else 0
                }
                "replaceComputedScoreWindow" -> {
                    val deviceId = args[0] as String
                    val from = args[1] as String
                    val to = args[2] as String
                    days.keys.removeAll { it.first == deviceId && it.second in from..to }
                    provenance.keys.removeAll { it.first == deviceId && it.second in from..to && it.third != "vo2max_est" }
                    (args[3] as List<*>).filterIsInstance<DailyMetric>().forEach { days[it.deviceId to it.day] = it }
                    (args[5] as List<*>).filterIsInstance<ScoreInputProvenanceRow>().forEach {
                        provenance[Triple(it.deviceId, it.day, it.key)] = it
                    }
                    Unit
                }
                "scoreInputSource" -> provenance[Triple(args[0] as String, args[1] as String, args[2] as String)]?.sourceId
                "upsertMetricSeries", "upsertMetricSeriesWithProvenance", "deleteWorkoutsBySport" -> Unit
                "sessionSleepStateJson" -> null
                "appleDaily", "workouts", "dismissedSleeps" -> emptyList<Any>()
                "insertRr" -> (args[0] as List<*>).map { value ->
                    val r = value as RrInterval
                    val inserted = statement("INSERT OR IGNORE INTO rrInterval VALUES " +
                        "(:deviceId,:ts,:rrMs,:seq,:synced,:ord,:srcChannel,:tsSuspect)", mapOf(
                        "deviceId" to r.deviceId, "ts" to r.ts, "rrMs" to r.rrMs, "seq" to r.seq,
                        "synced" to r.synced, "ord" to r.ord, "srcChannel" to r.srcChannel, "tsSuspect" to r.tsSuspect,
                    )).use { it.executeUpdate() }
                    if (inserted == 0) -1L else query("SELECT last_insert_rowid()") { it.getLong(1) }.single()
                }
                "promoteWhoop5RrSource" -> {
                    statement(PROMOTE_WHOOP5_RR_SOURCE_SQL,
                        listOf("deviceId", "ts", "rrMs", "seq", "ord", "source").zip(args.take(6)).toMap())
                        .use { it.executeUpdate() }
                    Unit
                }
                "rrIntervals", "whoop5RrIntervals" -> query(
                    if (method.name == "whoop5RrIntervals") WHOOP5_RR_INTERVALS_SQL else RR_INTERVALS_SQL,
                    listOf("deviceId", "from", "to", "limit").zip(args.take(4)).toMap(),
                ) { r ->
                    fun optional(column: String) = r.getInt(column).let { if (r.wasNull()) null else it }
                    RrInterval(r.getString("deviceId"), r.getLong("ts"), r.getInt("rrMs"), r.getInt("seq"),
                        r.getInt("synced"), optional("ord"), optional("srcChannel"), optional("tsSuspect"))
                }
                "hasWhoop5RrSource" -> query(HAS_WHOOP5_RR_SOURCE_SQL, mapOf("deviceId" to args[0])) {
                    it.getBoolean(1)
                }.single()
                "legacyWhoop5RrWithheld" -> query(LEGACY_WHOOP5_RR_WITHHELD_SQL,
                    listOf("deviceId", "from", "to").zip(args.take(3)).toMap()) {
                    it.getBoolean(1)
                }.single()
                "firstScorableWhoop5RrTs", "firstRecordedRrTs" -> query(
                    if (method.name == "firstRecordedRrTs") FIRST_RECORDED_RR_SQL
                    else FIRST_SCORABLE_WHOOP5_RR_SQL,
                    mapOf("deviceId" to args[0]),
                ) { row -> row.getLong(1).let { if (row.wasNull()) null else it } }.single()
                "analysisFingerprint" -> query(ANALYSIS_FINGERPRINT_SQL) { it.getString(1) }.single()
                "dayStreamFingerprint" -> query(DAY_STREAM_FINGERPRINT_SQL,
                    listOf("deviceId", "from", "to").zip(args.take(3)).toMap()) { it.getString(1) }.single()
                "stepSamples", "ppgHrSamples", "spo2Samples",
                "skinTempSamples", "respSamples", "sleepStateSamples", "events" -> emptyList<Any>()
                else -> error("Unimplemented DAO call: ${method.name}")
            }
        } as WhoopDao
        repo = WhoopRepository(dao, object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                if (!db.autoCommit) return block()
                db.autoCommit = false
                try { return block().also { db.commit() } }
                catch (failure: Throwable) { db.rollback(); throw failure }
                finally { db.autoCommit = true }
            }
        })
        registry("5.0 MG")
    }

    @After fun close() { db.close() }
    private fun sql(sql: String) { db.createStatement().use { it.execute(sql) } }
    private fun statement(sql: String, values: Map<String, Any?>) = run {
        val names = mutableListOf<String>()
        val bound = Regex(":([A-Za-z][A-Za-z0-9]*)").replace(sql) {
            names += it.groupValues[1]; "?"
        }
        db.prepareStatement(bound).also { stmt ->
            names.forEachIndexed { index, name ->
                require(values.containsKey(name)) { "Missing SQL bind: $name" }
                stmt.setObject(index + 1, values[name])
            }
        }
    }
    private fun <T> query(sql: String, values: Map<String, Any?> = emptyMap(), map: (ResultSet) -> T): List<T> =
        statement(sql, values).use { stmt -> stmt.executeQuery().use { rows ->
            buildList { while (rows.next()) add(map(rows)) }
        } }

    private fun hrRows(args: Array<out Any?>): List<HrSample> = query(
        "SELECT * FROM hrSample WHERE deviceId=:d AND ts>=:f AND ts<=:t ORDER BY ts LIMIT :l",
        mapOf("d" to args[0], "f" to args[1], "t" to args[2], "l" to (args.getOrNull(3) as? Int ?: 200_000)),
    ) { HrSample(it.getString("deviceId"), it.getLong("ts"), it.getInt("bpm")) }

    private fun registry(model: String, brand: String = "WHOOP", owner: String = id) {
        owners[owner] = PairedDeviceRow(owner, brand, model, null, sourceKind = "liveBLE",
            capabilities = "hr,hrv", status = "paired", addedAt = 1, lastSeenAt = 1)
        statement("INSERT OR REPLACE INTO pairedDevice VALUES(:id,:brand,:model,'paired')",
            mapOf("id" to owner, "brand" to brand, "model" to model)).use { it.executeUpdate() }
    }
    private fun activate(owner: String) {
        owners.replaceAll { key, value -> value.copy(status = if (key == owner) "active" else "paired") }
        statement("UPDATE pairedDevice SET status=CASE WHEN id=:id THEN 'active' ELSE 'paired' END",
            mapOf("id" to owner)).use { it.executeUpdate() }
    }
    private suspend fun read(from: Long = 0, to: Long = 1000, limit: Int = 100) =
        repo.rrIntervalsForDevice(id, from, to, limit)

    private fun seedBaseline(before: String) {
        for (offset in 1L..8L) {
            val day = java.time.LocalDate.parse(before).minusDays(offset).toString()
            days[id to day] = DailyMetric(deviceId = id, day = day, totalSleepMin = 480.0,
                efficiency = 0.9, restingHr = 60, avgHrv = 40.0 + offset % 3, recovery = 60.0)
        }
    }

    // The same persisted row and production SQL inputs consumed by the Today explanation.
    private suspend fun showsLegacyGap(row: DailyMetric, owner: String): Boolean {
        fun dayKey(ts: Long?) = ts?.let {
            java.time.LocalDate.ofInstant(java.time.Instant.ofEpochSecond(it),
                java.time.ZoneId.systemDefault()).toString()
        }
        return row.recovery == null && Whoop5RR.legacyUnscorableNight(
            strictWhoop5 = repo.isWhoop5RrSource(owner), day = row.day,
            firstRecordedDay = dayKey(repo.firstRecordedRrTs(owner)),
            firstScorableDay = dayKey(repo.firstScorableWhoop5RrTs(owner)),
            avgHrv = row.avgHrv, totalSleepMin = row.totalSleepMin,
        )
    }

    private suspend fun assertLegacySnapshotScoringLifecycle(model: String, expectsProtection: Boolean) {
        val owner = "physical-strap"
        registry(model, owner = owner)
        activate(owner)
        val now = 1_780_272_000L
        val offset = java.util.TimeZone.getDefault().getOffset(now * 1000L) / 1000L
        val end = now - Math.floorMod(now + offset, 86_400L)
        val start = end - 3_600L
        seedBaseline(AnalyticsEngine.dayString(end, offset))
        repo.insert(StreamBatch(hr = (start until end).map { HrRow(it, 60) }), owner)
        repo.upsertSleepSessions(listOf(SleepSession(deviceId = owner, startTs = start, endTs = end,
            efficiency = 1.0, stagesJSON = AnalyticsEngine.encodeStages(listOf(StageSegment(start, end, "light"))))))
        val registry = DeviceRegistry(dao, object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        })
        suspend fun score(): DailyMetric {
            val computed = IntelligenceEngine.analyzeRecent(repo, maxDays = 1, importedDeviceId = id,
                nowSeconds = now, ownerSource = RegistryDayOwnerSource(registry), dayCycleMode = DayCycleMode.MIDNIGHT).single()
            return days.getValue("$id-noop" to computed.day)
        }

        val noBeats = score()
        assertTrue((noBeats.totalSleepMin ?: 0.0) > 0.0)
        assertNull(noBeats.avgHrv)
        assertNull(noBeats.recovery)
        assertFalse("ordinary missing beats are not legacy units", showsLegacyGap(noBeats, owner))

        val computedId = "$id-noop"
        val legacySnapshot = noBeats.copy(deviceId = computedId, totalSleepMin = 1.0, efficiency = 0.01,
            restingHr = 199, avgHrv = 77.25, recovery = 0.42, strain = 99.0,
            respRateBpm = 14.25, avgSdnn = 63.5)
        days[computedId to legacySnapshot.day] = legacySnapshot
        provenance[Triple(computedId, legacySnapshot.day, "recovery")] = ScoreInputProvenanceRow(
            computedId, legacySnapshot.day, "recovery", "legacy-owner")
        val legacyRr = (start until end).map { RrRow(it, if (it % 2L == 0L) 980 else 1020) }
        repo.insert(StreamBatch(rr = legacyRr), owner)
        val legacy = score()
        assertFalse(showsLegacyGap(legacy, owner))
        if (expectsProtection) {
            assertEquals(legacySnapshot.avgHrv, legacy.avgHrv)
            assertEquals(legacySnapshot.recovery, legacy.recovery)
            assertEquals("RR-derived respiration must survive", legacySnapshot.respRateBpm, legacy.respRateBpm)
            assertEquals("the other persisted RR-only aggregate must survive", legacySnapshot.avgSdnn, legacy.avgSdnn)
            assertNotEquals("sleep must be freshly scored", legacySnapshot.totalSleepMin, legacy.totalSleepMin)
            assertNotEquals("only the R-R-derived snapshot is protected", legacySnapshot.restingHr, legacy.restingHr)
            assertEquals("legacy-owner", repo.scoreInputSource(computedId, legacy.day, "recovery"))
            val stable = score()
            assertEquals(legacySnapshot.avgHrv, stable.avgHrv)
            assertEquals(legacySnapshot.recovery, stable.recovery)
            assertEquals(legacySnapshot.respRateBpm, stable.respRateBpm)
            assertEquals(legacySnapshot.avgSdnn, stable.avgSdnn)
            assertEquals("legacy-owner", repo.scoreInputSource(computedId, legacy.day, "recovery"))

            val thin = legacyRr.first()
            assertEquals(0, repo.insert(StreamBatch(rr = listOf(thin.copy(
                srcChannel = RrSourceChannel.WHOOP5_STANDARD))), owner).rr)
            val insufficient = score()
            assertNull("a marked but insufficient transport must not be masked", insufficient.avgHrv)
            assertNull(insufficient.recovery)
            assertNull(insufficient.respRateBpm)
            assertNull(insufficient.avgSdnn)

            days[computedId to legacySnapshot.day] = legacySnapshot
            provenance[Triple(computedId, legacySnapshot.day, "recovery")] = ScoreInputProvenanceRow(
                computedId, legacySnapshot.day, "recovery", "legacy-owner")
            // Keep the same unlabelled-era bounds: valid HRV alone must rule out this cause.
            assertFalse("valid HRV without Charge is ordinary calibration",
                showsLegacyGap(legacy.copy(avgHrv = 40.0), owner))
            assertEquals(0, repo.insert(StreamBatch(rr = legacyRr.map {
                it.copy(srcChannel = RrSourceChannel.WHOOP5_HISTORICAL)
            }), owner).rr)
        } else {
            assertNotEquals(legacySnapshot.avgHrv, legacy.avgHrv)
            assertEquals(40.0, legacy.avgHrv!!, 0.001)
            assertNotNull(legacy.recovery)
        }

        val restored = score()
        assertEquals(40.0, restored.avgHrv!!, 0.001)
        assertNotNull(restored.recovery)
        if (expectsProtection) {
            assertNotEquals(legacySnapshot.respRateBpm, restored.respRateBpm)
            assertNotEquals(legacySnapshot.avgSdnn, restored.avgSdnn)
        }
        if (expectsProtection) assertEquals(owner, repo.scoreInputSource(computedId, restored.day, "recovery"))
        assertFalse(showsLegacyGap(restored, owner))
        val idle = score()
        assertEquals(restored.avgHrv, idle.avgHrv)
        assertEquals(restored.recovery, idle.recovery)
        assertFalse("a cache hit must not revive the explanation", showsLegacyGap(idle, owner))
    }

    @Test fun actualWhoop5LegacySnapshotClearsAfterSourcePromotion() = runBlocking {
        assertLegacySnapshotScoringLifecycle("5.0 MG", expectsProtection = true)
    }

    @Test fun actualWhoop4LegacyNightKeepsScoresWithoutExplanation() = runBlocking {
        assertLegacySnapshotScoringLifecycle("4.0", expectsProtection = false)
    }

    /** The date the "this night cannot be scored" explanation names comes from this query, so it has to
     *  agree with what scoring actually accepts: labelled transports only, suspect stamps excluded, and
     *  null rather than a fabricated epoch when the device has banked nothing scorable yet. */
    @Test fun firstScorableTimestampMatchesWhatScoringAccepts() = runBlocking {
        registry("5.0 MG")
        // Legacy unlabelled beats only: nothing here can be scored, so there is no first scorable day.
        repo.insert(StreamBatch(rr = (100L until 110L).map { RrRow(it, 1000) }), id)
        assertNull(repo.firstScorableWhoop5RrTs(id))
        // The lower bound sees those same rows: they WERE recorded, they just cannot be read.
        assertEquals(100L, repo.firstRecordedRrTs(id))
        // A type-40 live beat (6) is labelled but is NOT a scoring transport, so it must not count.
        insertRr(ts = 200L, channel = 6)
        assertNull(repo.firstScorableWhoop5RrTs(id))
        // A future-stamped beat is excluded from scoring (#1073), so it cannot name the day either.
        insertRr(ts = 300L, channel = 7, suspect = 1)
        assertNull(repo.firstScorableWhoop5RrTs(id))
        // The first genuinely scorable beat, and then an earlier one, which must win.
        insertRr(ts = 900L, channel = 7)
        assertEquals(900L, repo.firstScorableWhoop5RrTs(id))
        insertRr(ts = 400L, channel = 5)
        assertEquals(400L, repo.firstScorableWhoop5RrTs(id))
        // The lower bound ignores the channel entirely and still refuses the suspect stamp.
        assertEquals(100L, repo.firstRecordedRrTs(id))
        // Another device's beats never leak into either answer.
        assertNull(repo.firstScorableWhoop5RrTs("someone-else"))
        assertNull(repo.firstRecordedRrTs("someone-else"))
    }

    private fun insertRr(ts: Long, channel: Int?, suspect: Int? = null, device: String = id) {
        statement(
            "INSERT OR REPLACE INTO rrInterval(deviceId, ts, rrMs, seq, synced, ord, srcChannel, tsSuspect) " +
                "VALUES(:deviceId, :ts, 1000, 0, 0, 0, :srcChannel, :tsSuspect)",
            mapOf("deviceId" to device, "ts" to ts, "srcChannel" to channel, "tsSuspect" to suspect),
        ).use { it.executeUpdate() }
    }

    @Test fun sourceFingerprintQueriesUseCoveringIndex() {
        val plan = query("EXPLAIN QUERY PLAN $ANALYSIS_FINGERPRINT_SQL") { it.getString("detail") }
        assertEquals(3, plan.count { it.contains("USING COVERING INDEX rrInterval_source_suspect") })
        assertFalse(plan.any { it.contains("SCAN rrInterval") })
    }

    @Test fun legacyWithheldStatusUsesExactScoringWindowAndSourcePolicy() = runBlocking {
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 1000))), id)
        assertTrue(repo.legacyWhoop5RrWithheld(id, 100, 200))
        assertFalse("rows outside the exact read window cannot protect a score",
            repo.legacyWhoop5RrWithheld(id, 101, 200))
        statement("UPDATE rrInterval SET tsSuspect=1 WHERE deviceId=:id AND ts=100",
            mapOf("id" to id)).use { it.executeUpdate() }
        assertFalse("quarantined rows follow the scoring read exclusion",
            repo.legacyWhoop5RrWithheld(id, 100, 200))
        statement("UPDATE rrInterval SET tsSuspect=NULL WHERE deviceId=:id AND ts=100",
            mapOf("id" to id)).use { it.executeUpdate() }

        repo.insert(StreamBatch(rr = listOf(RrRow(150, 990,
            srcChannel = RrSourceChannel.WHOOP5_STANDARD))), id)
        assertFalse("a scorable labelled transport ends protection",
            repo.legacyWhoop5RrWithheld(id, 100, 200))

        registry("4.0")
        assertFalse(repo.legacyWhoop5RrWithheld(id, 100, 149))
        registry("5.0 MG", brand = "Oura")
        assertFalse(repo.legacyWhoop5RrWithheld(id, 100, 149))
    }

    @Test fun actualNightlyScorerGuardsCanonicalHistoryAfterRePairing() = runBlocking {
        registry("WHOOP")
        registry("5.0 MG", owner = "new-five")
        activate("new-five")
        val now = 1_780_272_000L
        val offset = java.util.TimeZone.getDefault().getOffset(now * 1000L) / 1000L
        val end = now - Math.floorMod(now + offset, 86_400L)
        val start = end - 3_600L
        repo.insert(StreamBatch(
            hr = (start until end).map { HrRow(it, 60) },
            rr = (start until end).map { RrRow(it, if (it % 2L == 0L) 980 else 1020) },
        ), id)
        assertTrue(repo.legacyWhoop5RrWithheld(id, start, end))
        repo.upsertSleepSessions(listOf(SleepSession(deviceId = id, startTs = start, endTs = end,
            efficiency = 1.0, restingHr = null, avgHrv = null,
            stagesJSON = AnalyticsEngine.encodeStages(listOf(StageSegment(start, end, "light"))))))
        val registry = DeviceRegistry(dao, object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        })
        suspend fun score() = IntelligenceEngine.analyzeRecent(repo = repo, maxDays = 1,
            importedDeviceId = "new-five", nowSeconds = now,
            ownerSource = RegistryDayOwnerSource(registry), dayCycleMode = DayCycleMode.MIDNIGHT)
        val first = score().single()
        assertEquals(60.0, first.sleepMin!!, 0.001)
        assertEquals(60, first.rhr)
        assertNull("unlabelled canonical history must not supply HRV after re-pairing", first.hrv)
        assertNull(days.getValue("new-five-noop" to first.day).avgHrv)

        // Same rows, same timestamps, same engine cache: only source provenance changes.
        assertEquals(0, repo.insert(StreamBatch(rr = (start until end).map {
            RrRow(it, if (it % 2L == 0L) 980 else 1020, RrSourceChannel.WHOOP5_HISTORICAL)
        }), id).rr)
        val promoted = score().single()
        assertEquals(40.0, promoted.hrv!!, 0.001)
        assertEquals(promoted.hrv, days.getValue("new-five-noop" to first.day).avgHrv)
        assertEquals(promoted.hrv, score().single().hrv)
    }

    @Test fun ordinaryRrReadsAndFingerprintsFollowActiveAliasPolicy() = runBlocking {
        registry("WHOOP")
        registry("4.0", owner = "old-four")
        registry("5.0 MG", owner = "new-five")
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 1000))), id)
        activate("old-four")
        val global = dao.analysisFingerprint()
        val day = repo.dayStreamFingerprint(id, 0, 1000)
        assertEquals(listOf(1000), read().map { it.rrMs })
        activate("new-five")
        assertTrue(read().isEmpty())
        assertNotEquals(global, dao.analysisFingerprint())
        assertNotEquals(day, repo.dayStreamFingerprint(id, 0, 1000))
        registry("4.0")
        assertEquals(listOf(1000), read().map { it.rrMs })
    }

    @Test fun actualRestagingGuardsLegacyAliasAndKeepsConfirmedWhoop4() = runBlocking {
        registry("WHOOP")
        registry("5.0 MG", owner = "new-five")
        activate("new-five")
        val start = 1_700_000_000L
        val duration = 6 * 3_600
        gravity += (0 until duration).map { GravitySample(id, start + it, 0.0, 0.0, 1.0) }
        repo.insert(StreamBatch(hr = (0 until duration).map { HrRow(start + it, 52 + (it / 60) % 3) }), id)
        suspend fun restage() = SleepStageHealer.restageFromRaw(repo, id, start, start + duration,
            useExperimentalSleepV2 = true)
        val baseline = restage()
        assertNotNull(baseline)
        repo.insert(StreamBatch(rr = (0 until duration).map {
            RrRow(start + it, 1000 + (40 * kotlin.math.sin(2 * Math.PI * it / 4)).toInt())
        }), id)
        assertEquals("the real restaging path must exclude ambiguous R-R", baseline, restage())
        registry("4.0")
        assertNotEquals("confirmed WHOOP 4 still stages from the same R-R", baseline, restage())
    }

    @Test fun actualNightlySlidingWindowDoesNotSpliceStandardIntoHistoricalSource() = runBlocking {
        registry("WHOOP")
        registry("5.0 MG", owner = "new-five")
        activate("new-five")
        val now = 1_781_136_000L
        val offset = java.util.TimeZone.getDefault().getOffset(now * 1000L) / 1000L
        val midnight = now - Math.floorMod(now + offset, 86_400L)
        val end = midnight - 86_400L
        val start = end - 3_600L
        repo.insert(StreamBatch(
            hr = (start until end).map { HrRow(it, 60) },
            rr = (start until end).map {
                RrRow(it, if (it % 2L == 0L) 980 else 1020, RrSourceChannel.WHOOP5_STANDARD)
            } + RrRow(midnight - 31 * 3_600L, 900, RrSourceChannel.WHOOP5_HISTORICAL),
        ), id)
        repo.upsertSleepSessions(listOf(SleepSession(deviceId = id, startTs = start, endTs = end,
            efficiency = 1.0, restingHr = null, avgHrv = null,
            stagesJSON = AnalyticsEngine.encodeStages(listOf(StageSegment(start, end, "light"))))))
        val registry = DeviceRegistry(dao, object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        })
        val scored = IntelligenceEngine.analyzeRecent(repo = repo, maxDays = 2,
            importedDeviceId = "new-five", nowSeconds = now,
            ownerSource = RegistryDayOwnerSource(registry), dayCycleMode = DayCycleMode.MIDNIGHT)
            .single { it.day == AnalyticsEngine.dayString(end, offset) }
        assertEquals(60.0, scored.sleepMin!!, 0.001)
        assertEquals(60, scored.rhr)
        assertNull("the older history-only window cannot reuse standard beats from its overlap", scored.hrv)
    }

    @Test fun rawCsvPreservesMixedTransportsWhileScoringSelectsHistory() = runBlocking {
        repo.insert(StreamBatch(rr = listOf(
            RrRow(100, 1024),
            RrRow(101, 900, RrSourceChannel.WHOOP5_HISTORICAL),
            RrRow(102, 800, RrSourceChannel.WHOOP5_REALTIME),
            RrRow(103, 700, RrSourceChannel.WHOOP5_STANDARD),
            RrRow(104, 600, RrSourceChannel.WHOOP5_HISTORICAL),
        )), id)
        sql("UPDATE rrInterval SET tsSuspect = 1 WHERE ts = 104")
        assertEquals(listOf(900), read().map { it.rrMs })
        val out = StringWriter()
        val counts = RawSensorExport.writeCsv(out, repo, id, 100, 104)
        assertEquals(4, counts["rr"])
        val lines = out.toString().lineSequence().drop(1).filter { it.isNotEmpty() }
            .map { it.split(',') }.toList()
        assertEquals(listOf("100", "101", "102", "103"), lines.map { it[0] })
        assertTrue(lines.all { it[2] == "rr" })
        assertEquals(listOf("1024", "900", "800", "700"), lines.map { it[4] })
        assertEquals(listOf(800, 700), repo.rawRrIntervalsForDevice(id, 102, 104, 2).map { it.rrMs })
    }

    @Test fun sourceSelectionPrecedesLimitAndSharesBoundsAndQuarantine() = runBlocking {
        repo.insert(StreamBatch(rr = (100L until 200L).map { RrRow(it, 1000, RrSourceChannel.WHOOP5_STANDARD) }
            + RrRow(200, 900, RrSourceChannel.WHOOP5_HISTORICAL)
            + RrRow(201, 800, RrSourceChannel.WHOOP5_REALTIME)), id)
        assertEquals(listOf(900), read(limit = 1).map { it.rrMs })
        assertEquals(listOf(1000), read(to = 199, limit = 1).map { it.rrMs })
        sql("UPDATE rrInterval SET tsSuspect = 1 WHERE ts = 200")
        assertEquals(listOf(1000), read(limit = 1).map { it.rrMs })
        assertTrue(read(from = 201).isEmpty())
    }

    @Test fun zeroInsertPromotionRestoresOrderAndInvalidatesBothCaches() = runBlocking {
        repo.insert(StreamBatch(rr = listOf(700, 900, 900, 800).map { RrRow(100, it) }), id)
        val g0 = dao.analysisFingerprint()
        val d0 = dao.dayStreamFingerprint(id, 0, 1000)
        val history = listOf(900, 700, 900, 800).map { RrRow(100, it, RrSourceChannel.WHOOP5_HISTORICAL) }
        assertEquals(0, repo.insert(StreamBatch(rr = history), id).rr)
        val rows = read()
        assertEquals(listOf(900, 700, 900, 800), rows.map { it.rrMs })
        assertEquals(listOf(0, 1, 2, 3), rows.map { it.ord })
        assertEquals(listOf(0, 0, 1, 0), rows.map { it.seq })
        val g1 = dao.analysisFingerprint()
        val d1 = dao.dayStreamFingerprint(id, 0, 1000)
        assertNotEquals(g0, g1)
        assertNotEquals(d0, d1)
        assertEquals(0, repo.insert(StreamBatch(rr = history), id).rr)
        assertEquals(g1, dao.analysisFingerprint())
        assertEquals(d1, dao.dayStreamFingerprint(id, 0, 1000))
    }

    @Test fun interleavedTransportsKeepHistoricalPositionAndDuplicateOccurrence() = runBlocking {
        val h = RrSourceChannel.WHOOP5_HISTORICAL
        val s = RrSourceChannel.WHOOP5_STANDARD
        val rows = listOf(700 to s, 900 to h, 900 to s, 700 to h, 900 to h, 800 to h)
            .map { RrRow(100, it.first, it.second) }
        assertEquals(4, repo.insert(StreamBatch(rr = rows), id).rr)
        val selected = read()
        assertEquals(listOf(900, 700, 900, 800), selected.map { it.rrMs })
        assertEquals(listOf(0, 1, 2, 3), selected.map { it.ord })
        assertEquals(listOf(0, 0, 1, 0), selected.map { it.seq })
    }

    @Test fun registryPolicyPreservesLegacyAndOnlyUsesPositiveWhoop5Evidence() = runBlocking {
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 1000))), id)
        assertTrue(read().isEmpty())
        registry("4.0")
        assertEquals(listOf(1000), read().map { it.rrMs })
        registry("WHOOP")
        val g0 = dao.analysisFingerprint()
        val d0 = dao.dayStreamFingerprint(id, 0, 1000)
        assertEquals(listOf(1000), read().map { it.rrMs })
        registry("5.0 MG")
        assertNotEquals(g0, dao.analysisFingerprint())
        assertNotEquals(d0, dao.dayStreamFingerprint(id, 0, 1000))
        registry("WHOOP")
        repo.insert(StreamBatch(rr = listOf(RrRow(101, 977, RrSourceChannel.WHOOP5_STANDARD))), id)
        assertEquals(listOf(977), read().map { it.rrMs })
        registry("5.0 MG", "Oura")
        assertEquals(listOf(1000, 977), read().map { it.rrMs })
        assertEquals(2, dao.rrIntervals(id, 0, 1000, 100).size)
    }

    @Test fun standardWinsNativeAndLegacyCollisionsInBothArrivalOrders() = runBlocking {
        for (lowerSource in listOf(null, RrSourceChannel.WHOOP5_REALTIME)) {
            for (standardFirst in listOf(false, true)) {
                // Independent owners avoid sharing rows or fingerprints between arrival-order cases.
                val owner = "case-${lowerSource?.code}-$standardFirst"
                registry("5.0 MG", owner = owner)
                val lower = listOf(700, 900, 900, 800).map { RrRow(100, it, lowerSource) }
                val standard = listOf(900, 700, 900, 800).map { RrRow(100, it, RrSourceChannel.WHOOP5_STANDARD) }
                assertEquals(4, repo.insert(StreamBatch(rr = if (standardFirst) standard else lower), owner).rr)
                val g0 = dao.analysisFingerprint()
                val d0 = dao.dayStreamFingerprint(owner, 0, 1000)
                assertEquals(0, repo.insert(StreamBatch(rr = if (standardFirst) lower else standard), owner).rr)
                val rows = repo.rrIntervalsForDevice(owner, 0, 1000, 100)
                assertEquals(listOf(900, 700, 900, 800), rows.map { it.rrMs })
                assertEquals(listOf(0, 1, 2, 3), rows.map { it.ord })
                assertEquals(listOf(0, 0, 1, 0), rows.map { it.seq })
                assertEquals(List(4) { 7 }, rows.map { it.srcChannel })
                val g1 = dao.analysisFingerprint()
                val d1 = dao.dayStreamFingerprint(owner, 0, 1000)
                assertEquals("global cache must see a zero-insert promotion", standardFirst, g0 == g1)
                assertEquals("day cache must see a zero-insert promotion", standardFirst, d0 == d1)
                for (replay in listOf(lower, standard)) {
                    assertEquals(0, repo.insert(StreamBatch(rr = replay), owner).rr)
                }
                assertEquals(g1, dao.analysisFingerprint())
                assertEquals(d1, dao.dayStreamFingerprint(owner, 0, 1000))
                val history = listOf(800, 900, 700, 900).map { RrRow(100, it, RrSourceChannel.WHOOP5_HISTORICAL) }
                assertEquals(0, repo.insert(StreamBatch(rr = history), owner).rr)
                val g2 = dao.analysisFingerprint()
                val d2 = dao.dayStreamFingerprint(owner, 0, 1000)
                assertNotEquals(g1, g2)
                assertNotEquals(d1, d2)
                for (replay in listOf(standard, lower, history)) {
                    assertEquals(0, repo.insert(StreamBatch(rr = replay), owner).rr)
                }
                val final = repo.rrIntervalsForDevice(owner, 0, 1000, 100)
                assertEquals(listOf(800, 900, 700, 900), final.map { it.rrMs })
                assertEquals(listOf(0, 1, 2, 3), final.map { it.ord })
                assertEquals(List(4) { 5 }, final.map { it.srcChannel })
                assertEquals(g2, dao.analysisFingerprint())
                assertEquals(d2, dao.dayStreamFingerprint(owner, 0, 1000))
            }
        }
    }

    @Test fun historicalCanonicalOwnerAfterRePairingUsesActiveWhoop5Policy() = runBlocking {
        registry("WHOOP")
        registry("5.0 MG", owner = "new-five")
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 1024))), id)
        val activeFive = repo.isWhoop5RrSource("new-five")
        assertTrue(activeFive)
        assertTrue(repo.isWhoop5RrSource(id, activeFive))
        assertTrue(repo.rrIntervalsForDevice(id, 0, 1000, unlabelledAliasOfWhoop5 = activeFive).isEmpty())
        registry("4.0")
        assertFalse(repo.isWhoop5RrSource(id, activeFive))
        assertEquals(listOf(1024), repo.rrIntervalsForDevice(id, 0, 1000,
            unlabelledAliasOfWhoop5 = activeFive).map { it.rrMs })
    }

    @Test fun deviceSwitchKeepsArchivedPhysicalHistoryAndGuardsOnlyUnknownAlias() = runBlocking {
        registry("WHOOP")
        repo.insert(StreamBatch(rr = listOf(RrRow(90, 1024))), id)
        registry("4.0", owner = "old-four")
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 810))), "old-four")
        registry("5.0 MG", owner = "old-five")
        val h = RrSourceChannel.WHOOP5_HISTORICAL
        repo.insert(StreamBatch(rr = listOf(900, 700, 900, 800).map { RrRow(200, it, h) }), "old-five")
        registry("5.0 MG", owner = "new-five")
        repo.insert(StreamBatch(rr = listOf(RrRow(300, 850, RrSourceChannel.WHOOP5_STANDARD))), "new-five")
        val rows = repo.rrIntervalsUnion("new-five", 0, 1000)
        assertEquals(listOf(810, 900, 700, 900, 800, 850), rows.map { it.rrMs })
        assertEquals(listOf("old-four") + List(4) { "old-five" } + "new-five", rows.map { it.deviceId })
        registry("4.0")
        assertEquals(1024, repo.rrIntervalsUnion("new-five", 0, 1000).first().rrMs)
    }

    @Test fun promotionDoesNotRelabelAnotherOpticalChannel() = runBlocking {
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 800, RrSourceChannel.GREEN_QUALITY))), id)
        for (source in listOf(RrSourceChannel.WHOOP5_STANDARD, RrSourceChannel.WHOOP5_HISTORICAL)) {
            assertEquals(0, repo.insert(StreamBatch(rr = listOf(RrRow(100, 800, source))), id).rr)
        }
        assertEquals(1, dao.rrIntervals(id, 0, 1000, 100).single().srcChannel)
    }

    @Test fun firstTagOutsideDayAndSuspectPromotionInvalidateOwnerPolicyCaches() = runBlocking {
        registry("WHOOP")
        repo.insert(StreamBatch(rr = listOf(RrRow(100, 800), RrRow(2000, 900))), id)
        sql("UPDATE rrInterval SET tsSuspect = 1 WHERE ts = 2000")
        val g0 = dao.analysisFingerprint()
        val d0 = dao.dayStreamFingerprint(id, 0, 1000)
        assertEquals(listOf(800), read().map { it.rrMs })
        assertEquals(0, repo.insert(StreamBatch(rr = listOf(RrRow(2000, 900, RrSourceChannel.WHOOP5_HISTORICAL))), id).rr)
        assertTrue(read().isEmpty())
        assertNotEquals(g0, dao.analysisFingerprint())
        assertNotEquals(d0, dao.dayStreamFingerprint(id, 0, 1000))
    }
}
