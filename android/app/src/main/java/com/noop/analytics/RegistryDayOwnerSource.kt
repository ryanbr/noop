package com.noop.analytics

import com.noop.data.DeviceRegistry
import com.noop.data.DeviceStatus
import com.noop.data.SourceKind
import com.noop.protocol.DeviceFamily

/**
 * [IntelligenceEngine.DayOwnerSource] backed by the [DeviceRegistry] (Phase 1B-4). Supplies the engine
 * with the per-day owner-resolution inputs so a day is scored from exactly ONE device (invariant I2),
 * without giving the pure-JVM engine a Room dependency.
 *
 * Priorities mirror the Swift IntelligenceEngine.resolveDayOwner for current sources, with priority 4
 * reserved for archived devices. Archived rows remain read-only historical candidates so removing and
 * later re-adding a strap cannot erase its earlier physiological boundary/coverage; every current live,
 * import, and activity source still wins an overlap. With only the seeded active 'my-whoop' row paired
 * (the default and every single-WHOOP install), the sole candidate is priority 0, so reads stay identical.
 */
class RegistryDayOwnerSource(private val registry: DeviceRegistry) : IntelligenceEngine.DayOwnerSource {

    override suspend fun candidatePriorities(): List<Pair<String, Int>> {
        val activeId = registry.activeDeviceId()
        return registry.all()
            .map { d ->
                val isImport = d.sourceKind == SourceKind.cloudImport.name ||
                    d.sourceKind == SourceKind.fileImport.name
                // #137: an activity-file ride ranks BELOW whole-day imports (priority 3 vs 2), so a
                // full-day WHOOP CSV/cloud import keeps ownership of a day it has HR for; the ride only
                // wins a day nothing else covers. Mirrors Swift IntelligenceEngine.resolveDayOwner.
                val priority = when {
                    d.id == activeId -> 0
                    d.status == DeviceStatus.archived.name -> 4
                    d.sourceKind == SourceKind.activityFile.name -> 3
                    isImport -> 2
                    else -> 1
                }
                d.id to priority
            }
    }

    // Any dayOwnership override wins outright, regardless of its `locked` flag — matching the Swift
    // `(try? registry.dayOwner(day))?.deviceId` read in IntelligenceEngine.resolveDayOwner, which uses
    // the stored owner as an authoritative override (the `locked` flag gates the UI, not the read).
    override suspend fun lockedOwner(day: String): String? = registry.dayOwner(day)?.deviceId

    // CAPTURE-B: the registry's active strap id, for the universal dayOwner diagnostic's writeActiveId.
    // This is the SAME id the live read path resolves to (BLEManager/AppModel's activeDeviceId), so the
    // universal line can prove the read owner and the write target are the same device (or surface it
    // when they diverge, the #814/#799 spine symptom).
    override suspend fun activeWriteId(): String? = registry.activeDeviceId()

    // #938: resolve the strap family that wrote [deviceId]'s rows from its registry model. The model-label
    // → family mapping (and the WHOOP5 fallback for unknowns) lives in DeviceFamily.forRegistryDevice (#171, #1086).
    // Mirrors the Swift IntelligenceEngine.skinTempFamily(forOwner:devices:).
    override suspend fun skinTempFamily(deviceId: String): DeviceFamily {
        val d = registry.all().firstOrNull { it.id == deviceId }
        // Non-WHOOP device (null) shares the non-4.0 temp scale, so coalesce to WHOOP5 — same conversion
        // as before; brand-awareness just stops it claiming to be a WHOOP (#1086).
        return DeviceFamily.forRegistryDevice(d?.model, d?.brand) ?: DeviceFamily.WHOOP5
    }

    // #1005: the UN-coalesced registered WHOOP family (null for a non-WHOOP owner), for the reuse-cache
    // eligibility gate. Same registry lookup as skinTempFamily but WITHOUT the WHOOP5 fallback, so a ring /
    // import / unknown owner resolves to null and is never cached. Mirrors the Swift reuse gate's inline
    // DeviceFamily.forRegistryDevice(model:brand:).
    override suspend fun registeredWhoopFamily(deviceId: String): DeviceFamily? {
        val d = registry.all().firstOrNull { it.id == deviceId }
        return DeviceFamily.forRegistryDevice(d?.model, d?.brand)
    }

    // #1467: the worn-gate timestamp tolerance for this owner (0 for WHOOP, byte-identical). Same
    // registry lookup skinTempFamily uses; deliberately its own small helper rather than folding into
    // DeviceFamily, which has no Oura case (#1086) and a tolerance-in-seconds isn't a temperature-scale
    // concern. Mirrors the Swift IntelligenceEngine.skinTempWornToleranceSec(forOwner:devices:).
    override suspend fun skinTempWornToleranceSec(deviceId: String): Long {
        val d = registry.all().firstOrNull { it.id == deviceId }
        return if (d?.brand == "Oura") AnalyticsEngine.DEFAULT_OURA_WORN_TOLERANCE_SEC else 0
    }
}
