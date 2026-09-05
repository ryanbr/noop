import XCTest
import UserNotifications
@testable import Strand

/// `BatteryNotifier.decision(for:)` — the pure classification behind `ensureAuthorized()`. Pins the
/// exact mapping from `UNAuthorizationStatus` to what the caller should do next, so a future edit to
/// the switch can't silently start re-prompting an already-answered user (`.deny` case) or stop
/// asking a genuinely undetermined one (`.mustAsk` case). This is the seam that was missing before
/// the fix: every notifier in the app used to inline this switch inside a `getNotificationSettings`
/// closure, which needs a live `UNUserNotificationCenter` round-trip to exercise at all. The
/// authorization round-trip itself and actual notification delivery remain device/OS-only and are
/// not covered here — see the PR description.
final class BatteryNotifierAuthDecisionTests: XCTestCase {
    private typealias Decision = BatteryNotifier.AuthDecision

    func testAuthorizedProceeds() {
        XCTAssertEqual(BatteryNotifier.decision(for: .authorized), .proceed)
    }

    func testProvisionalProceeds() {
        // Never granted by THIS app's own request (it never passes `.provisional`), but a future OS
        // change or another path could surface it — treat it exactly like `.authorized` so we don't
        // re-prompt someone who already has a working (if quiet) grant.
        XCTAssertEqual(BatteryNotifier.decision(for: .provisional), .proceed)
    }

    #if os(iOS)
    // `.ephemeral` (App Clips) is `@available(macOS, unavailable)` — StrandTests only runs on macOS
    // (it hosts inside the macOS app for `@testable import`), so this case is iOS-only here.
    func testEphemeralProceeds() {
        XCTAssertEqual(BatteryNotifier.decision(for: .ephemeral), .proceed)
    }
    #endif

    func testNotDeterminedMustAsk() {
        // The ONLY status that should trigger a live `requestAuthorization()` call.
        XCTAssertEqual(BatteryNotifier.decision(for: .notDetermined), .mustAsk)
    }

    func testDeniedDoesNotReAsk() {
        // `requestAuthorization` silently no-ops once denied (the OS never re-shows the dialog), so a
        // denied user must be classified `.deny`, NOT `.mustAsk` — asking again would be a no-op that
        // masks the real state from the caller instead of surfacing the "notifications are off" alert.
        XCTAssertEqual(BatteryNotifier.decision(for: .denied), .deny)
    }
}
