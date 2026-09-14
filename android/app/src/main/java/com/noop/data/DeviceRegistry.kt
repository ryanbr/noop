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
    suspend fun all(): List<PairedDeviceRow> =
        dao.pairedDevices().map { honestWhoopCapabilities(it) }

    /**
     * #548: calibrated SpO₂ % is never produced from a live WHOOP path — drop a stale registry bit so
     * Devices / day-owner UI never advertise a capability AnalyticsEngine will not fill. Twin of the
     * Swift `DeviceRegistryStore.decode` strip.
     */
    private fun honestWhoopCapabilities(row: PairedDeviceRow): PairedDeviceRow {
        val isWhoop = row.brand.equals("WHOOP", ignoreCase = true)
            || row.id == "my-whoop"
            || row.id.startsWith("whoop-")
        if (!isWhoop) return row
        val stripped = WhoopLiveCapabilities.stripSpo2Token(row.capabilities)
        return if (stripped == row.capabilities) row else row.copy(capabilities = stripped)
    }

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
            // BOTH id shapes. Every strap also owns a COMPUTED sibling keyed `<deviceId>-noop` (see
            // WhoopRepository.computedDeviceId) holding the scored days, detected workouts and metric
            // series the engine derives. That id never equals activeId, so re-keying only the pairing's
            // own id left the computed history stranded under an id nothing reads again while the next
            // scoring pass wrote under `<serialId>-noop` — the orphaned history this adoption exists to
            // prevent, displaced onto the computed half. A ring has no computed sibling, which is why the
            // shipped Oura path never surfaced it.
            reKeyDeviceScopedRows(activeId, serialId)
            reKeyDeviceScopedRows(activeId + COMPUTED_SUFFIX, serialId + COMPUTED_SUFFIX)
            dao.deletePairedDeviceRow(activeId)
            dao.deleteDeviceRow(activeId)
            true
        }
    }

    /** Stamp a device as seen right now — a real connect or disconnect, not every inbound packet, which
     *  would be a write per second for no more truth. Twin of Swift `DeviceRegistry.touchLastSeen`. (#1527) */
    suspend fun touchLastSeen(id: String, now: Long = System.currentTimeMillis() / 1000) =
        dao.touchLastSeen(id, now)

    /** Suffix of the COMPUTED sibling every device id owns; twin of `WhoopRepository.computedDeviceId`
     *  and the Swift `DeviceRegistryStore.computedSuffix`. */
    private val COMPUTED_SUFFIX = "-noop"

    /** Move every device-scoped row from [from] onto [to], canonical winning a PK clash, then clear the
     *  source. Registry rows are deliberately NOT touched here: a computed sibling has none, so the
     *  pairedDevice/device deletions stay with the caller and run once, for the real pairing only. */
    private suspend fun reKeyDeviceScopedRows(from: String, to: String) {
        dao.reKeyHr(from, to); dao.deleteHrFor(from)
        dao.reKeyRr(from, to); dao.deleteRrFor(from)
        dao.reKeySpo2(from, to); dao.deleteSpo2For(from)
        dao.reKeySkinTemp(from, to); dao.deleteSkinTempFor(from)
        dao.reKeyResp(from, to); dao.deleteRespFor(from)
        dao.reKeyGravity(from, to); dao.deleteGravityFor(from)
        dao.reKeySteps(from, to); dao.deleteStepsFor(from)
        dao.reKeyPpgHr(from, to); dao.deletePpgHrFor(from)
        dao.reKeyPpgWaveform(from, to); dao.deletePpgWaveformFor(from)
        dao.reKeyV18Aux(from, to); dao.deleteV18AuxFor(from)
        dao.reKeyEvents(from, to); dao.deleteEventsFor(from)
        dao.reKeyBattery(from, to); dao.deleteBatteryFor(from)
        dao.reKeyDailyMetrics(from, to); dao.deleteDailyMetricsFor(from)
        dao.reKeySleepSessions(from, to); dao.deleteSleepSessionsFor(from)
        dao.reKeyJournal(from, to); dao.deleteJournalFor(from)
        dao.reKeyWorkouts(from, to); dao.deleteWorkoutsFor(from)
        dao.reKeyAppleDaily(from, to); dao.deleteAppleDailyFor(from)
        dao.reKeyAppleStepHour(from, to); dao.deleteAppleStepHoursFor(from)
        dao.reKeyMetricSeries(from, to); dao.deleteMetricSeriesFor(from)
        dao.reKeyDayOwnership(from, to); dao.deleteDayOwnershipFor(from)
        dao.reKeySleepStates(from, to); dao.deleteSleepStatesFor(from)
        dao.reKeyLabMarkers(from, to); dao.deleteLabMarkersFor(from)
        dao.reKeyLiveSessions(from, to); dao.deleteLiveSessionsFor(from)
        dao.reKeyDismissedWorkouts(from, to); dao.deleteDismissedWorkoutsFor(from)
        dao.reKeyDismissedSleeps(from, to); dao.deleteDismissedSleepsFor(from)
        dao.reKeyLiftExercises(from, to); dao.deleteLiftExercisesFor(from)
        dao.reKeyLiftPrograms(from, to); dao.deleteLiftProgramsFor(from)
        dao.reKeyLiftProgramItems(from, to); dao.deleteLiftProgramItemsFor(from)
        dao.reKeyLiftSessions(from, to); dao.deleteLiftSessionsFor(from)
        dao.reKeyLiftSets(from, to); dao.deleteLiftSetsFor(from)
    }

    /** Archive a device — keeps its row and samples (invariant I4). */
    suspend fun archive(id: String) = dao.archiveDevice(id)

    /**
     * Permanently FORGET a device: wipe all of its recorded data AND remove its registry entry (both the
     * `pairedDevice` row the Devices screen lists and its `device` provenance row), so a duplicate/stale
     * strap can be purged entirely instead of lingering in the archived "Removed" list forever (#1193).
     * Twin of the Swift `DeviceRegistry.forget`. The data wipe runs first (its own transaction, via
     * [deleteDeviceData]), then the small registry-row deletes — registry entry vs. recordings are separate
     * ops, exactly as [adoptSerialIdentity] treats them.
     */
    suspend fun forget(id: String) {
        deleteDeviceData(id)
        transactor.run {
            dao.deletePairedDeviceRow(id)
            dao.deleteDeviceRow(id)
        }
    }

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
            dao.deleteV18AuxFor(id)
            dao.deleteEventsFor(id)
            dao.deleteBatteryFor(id)
            dao.deleteDailyMetricsFor(id)
            dao.deleteSleepSessionsFor(id)
            dao.deleteJournalFor(id)
            dao.deleteWorkoutsFor(id)
            dao.deleteAppleDailyFor(id)
            dao.deleteAppleStepHoursFor(id)
            dao.deleteMetricSeriesFor(id)
            dao.deleteDayOwnershipFor(id)
            dao.deleteScoreInputProvenanceFor(id)
            dao.deleteSleepStatesFor(id)
            dao.deleteLabMarkersFor(id)
            dao.deleteLiveSessionsFor(id)
            dao.deleteDismissedWorkoutsFor(id)
            dao.deleteDismissedSleepsFor(id)
            dao.deleteLiftExercisesFor(id)
            dao.deleteLiftProgramsFor(id)
            dao.deleteLiftProgramItemsFor(id)
            dao.deleteLiftSessionsFor(id)
            dao.deleteLiftSetsFor(id)
        }
    }

    /** Set the owner override for a day (insert-or-replace). */
    suspend fun setDayOwner(day: String, deviceId: String, locked: Boolean) =
        dao.setDayOwner(DayOwnershipRow(day = day, deviceId = deviceId, locked = locked))

    /** The owner override for a day, or null if none. */
    suspend fun dayOwner(day: String): DayOwnershipRow? {
        // Timed here rather than at the call site, matching the other per-day probes: the resolver that
        // drives these sits inside `analyzeRecentOnCpu`, which has no ratchet margin for a stopwatch.
        // See StoreProbeTally. Instrumentation only.
        val started = System.nanoTime()
        val row = dao.dayOwner(day)
        com.noop.analytics.StoreProbeTally.recordDayOwner(System.nanoTime() - started)
        return row
    }
}
