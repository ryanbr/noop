package com.noop.testcentre

/** One registry row, reduced to what the inventory prints — see [deviceInventoryLines]. */
internal data class InventoryRow(
    val id: String,
    val brand: String,
    val model: String,
    val status: String,
    val lastSeenAt: Long,
    val firmware: String? = null,
)

/**
 * The strap log's paired-device inventory: every registry row, which one is ACTIVE, and when each was
 * last seen.
 *
 * The header above it describes a single device because it reads the last-connected PREFS rather than
 * the registry, so a two-strap install produces a log that never mentions the second strap. That makes
 * the id-bearing lines elsewhere — `dayOwner readId=…`, the funnel's orphan check — impossible to
 * cross-check: a reader can see which id a day was read from but not which ids exist, nor which of them
 * actually synced. Naming the set is what turns those lines into evidence.
 *
 * Sorted ACTIVE first, then by most-recently-seen, then by id: a stable order that puts the row a reader
 * wants first at the top, and never depends on registry iteration order.
 *
 * Device ids embed a BLE address for a re-added strap, and the export's redaction masks the middle four
 * octets while keeping the first and last — enough to tell two straps apart in a shared log without
 * publishing an address. This line carries no data the log did not already carry.
 *
 * [nowSec] is passed in rather than read, so the output is a pure function of its inputs. Swift twin:
 * `DebugDataDiagnostics.deviceInventoryLines`.
 */
internal fun deviceInventoryLines(
    rows: List<InventoryRow>,
    activeId: String?,
    nowSec: Long,
    relTime: (Long) -> String,
): List<String> {
    if (rows.isEmpty()) return listOf("Devices:     none registered")
    val active = rows.count { it.status == "active" }
    val paired = rows.count { it.status == "paired" }
    val archived = rows.count { it.status == "archived" }
    val head = "Devices:     ${rows.size} registered ($active active, $paired paired, $archived archived)"
    val ordered = rows.sortedWith(
        compareByDescending<InventoryRow> { it.id == activeId }
            .thenByDescending { it.lastSeenAt }
            .thenBy { it.id },
    )
    return listOf(head) + ordered.map { r ->
        val marker = if (r.id == activeId) "ACTIVE" else r.status
        val seen = if (r.lastSeenAt > 0L) relTime((nowSec - r.lastSeenAt) * 1000L) else "never"
        "  device id=${r.id} status=$marker brand=${r.brand} model=${r.model} lastSeen=$seen" +
            " fw=${r.firmware ?: "unknown"}"
    }
}
