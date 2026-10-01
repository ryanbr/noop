import XCTest
@testable import Strand

/// Pins which pace a stress check-in's breath runs at: the locked resonance pace only while "Use my
/// resonance pace" is on. Same cases as the Kotlin `CheckInLockedPaceTest`.
final class CheckInLockedPaceTests: XCTestCase {

    func testOnWithALockedPaceUsesIt() {
        XCTAssertEqual(BiofeedbackPrefs.checkInLockedPace(useResonance: true, locked: 6.2), 6.2)
    }

    func testOffFallsBackEvenWithALockedPace() {
        XCTAssertNil(BiofeedbackPrefs.checkInLockedPace(useResonance: false, locked: 6.2))
    }

    func testNoLockedPaceFallsBackEitherWay() {
        XCTAssertNil(BiofeedbackPrefs.checkInLockedPace(useResonance: true, locked: nil))
        XCTAssertNil(BiofeedbackPrefs.checkInLockedPace(useResonance: false, locked: nil))
    }
}
