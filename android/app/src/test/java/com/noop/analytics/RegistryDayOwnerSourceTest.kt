package com.noop.analytics

import com.noop.data.DayOwnershipRow
import com.noop.data.DeviceRegistry
import com.noop.data.DeviceRegistryDao
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Phase 1B-4 owner read-through, mirroring the Swift IntelligenceEngine I2 test (two devices share a
 * day → the day is read from exactly ONE owner). This exercises the pure, Room-free seam: the
 * [RegistryDayOwnerSource] priority mapping + the [DayOwnerResolver] it feeds. The full analyzeRecent
 * read-through is the same `DayOwnerResolver.resolve(...)` over these candidates (see IntelligenceEngine
 * .resolveDayOwner), so resolving to one owner here is what makes the engine read one source for the day.
 *
 * No Robolectric: a [DeviceRegistry] over an in-memory fake DAO (same pattern as DeviceRegistryTest).
 */
class RegistryDayOwnerSourceTest {

    /** Minimal in-memory DeviceRegistryDao — only the methods this test exercises hold state. */
    private class FakeDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>()
        val owners = LinkedHashMap<String, DayOwnershipRow>()
        override suspend fun pairedDevices() = devices.values.sortedBy { it.addedAt }
        override suspend fun activeDeviceId() =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id
        override suspend fun upsertPairedDevice(row: PairedDeviceRow) { devices[row.id] = row }
        override suspend fun demoteActive() {
            for ((id, r) in devices) if (r.status == DeviceStatus.active.name)
                devices[id] = r.copy(status = DeviceStatus.paired.name)
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
        override suspend fun renameDevice(id: String, nickname: String?) {}
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
        override suspend fun setDayOwner(row: DayOwnershipRow) { owners[row.day] = row }
        override suspend fun dayOwner(day: String) = owners[day]
        override suspend fun deleteHrFor(deviceId: String) {}
        override suspend fun deleteRrFor(deviceId: String) {}
        override suspend fun deleteSpo2For(deviceId: String) {}
        override suspend fun deleteSkinTempFor(deviceId: String) {}
        override suspend fun deleteRespFor(deviceId: String) {}
        override suspend fun deleteGravityFor(deviceId: String) {}
        override suspend fun deleteStepsFor(deviceId: String) {}
        override suspend fun deletePpgHrFor(deviceId: String) {}
        override suspend fun deletePpgWaveformFor(deviceId: String) {}
        override suspend fun deleteRawImuFor(deviceId: String) {}
        override suspend fun deleteV18AuxFor(deviceId: String) {}
        override suspend fun deleteEventsFor(deviceId: String) {}
        override suspend fun deleteBatteryFor(deviceId: String) {}
        override suspend fun deleteDailyMetricsFor(deviceId: String) {}
        override suspend fun deleteSleepSessionsFor(deviceId: String) {}
        override suspend fun deleteJournalFor(deviceId: String) {}
        override suspend fun deleteWorkoutsFor(deviceId: String) {}
        override suspend fun deleteAppleDailyFor(deviceId: String) {}
        override suspend fun deleteAppleStepHoursFor(deviceId: String) {}
        override suspend fun deleteMetricSeriesFor(deviceId: String) {}
        override suspend fun deleteDayOwnershipFor(deviceId: String) {}
        override suspend fun deleteScoreInputProvenanceFor(deviceId: String) {}
        override suspend fun deleteSleepStatesFor(deviceId: String) {}
        override suspend fun deleteLabMarkersFor(deviceId: String) {}
        override suspend fun deleteLiveSessionsFor(deviceId: String) {}
        override suspend fun deleteDismissedWorkoutsFor(deviceId: String) {}
        override suspend fun deleteDismissedSleepsFor(deviceId: String) {}

        // #771 adopt-serial re-key: sample-table re-keys are unmodelled here (no per-table storage in
        // this fake), same as the delete*For no-ops above. dayOwnership IS modelled ([owners]), so its
        // re-key actually mutates state.
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

        override suspend fun pairedDevice(id: String): PairedDeviceRow? = devices[id]

        override suspend fun deletePairedDeviceRow(id: String) { devices.remove(id) }
        override suspend fun deleteDeviceRow(id: String) {}
    }

