import XCTest
@testable import Strand

/// #1008 — which way "Overnight only" falls when the user has never chosen. Twin of the Kotlin
/// `ContinuousHrvOvernightDefaultTest`; same cases in the same order.
///
/// WHOOP publishes no daytime HRV figure, so a 24/7 stream has no official-app analogue and costs
/// roughly twice the battery. The cheaper, WHOOP-comparable behaviour should be the default — but only
/// for someone not already running the other one.
///
/// The rule that must not break: an existing Continuous HRV user's capture is never silently narrowed.
/// They opted into "all day and night" and may be reading daytime Stress off it.
///
/// Note: `StrandTests` runs only under `xcodebuild` on macOS, and `app-build.yml` is disabled — so this
/// suite is not executed by CI today. The Kotlin twin is, under `testFullDebugUnitTest`.
final class ContinuousHrvOvernightDefaultTests: XCTestCase {

    /// The case the migration exists for: used the feature, never chose — pin the old default.
    func testAnExistingContinuousHrvUserIsPinnedToAlwaysOn() {
        XCTAssertTrue(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: true))
    }

    /// A fresh install is left alone, so the read picks up the new ON default.
    func testAFreshInstallIsLeftAloneAndTakesTheNewDefault() {
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: false))
    }

    /// An explicit choice is never overwritten, whichever way it points.
    func testAnExplicitChoiceIsNeverOverwritten() {
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: true, hasUsedContinuousHrv: true))
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: true, hasUsedContinuousHrv: false))
    }

    /// Idempotence, which is what makes it safe to run on every launch.
    func testTheMigrationIsIdempotent() {
        XCTAssertTrue(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: true))
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: true, hasUsedContinuousHrv: true))
    }

    /// The sequence that broke the first attempt: resolving the default at READ time from a fact the
    /// user's own opt-in creates. Running the decision once at launch is what fixes it.
    func testEnablingContinuousHrvAfterLaunchCannotChangeTheDecision() {
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: false))
        XCTAssertTrue(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: true))
    }
}
