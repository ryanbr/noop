import XCTest
import SwiftUI
@testable import StrandDesign

/// The brand sleep ramps (#1290) shipped FLAT — one hex for both schemes — because both source apps are
/// dark-tuned. Measured against the card they are actually drawn on that is fine in dark and broken in
/// light: the Oura `awake` cream sits at 1.28:1 on #FFFFFF, i.e. not drawn, and awake was 64% of one real
/// ring night's chart. The light variants added here are DERIVED, and these tests pin the three properties
/// that make the derivation defensible — because "it looks fine on my phone" is exactly how the flat ramp
/// shipped in the first place.
///
/// The obvious alternative is clamping each band to 3:1 on its own, and it is a trap worth remembering:
/// it drives Oura `rem` to #1E9EDD and `light` to #239FD5, **1.00:1 apart** — two adjacent stages rendered
/// the same colour. A uniform per-ramp lightness scale is used instead. Twin: `BrandSleepRampTest` (Android).
final class BrandSleepRampTests: XCTestCase {

    /// `NoopVisualStyle.surface` — the card the stepped hypnogram is drawn on (ChartCard → NoopCard).
    private let lightSurface = "#FFFFFF"
    private let darkSurface  = "#2A2C34"

    private typealias Ramp = [(light: String, dark: String)]
    private var ramps: [(name: String, ramp: Ramp)] {
        [("Oura/Ribbon", StrandPalette.BrandSleepRamp.oura),
         ("Garmin/Filled", StrandPalette.BrandSleepRamp.garmin)]
    }

    // MARK: WCAG relative luminance / contrast, on the hex strings (a dynamic Color cannot be read back)

