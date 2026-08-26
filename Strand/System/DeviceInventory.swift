import Foundation

/// One registry row, reduced to what the inventory prints — see `deviceInventoryLines`.
struct InventoryRow {
    let id: String
    let brand: String
    let model: String
    let status: String
    let lastSeenAt: Int
    let firmware: String?
}

/// The strap log's paired-device inventory: every registry row, which one is ACTIVE, and when each was
/// last seen.
///
/// The header above it describes a single device because it reads the last-connected PREFS rather than
/// the registry, so a two-strap install produces a log that never mentions the second strap. That makes
/// the id-bearing lines elsewhere — `dayOwner readId=…`, the funnel's orphan check — impossible to
/// cross-check: a reader can see which id a day was read from but not which ids exist, nor which of them
/// actually synced. Naming the set is what turns those lines into evidence.
///
/// Sorted ACTIVE first, then by most-recently-seen, then by id: a stable order that puts the row a reader
/// wants first at the top, and never depends on registry iteration order.
///
/// Device ids embed a BLE address for a re-added strap, and the export's redaction masks the middle four
/// octets while keeping the first and last — enough to tell two straps apart in a shared log without
/// publishing an address. This line carries no data the log did not already carry.
///
/// `nowSec` is passed in rather than read, so the output is a pure function of its inputs. Kotlin twin:
/// `com.noop.testcentre.deviceInventoryLines`.
func deviceInventoryLines(rows: [InventoryRow],
                          activeId: String?,
                          nowSec: Int,
                          relTime: (Double) -> String) -> [String] {
    if rows.isEmpty { return ["Devices:     none registered"] }
    let active = rows.filter { $0.status == "active" }.count
    let paired = rows.filter { $0.status == "paired" }.count
    let archived = rows.filter { $0.status == "archived" }.count
    let head = "Devices:     \(rows.count) registered (\(active) active, \(paired) paired, \(archived) archived)"
    let ordered = rows.sorted { a, b in
        let aActive = a.id == activeId, bActive = b.id == activeId
        if aActive != bActive { return aActive }
        if a.lastSeenAt != b.lastSeenAt { return a.lastSeenAt > b.lastSeenAt }
        return a.id < b.id
    }
    return [head] + ordered.map { r in
        let marker = r.id == activeId ? "ACTIVE" : r.status
        let seen = r.lastSeenAt > 0 ? relTime(Double(nowSec - r.lastSeenAt)) : "never"
        return "  device id=\(r.id) status=\(marker) brand=\(r.brand) model=\(r.model) lastSeen=\(seen)"
            + " fw=\(r.firmware ?? "unknown")"
    }
}
