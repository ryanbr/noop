import XCTest
@testable import Strand

/// The live heart rate banner is kept, and shows what is true, through what used to end it: a dropped link and a sync
/// in the background. iOS lets an app start one only while it is on screen, so every needless end left the Lock Screen
/// without it until NOOP was opened again.
final class LiveHRBannerLifecycleTests: XCTestCase {

    private func step(switchOn: Bool = true, standsAside: Bool = false, linkUp: Bool = true, bpm: Int? = 72,
                      showing: Bool = true, appActive: Bool = false) -> LiveHRBannerLifecycle.Step {
        LiveHRBannerLifecycle.step(switchOn: switchOn, standsAside: standsAside, linkUp: linkUp, bpm: bpm,
                                   showing: showing, appActive: appActive)
    }

    func testADroppedLinkKeepsTheBanner() {
        XCTAssertEqual(step(linkUp: false, bpm: nil), .push)   // it shows the dash, and comes back by itself
    }

    func testAStrapThatIsNotMeasuringKeepsTheBanner() {
        XCTAssertEqual(step(bpm: nil), .push)
    }

    /// A background sync shows no sync banner, so there is nothing to make room for.
    func testOnlyABannerOnScreenTakesItsPlace() {
        XCTAssertEqual(step(standsAside: false), .push)
        XCTAssertEqual(step(standsAside: true), .end)
        XCTAssertEqual(step(standsAside: true, showing: false), .nothing)
    }

    func testTheSwitchEndsIt() {
        XCTAssertEqual(step(switchOn: false), .end)
        XCTAssertEqual(step(switchOn: false, showing: false, appActive: true), .nothing)
    }

    /// iOS refuses a new banner to an app in the background: it is not asked for one on every heartbeat there.
    func testANewBannerIsAskedForOnlyInTheForegroundWithSomethingToShow() {
        XCTAssertEqual(step(showing: false, appActive: false), .nothing)
        XCTAssertEqual(step(showing: false, appActive: true), .start)
        XCTAssertEqual(step(bpm: nil, showing: false, appActive: true), .nothing)
        XCTAssertEqual(step(linkUp: false, showing: false, appActive: true), .nothing)
    }
}
