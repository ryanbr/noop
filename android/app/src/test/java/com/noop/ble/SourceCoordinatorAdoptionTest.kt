package com.noop.ble

import com.noop.data.DayOwnershipRow
import com.noop.data.DeviceRegistry
import com.noop.data.DeviceRegistryDao
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SourceCoordinator.connectedPeripheralChanged] identity-adoption + GUARD tests — the Kotlin twin of the
 * macOS `SourceCoordinator.connectedPeripheralChanged(to:)` behaviour (Strand/BLE/SourceCoordinator.swift
 * 213-231). The critical assertion is the different-strap guard: a strap whose address differs from the
 * active WHOOP row's already-adopted `peripheralId` must NEVER overwrite it (that would mis-map another
 * physical strap's samples onto this device's row).
 *
 * Harness mirrors DeviceRegistryTest: the project ships NO mocking framework and NO Robolectric (junit +
 * kotlinx-coroutines-test only — see app/build.gradle.kts), so this runs the REAL [DeviceRegistry] over an
 * in-memory [FakeRegistryDao] (the DAO's SQL semantics reproduced by hand). The coordinator's Android-only
 * deps ([context]/[repository]) are passed null — only [switchToStrap] touches them, and the adoption path
 * never reaches it. [Dispatchers.Unconfined] makes `scope.launch { … }` run eagerly inside `runBlocking`,
 * so the registry write is observable synchronously after the call.
 */
class SourceCoordinatorAdoptionTest {

    /** In-memory [DeviceRegistryDao] (same reproduction as DeviceRegistryTest, trimmed to what's used). */
    private class FakeRegistryDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>()
        val owners = LinkedHashMap<String, DayOwnershipRow>()

        override suspend fun pairedDevices(): List<PairedDeviceRow> = devices.values.sortedBy { it.addedAt }
        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id
        override suspend fun upsertPairedDevice(row: PairedDeviceRow) { devices[row.id] = row }
        override suspend fun demoteActive() {
            for ((id, row) in devices) if (row.status == DeviceStatus.active.name) {
                devices[id] = row.copy(status = DeviceStatus.paired.name)
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
        override suspend fun setPeripheralId(id: String, peripheralId: String?) {
            devices[id]?.let { devices[id] = it.copy(peripheralId = peripheralId) }
        }
        override suspend fun touchLastSeen(id: String, now: Long) {
            // Reproduces the query's `AND status != 'archived'` guard.
            devices[id]?.let {
                if (it.status != DeviceStatus.archived.name) devices[id] = it.copy(lastSeenAt = now)
            }
        }
        override suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
            devices.values.firstOrNull { it.peripheralId == peripheralId }
        override suspend fun setDayOwner(row: DayOwnershipRow) { owners[row.day] = row }
        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]

        // Sample-table deletes are unmodelled here (validated by the Room-backed integration).
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
        override suspend fun deleteSleepStatesFor(deviceId: String) {}
        override suspend fun deleteLabMarkersFor(deviceId: String) {}
        override suspend fun deleteLiveSessionsFor(deviceId: String) {}
        override suspend fun deleteDismissedWorkoutsFor(deviceId: String) {}
        override suspend fun deleteDismissedSleepsFor(deviceId: String) {}
        override suspend fun deleteDayOwnershipFor(deviceId: String) {
            owners.entries.removeIf { it.value.deviceId == deviceId }
        }
        override suspend fun deleteScoreInputProvenanceFor(deviceId: String) {}

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

    private fun registryWith(dao: FakeRegistryDao) = DeviceRegistry(
        dao,
        object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        },
    )

    /** A WHOOP row seeded active, with the given [peripheralId] (null = not yet adopted). */
    private fun whoopRow(id: String, peripheralId: String?) = PairedDeviceRow(
        id = id, brand = "WHOOP", model = "WHOOP", nickname = null,
        sourceKind = SourceKind.liveBLE.name, capabilities = "hr",
        status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        peripheralId = peripheralId,
    )

    private fun strapRow(id: String, peripheralId: String) = PairedDeviceRow(
        id = id, brand = "Polar", model = "H10", nickname = null,
        sourceKind = SourceKind.liveBLE.name, capabilities = "hr",
        status = DeviceStatus.paired.name, addedAt = 200, lastSeenAt = 200,
        peripheralId = peripheralId,
    )

    private fun coordinatorOver(dao: FakeRegistryDao, log: (String) -> Unit = {}): SourceCoordinator =
        SourceCoordinator(
            context = null,                       // adoption path never reaches switchToStrap
            registry = registryWith(dao),
            repository = null,                    // same
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined), // launch runs eagerly inside runBlocking
            log = log,
        )

    /** A coordinator that counts the WHOOP start/stop churn, for the make-active adopt-in-place tests. */
    private fun churnCountingCoordinator(
        dao: FakeRegistryDao,
        starts: () -> Unit,
        stops: () -> Unit,
    ): SourceCoordinator = SourceCoordinator(
        context = null,
        registry = registryWith(dao),
        repository = null,
        liveSink = { _, _ -> },
        startWhoop = starts,
        stopWhoop = stops,
        scope = CoroutineScope(Dispatchers.Unconfined),
    )

    private fun ouraAdoptionCoordinatorOver(dao: FakeRegistryDao): SourceCoordinator = SourceCoordinator(
        context = null,
        registry = registryWith(dao),
        repository = null,
        liveSink = { _, _ -> },
        startWhoop = {},
        stopWhoop = {},
        scope = CoroutineScope(Dispatchers.Unconfined),
        migrateOuraInstallKey = { _, _ -> },
    )

    @Test
    fun awaitedReconcileReturnsTrueAfterSuccessIncludingSameId() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["whoop-a"] = whoopRow("whoop-a", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        val coordinator = coordinatorOver(dao)

        assertNull(coordinator.activeDeviceId.value)
        assertTrue(coordinator.reconcileActiveDevice("whoop-a"))
        assertEquals("whoop-a", coordinator.activeDeviceId.value)
        assertTrue("an already-reconciled id is still a successful completion", coordinator.reconcileActiveDevice("whoop-a"))
        assertEquals("same-id success must keep the single published source stable", "whoop-a", coordinator.activeDeviceId.value)
    }

    @Test
    fun awaitedReconcileReturnsFalseWhenStrapActivationFails() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["whoop-a"] = whoopRow("whoop-a", peripheralId = "AA:BB:CC:DD:EE:01")
            devices["polar-b"] = strapRow("polar-b", peripheralId = "11:22:33:44:55:66")
        }
        val coordinator = coordinatorOver(dao)

        assertTrue(coordinator.reconcileActiveDevice("whoop-a"))
        assertEquals("whoop-a", coordinator.activeDeviceId.value)
        assertFalse(
            "completion must report the context-less makeSource activation failure",
            coordinator.reconcileActiveDevice("polar-b"),
        )
        assertEquals("a failed switch must never publish its requested id", "whoop-a", coordinator.activeDeviceId.value)
    }

    @Test
    fun ouraSerialAdoptionPublishesReconciledStableId() = runBlocking {
        val transientId = "oura-transient-address"
        val stableId = "oura-S12345678"
        val dao = FakeRegistryDao().apply {
            // The direct adoption callback is under test. A liveBLE-shaped row keeps this plain-JVM
            // harness off Android BLE while exercising the real registry re-key + internal reconcile.
            devices[transientId] = whoopRow(transientId, peripheralId = "AA:BB:CC:DD:EE:01")
        }
        val coordinator = ouraAdoptionCoordinatorOver(dao)
        assertTrue(coordinator.reconcileActiveDevice(transientId))
        assertEquals(transientId, coordinator.activeDeviceId.value)

        SourceCoordinator::class.java
            .getDeclaredMethod("adoptOuraSerial", String::class.java, String::class.java)
            .apply { isAccessible = true }
            .invoke(coordinator, transientId, "S12345678")

        assertEquals(stableId, dao.activeDeviceId())
        assertEquals(
            "the Oura-internal A→S path must reach the same success-only publication as UI selection",
            stableId,
            coordinator.activeDeviceId.value,
        )
    }

    @Test
    fun nullPeripheralIdRowAdoptsConnectedAddress() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
    }

    @Test
    fun matchingAddressIsANoOp() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        // Same strap reconnecting (case-insensitive match) — nothing written, nothing logged.
        coordinator.connectedPeripheralChanged("aa:bb:cc:dd:ee:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertNull("matching address must not log a different-strap notice", logged)
    }

    @Test
    fun differentStrapDoesNotOverwriteAndLogs() = runBlocking {
        // The GUARD: the active WHOOP row already adopted ...:01; a DIFFERENT strap ...:02 connects.
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:02")

        // Stored identity is UNCHANGED — the other strap's address never lands on this row.
        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        // And the mismatch is logged with the exact macOS wording.
        assertEquals(
            "Multi-WHOOP: active device my-whoop is registered to strap AA:BB:CC:DD:EE:01 but " +
                "AA:BB:CC:DD:EE:02 connected — not overwriting.",
            logged,
        )
    }

    @Test
    fun nullAddressIsIgnored() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged(null) // a disconnect republish

        assertNull(dao.devices["my-whoop"]!!.peripheralId) // nothing adopted
    }

    @Test
    fun nonWhoopActiveDeviceIsIgnored() = runBlocking {
        // A generic strap is the active device — this WHOOP-side connection isn't ours; do not touch it.
        val dao = FakeRegistryDao().apply {
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.active.name, addedAt = 200, lastSeenAt = 200,
                peripheralId = null,
            )
        }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertNull("a generic-strap active row must not adopt a WHOOP connection's address",
            dao.devices["polar-1"]!!.peripheralId)
        assertTrue(dao.devices.size == 1)
    }

    // ── make-active adopt-in-place (#74 keep) ───────────────────────────────────
    // switchToWhoop: activating a WHOOP row that is the SAME physical strap already connected must NOT
    // churn the link (no stopWhoop/startWhoop) - a churn there would drop the kept live link and force a
    // scan reconnect. Activating a DIFFERENT WHOOP must still churn.

    /** Seed two ACTIVE-capable WHOOP rows sharing the dao; only [activeId] is marked active. */
    private fun daoWithTwoWhoops(
        activeId: String,
        activePeripheral: String?,
        otherId: String,
        otherPeripheral: String?,
    ): FakeRegistryDao = FakeRegistryDao().apply {
        devices[activeId] = whoopRow(activeId, activePeripheral)
        // the other row is paired (not active) until we promote it
        devices[otherId] = whoopRow(otherId, otherPeripheral).copy(status = DeviceStatus.paired.name)
    }

    @Test
    fun makeActiveSameStrapAdoptsInPlaceWithoutChurn() = runBlocking {
        // Two WHOOP rows for the SAME physical strap (pick-same-strap Add flow): identical peripheralId.
        val dao = daoWithTwoWhoops(
            activeId = "my-whoop", activePeripheral = "AA:BB:CC:DD:EE:01",
            otherId = "whoop-aabbccddee01", otherPeripheral = "AA:BB:CC:DD:EE:01",
        )
        var starts = 0
        var stops = 0
        val coordinator = churnCountingCoordinator(dao, starts = { starts++ }, stops = { stops++ })

        coordinator.start()                                     // first WHOOP activation, no churn
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01") // link is live on this strap
        // Make the second (same-strap) row active, then reconcile it.
        dao.demoteActive(); dao.promote("whoop-aabbccddee01", 200)
        coordinator.onActiveDeviceChanged("whoop-aabbccddee01")

        assertEquals("same-strap make-active must not stop the live link", 0, stops)
        assertEquals("same-strap make-active must not rescan", 0, starts)
    }

    @Test
    fun makeActiveDifferentStrapStillChurns() = runBlocking {
        // Two WHOOP rows for DIFFERENT physical straps: switching must drop + reconnect.
        val dao = daoWithTwoWhoops(
            activeId = "my-whoop", activePeripheral = "AA:BB:CC:DD:EE:01",
            otherId = "whoop-aabbccddee02", otherPeripheral = "AA:BB:CC:DD:EE:02",
        )
        var starts = 0
        var stops = 0
        val coordinator = churnCountingCoordinator(dao, starts = { starts++ }, stops = { stops++ })

        coordinator.start()
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        dao.demoteActive(); dao.promote("whoop-aabbccddee02", 200)
        coordinator.onActiveDeviceChanged("whoop-aabbccddee02")

        assertEquals("a different WHOOP must drop the current link", 1, stops)
        assertEquals("a different WHOOP must reconnect", 1, starts)
    }

    // MARK: - "Last seen" is stamped by the link, not by the wizard (#1527)

    /**
     * The regression: a strap that connects must move `lastSeenAt`. Nothing in the BLE path wrote the
     * column before this, so the Devices card reported time-since-ADDED and a strap syncing every day
     * read "Last seen 45 d ago".
     */
    @Test
    fun aConnectStampsTheActiveRowAsSeen() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        coordinatorOver(dao).connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        assertTrue("a connect must move lastSeenAt off its seeded value",
                   dao.devices["my-whoop"]!!.lastSeenAt > 100)
    }

    /** A first connect adopts the identity AND records the sighting — the two are the same event. */
    @Test
    fun aFirstConnectAdoptsTheIdentityAndStamps() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null)
        }
        coordinatorOver(dao).connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertTrue(dao.devices["my-whoop"]!!.lastSeenAt > 100)
    }

    /**
     * The disconnect edge stamps too. Without it the card would report the time of the CONNECT, so an
     * overnight session would read "Last seen 10 h ago" the instant the link dropped. The connect stamp is
     * rewound here so the assertion can only pass on the disconnect's own write.
     */
    @Test
    fun aDisconnectStampsTheRowAsSeenRatherThanLeavingTheConnectTime() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        val coordinator = coordinatorOver(dao)
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        dao.devices["my-whoop"] = dao.devices["my-whoop"]!!.copy(lastSeenAt = 100)   // rewind the connect stamp
        coordinator.connectedPeripheralChanged(null)
        assertTrue("the disconnect edge must stamp the row itself",
                   dao.devices["my-whoop"]!!.lastSeenAt > 100)
    }

    /** A null republish with no live link is not a sighting — nothing was ever connected to record. */
    @Test
    fun aNullWithNoPriorConnectIsNotASighting() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        coordinatorOver(dao).connectedPeripheralChanged(null)
        assertEquals(100, dao.devices["my-whoop"]!!.lastSeenAt)
    }

    /**
     * The guard that matters on a multi-WHOOP install: a DIFFERENT strap connecting under this row must
     * neither overwrite its identity nor claim to be a sighting OF IT. Same reasoning as the peripheralId
     * guard above — that strap is not this row.
     */
    @Test
    fun aDifferentStrapDoesNotStampThisRow() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        coordinatorOver(dao).connectedPeripheralChanged("AA:BB:CC:DD:EE:99")
        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertEquals(100, dao.devices["my-whoop"]!!.lastSeenAt)
    }

    /**
     * The disconnect stamps the strap that was CONNECTED, not whatever is active by the time it drops.
     * Make another WHOOP active while this one is live — a multi-WHOOP install can — and resolving "the
     * active row" would record a sighting of a strap nobody connected. That is the same mis-mapping the
     * peripheralId guard exists to prevent, so the disconnect resolves by adopted identity instead.
     */
    @Test
    fun theDisconnectStampsTheStrapThatWasConnectedNotWhateverIsActiveNow() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["whoop-a"] = whoopRow("whoop-a", peripheralId = "AA:BB:CC:DD:EE:01")
            devices["whoop-b"] = whoopRow("whoop-b", peripheralId = "AA:BB:CC:DD:EE:02")
                .copy(status = DeviceStatus.paired.name)
        }
        val coordinator = coordinatorOver(dao)
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        // whoop-b becomes active while whoop-a is still the live link; rewind both stamps so the
        // assertions can only be satisfied by the disconnect's own write.
        dao.devices["whoop-a"] = dao.devices["whoop-a"]!!.copy(
            status = DeviceStatus.paired.name, lastSeenAt = 100)
        dao.devices["whoop-b"] = dao.devices["whoop-b"]!!.copy(
            status = DeviceStatus.active.name, lastSeenAt = 100)

        coordinator.connectedPeripheralChanged(null)

        assertTrue("the strap that was connected must be the one stamped",
                   dao.devices["whoop-a"]!!.lastSeenAt > 100)
        assertEquals("a strap that was never connected must not be stamped",
                     100, dao.devices["whoop-b"]!!.lastSeenAt)
    }

    /**
     * The disconnect must resolve identity the way the connect path does. That comparison is
     * `ignoreCase` — a stored address differing only in case is the SAME strap to the adopt guard — so a
     * stricter lookup here would adopt on connect and then quietly stamp nothing on disconnect.
     */
    @Test
    fun aDisconnectResolvesTheStrapCaseInsensitivelyLikeTheAdoptGuard() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "aa:bb:cc:dd:ee:01")
        }
        val coordinator = coordinatorOver(dao)
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")   // same strap, upper-cased
        dao.devices["my-whoop"] = dao.devices["my-whoop"]!!.copy(lastSeenAt = 100)
        coordinator.connectedPeripheralChanged(null)
        assertTrue("a case-different address is the same strap to the adopt guard, so it must stamp",
                   dao.devices["my-whoop"]!!.lastSeenAt > 100)
    }

    /** An address no row has adopted stamps nothing rather than guessing at the active row. */
    @Test
    fun aDisconnectFromAnUnadoptedStrapStampsNothing() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        val coordinator = coordinatorOver(dao)
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:77")   // different strap, never adopted
        dao.devices["my-whoop"] = dao.devices["my-whoop"]!!.copy(lastSeenAt = 100)
        coordinator.connectedPeripheralChanged(null)
        assertEquals(100, dao.devices["my-whoop"]!!.lastSeenAt)
    }

    /**
     * "Removed - data kept" is a deliberate resting state: a stray connect must not quietly resurrect an
     * archived row into looking live. The real guard is the query's `AND status != 'archived'`; the fake
     * reproduces it, so this pins the CONTRACT callers rely on rather than Room's SQL.
     */
    @Test
    fun anArchivedRowIsNotStamped() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["old-whoop"] = whoopRow("old-whoop", peripheralId = "AA:BB:CC:DD:EE:02")
                .copy(status = DeviceStatus.archived.name)
        }
        registryWith(dao).touchLastSeen("old-whoop")
        assertEquals(100, dao.devices["old-whoop"]!!.lastSeenAt)
    }
}
