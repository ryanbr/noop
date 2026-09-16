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

    func testImportNamespacesAreIncluded() {
        // A workout imported from Apple Health, Hevy/Liftosaur or a FIT/GPX/TCX file is shown by the list,
        // so it has to be deletable too. These were the namespaces the old delete could never reach.
        let ids = Repository.workoutNamespaces(rawIds: ["strap-a"])
        XCTAssertTrue(ids.contains("apple-health"))
        XCTAssertTrue(ids.contains("lifting"))
        XCTAssertTrue(ids.contains("activity-file"))
    }

    func testNoDuplicatesAndReadOrderIsStable() {
        // Duplicates would make the delete issue the same statement twice and the read return the same row
        // twice, which the natural-key dedup would then have to clean up.
        let ids = Repository.workoutNamespaces(rawIds: ["a", "a", "b"])
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
