import XCTest
import SwiftUI
import StrandDesign
@testable import Strand

/// Pins what lets a filled `LiquidVessel` stop its frame loop: the ring it draws depends on the fill level
/// alone, and the fill arrives and then holds.
///
/// Since #1068 `LiquidRender.vessel` draws a ring, not liquid. If a later change draws the waves, tilt or
/// drops again, `testTheRingIsDrawnFromTheLevelAlone` fails, and the still ring would be freezing motion a
/// person can see: the loop would have to run again.
@MainActor
final class LiquidVesselStillTests: XCTestCase {

    func testAFillArrivesThenHoldsItsLevel() {
        let sim = LiquidSim(target: 0.58)
        var now = 1_000.0
        for frame in 0..<(4 * 60) {   // four seconds at 60 fps, the tilt swinging throughout
            sim.step(now: now, tilt: 0.4 * sin(Double(frame) / 9), target: 0.58)
            now += 1.0 / 60
        }
        XCTAssertTrue(sim.fillArrived, "level \(sim.level)")
        let arrived = sim.level
        sim.splash(12)
        for frame in 0..<(2 * 60) {
            sim.step(now: now, tilt: 0.5 * cos(Double(frame) / 7), target: 0.58)
            now += 1.0 / 60
        }
        XCTAssertEqual(sim.level, arrived, "a splash or a tilt moved the level")
    }

    func testAFillHasNotArrivedWhileItIsStillMoving() {
        let sim = LiquidSim(target: 0.9)
        sim.step(now: 0, tilt: 0, target: 0.9)
        sim.step(now: 1.0 / 60, tilt: 0, target: 0.9)
        XCTAssertFalse(sim.fillArrived)
    }

    /// A loop restarted after resting must move the fill as a running one does, not by one capped 33 ms
    /// step taken from the stale time it stopped at.
    func testARestartedLoopStepsFromItsOwnFirstFrame() {
        let sim = LiquidSim(target: 0.2)
        var now = 0.0
        for _ in 0..<(4 * 60) { sim.step(now: now, tilt: 0, target: 0.2); now += 1.0 / 60 }
        XCTAssertTrue(sim.fillArrived)
        now += 30   // the ring sat still for half a minute; the value then changes
        sim.restartClock()
        let before = sim.level
        sim.step(now: now, tilt: 0, target: 0.8)
        XCTAssertEqual(sim.level, before, "the first frame after a restart has no elapsed time")
        sim.step(now: now + 1.0 / 60, tilt: 0, target: 0.8)
        XCTAssertEqual(sim.level - before, (0.8 - before) * (2.6 / 60), accuracy: 1e-9)
    }

    /// The same level drawn from a sim that has sloshed, tilted, splashed and run for minutes, and from one
    /// posed still at that level with the clock at zero: the pixels must be identical.
    func testTheRingIsDrawnFromTheLevelAlone() throws {
        let busy = LiquidSim(target: 0.58)
        var now = 5_000.0
        for frame in 0..<(5 * 60) {
            busy.step(now: now, tilt: 0.45 * sin(Double(frame) / 5), target: 0.58)
            if frame % 40 == 0 { busy.splash(12) }
            now += 1.0 / 60
        }
        let still = LiquidSim.posed(busy.level)
        let a = try XCTUnwrap(ringPixels(busy, now: now))
        let b = try XCTUnwrap(ringPixels(still, now: 0))
        XCTAssertEqual(a, b)
    }

    /// Named unlike any production function (the parity ledger pairs calls by name).
    private func ringPixels(_ sim: LiquidSim, now: Double) -> Data? {
        let view = Canvas { context, size in
            LiquidRender.vessel(context, size, sim, now: now, tint: StrandPalette.restColor)
        }
        .frame(width: 96, height: 96)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }
}
