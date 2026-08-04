import XCTest
@testable import Strand

/// #510: `reconcileWorkoutHrWithTrace` used to read every workout's HR window under the Repository's single
/// active `deviceId`, so a bout auto-detected on a SECOND WHOOP (its `hrSample` rows banked under that strap)
/// read the active strap's empty window and its Avg HR / Effort went un-reconciled. `Repository.workoutHrDeviceIds`
/// now resolves the read key per row from the workout's own `source`. Kotlin twin: `WorkoutHrDeviceKeyTest`.
///
/// NB the Swift read-model `WorkoutRow` carries no `deviceId`, so only DETECTED rows (whose `source` IS their
/// computed strap id "<base>-noop") can key on their own strap here; MANUAL/IMPORTED rows reconcile against the
/// active strap. This mirrors the Kotlin fix for the dominant (detected) multi-WHOOP case.
final class WorkoutHrDeviceKeyTests: XCTestCase {

    /// A bout detected on a 2nd WHOOP lives under "whoop-aabbcc-noop"; its HR is banked under "whoop-aabbcc".
    /// The active strap being something else must NOT redirect the read to an empty window.
    func testDetectedReadsItsOwnBaseStrap_notActive() {
        XCTAssertEqual(
            Repository.workoutHrDeviceIds(source: "whoop-aabbcc-noop", activeStrapId: "my-whoop",
                                          importedIds: ["my-whoop"]),
            ["whoop-aabbcc"],
            "#856: exactly ONE id — unioning would mix in a strap that never recorded this bout")
    }

    /// Single-WHOOP: the canonical detected id strips to the active id, so the read is byte-identical to the
    /// old `self.deviceId` behaviour.
    func testDetectedCanonicalIsByteIdenticalToActive() {
        XCTAssertEqual(
            Repository.workoutHrDeviceIds(source: "my-whoop-noop", activeStrapId: "my-whoop",
                                          importedIds: ["my-whoop"]),
            ["my-whoop"])
    }

    /// Manual rows carry no strap id in `source`, so they reconcile against the active strap (the documented
    /// display-only divergence from the Kotlin twin, which keys manual rows on their stored deviceId).
    func testManualReadsActiveStrap() {
        XCTAssertEqual(
            Repository.workoutHrDeviceIds(source: "manual", activeStrapId: "whoop-aabbcc",
                                          importedIds: ["whoop-aabbcc"]),
            ["whoop-aabbcc"])
    }

    /// Imported rows (Apple / activity file / lifting / WHOOP CSV) reconcile against the active strap — the
    /// worn-strap fill (#77) is unchanged. Includes the legacy `apple_health` spelling and the CSV `my-whoop`
    /// source (contains "whoop" but not "-noop", so it classifies non-detected and is NOT stripped).
    func testImportedReadsActiveStrap() {
        for src in ["apple-health", "apple_health", "activity-file", "lifting", "my-whoop", "Health Connect"] {
            XCTAssertEqual(
                Repository.workoutHrDeviceIds(source: src, activeStrapId: "whoop-aabbcc",
                                              importedIds: ["whoop-aabbcc"]),
                ["whoop-aabbcc"],
                "imported source \(src) should reconcile against the active strap")
        }
    }

    /// #856: an imported row on a MULTI-namespace install gets the whole #814 union, not just the
    /// active strap — it has no strap of its own, and after a re-add the worn strap's history may sit
    /// under the canonical id. This is the case the single-id resolver silently under-read.
    func testImportedGetsTheFullUnionWhenTheyDiffer() {
        XCTAssertEqual(
            Repository.workoutHrDeviceIds(source: "apple-health", activeStrapId: "whoop-aabbcc",
                                          importedIds: ["whoop-aabbcc", "my-whoop"]),
            ["whoop-aabbcc", "my-whoop"])
    }

    /// …while a DETECTED row on that same install still resolves to one id. The union must not leak
    /// into the branch where it would be wrong.
    func testDetectedIgnoresTheUnionEvenWhenOneIsAvailable() {
        XCTAssertEqual(
            Repository.workoutHrDeviceIds(source: "whoop-aabbcc-noop", activeStrapId: "my-whoop",
                                          importedIds: ["my-whoop", "whoop-zzz"]),
            ["whoop-aabbcc"])
    }
}
