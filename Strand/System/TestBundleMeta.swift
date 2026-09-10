import Foundation
import StrandAnalytics

/// The machine-readable tie between a strap log and the test profile that produced it: meta.json,
/// schema v1 (spec section 5.1). Folds in build-provenance and the storage / DB-size block so a
/// maintainer sees the version, channel, signing and on-disk footprint without asking. snake_case
/// wire keys match the spec JSON sample; sortedKeys keeps the Swift and Kotlin output byte-aligned.
struct TestBundleMeta: Codable {
    let schema: Int                    // always 1
    let appVersion: String
    let platform: String               // "iOS" | "macOS" | "Android"
    let osVersion: String
    let strapModel: String?
    let source: [String]               // e.g. ["Live Bluetooth"]
    let testProfile: String            // TestDomain.id
    let profileStartedAt: String?      // ISO8601, from TestCentre.startedAt
    let questionnaire: [String: String]
    let build: Build
    let storage: Storage
    let redaction: String              // "v2"
    let truncated: Bool
    /// The report-completeness guard result (#812, generalised): per ACTIVE domain, OK (its killer trace
    /// landed, with a count) or INCOMPLETE (the mode was on but produced no trace). Empty on a non-test
    /// export. Lets a maintainer see at a glance, from meta alone, that a report is thin and WHICH capture
    /// failed. Built by CaptureCompleteness.evaluate over the redacted report.txt.
    var captureCheck: [CaptureCheck] = []

    /// channel: one of AltStore / App Store / TestFlight / brew / GitHub / sideload. signed is false on
    /// the sideloaded iOS path; derived from IOSDiagnostics.isSideloaded on iOS, fixed per flavour else.
    struct Build: Codable { let channel: String; let signed: Bool }

    /// db_bytes plus per-table row counts plus the raw-capture footprint (#590 asked us to surface this).
    struct Storage: Codable {
        let dbBytes: Int; let rows: [String: Int]; let rawCaptureBytes: Int
        /// #1911: estimated payload bytes per table, keyed as `rows` is. Rows alone cannot say which table
        /// holds a large store — `ppgWaveformSample`'s rows carry a BLOB, so it is exactly where a row
        /// model misleads. A sampled payload estimate with no index or page overhead, so read it as a
        /// lower bound to compare against `db_bytes`, never as a second file size.
        let rowBytes: [String: Int]
        enum CodingKeys: String, CodingKey {
            case rows
            case dbBytes = "db_bytes", rawCaptureBytes = "raw_capture_bytes", rowBytes = "row_bytes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, platform, source, questionnaire, build, storage, redaction, truncated
        case appVersion = "app_version", osVersion = "os_version", strapModel = "strap_model"
        case testProfile = "test_profile", profileStartedAt = "profile_started_at"
        case captureCheck = "capture_check"
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}
