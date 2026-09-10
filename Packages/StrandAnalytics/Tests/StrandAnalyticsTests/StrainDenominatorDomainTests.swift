import XCTest
@testable import StrandAnalytics

/// Log-map denominator behavior outside the map's domain.
///
/// D ≤ 1 has no ln-based score: ln(1) = 0 divides to ±∞, ln(D) < 0 below 1 flips the sign, and ln(D)
/// is NaN at or below 0. Before the guard, Swift returned `+Inf` for D = 1 while Kotlin's
/// `roundToLong()` saturated to 9.223372036854776E16 — the same input, two different answers.
/// The Kotlin twin is `StrainScorerDenominatorDomainTest`; its expected literals are the stdout of
/// this file's formula compiled standalone.
final class StrainDenominatorDomainTests: XCTestCase {

    func testDenominatorAtOrBelowOneScoresZero() {
        for denominator in [1.0, 0.5, 0.0, -3.0, Double.nan] {
            let s = StrainScorer.trimpToStrain(1, denominator: denominator)
            XCTAssertTrue(s.isFinite, "D = \(denominator) produced a non-finite Effort")
            XCTAssertEqual(s, 0.0, accuracy: 0, "D = \(denominator)")
        }
    }

    func testValidDenominatorsAreUnchanged() {
        XCTAssertEqual(StrainScorer.trimpToStrain(1, denominator: 7201), 7.8, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(100, denominator: 7201), 51.96, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(7200, denominator: 7201), 100.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(1, denominator: 2), 100.0, accuracy: 1e-9)
    }

    /// Just above the boundary the score is enormous but finite, and it must stay a Double on both
    /// platforms — this is the value Kotlin's `roundToLong()` clipped to Long.MAX / 100.
    ///
    /// Loosely toleranced on purpose: ln(1 + 2⁻⁵²) is ~2.2e-16, so a 1-ulp difference between
    /// Darwin's and glibc's `log` moves the quotient by ~±30 absolute. Linux/glibc observes exactly
    /// 3.1216573840826803e+17; the assertion checks the magnitude, not the last bits.
    func testDenominatorJustAboveOneStaysFinite() {
        let s = StrainScorer.trimpToStrain(1, denominator: 1.0000000000000002)
        XCTAssertTrue(s.isFinite)
        XCTAssertEqual(s, 3.1216573840826803e+17, accuracy: 1e4)
    }

    /// Non-finite TRIMP propagates rather than being caught by the domain guard — the guard is about
    /// D, not TRIMP. Both platforms agree here only because Kotlin no longer rounds through Long
    /// (`roundToLong()` mapped +∞ to Long.MAX), so pin the non-finite propagation behavior.
    func testNonFiniteTrimpPropagates() {
        let inf = StrainScorer.trimpToStrain(.infinity, denominator: 7201)
        XCTAssertFalse(inf.isFinite)
        XCTAssertFalse(inf.isNaN)
        XCTAssertGreaterThan(inf, 0)
        XCTAssertTrue(StrainScorer.trimpToStrain(.nan, denominator: 7201).isNaN)
    }
}
