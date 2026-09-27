package com.noop.ble

/**
 * Which "last sync" timestamp belongs to a strap, given what is known about it.
 *
 * The same bug [resolveFirmware] fixed for firmware, in the field again and reported three times before
 * it was believed. `noop.lastSyncAtSec` is ONE global key, stamped on any strap's HISTORY_COMPLETE and
 * read back for whichever strap is active. On a single-strap install those are the same strap, which is
 * why it went unnoticed. With two paired it reports the OTHER strap's sync: a capture showing
 * "Last sync: 4d ago" beside `Days: whoop-MGB…=0` and a 4.0 last seen 3 days earlier — the 5/MG had never
 * banked a single row, and the number on its screen was the 4.0's.
 *
 * Worse than merely wrong: it is wrong in the reassuring direction. A strap that has never synced reads
 * as recently synced, and the pull-to-refresh that cannot possibly change it looks broken rather than
 * inapplicable. It sent this investigation after a "sync regression" that never existed.
 *
 * The rule, in order:
 *  - [perDevice] wins: this strap's own stamp, from its own completed offload.
 *  - [legacyGlobal] ONLY when [pairedCount] is 1. The old key cannot say which strap it belongs to, so
 *    it is trustworthy exactly when there is only one strap it could have come from — which keeps a
 *    single-strap install reading correctly across the upgrade instead of resetting to "never".
 *  - otherwise null, meaning "this strap has never synced". For the strap in the capture that is not a
 *    degraded answer, it is the correct one, and it is what the whole thread was missing.
 *
 * Deliberately NOT migrated by writing the global onto the active device at upgrade. That is the same
 * guess in a different place, and on a multi-strap install it would bake the wrong attribution in
 * permanently instead of leaving it to self-correct at the next real sync.
 *
 * Pure so the attribution is unit-tested without prefs, a strap, or a registry.
 */
internal fun resolveLastSync(
    perDevice: Long,
    legacyGlobal: Long,
    pairedCount: Int,
): Long? = perDevice.takeIf { it > 0L }
    ?: legacyGlobal.takeIf { it > 0L && pairedCount == 1 }

/**
 * The per-device preference key for a persisted last-sync timestamp.
 *
 * Keyed on the BLE peripheral address for the same reason [firmwarePrefKey] is: HISTORY_COMPLETE arrives
 * on a connection whose address is known, and resolving it to a registry id there would repeat the
 * mis-mapping #1527 fixed for `lastSeen` — stamping "the active row" records a sync for a strap that was
 * never connected, which is precisely the class of error being removed here.
 *
 * Lowercased, because the same strap presents its address in different cases across sessions and a
 * case-sensitive key would strand the earlier stamp under a second name. Returns null for a blank
 * address, so a caller with no address writes nothing rather than writing to a key that belongs to no
 * device.
 */
internal fun lastSyncPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "noop.lastSyncAt.${it.lowercase()}" }

/**
 * The per-device preference key for the #57 write-health stamps ("rows last landed", "offload stalled").
 *
 * Same defect as [lastSyncPrefKey] and found in the same capture, one line below it: `Data write: rows
 * last landed 4d ago` printed against a strap whose own row count was zero, because the stamp was global
 * and the 4.0 had written it. Two lines that both looked like evidence the 5/MG had been syncing, and
 * neither was about the 5/MG.
 *
 * [kind] separates "ok" from "stalled" so both keep the per-device scoping rather than only the one that
 * happened to be noticed — they are read as a PAIR ("stalled more recently than ok" is the alarm), and
 * scoping one without the other would compare a strap's own stall against another strap's success.
 */
internal fun writeHealthPrefKey(peripheralId: String?, kind: String): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }
        ?.let { "sync.$kind.${it.lowercase()}" }

/**
 * Which strap-clock reading belongs to a strap: the newest banked-record timestamp the alarm section's
 * clock verdict is derived from.
 *
 * The FOURTH place this one defect has surfaced, after [resolveFirmware], [resolveLastSync] and
 * [writeHealthPrefKey]. `strap.newestRecordTs` is ONE global key, written on any strap's GET_DATA_RANGE
 * reply and read back for whichever strap is active. A capture on a two-strap install showed
 * `Strap clock: 20d behind wall (reset/stale - alarm unreliable)` for an active 5/MG whose own header
 * said `Last sync: never (this strap)` and `no history rows ever persisted`: the strap had banked nothing,
 * so the 20 days could only be the paired 4.0's, last seen exactly 20 days earlier. Two lines below, the
 * same strap's own alarm readback said 2045, which is ahead of the wall clock and not behind it.
 *
 * This one is worse than a wrong number, because the verdict it feeds is a judgement: "alarm unreliable"
 * was being asserted about a strap from another strap's clock, and the honest reading for a strap that has
 * banked nothing is that its clock is not known yet.
 *
 * Same rule, same reasons, as [resolveLastSync]: the strap's own value, then the legacy global ONLY at
 * [pairedCount] 1 because that is exactly when it cannot have come from anything else, then null.
 */
internal fun resolveStrapClockTs(
    perDevice: Long,
    legacyGlobal: Long,
    pairedCount: Int,
): Long? = perDevice.takeIf { it > 0L }
    ?: legacyGlobal.takeIf { it > 0L && pairedCount == 1 }

/**
 * The per-device preference key for the strap's newest banked-record timestamp.
 *
 * Keyed on the BLE peripheral address for the same reason [lastSyncPrefKey] is: the range reply arrives on
 * a connection whose address is known, and resolving it to a registry id at the write site would repeat
 * the mis-mapping #1527 fixed for `lastSeen`. Lowercased and blank-rejecting for the same reasons.
 */
internal fun strapClockPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "strap.newestRecordTs.${it.lowercase()}" }
