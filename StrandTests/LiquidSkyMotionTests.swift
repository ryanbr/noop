import XCTest
@testable import Strand

/// Pins when Today's liquid sky runs its 20 fps frame loop: only while a star can be drawn to twinkle.
///
/// The breath of light is the sky's one other moving layer, and it changes no pixel by more than a few of 255
/// levels, so an hour with no drawable star gains nothing from redrawing and the loop stands down. Pure, so it
/// needs no view, no clock and no simulator.
final class LiquidSkyMotionTests: XCTestCase {

    func testStarlessDaytimeHoursPauseTheLoop() {
        for light in [false, true] {
            for hour in [9.0, 12.0, 15.25, 17.5, 18.5, 19.0] {
                XCTAssertTrue(LiquidSky.pausesFrames(hour: hour, light: light, poseStill: false),
                              "hour \(hour), light \(light)")
            }
        }
    }

    func testStarryHoursKeepTheTwinkle() {
        for light in [false, true] {
            for hour in [0.0, 3.0, 5.0, 21.5, 23.5] {
                XCTAssertFalse(LiquidSky.pausesFrames(hour: hour, light: light, poseStill: false),
                               "hour \(hour), light \(light)")
            }
        }
    }

    /// Reduce Motion, Low Power Mode and the in-app toggle still pause it at any hour.
    func testPoseStillPausesEvenUnderStars() {
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 0, light: false, poseStill: true))
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 23.5, light: true, poseStill: true))
    }

    /// A star is drawn once the nearest one, at the peak of its twinkle, reaches opacity 0.02: a star amount of
    /// 0.02 / 0.48. Dark keyframes 6.5 h (0.06) → 8.5 h (0) and 17.5 h (0) → 19.5 h (0.05) cross it near 7:07 and
    /// 19:10; light 5 h (0.05) → 6.5 h (0.02) and 19.5 h (0.02) → 22 h (0.06) near 5:25 and 20:51.
    func testTheLoopFollowsTheDrawableStarsAtDawnAndDusk() {
        XCTAssertFalse(LiquidSky.pausesFrames(hour: 7.05, light: false, poseStill: false))
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 7.15, light: false, poseStill: false))
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 19.1, light: false, poseStill: false))
        XCTAssertFalse(LiquidSky.pausesFrames(hour: 19.25, light: false, poseStill: false))
        XCTAssertFalse(LiquidSky.pausesFrames(hour: 5.35, light: true, poseStill: false))
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 5.5, light: true, poseStill: false))
        XCTAssertTrue(LiquidSky.pausesFrames(hour: 20.75, light: true, poseStill: false))
        XCTAssertFalse(LiquidSky.pausesFrames(hour: 20.95, light: true, poseStill: false))
    }

    /// At every minute of the day, in both appearances: while the loop is stopped no star, at any depth and at any
    /// point of its twinkle, reaches the drawing floor, so stopping it never freezes a star someone could see; and
    /// while it runs, the nearest star at its peak does.
    func testTheLoopStopsOnlyWhenNoStarCanBeDrawn() {
        let steps = (0...20).map { Double($0) / 20 }
        for minute in 0..<(24 * 60) {
            let hour = Double(minute) / 60
            for light in [false, true] {
                let stars = liquidSkyAt(hour, light: light).stars
                if LiquidSky.pausesFrames(hour: hour, light: light, poseStill: false) {
                    for depth in steps {
                        for twinkle in steps {
                            XCTAssertLessThan(liquidStarOpacity(stars: stars, depth: depth, twinkle: twinkle),
                                              liquidStarMinOpacity, "minute \(minute), light \(light)")
                        }
                    }
                } else {
                    XCTAssertGreaterThanOrEqual(liquidStarOpacity(stars: stars, depth: 1, twinkle: 1),
                                                liquidStarMinOpacity, "minute \(minute), light \(light)")
                }
            }
        }
    }
}
