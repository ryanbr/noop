package com.noop.data

import androidx.room.withTransaction

/**
 * Device-registry façade over [WhoopDao] + [WhoopDatabase] — the Android port of the Swift
 * `DeviceRegistryStore` (Packages/WhoopStore). Owns the device list, the single-active invariant, and
 * the day-ownership override table.
 *
 * Invariant I1 (at most one `active` device) is enforced in [setActive]: the demote+promote pair runs
 * inside one transaction, so a crash mid-swap can never leave two active rows (or none).
 *
 * The transaction boundary is injected as [transactor] (defaulting to Room's `db.withTransaction`) so
 * the registry's logic is exercisable on the plain JVM without a real Room database — mirroring how the
 * rest of the test suite stays Robolectric-free (see DeviceRegistryTest / MoodStoreTest).
 */
class DeviceRegistry(
    private val dao: DeviceRegistryDao,
    private val transactor: Transactor,
) {
    /** A single-transaction boundary. Production wraps Room's `withTransaction`; tests pass through.
     *  Not a `fun interface` — a SAM method may not be generic — so implementors use the object form. */
    interface Transactor {
        suspend fun <R> run(block: suspend () -> R): R
    }

    /** Production constructor: wraps the DAO + Room transaction over [db]. */
    constructor(db: WhoopDatabase) : this(
        dao = db.whoopDao(),
        transactor = object : Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = db.withTransaction { block() }
        },
    )

    /** All paired devices, oldest first. */
    suspend fun all(): List<PairedDeviceRow> = dao.pairedDevices()

    /** The single active device id, or null if none. */
    suspend fun activeDeviceId(): String? = dao.activeDeviceId()

    /** Add (or update) a device. */
    suspend fun add(row: PairedDeviceRow) = dao.upsertPairedDevice(row)

    /**
     * Make [id] the single active device. The demote-old + promote-new pair is ONE transaction so the
     * "exactly one active" invariant (I1) holds even across a crash mid-swap — mirrors the Swift
     * store's single write transaction.
     */
    suspend fun setActive(id: String, now: Long = System.currentTimeMillis() / 1000) {
        transactor.run {
            dao.demoteActive()
            dao.promote(id, now)
        }
    }

    /**
     * #771 (twin of Swift's `DeviceRegistryStore.adoptSerialIdentity`): re-point the ACTIVE Oura device from
     * its transient CoreBluetooth-UUID id ([activeId]) onto its STABLE serial id ([serialId], read from the
     * ring on connect), so a re-pair never orphans history again. Moves ONLY [activeId]'s data + registry row
     * onto [serialId] — a clone when the serial id is new, a carry-over (fresh peripheralId/model, kept
     * active, original addedAt preserved) when a prior pairing already established it. Any OTHER `oura-*` rows
     * (past pairings) are DELIBERATELY left untouched — the agreed scope. One transaction; idempotent (no-op
     * when [activeId] == [serialId] or [activeId] is absent). Returns true when a re-point happened; the
     * caller then `setActive(serialId)` so the spine follows.
     */
    suspend fun adoptSerialIdentity(activeId: String, serialId: String): Boolean {
        if (activeId == serialId) return false
        return transactor.run {
            val active = dao.pairedDevice(activeId) ?: return@run false
            val serial = dao.pairedDevice(serialId)
            if (serial != null) {
                dao.upsertPairedDevice(serial.copy(peripheralId = active.peripheralId, model = active.model,
                                                   status = "active", lastSeenAt = active.lastSeenAt))
            } else {
                dao.upsertPairedDevice(active.copy(id = serialId))
            }
            dao.reKeyHr(activeId, serialId); dao.deleteHrFor(activeId)
            dao.reKeyRr(activeId, serialId); dao.deleteRrFor(activeId)
            dao.reKeySpo2(activeId, serialId); dao.deleteSpo2For(activeId)
            dao.reKeySkinTemp(activeId, serialId); dao.deleteSkinTempFor(activeId)
            dao.reKeyResp(activeId, serialId); dao.deleteRespFor(activeId)
            dao.reKeyGravity(activeId, serialId); dao.deleteGravityFor(activeId)
            dao.reKeySteps(activeId, serialId); dao.deleteStepsFor(activeId)
            dao.reKeyPpgHr(activeId, serialId); dao.deletePpgHrFor(activeId)
            dao.reKeyPpgWaveform(activeId, serialId); dao.deletePpgWaveformFor(activeId)
            dao.reKeyRawImu(activeId, serialId); dao.deleteRawImuFor(activeId)
            dao.reKeyV18Aux(activeId, serialId); dao.deleteV18AuxFor(activeId)
            dao.reKeyEvents(activeId, serialId); dao.deleteEventsFor(activeId)
            dao.reKeyBattery(activeId, serialId); dao.deleteBatteryFor(activeId)
            dao.reKeyDailyMetrics(activeId, serialId); dao.deleteDailyMetricsFor(activeId)
            dao.reKeySleepSessions(activeId, serialId); dao.deleteSleepSessionsFor(activeId)
            dao.reKeyJournal(activeId, serialId); dao.deleteJournalFor(activeId)
            dao.reKeyWorkouts(activeId, serialId); dao.deleteWorkoutsFor(activeId)
            dao.reKeyAppleDaily(activeId, serialId); dao.deleteAppleDailyFor(activeId)
            dao.reKeyMetricSeries(activeId, serialId); dao.deleteMetricSeriesFor(activeId)
            dao.reKeyDayOwnership(activeId, serialId); dao.deleteDayOwnershipFor(activeId)
            dao.reKeySleepStates(activeId, serialId); dao.deleteSleepStatesFor(activeId)
            dao.reKeyLabMarkers(activeId, serialId); dao.deleteLabMarkersFor(activeId)
            dao.reKeyLiveSessions(activeId, serialId); dao.deleteLiveSessionsFor(activeId)
            dao.reKeyDismissedWorkouts(activeId, serialId); dao.deleteDismissedWorkoutsFor(activeId)
            dao.reKeyDismissedSleeps(activeId, serialId); dao.deleteDismissedSleepsFor(activeId)
            dao.deletePairedDeviceRow(activeId)
            dao.deleteDeviceRow(activeId)
            true
        }
    }

    /** Archive a device — keeps its row and samples (invariant I4). */
    suspend fun archive(id: String) = dao.archiveDevice(id)

    /** Update the model label for a device. Mirrors the Swift store's `setModel`. */
    suspend fun setModel(id: String, model: String) = dao.setModel(id, model)

    /** Persist (or clear) a device's stable BLE peripheral identifier (the MAC address on Android). Lets
     *  the seeded "my-whoop" adopt its strap's address on first connect and a specific WHOOP confirm its
     *  identity. Façade over [DeviceRegistryDao.setPeripheralId]; mirrors the Swift store. */
    suspend fun setPeripheralId(id: String, peripheralId: String?) = dao.setPeripheralId(id, peripheralId)

    /** The paired device whose `peripheralId` matches [peripheralId], or null if none — resolves a strap
     *  discovered by its MAC address back to its registry row. Mirrors the Swift store. */
    suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
        dao.deviceForPeripheralId(peripheralId)

    /** Rename a device. A blank [nickname] clears it so the UI falls back to brand+model. Trims
     *  whitespace, mirroring the Swift `DeviceRegistry.rename`. */
    suspend fun rename(id: String, nickname: String?) {
        val trimmed = nickname?.trim()
        dao.renameDevice(id, if (!trimmed.isNullOrEmpty()) trimmed else null)
    }

    /**
     * Permanently delete every recorded sample/derived row for [id] across all deviceId-keyed tables, in
     * ONE transaction (all-or-nothing) — the Android twin of the Swift
     * `DeviceRegistryStore.deleteAllData(deviceId:)`. The `pairedDevice` registry row is left intact: a
     * delete-data op empties recordings; archiving/removing the registry entry is a separate op (I4).
     *
     * The table set is EVERY device-keyed table of [WhoopDatabase]: hrSample, rrInterval, spo2Sample,
     * skinTempSample, respSample, gravitySample, stepSample, ppgHrSample, ppgWaveformSample, event, battery, dailyMetric,
     * sleepSession, journal, workout, appleDaily, metricSeries, dayOwnership, sleepStateSample, labMarker,
     * liveSession, dismissedWorkout, dismissedSleep. DeviceRegistryTest.deleteDeviceDataCallsEveryDaoDeleteMethod
     * guards completeness (fails if a delete*For DAO method isn't wired in here).
     */
    suspend fun deleteDeviceData(id: String) {
        transactor.run {
            dao.deleteHrFor(id)
            dao.deleteRrFor(id)
            dao.deleteSpo2For(id)
            dao.deleteSkinTempFor(id)
            dao.deleteRespFor(id)
            dao.deleteGravityFor(id)
            dao.deleteStepsFor(id)
            dao.deletePpgHrFor(id)
            dao.deletePpgWaveformFor(id)
            dao.deleteRawImuFor(id)   // #423
            dao.deleteV18AuxFor(id)
            dao.deleteEventsFor(id)
            dao.deleteBatteryFor(id)
            dao.deleteDailyMetricsFor(id)
            dao.deleteSleepSessionsFor(id)
            dao.deleteJournalFor(id)
            dao.deleteWorkoutsFor(id)
            dao.deleteAppleDailyFor(id)
            dao.deleteMetricSeriesFor(id)
            dao.deleteDayOwnershipFor(id)
            dao.deleteScoreInputProvenanceFor(id)
            dao.deleteSleepStatesFor(id)
            dao.deleteLabMarkersFor(id)
            dao.deleteLiveSessionsFor(id)
            dao.deleteDismissedWorkoutsFor(id)
            dao.deleteDismissedSleepsFor(id)
        }
    }

    /** Set the owner override for a day (insert-or-replace). */
    suspend fun setDayOwner(day: String, deviceId: String, locked: Boolean) =
        dao.setDayOwner(DayOwnershipRow(day = day, deviceId = deviceId, locked = locked))

    /** The owner override for a day, or null if none. */
    suspend fun dayOwner(day: String): DayOwnershipRow? = dao.dayOwner(day)
}
