package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [DeviceRegistry] contract tests — mirror the Swift DeviceRegistryStoreTests in
 * Packages/WhoopStore. The project ships NO Robolectric (junit + kotlinx-coroutines-test only — see
 * app/build.gradle.kts and MoodStoreTest), so rather than build a real Room DB these run the REAL
 * [DeviceRegistry] over an in-memory [FakeRegistryDao] that reproduces the DAO's SQL semantics exactly:
 *   - pairedDevices()  ORDER BY addedAt ASC
 *   - activeDeviceId() the single row WHERE status='active', LIMIT 1
 *   - upsertPairedDevice() / setDayOwner()  INSERT OR REPLACE by PK
 *   - demoteActive() + promote()  the single-active swap (run together via the pass-through transactor)
 * The fake is seeded with `my-whoop` active, exactly as MIGRATION_7_8 seeds the real DB.
 */
class DeviceRegistryTest {

    /** In-memory stand-in for [DeviceRegistryDao]. The (deviceId, status) bookkeeping reproduces the
     *  pairedDevice table; [day] map reproduces dayOwnership. No transaction isolation is modelled —
     *  the registry's [DeviceRegistry.setActive] is what couples demote+promote, and the test's
     *  transactor runs the block straight through, exactly as Room's withTransaction would commit it. */
    private class FakeRegistryDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>() // insertion order ≈ addedAt order
        val owners = LinkedHashMap<String, DayOwnershipRow>()

        override suspend fun pairedDevices(): List<PairedDeviceRow> =
            devices.values.sortedBy { it.addedAt }

        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id

        override suspend fun upsertPairedDevice(row: PairedDeviceRow) {
            devices[row.id] = row // INSERT OR REPLACE by id PK
        }

        override suspend fun demoteActive() {
            for ((id, row) in devices) {
                if (row.status == DeviceStatus.active.name) {
                    devices[id] = row.copy(status = DeviceStatus.paired.name)
                }
            }
        }

