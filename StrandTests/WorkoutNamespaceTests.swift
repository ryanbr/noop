import XCTest
@testable import Strand

/// The Workouts list and the Workouts delete must agree about where a row lives (#2278).
///
/// Why this exists: the list unioned many device namespaces while the delete touched exactly one, the
/// active strap. A row banked anywhere else was visible but undeletable, because the delete reported
/// nothing and the reload re-read the row from a namespace the delete never went near. Both sides now
/// derive from `workoutNamespaces`, and these tests pin what that list must contain.
final class WorkoutNamespaceTests: XCTestCase {

    func testEveryRawIdAndItsComputedSiblingAreIncluded() {
        let ids = Repository.workoutNamespaces(rawIds: ["strap-a", "my-whoop"])
        XCTAssertTrue(ids.contains("strap-a"))
        XCTAssertTrue(ids.contains("my-whoop"))
        XCTAssertTrue(ids.contains("strap-a-noop"), "the computed sibling holds detected bouts")
        XCTAssertTrue(ids.contains("my-whoop-noop"))
    }

    func testAnIdThatIsAlreadyComputedIsNotDoubleSuffixed() {
        let ids = Repository.workoutNamespaces(rawIds: ["my-whoop-noop"])
        XCTAssertTrue(ids.contains("my-whoop-noop"))
        XCTAssertFalse(ids.contains("my-whoop-noop-noop"), "suffixing must be idempotent")
    }

    func testTheReadIncludesImportNamespaces() {
        // A workout imported from Apple Health, Hevy/Liftosaur or a FIT/GPX/TCX file is SHOWN by the list.
        let ids = Repository.workoutNamespaces(rawIds: ["strap-a"])
        XCTAssertTrue(ids.contains("apple-health"))
        XCTAssertTrue(ids.contains("lifting"))
        XCTAssertTrue(ids.contains("activity-file"))
    }

    func testDeleteNeverReachesImportNamespaces() {
        // Imported history is read-only, enforced in the row menu (imported rows are offered only
        // "Duplicate as manual…"), in bulkDeleteWorkouts and in mergeWorkouts ("never rewrite imported
        // history"). A delete sweeping the import namespaces would reach underneath all three and destroy
        // a row nothing in the UI ever offers to remove, so the deletable set must stay strap-only.
        let ids = Repository.deletableWorkoutNamespaces(rawIds: ["strap-a"])
        XCTAssertFalse(ids.contains("apple-health"), "imported Apple Health history must survive a delete")
        XCTAssertFalse(ids.contains("lifting"), "imported Hevy / Liftosaur history must survive a delete")
        XCTAssertFalse(ids.contains("activity-file"), "imported FIT / GPX / TCX history must survive")
    }

    func testDeleteStillCoversEveryStrapNamespace() {
        // The actual bug: a manual row under a retained strap or a computed sibling was undeletable.
        let ids = Repository.deletableWorkoutNamespaces(rawIds: ["active", "retained"])
        XCTAssertEqual(ids, ["active", "retained", "active-noop", "retained-noop"])
    }

    func testTheDeletableSetIsASubsetOfWhatTheListReads() {
        // If a delete could target a namespace the list never reads, it would be deleting something the
        // wearer cannot see. Pin the containment rather than the two lists separately.
        let raw = ["active", "retained", "my-whoop-noop"]
        let readable = Set(Repository.workoutNamespaces(rawIds: raw))
        for id in Repository.deletableWorkoutNamespaces(rawIds: raw) {
            XCTAssertTrue(readable.contains(id), "\(id) is deletable but never read")
        }
    }

    func testNoDuplicatesAndReadOrderIsStable() {
        // Duplicates would make the delete issue the same statement twice and the read return the same row
        // twice, which the natural-key dedup would then have to clean up.
        let ids = Repository.deletableWorkoutNamespaces(rawIds: ["a", "a", "b"])
        XCTAssertEqual(ids.count, Set(ids).count, "duplicates must collapse")
        XCTAssertEqual(ids.firstIndex(of: "a"), 0, "the active id stays first, preserving read order")
    }

    func testTheActiveStrapAloneIsNotEnough() {
        // The regression in one line: the old delete used only the active id. If that were still the whole
        // namespace set, every import and every retained strap would remain undeletable.
        let ids = Repository.workoutNamespaces(rawIds: ["active"])
        XCTAssertGreaterThan(ids.count, 1, "delete must reach more than the active strap")
        XCTAssertTrue(ids.contains("active"))
    }
}
