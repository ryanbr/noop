import XCTest
@testable import Strand
import StrandAnalytics

/// Locks the Report flow's pure decisions (spec section 5.2): the saved bundle filename, the attach
/// toast that names that file, and whether the platform offers the "Copy report.txt" mobile fallback
/// (iOS only, since GitHub's mobile composer can't reliably attach a .zip).
final class TestReportFlowTests: XCTestCase {

    func testBundleNameFollowsProfilePlatformVersionPattern() {
        let name = TestReportFlow.Plan.bundleName(
            profile: .sleep, platform: "ios", version: "7.3.0",
            date: Date(timeIntervalSince1970: 1_781_500_320)) // fixed instant for a stable stamp
        XCTAssertTrue(name.hasPrefix("noop-sleep-ios-v7.3.0-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
    }

    func testAttachToastNamesTheSavedFile() {
        let toast = TestReportFlow.Plan.attachToast(savedName: "noop-sleep-ios-v7.3.0-260626-0712.zip")
        XCTAssertTrue(toast.contains("noop-sleep-ios-v7.3.0-260626-0712.zip"))
        XCTAssertTrue(toast.contains("Attach"))
        XCTAssertFalse(toast.contains("\u{2014}"))   // hard rule: no em-dash
        // The flow no longer opens a GitHub issue composer, so the toast must not walk the user through
        // one. It used to say "On the next screen tap the paperclip and pick it", describing a screen
        // that will never appear now.
        XCTAssertFalse(toast.contains("paperclip"))
        XCTAssertFalse(toast.contains("next screen"))
    }

    func testCopyFallbackOfferedOnMobileOnly() {
        XCTAssertTrue(TestReportFlow.Plan.offersCopyFallback(platform: "ios"))
        XCTAssertTrue(TestReportFlow.Plan.offersCopyFallback(platform: "iOS"))
        XCTAssertFalse(TestReportFlow.Plan.offersCopyFallback(platform: "macOS"))
    }
}