        override suspend fun promote(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.active.name, lastSeenAt = now) }
        }

        override suspend fun archiveDevice(id: String) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.archived.name) }
        }

        override suspend fun setModel(id: String, model: String) {
            devices[id]?.let { devices[id] = it.copy(model = model) }
        }

        override suspend fun renameDevice(id: String, nickname: String?) {
            devices[id]?.let { devices[id] = it.copy(nickname = nickname) }
        }
        override suspend fun touchLastSeen(id: String, now: Long) {
            // #1527, mirrors the query's `AND status != 'archived'`.
            devices[id]?.let {
                if (it.status != DeviceStatus.archived.name) devices[id] = it.copy(lastSeenAt = now)
            }
        }

        override suspend fun setPeripheralId(id: String, peripheralId: String?) {
            devices[id]?.let { devices[id] = it.copy(peripheralId = peripheralId) }
        }

        override suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
            devices.values.firstOrNull { it.peripheralId == peripheralId }

        override suspend fun setDayOwner(row: DayOwnershipRow) {
            owners[row.day] = row // INSERT OR REPLACE by day PK
        }

        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]

        // deleteAllData: this fake models the registry tables only (pairedDevice/dayOwnership). The
        // sample-table deletes are validated by the real Room-backed integration; here each delete just
        // RECORDS the table name + deviceId it was asked to clear (into [deletedTables]) so a test can
        // assert the fan-out reaches every device-scoped table for the right deviceId, and the
        // dayOwnership delete additionally mutates the state the fake holds.
        val deletedTables = mutableListOf<Pair<String, String>>() // (table, deviceId), in call order
        override suspend fun deleteHrFor(deviceId: String) { deletedTables += "hrSample" to deviceId }
        override suspend fun deleteRrFor(deviceId: String) { deletedTables += "rrInterval" to deviceId }
        override suspend fun deleteSpo2For(deviceId: String) { deletedTables += "spo2Sample" to deviceId }
        override suspend fun deleteSkinTempFor(deviceId: String) { deletedTables += "skinTempSample" to deviceId }
        override suspend fun deleteRespFor(deviceId: String) { deletedTables += "respSample" to deviceId }
        override suspend fun deleteGravityFor(deviceId: String) { deletedTables += "gravitySample" to deviceId }
        override suspend fun deleteStepsFor(deviceId: String) { deletedTables += "stepSample" to deviceId }
        override suspend fun deletePpgHrFor(deviceId: String) { deletedTables += "ppgHrSample" to deviceId }
        override suspend fun deletePpgWaveformFor(deviceId: String) { deletedTables += "ppgWaveformSample" to deviceId }
        override suspend fun deleteRawImuFor(deviceId: String) { deletedTables += "rawImuSample" to deviceId }
        override suspend fun deleteV18AuxFor(deviceId: String) { deletedTables += "v18AuxSample" to deviceId }
        override suspend fun deleteEventsFor(deviceId: String) { deletedTables += "event" to deviceId }
        override suspend fun deleteBatteryFor(deviceId: String) { deletedTables += "battery" to deviceId }
        override suspend fun deleteDailyMetricsFor(deviceId: String) { deletedTables += "dailyMetric" to deviceId }
        override suspend fun deleteSleepSessionsFor(deviceId: String) { deletedTables += "sleepSession" to deviceId }
        override suspend fun deleteJournalFor(deviceId: String) { deletedTables += "journal" to deviceId }
        override suspend fun deleteWorkoutsFor(deviceId: String) { deletedTables += "workout" to deviceId }
        override suspend fun deleteAppleDailyFor(deviceId: String) { deletedTables += "appleDaily" to deviceId }
        override suspend fun deleteAppleStepHoursFor(deviceId: String) { deletedTables += "appleStepHour" to deviceId }
        override suspend fun deleteMetricSeriesFor(deviceId: String) { deletedTables += "metricSeries" to deviceId }
        override suspend fun deleteDayOwnershipFor(deviceId: String) {
            deletedTables += "dayOwnership" to deviceId
            owners.entries.removeIf { it.value.deviceId == deviceId }
        }
        override suspend fun deleteScoreInputProvenanceFor(deviceId: String) {
            deletedTables += "scoreInputProvenance" to deviceId
        }
        override suspend fun deleteSleepStatesFor(deviceId: String) { deletedTables += "sleepStateSample" to deviceId }
        override suspend fun deleteLabMarkersFor(deviceId: String) { deletedTables += "labMarker" to deviceId }
        override suspend fun deleteLiveSessionsFor(deviceId: String) { deletedTables += "liveSession" to deviceId }
        override suspend fun deleteDismissedWorkoutsFor(deviceId: String) { deletedTables += "dismissedWorkout" to deviceId }
        override suspend fun deleteDismissedSleepsFor(deviceId: String) { deletedTables += "dismissedSleep" to deviceId }

        // #771 adopt-serial re-key: sample-table re-keys are unmodelled here (no per-table storage in
        // this fake), same as the delete*For no-ops above for those tables. dayOwnership IS modelled
        // ([owners]), so its re-key actually mutates state, mirroring `UPDATE OR IGNORE ... WHERE
        // deviceId = :from` (no PK clash possible since `day`, not `deviceId`, is the row's key).
        override suspend fun reKeyHr(from: String, to: String) {}
        override suspend fun reKeyRr(from: String, to: String) {}
        override suspend fun reKeySpo2(from: String, to: String) {}
        override suspend fun reKeySkinTemp(from: String, to: String) {}
        override suspend fun reKeyResp(from: String, to: String) {}
        override suspend fun reKeyGravity(from: String, to: String) {}
        override suspend fun reKeySteps(from: String, to: String) {}
        override suspend fun reKeyPpgHr(from: String, to: String) {}
        override suspend fun reKeyPpgWaveform(from: String, to: String) {}
        override suspend fun reKeyRawImu(from: String, to: String) {}
        override suspend fun reKeyV18Aux(from: String, to: String) {}
        override suspend fun reKeyEvents(from: String, to: String) {}
        override suspend fun reKeyBattery(from: String, to: String) {}
        override suspend fun reKeyDailyMetrics(from: String, to: String) {}
        override suspend fun reKeySleepSessions(from: String, to: String) {}
        override suspend fun reKeyJournal(from: String, to: String) {}
        override suspend fun reKeyWorkouts(from: String, to: String) {}
        override suspend fun reKeyAppleDaily(from: String, to: String) {}
        override suspend fun reKeyAppleStepHour(from: String, to: String) {}
        override suspend fun reKeyMetricSeries(from: String, to: String) {}
        override suspend fun reKeyDayOwnership(from: String, to: String) {
            for ((day, row) in owners) if (row.deviceId == from) owners[day] = row.copy(deviceId = to)
        }
        override suspend fun reKeySleepStates(from: String, to: String) {}
        override suspend fun reKeyLabMarkers(from: String, to: String) {}
        override suspend fun reKeyLiveSessions(from: String, to: String) {}
        override suspend fun reKeyDismissedWorkouts(from: String, to: String) {}
        override suspend fun reKeyDismissedSleeps(from: String, to: String) {}

        /** The registry row for [id], or null (#771 adopt-serial needs the active row's fields). */
        override suspend fun pairedDevice(id: String): PairedDeviceRow? = devices[id]

        override suspend fun deletePairedDeviceRow(id: String) { devices.remove(id) }
        override suspend fun deleteDeviceRow(id: String) {}
    }

    /** Registry over the fake DAO with a pass-through transactor (Room's withTransaction stand-in). */
    private fun registryWith(dao: FakeRegistryDao) =
        DeviceRegistry(
            dao,
            object : DeviceRegistry.Transactor {
                override suspend fun <R> run(block: suspend () -> R): R = block()
            },
        )

    /** Seed the fake exactly as MIGRATION_7_8 does: `my-whoop`, brand/model WHOOP, liveBLE, active. */
    private fun seededDao(): FakeRegistryDao = FakeRegistryDao().apply {
        devices["my-whoop"] = PairedDeviceRow(
            id = "my-whoop", brand = "WHOOP", model = "WHOOP", nickname = null,
            sourceKind = SourceKind.liveBLE.name,
            capabilities = "hr,hrv,spo2,skinTemp,sleep,strainLoad",
            status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        )
    }

    @Test
    fun seededWhoopIsActive() = runBlocking {
        val reg = registryWith(seededDao())
        val all = reg.all()
        assertEquals(1, all.size)
        assertEquals("my-whoop", all.first().id)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    /** #548: stale registry bits listing calibrated SpO₂ must not surface for a live WHOOP. */
    @Test
    fun allStripsSpo2FromWhoopCapabilities() = runBlocking {
        val reg = registryWith(seededDao())
        val caps = reg.all().first().capabilities
        assertFalse(caps.split(',').contains("spo2"))
        assertTrue(caps.contains("hr"))
        assertTrue(caps.contains("skinTemp"))
    }

    @Test
    fun setActiveDemotesPreviousAndKeepsExactlyOneActive() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        reg.add(
            PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.paired.name, addedAt = 200, lastSeenAt = 200,
            ),
        )

        reg.setActive("polar-1", now = 999)

        assertEquals("polar-1", reg.activeDeviceId())
        val byId = reg.all().associate { it.id to it.status }
        assertEquals(DeviceStatus.active.name, byId["polar-1"])
        assertEquals(DeviceStatus.paired.name, byId["my-whoop"]) // the previously-active device demoted
        // Invariant I1: exactly one active row.
        assertEquals(1, reg.all().count { it.status == DeviceStatus.active.name })
        assertEquals(999L, reg.all().first { it.id == "polar-1" }.lastSeenAt) // promote stamped lastSeenAt
    }

    @Test
    fun archiveKeepsRowAndClearsActive() = runBlocking {
        val reg = registryWith(seededDao())
        reg.archive("my-whoop")
        // I4: the row is kept (not deleted), just archived.
        assertEquals(1, reg.all().size)
        assertEquals(DeviceStatus.archived.name, reg.all().first().status)
        assertNull(reg.activeDeviceId())
    }

    @Test
    fun forgetRemovesRegistryRowAndWipesData() = runBlocking {
        // #1193: unlike archive (row kept, I4) and deleteDeviceData (row kept), forget PURGES the registry
        // entry so a duplicate/stale strap disappears from the list entirely — after wiping its recordings.
        val dao = seededDao()
        val reg = registryWith(dao)
        reg.forget("my-whoop")
        assertTrue(reg.all().isEmpty())                               // registry row purged, not just archived
        assertTrue(dao.deletedTables.any { it.second == "my-whoop" }) // its recorded data was wiped first
    }

    @Test
    fun renameSetsAndClearsNickname() = runBlocking {
        val reg = registryWith(seededDao())
        reg.rename("my-whoop", "  Left wrist  ")
        assertEquals("Left wrist", reg.all().first().nickname) // trimmed
        reg.rename("my-whoop", "   ")
        assertNull(reg.all().first().nickname) // blank clears it
    }

    @Test
    fun deleteDeviceDataKeepsRegistryRowAndClearsOwnership() = runBlocking {
        val reg = registryWith(seededDao())
        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertNotNull(reg.dayOwner("2026-06-15"))

        reg.deleteDeviceData("my-whoop")

        // I4: the pairedDevice registry row is NOT removed by a delete-data op.
        assertEquals(1, reg.all().size)
        assertEquals("my-whoop", reg.all().first().id)
        // dayOwnership rows for the device are cleared (the one table the JVM fake models).
        assertNull(reg.dayOwner("2026-06-15"))
    }

    /**
     * Drift guard — Kotlin twin of the Swift DeviceRegistryStoreTests schema check (which enumerates
     * sqlite_master). No Room instance is available in JVM tests, so this asserts via the DAO's own method
     * surface instead: [DeviceRegistry.deleteDeviceData] must clear ONE deviceId-keyed table per
     * `delete*For(deviceId)` method the DAO exposes. If a new `delete*For` is added (a new deviceId-keyed
     * table) but left unwired from deleteDeviceData, that device's rows would silently survive a
     * "delete all" — this fails until it's wired. Unlike the hardcoded `expectedTables` set below, this
     * can't drift: it reads the DAO surface, not a copy of it. (Java reflection — the project ships no
     * kotlin-reflect.)
     */
    @Test
    fun deleteDeviceDataCallsEveryDaoDeleteMethod() = runBlocking {
        val dao = FakeRegistryDao()
        registryWith(dao).deleteDeviceData("apple-health")

        val daoDeleteMethods = DeviceRegistryDao::class.java.declaredMethods
            .map { it.name }
            .filter { it.startsWith("delete") && it.endsWith("For") }
            .toSet()
        val clearedTables = dao.deletedTables.map { it.first }.toSet()

        assertEquals(
            "deleteDeviceData cleared ${clearedTables.size} tables but the DAO exposes " +
                "${daoDeleteMethods.size} delete*For methods — a deviceId-keyed delete is unwired, so that " +
                "device's rows would survive a delete-all. Add the missing dao.delete…For(id) call to " +
                "DeviceRegistry.deleteDeviceData.",
            daoDeleteMethods.size, clearedTables.size,
        )
    }

    @Test
    fun deleteDeviceDataForAppleHealthFansOutToEveryDeviceScopedTableAndKeepsRegistry() = runBlocking {
        // ah-delete (#616): "Remove Apple Health imported data" calls deleteDeviceData("apple-health").
        // It must clear every deviceId-keyed table for THAT source (not my-whoop) and never touch the
        // pairedDevice registry row. This mirrors the Swift store's deviceScopedTables fan-out.
        val dao = seededDao()
        val reg = registryWith(dao)

        reg.deleteDeviceData("apple-health")

        // EVERY device-keyed table the fan-out must clear (mirrors the Swift store's deviceScopedTables).
        // Keep in sync with the deviceId-keyed @Entity list in Entities.kt — the audit found the last five
        // were missing, leaving raw sleep-state, lab markers, live sessions and dismissed markers behind.
        val expectedTables = setOf(
            "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
            "stepSample", "ppgHrSample", "ppgWaveformSample", "rawImuSample", "v18AuxSample",
            "event", "battery", "dailyMetric", "sleepSession",
            "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
            "scoreInputProvenance",
            "sleepStateSample", "labMarker", "liveSession", "dismissedWorkout", "dismissedSleep",
            // v38-apple-step-hour: hourly Apple-Health steps. No Android importer writes this table, but a
            // `.noopbak` restored from iOS carries its rows — and THIS path is "Remove Apple Health
            // imported data", so leaving them behind would be the plainest form of the defect.
            "appleStepHour",
        )
        assertEquals(expectedTables, dao.deletedTables.map { it.first }.toSet())
        // Every delete was scoped to the requested device, not the seeded my-whoop.
        assertEquals(setOf("apple-health"), dao.deletedTables.map { it.second }.toSet())
        // I4: the pairedDevice registry row is left intact (apple-health is a source, not a device row).
        assertEquals(1, reg.all().size)
        assertEquals("my-whoop", reg.all().first().id)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun seededWhoopHasNoPeripheralIdUntilSet() = runBlocking {
        // The v8→v9 migration adds peripheralId as a nullable column; the seeded "my-whoop" row keeps it
        // NULL until the strap is (re)paired and adopts its address. (MW-1 parity)
        val reg = registryWith(seededDao())
        assertNull(reg.all().first().peripheralId)
        assertNull(reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun setPeripheralIdRoundTrips() = runBlocking {
        val reg = registryWith(seededDao())
        reg.setPeripheralId("my-whoop", "AA:BB:CC:DD:EE:FF")
        assertEquals("AA:BB:CC:DD:EE:FF", reg.all().first().peripheralId)
        // Resolvable back from the address.
        assertEquals("my-whoop", reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF")!!.id)
        // A null clears it (back to "no stored MAC").
        reg.setPeripheralId("my-whoop", null)
        assertNull(reg.all().first().peripheralId)
        assertNull(reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun dayOwnerUpsertAndRead() = runBlocking {
        val reg = registryWith(seededDao())
        assertNull(reg.dayOwner("2000-01-01"))

        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertNotNull(reg.dayOwner("2026-06-15"))
        assertEquals("my-whoop", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(true, reg.dayOwner("2026-06-15")!!.locked)

        // Upsert: re-writing the same day replaces the owner + locked flag (no duplicate row).
        reg.setDayOwner("2026-06-15", "polar-1", locked = false)
        assertEquals("polar-1", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(false, reg.dayOwner("2026-06-15")!!.locked)
    }
}
