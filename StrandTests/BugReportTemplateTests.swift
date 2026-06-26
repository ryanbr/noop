import XCTest

/// Guards the bug_report.yml fields the Test Centre deep-link binds (spec section 5.5). This is a
/// text-level structural check (we ship no YAML parser in the app target): it asserts the test_profile
/// dropdown id, the 14 dropdown options, the reworked attach guidance, the importer source options and
/// the attach checkbox are all present, so a hand-edit can't silently break the prefilled report link.
final class BugReportTemplateTests: XCTestCase {

    private func templateText() -> String {
        // The repo root is two levels above StrandTests at build time; resolve from this file.
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let yml = repoRoot.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        return (try? String(contentsOf: yml, encoding: .utf8)) ?? ""
    }

    func testHasTestProfileDropdownWithId() {
        let t = templateText()
        XCTAssertTrue(t.contains("id: test_profile"))
        XCTAssertTrue(t.contains("type: dropdown"))
    }

    func testTestProfileOptionsCoverAllProfilesPlusEscapes() {
        let t = templateText()
        for label in ["Sleep & Rest", "Connection & Sync", "Workouts & GPS",
                      "Display & Performance", "Import & Data Ingest", "Steps",
                      "Notifications, Alarm & Wake", "Battery & Charging", "Recovery (Charge)",
                      "HRV & Autonomic", "Sources, Fusion & Metric Decode",
                      "Stress & Illness", "Longevity, Cycles & Haptics",
                      "Log everything", "Not a test-mode bug"] {
            XCTAssertTrue(t.contains(label), "missing test_profile option: \(label)")
        }
    }

    func testSourceDropdownGainsImporters() {
        let t = templateText()
        for label in ["Oura import", "Fitbit import", "Garmin import",
                      "Xiaomi import", "FIT / GPX / TCX import"] {
            XCTAssertTrue(t.contains(label), "missing source importer: \(label)")
        }
    }

    func testLogTextareaTellsToAttachZipNotPaste() {
        let t = templateText()
        XCTAssertTrue(t.contains("Attach your exported"))
        XCTAssertTrue(t.contains("Do NOT paste the whole log inline"))
    }

    func testAttachZipCheckboxPresent() {
        let t = templateText()
        XCTAssertTrue(t.contains("I attached my exported NOOP"))
        XCTAssertTrue(t.contains("not a screenshot of the Live screen"))
    }
}
