package com.noop.data

import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/**
 * The device-registry slice of the DAO (pairedDevice / dayOwnership, schema v8) — the Android port of
 * the Swift `DeviceRegistryStore` reads/writes. Split into its own interface (which [WhoopDao] extends)
 * so [DeviceRegistry] depends on a narrow, easily-faked surface and can be unit-tested on the plain JVM
 * without Room/Robolectric (see DeviceRegistryTest). Room flattens these inherited annotated methods
 * into the concrete @Dao at compile time, so they generate identically to being declared on WhoopDao.
 */
interface DeviceRegistryDao {

    /** All paired devices, oldest first (Swift `all()` ORDER BY addedAt ASC). */
    @Query("SELECT * FROM pairedDevice ORDER BY addedAt ASC")
    suspend fun pairedDevices(): List<PairedDeviceRow>

    /** The single `active` device id, or null if none (e.g. after archiving the only device). */
    @Query("SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1")
    suspend fun activeDeviceId(): String?

    /** Insert-or-replace a device by its id PK (Swift `add`'s ON CONFLICT(id) DO UPDATE upsert). */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertPairedDevice(row: PairedDeviceRow)

    /** Demote whatever device is currently active to `paired`. Half of the single-active swap
     *  (invariant I1); MUST run in the same transaction as [promote] — see [DeviceRegistry.setActive]. */
    @Query("UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
    suspend fun demoteActive()

    /** Promote one device to `active` and stamp its lastSeenAt. Other half of the I1 swap. */
    @Query("UPDATE pairedDevice SET status = 'active', lastSeenAt = :now WHERE id = :id")
    suspend fun promote(id: String, now: Long)

    /** Stamp a device as seen right now. Nothing in the BLE path wrote `lastSeenAt` before #1527 — it was
     *  set only when the row was created or promoted to active — so the Devices card reported
     *  time-since-ADDED, and a strap syncing daily could read "Last seen 45 d ago".
     *
     *  Archived rows are excluded: "Removed - data kept" is a deliberate resting state and a stray connect
     *  must not quietly resurrect one into looking live. Twin of the Swift store's `touchLastSeen`. */
    @Query("UPDATE pairedDevice SET lastSeenAt = :now WHERE id = :id AND status != 'archived'")
    suspend fun touchLastSeen(id: String, now: Long)

    /** Archive a device (keeps the row + its samples — invariant I4). */
    @Query("UPDATE pairedDevice SET status = 'archived' WHERE id = :id")
    suspend fun archiveDevice(id: String)

    /** Rename a device. A null/empty nickname clears it so the UI falls back to brand+model. Mirrors the
     *  Swift store's `UPDATE pairedDevice SET nickname = ? WHERE id = ?`. */
    @Query("UPDATE pairedDevice SET nickname = :nickname WHERE id = :id")
    suspend fun renameDevice(id: String, nickname: String?)

    /** Update the model label for an existing device (e.g. seeded "WHOOP" → "WHOOP 4.0" once the
     *  strap's service family is known from a live BLE connect). Twin of the Swift store's `setModel`. */
    @Query("UPDATE pairedDevice SET model = :model WHERE id = :id")
    suspend fun setModel(id: String, model: String)

    /** Persist (or clear) a device's stable BLE peripheral identifier (the MAC address on Android). Lets
     *  the seeded "my-whoop" adopt its strap's address on first connect and a specific WHOOP confirm its
     *  identity. Twin of the Swift store's `setPeripheralId`. */
    @Query("UPDATE pairedDevice SET peripheralId = :peripheralId WHERE id = :id")
    suspend fun setPeripheralId(id: String, peripheralId: String?)

    /** The paired device whose [peripheralId] matches, or null if none — so a strap discovered by its MAC
     *  address can be resolved back to its registry row. Twin of the Swift store's `deviceForPeripheralId`. */
    @Query("SELECT * FROM pairedDevice WHERE peripheralId = :peripheralId LIMIT 1")
    suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow?

    // MARK: deleteAllData — clear one device's recordings across every deviceId-keyed table.
    //
    // Room has no dynamic table names, so each device-scoped table gets its own DELETE here; the
    // orchestrator [DeviceRegistry.deleteDeviceData] runs them inside one transaction (all-or-nothing).
    // This is the Android twin of the Swift DeviceRegistryStore.deviceScopedTables list. The
    // `pairedDevice` registry row itself is NOT here — a delete-data op empties recordings; archiving /
    // removing the registry entry is a separate op (invariant I4).

    @Query("DELETE FROM hrSample WHERE deviceId = :deviceId") suspend fun deleteHrFor(deviceId: String)
    @Query("DELETE FROM rrInterval WHERE deviceId = :deviceId") suspend fun deleteRrFor(deviceId: String)
    @Query("DELETE FROM spo2Sample WHERE deviceId = :deviceId") suspend fun deleteSpo2For(deviceId: String)
    @Query("DELETE FROM skinTempSample WHERE deviceId = :deviceId") suspend fun deleteSkinTempFor(deviceId: String)
    @Query("DELETE FROM respSample WHERE deviceId = :deviceId") suspend fun deleteRespFor(deviceId: String)
    @Query("DELETE FROM gravitySample WHERE deviceId = :deviceId") suspend fun deleteGravityFor(deviceId: String)
    @Query("DELETE FROM stepSample WHERE deviceId = :deviceId") suspend fun deleteStepsFor(deviceId: String)
    @Query("DELETE FROM ppgHrSample WHERE deviceId = :deviceId") suspend fun deletePpgHrFor(deviceId: String)
    @Query("DELETE FROM ppgWaveformSample WHERE deviceId = :deviceId") suspend fun deletePpgWaveformFor(deviceId: String)
    @Query("DELETE FROM rawImuSample WHERE deviceId = :deviceId") suspend fun deleteRawImuFor(deviceId: String)   // #423
    @Query("DELETE FROM v18AuxSample WHERE deviceId = :deviceId") suspend fun deleteV18AuxFor(deviceId: String)
    @Query("DELETE FROM event WHERE deviceId = :deviceId") suspend fun deleteEventsFor(deviceId: String)
    @Query("DELETE FROM battery WHERE deviceId = :deviceId") suspend fun deleteBatteryFor(deviceId: String)
    @Query("DELETE FROM dailyMetric WHERE deviceId = :deviceId") suspend fun deleteDailyMetricsFor(deviceId: String)
    @Query("DELETE FROM sleepSession WHERE deviceId = :deviceId") suspend fun deleteSleepSessionsFor(deviceId: String)
    @Query("DELETE FROM journal WHERE deviceId = :deviceId") suspend fun deleteJournalFor(deviceId: String)
    @Query("DELETE FROM workout WHERE deviceId = :deviceId") suspend fun deleteWorkoutsFor(deviceId: String)
    @Query("DELETE FROM appleDaily WHERE deviceId = :deviceId") suspend fun deleteAppleDailyFor(deviceId: String)
    // v38-apple-step-hour: no Android importer writes this table, but a `.noopbak` restored FROM iOS
    // carries its rows, so "delete this device's data" must clear them here too — otherwise the hourly
    // step history survives a delete on Android alone (the defect this set exists to close).
    @Query("DELETE FROM appleStepHour WHERE deviceId = :deviceId") suspend fun deleteAppleStepHoursFor(deviceId: String)
    @Query("DELETE FROM metricSeries WHERE deviceId = :deviceId") suspend fun deleteMetricSeriesFor(deviceId: String)
    @Query("DELETE FROM dayOwnership WHERE deviceId = :deviceId") suspend fun deleteDayOwnershipFor(deviceId: String)
    @Query("DELETE FROM scoreInputProvenance WHERE deviceId = :deviceId OR sourceId = :deviceId")
    suspend fun deleteScoreInputProvenanceFor(deviceId: String)
    // Added (audit finding): device-keyed tables the delete set previously missed, so "delete all data"
    // left raw band sleep-state (sleepStateSample), user-entered lab/blood markers (labMarker), live
    // coaching sessions (liveSession) and dismissed workout/sleep markers behind — a privacy defect for a
    // delete-means-gone app. DeviceRegistryTest.deleteDeviceDataCallsEveryDaoDeleteMethod asserts every
    // delete*For DAO method is wired into deleteDeviceData so a future migration can't reintroduce the gap.
    @Query("DELETE FROM sleepStateSample WHERE deviceId = :deviceId") suspend fun deleteSleepStatesFor(deviceId: String)
    @Query("DELETE FROM labMarker WHERE deviceId = :deviceId") suspend fun deleteLabMarkersFor(deviceId: String)
    @Query("DELETE FROM liveSession WHERE deviceId = :deviceId") suspend fun deleteLiveSessionsFor(deviceId: String)
    @Query("DELETE FROM dismissedWorkout WHERE deviceId = :deviceId") suspend fun deleteDismissedWorkoutsFor(deviceId: String)
    @Query("DELETE FROM dismissedSleep WHERE deviceId = :deviceId") suspend fun deleteDismissedSleepsFor(deviceId: String)

    // #771 adopt-serial: re-key one device's rows onto the serial id across every device-scoped table.
    // `UPDATE OR IGNORE` so the canonical (serial) row wins any (deviceId, ts…) primary-key clash; the
    // leftover clashing rows are then cleared by the matching delete*For(from) above. One per table (Room
    // has no dynamic table names) — the SAME table set as deleteDeviceData, guarded by DeviceRegistryTest.
    @Query("UPDATE OR IGNORE hrSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyHr(from: String, to: String)
    @Query("UPDATE OR IGNORE rrInterval SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyRr(from: String, to: String)
    @Query("UPDATE OR IGNORE spo2Sample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeySpo2(from: String, to: String)
    @Query("UPDATE OR IGNORE skinTempSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeySkinTemp(from: String, to: String)
    @Query("UPDATE OR IGNORE respSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyResp(from: String, to: String)
    @Query("UPDATE OR IGNORE gravitySample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyGravity(from: String, to: String)
    @Query("UPDATE OR IGNORE stepSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeySteps(from: String, to: String)
    @Query("UPDATE OR IGNORE ppgHrSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyPpgHr(from: String, to: String)
    @Query("UPDATE OR IGNORE ppgWaveformSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyPpgWaveform(from: String, to: String)
    @Query("UPDATE OR IGNORE rawImuSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyRawImu(from: String, to: String)
    @Query("UPDATE OR IGNORE v18AuxSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyV18Aux(from: String, to: String)
    @Query("UPDATE OR IGNORE event SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyEvents(from: String, to: String)
    @Query("UPDATE OR IGNORE battery SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyBattery(from: String, to: String)
    @Query("UPDATE OR IGNORE dailyMetric SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyDailyMetrics(from: String, to: String)
    @Query("UPDATE OR IGNORE sleepSession SET deviceId = :to WHERE deviceId = :from") suspend fun reKeySleepSessions(from: String, to: String)
    @Query("UPDATE OR IGNORE journal SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyJournal(from: String, to: String)
    @Query("UPDATE OR IGNORE workout SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyWorkouts(from: String, to: String)
    @Query("UPDATE OR IGNORE appleDaily SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyAppleDaily(from: String, to: String)
    @Query("UPDATE OR IGNORE appleStepHour SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyAppleStepHour(from: String, to: String)
    @Query("UPDATE OR IGNORE metricSeries SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyMetricSeries(from: String, to: String)
    @Query("UPDATE OR IGNORE dayOwnership SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyDayOwnership(from: String, to: String)
    @Query("UPDATE OR IGNORE sleepStateSample SET deviceId = :to WHERE deviceId = :from") suspend fun reKeySleepStates(from: String, to: String)
    @Query("UPDATE OR IGNORE labMarker SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyLabMarkers(from: String, to: String)
    @Query("UPDATE OR IGNORE liveSession SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyLiveSessions(from: String, to: String)
    @Query("UPDATE OR IGNORE dismissedWorkout SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyDismissedWorkouts(from: String, to: String)
    @Query("UPDATE OR IGNORE dismissedSleep SET deviceId = :to WHERE deviceId = :from") suspend fun reKeyDismissedSleeps(from: String, to: String)

    /** The registry row for [id], or null. (#771 adopt-serial needs the active row's fields to clone/carry.) */
    @Query("SELECT * FROM pairedDevice WHERE id = :id")
    suspend fun pairedDevice(id: String): PairedDeviceRow?

    /** Drop a registry row / its `device` twin by id (#771: remove the folded-in provisional CB-UUID id). */
    @Query("DELETE FROM pairedDevice WHERE id = :id") suspend fun deletePairedDeviceRow(id: String)
    @Query("DELETE FROM device WHERE id = :id") suspend fun deleteDeviceRow(id: String)

    /** Set the owner override for a day (insert-or-replace by the day PK). */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun setDayOwner(row: DayOwnershipRow)

    /** The owner override for a day, or null if none has been set. */
    @Query("SELECT * FROM dayOwnership WHERE day = :day")
    suspend fun dayOwner(day: String): DayOwnershipRow?
}
