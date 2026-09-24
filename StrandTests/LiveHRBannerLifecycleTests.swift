import XCTest
@testable import Strand

/// The live heart rate banner is kept, and shows what is true, until its switch turns it off. iOS lets an app start one
/// only while it is on screen, so every end NOOP made on its own left the Lock Screen without it until NOOP was opened.
final class LiveHRBannerLifecycleTests: XCTestCase {

    private func step(switchOn: Bool = true, standsAside: Bool = false, linkUp: Bool = true,
                      showing: Bool = true, appActive: Bool = false) -> LiveHRBannerLifecycle.Step {
        LiveHRBannerLifecycle.step(switchOn: switchOn, standsAside: standsAside, linkUp: linkUp,
                                   showing: showing, appActive: appActive)
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
}