    private fun registry(dao: FakeDao) = DeviceRegistry(
        dao,
        object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        },
    )

    private fun device(id: String, brand: String, kind: SourceKind, status: DeviceStatus) =
        PairedDeviceRow(
            id = id, brand = brand, model = brand, nickname = null,
            sourceKind = kind.name, capabilities = "hr,hrv",
            status = status.name, addedAt = 100, lastSeenAt = 100,
        )

    /** Resolve an owner the way IntelligenceEngine.resolveDayOwner does, given which devices have data. */
    private suspend fun resolveWith(
        src: IntelligenceEngine.DayOwnerSource,
        day: String,
        dataByDevice: Map<String, Boolean>,
    ): String? {
        src.lockedOwner(day)?.let { return it }
        val candidates = src.candidatePriorities().map { (id, priority) ->
            DayOwnerResolver.Candidate(id, priority, hasData = dataByDevice[id] ?: false)
        }
        return DayOwnerResolver.resolve(day, lockedOwner = null, candidates = candidates)
    }

    @Test
    fun twoDevicesOneDayResolvesToTheActiveStrapOnly() = runBlocking {
        val dao = FakeDao().apply {
            // Active live strap (priority 0) + an import (priority 2) — both have data for the day.
            devices["my-whoop"] = device("my-whoop", "WHOOP", SourceKind.liveBLE, DeviceStatus.active)
            devices["oura"] = device("oura", "Oura", SourceKind.cloudImport, DeviceStatus.paired)
        }
        val src = RegistryDayOwnerSource(registry(dao))

        // Priorities: active strap 0, import 2.
        val priorities = src.candidatePriorities().toMap()
        assertEquals(0, priorities["my-whoop"])
        assertEquals(2, priorities["oura"])

        // Both have data → exactly ONE owner, the active strap (so the engine reads only its streams).
        val owner = resolveWith(src, "2026-06-15", mapOf("my-whoop" to true, "oura" to true))
        assertEquals("my-whoop", owner)
    }

    @Test
    fun importFillsTheDayWhenTheStrapHasNoData() = runBlocking {
        val dao = FakeDao().apply {
            devices["my-whoop"] = device("my-whoop", "WHOOP", SourceKind.liveBLE, DeviceStatus.active)
            devices["oura"] = device("oura", "Oura", SourceKind.cloudImport, DeviceStatus.paired)
        }
        val src = RegistryDayOwnerSource(registry(dao))
        // Strap collected nothing this day → the import (only candidate with data) owns it.
        val owner = resolveWith(src, "2026-06-15", mapOf("my-whoop" to false, "oura" to true))
        assertEquals("oura", owner)
    }

    @Test
    fun activityFileRideRanksBelowWholeDayImport() = runBlocking {
        // #137: a whole-day WHOOP import (priority 2) and an activity-file ride (priority 3) both have HR
        // for the same strap-less day. The whole-day import must OWN it — a 90-minute ride can never
        // displace a full-day source. Parity with the Swift DayOwnerReadIntegrationTests tie-break test.
        val dao = FakeDao().apply {
            devices["my-whoop"] = device("my-whoop", "WHOOP", SourceKind.liveBLE, DeviceStatus.active)
            devices["whoop-import"] = device("whoop-import", "WHOOP", SourceKind.fileImport, DeviceStatus.paired)
            devices["activity-file"] = device("activity-file", "Workout files", SourceKind.activityFile, DeviceStatus.paired)
        }
        val src = RegistryDayOwnerSource(registry(dao))

        val priorities = src.candidatePriorities().toMap()
        assertEquals(2, priorities["whoop-import"])   // whole-day import
        assertEquals(3, priorities["activity-file"])  // partial ride, ranked below

        // Strap-less day, both imports have data → the whole-day import wins, not the ride.
        val owner = resolveWith(src, "2026-06-15",
            mapOf("my-whoop" to false, "whoop-import" to true, "activity-file" to true))
        assertEquals("whoop-import", owner)
    }

    @Test
    fun lockedOwnerWinsOutright() = runBlocking {
        val dao = FakeDao().apply {
            devices["my-whoop"] = device("my-whoop", "WHOOP", SourceKind.liveBLE, DeviceStatus.active)
            devices["oura"] = device("oura", "Oura", SourceKind.cloudImport, DeviceStatus.paired)
            owners["2026-06-15"] = DayOwnershipRow("2026-06-15", "oura", locked = true)
        }
        val src = RegistryDayOwnerSource(registry(dao))
        // Even though the active strap has data, the locked override pins the day to the import.
        val owner = resolveWith(src, "2026-06-15", mapOf("my-whoop" to true, "oura" to true))
        assertEquals("oura", owner)
    }

    @Test
    fun archivedDeviceIsNotACandidate() = runBlocking {
        val dao = FakeDao().apply {
            devices["my-whoop"] = device("my-whoop", "WHOOP", SourceKind.liveBLE, DeviceStatus.active)
            devices["old"] = device("old", "Polar", SourceKind.liveBLE, DeviceStatus.archived)
        }
        val src = RegistryDayOwnerSource(registry(dao))
        val ids = src.candidatePriorities().map { it.first }
        assertEquals(listOf("my-whoop"), ids) // archived 'old' excluded
        // With only the active strap and it having NO data, there is no owner (honest gap).
        assertNull(resolveWith(src, "2026-06-15", mapOf("my-whoop" to false)))
    }
}
