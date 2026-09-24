import XCTest
@testable import Strand

/// The live heart rate banner is kept, and shows what is true, until its switch turns it off. iOS lets an app start one
/// only while it is on screen, so every end NOOP made on its own left the Lock Screen without it until NOOP was opened.
final class LiveHRBannerLifecycleTests: XCTestCase {

    private func step(switchOn: Bool = true, standsAside: Bool = false, linkUp: Bool = true,
                      showing: Bool = true, age: TimeInterval? = 60,
                      appActive: Bool = false) -> LiveHRBannerLifecycle.Step {
        LiveHRBannerLifecycle.step(switchOn: switchOn, standsAside: standsAside, linkUp: linkUp,
                                   showing: showing, age: age, appActive: appActive)
    }

    /// A dropped link of any length and a strap that is not measuring show the dash, on screen or not; the number comes
    /// back by itself. What the banner shows is not a reason to end it: the lifecycle does not read the heart rate.
    func testNothingButItsSwitchAndTheGymBannerEndsIt() {
        for linkUp in [true, false] {
            for appActive in [true, false] {
                XCTAssertEqual(step(linkUp: linkUp, appActive: appActive), .push,
                               "link up \(linkUp), on screen \(appActive)")
            }
        }
    }

    func testTheSwitchEndsIt() {
        XCTAssertEqual(step(switchOn: false), .end)
        XCTAssertEqual(step(switchOn: false, showing: false, appActive: true), .nothing)
    }

    /// A background sync shows no sync banner, so there is nothing to make room for.
    func testOnlyTheGymBannerTakesItsPlace() {
        XCTAssertEqual(step(standsAside: true), .end)
        XCTAssertEqual(step(standsAside: true, showing: false, appActive: true), .nothing)
    }

    /// iOS refuses a new banner to an app in the background: it is not asked for one there. On screen it starts with
    /// the strap connected, before a heart rate arrives (the dash), so a strap put on later with NOOP in the background
    /// finds a banner to fill.
    func testANewBannerIsAskedForOnlyOnScreenWithTheStrapConnected() {
        XCTAssertEqual(step(showing: false, appActive: false), .nothing)
        XCTAssertEqual(step(showing: false, appActive: true), .start)
        XCTAssertEqual(step(linkUp: false, showing: false, appActive: true), .nothing)
    }

    /// iOS ends a banner about eight hours after it started. Opened after the first hour, NOOP starts a fresh one, so
    /// the banner has most of those hours ahead of it again; in the background it cannot, and does not ask.
    func testAnOldBannerIsRenewedWhenNOOPIsOnScreen() {
        let renewAfter = LiveHRBannerLifecycle.renewAfter
        XCTAssertEqual(step(age: renewAfter - 1, appActive: true), .push)
        XCTAssertEqual(step(age: renewAfter, appActive: true), .renew)
        XCTAssertEqual(step(age: nil, appActive: true), .renew)            // started by an earlier build: unknown age
        XCTAssertEqual(step(linkUp: false, age: renewAfter, appActive: true), .renew)
        XCTAssertEqual(step(age: 7 * 60 * 60, appActive: false), .push)
        XCTAssertEqual(step(switchOn: false, age: renewAfter, appActive: true), .end)
    }
}
