import XCTest
@testable import Strand

/// Pins the paired-device inventory. Kotlin twin: `DeviceInventoryTest`.
///
/// The block exists because the header above it reads the last-connected prefs rather than the registry,
/// so a two-strap install produced a log that never mentioned the second strap.
final class DeviceInventoryTests: XCTestCase {

    // The same relTime the diagnostics use, inlined so the test is independent of that private helper.
    private let rel: (Double) -> String = { sec in
        if sec < 60 { return "just now" }
        let m = Int(sec / 60)
        if m < 60 { return "\(m)m ago" }
        if m < 1440 { return "\(m / 60)h \(m % 60)m ago" }
        return "\(m / 1440)d ago"
    }

    private func row(_ id: String, _ status: String, _ seen: Int,
                     model: String = "WHOOP 4.0", fw: String? = nil) -> InventoryRow {
        InventoryRow(id: id, brand: "WHOOP", model: model, status: status, lastSeenAt: seen, firmware: fw)
    }

    func testAnEmptyRegistrySaysSoRatherThanPrintingABareHeader() {
        XCTAssertEqual(deviceInventoryLines(rows: [], activeId: nil, nowSec: 1000, relTime: rel),
                       ["Devices:     none registered"])
    }

    func testTheActiveStrapIsMarkedAndSortedFirstEvenWhenSeenLongestAgo() {
        // The whole point: the ACTIVE row is the one a reader wants first, and it is NOT necessarily the
        // most recently seen — switching straps leaves the old one with a fresher lastSeen.
        let now = 100_000
        let lines = deviceInventoryLines(
            rows: [row("whoop-B", "paired", now - 600),
                   row("my-whoop", "active", now - 11_400, model: "WHOOP 5.0 / MG")],
            activeId: "my-whoop", nowSec: now, relTime: rel)
        XCTAssertEqual(lines, [
            "Devices:     2 registered (1 active, 1 paired, 0 archived)",
            "  device id=my-whoop status=ACTIVE brand=WHOOP model=WHOOP 5.0 / MG lastSeen=3h 10m ago fw=unknown",
            "  device id=whoop-B status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=10m ago fw=unknown",
        ])
    }

    func testANeverSeenRowReadsNeverRatherThanAHugeDuration() {
        let lines = deviceInventoryLines(rows: [row("whoop-C", "paired", 0)],
                                         activeId: nil, nowSec: 100_000, relTime: rel)
        XCTAssertEqual(lines[1],
                       "  device id=whoop-C status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=never fw=unknown")
    }

    func testCountsSplitActivePairedAndArchived() {
        let now = 100_000
        let lines = deviceInventoryLines(
            rows: [row("a", "active", now - 60), row("b", "paired", now - 60),
                   row("c", "archived", now - 60), row("d", "archived", now - 60)],
            activeId: "a", nowSec: now, relTime: rel)
        XCTAssertEqual(lines[0], "Devices:     4 registered (1 active, 1 paired, 2 archived)")
    }

    func testTiesBreakOnIdSoTheOrderNeverDependsOnRegistryIteration() {
        let now = 100_000
        let lines = deviceInventoryLines(
            rows: [row("zzz", "paired", now - 60), row("aaa", "paired", now - 60)],
            activeId: nil, nowSec: now, relTime: rel)
        let ids = lines.dropFirst().map { String($0.split(separator: "=")[1].split(separator: " ")[0]) }
        XCTAssertEqual(ids, ["aaa", "zzz"])
    }
}