    private func luminance(_ hex: String) -> Double {
        let c = Color.sRGBComponents(hex: hex)
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let (hi, lo) = { (x: Double, y: Double) in x > y ? (x, y) : (y, x) }(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Sanity-check the metric itself before trusting the assertions built on it.
    func testContrastMetricMatchesKnownValues() {
        XCTAssertEqual(contrast("#FFFFFF", "#000000"), 21.0, accuracy: 0.01)
        XCTAssertEqual(contrast("#FFFFFF", "#FFFFFF"), 1.0, accuracy: 0.001)
        // The defect this whole change exists for, stated as a number.
        XCTAssertEqual(contrast("#EAE3D3", "#FFFFFF"), 1.28, accuracy: 0.01)
    }

    // MARK: The three properties

    /// THE ONE THAT MATTERS: every band is actually visible on the light card. 3:1 is the WCAG minimum for
    /// non-text graphics, which is what a stage band is.
    func testEveryLightBandClearsThreeToOneOnTheLightCard() {
        for (name, ramp) in ramps {
            for (i, pair) in ramp.enumerated() {
                let c = contrast(pair.light, lightSurface)
                XCTAssertGreaterThanOrEqual(
                    c, 3.0,
                    "\(name) band \(i) \(pair.light) is \(String(format: "%.2f", c)):1 on \(lightSurface) — under the 3:1 non-text minimum")
            }
        }
    }

    /// The dark ramp is @ryanbr's and is NOT changed here. Pinned so this file notices if a later light-mode
    /// tweak reaches across and edits it. 2:1 rather than 3:1 because the shipped Oura `deep` is 2.02:1 on
    /// the dark card — a real weak spot, but a pre-existing one and not this change's business.
    func testDarkRampIsUnchangedAndStillClearsTwoToOneOnTheDarkCard() {
        XCTAssertEqual(StrandPalette.BrandSleepRamp.ouraAwake.dark, "#EAE3D3")
        XCTAssertEqual(StrandPalette.BrandSleepRamp.ouraDeep.dark, "#206080")
        XCTAssertEqual(StrandPalette.BrandSleepRamp.garminAwake.dark, "#F26FE8")
        XCTAssertEqual(StrandPalette.BrandSleepRamp.garminDeep.dark, "#2472D8")
        for (name, ramp) in ramps {
            for (i, pair) in ramp.enumerated() {
                let c = contrast(pair.dark, darkSurface)
                XCTAssertGreaterThanOrEqual(
                    c, 2.0,
                    "\(name) band \(i) \(pair.dark) is \(String(format: "%.2f", c)):1 on \(darkSurface)")
            }
        }
    }

    /// A ramp is an ORDERED scale — light-to-dark is what makes it read as one. A per-band clamp destroys
    /// that (see the file header); a uniform lightness scale is monotone, so each ramp's own luminance order
    /// must survive into the light variant.
    func testLightVariantPreservesEachRampsOwnLuminanceOrder() {
        for (name, ramp) in ramps {
            let darkOrder  = ramp.indices.sorted { luminance(ramp[$0].dark)  > luminance(ramp[$1].dark) }
            let lightOrder = ramp.indices.sorted { luminance(ramp[$0].light) > luminance(ramp[$1].light) }
            XCTAssertEqual(lightOrder, darkOrder,
                           "\(name): the light variant reorders the ramp (dark \(darkOrder) vs light \(lightOrder))")
        }
    }

    /// ...and the stages must stay as separable from EACH OTHER as they already were. This is the property
    /// the naive per-band clamp fails: it passes the 3:1 test above while collapsing two stages onto the
    /// same colour.
    ///
    /// Two rules, because either alone has a hole. RELATIVE (no pair loses more than 30% of its separation)
    /// catches a ramp squashed flat — worst observed under the uniform scale is 0.76 (Oura light vs deep),
    /// against 0.42 for the naive clamp. ABSOLUTE (a pair that was distinguishable stays distinguishable)
    /// catches a single pair collapsing while the rest of the ramp looks healthy, which is exactly the naive
    /// clamp's Oura `rem` vs `light`: 1.47 → 1.00. The 1.20 floor is grandfathered against the SHIPPED dark
    /// ramp, so pairs that are already luminance-close there (Garmin awake vs light, 1.02:1 — magenta vs
    /// blue, separated by hue not lightness) are not held to a bar the original never met.
    func testLightVariantDoesNotWorsenSeparationBetweenStages() {
        let collapseFloor = 1.20
        for (name, ramp) in ramps {
            for i in ramp.indices {
                for j in ramp.indices where j > i {
                    let dark  = contrast(ramp[i].dark,  ramp[j].dark)
                    let light = contrast(ramp[i].light, ramp[j].light)
                    XCTAssertGreaterThanOrEqual(
                        light / dark, 0.70,
                        "\(name) \(i) vs \(j): separation drops \(String(format: "%.2f", dark)) → \(String(format: "%.2f", light))")
                    if dark >= collapseFloor {
                        XCTAssertGreaterThanOrEqual(
                            light, collapseFloor,
                            "\(name) \(i) vs \(j): a pair that was separable in dark (\(String(format: "%.2f", dark))) collapses in light (\(String(format: "%.2f", light)))")
                    }
                }
            }
        }
    }

    /// The trap, pinned as a value so it cannot be re-derived by accident: clamping each band to 3:1 on its
    /// own gives Oura `rem` #1E9EDD and `light` #239FD5, which are the same colour to the eye. If a future
    /// change adopts a per-band clamp, the test above fails — this one says why in one line.
    func testNaivePerBandClampWouldCollapseTwoOuraStages() {
        XCTAssertEqual(contrast("#1E9EDD", "#239FD5"), 1.00, accuracy: 0.02)
        XCTAssertGreaterThan(contrast(StrandPalette.BrandSleepRamp.ouraREM.light,
                                      StrandPalette.BrandSleepRamp.ouraLight.light), 1.20)
    }

    /// The eight light hexes, pinned literally. They are the byte-identical contract with the Kotlin twin,
    /// and a silent edit on one platform is exactly the divergence the parity rule exists to stop.
    func testLightHexesArePinnedForKotlinParity() {
        XCTAssertEqual(StrandPalette.BrandSleepRamp.oura.map(\.light),
                       ["#AD9153", "#1A8AC2", "#176B8E", "#12374A"])
        XCTAssertEqual(StrandPalette.BrandSleepRamp.garmin.map(\.light),
                       ["#EF52E3", "#D91EC7", "#3099F0", "#2168C5"])
    }
}
