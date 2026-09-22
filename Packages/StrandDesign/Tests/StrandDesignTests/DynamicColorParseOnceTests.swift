import XCTest
import SwiftUI
@testable import StrandDesign

/// #2393: the dynamic colour provider must not parse a hex string.
///
/// `Color.init(light:dark:)` builds a `UIColor`/`NSColor` dynamic provider, and that closure runs once
/// per RESOLUTION, not once per token. The liquid layer resolves every frame: `liquidComponents()` asks
/// for `NSColor(self).usingColorSpace(.sRGB)`, which re-invokes the provider. While the provider called
/// `sRGBComponents(hex:)`, every frame ran `trimmingCharacters` plus a `Scanner` over a string, which is
/// how a reporter's profile of NOOP at a third to half a CPU core came to show
/// `Color.sRGBComponents(hex:)` and `closure #1 in Color.init(light:dark:)` among its hot leaves.
///
/// This is a source census rather than a behavioural test for the reason `BrandSleepRampTests` already
/// gives: a dynamic `Color` cannot be read back, so the resolved value is not available to assert on.
/// What CAN be pinned is the shape the fix depends on, and the regression is silent: reintroducing a
/// parse inside either closure looks correct, renders identically, and quietly restores the per-frame
/// string work.
final class DynamicColorParseOnceTests: XCTestCase {

    private func dynamicInitBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StrandDesignTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // StrandDesign
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
        let src = try String(contentsOf: root.appendingPathComponent(
            "Packages/StrandDesign/Sources/StrandDesign/Palette.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "init(light: String, dark: String) {"),
                                  "the dynamic token initialiser moved or was renamed")
        // The initialiser is the last member of the extension, so its body runs to the closing brace
        // pair that ends the extension. Cutting at the NEXT top-level `// MARK:` is stable against
        // formatting and does not depend on counting braces.
        let rest = src[start.upperBound...]
        let end = rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Exactly two parses: the two hoisted `let`s. A third means one crept back into a closure.
    ///
    /// Comment lines are dropped first. The initialiser's own comment explains the fix by naming the
    /// function, and counting that would make this test fail on an accurate description of the code it
    /// is guarding.
    func testTheHexIsParsedExactlyTwicePerToken() throws {
        let body = try dynamicInitBody()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let parses = body.components(separatedBy: "sRGBComponents(hex:").count - 1
        XCTAssertEqual(parses, 2,
                       "the provider must pick between two pre-parsed tuples, not parse per resolution")
    }

    /// Both appearances must come from the hoist, or one branch is still parsing per resolution.
    func testBothAppearancesReadTheHoistedComponents() throws {
        let body = try dynamicInitBody()
        XCTAssertTrue(body.contains("light: Color.sRGBComponents(hex: light)"))
        XCTAssertTrue(body.contains("dark: Color.sRGBComponents(hex: dark)"))
        XCTAssertTrue(body.contains("components.light"), "the light branch must read the hoisted pair")
        XCTAssertTrue(body.contains("components.dark"), "the dark branch must read the hoisted pair")
    }

    /// The parser itself is untouched by the hoist, so its output stays pinned here.
    func testTheParserStillDecodesRGBAndRGBA() {
        let rgb = Color.sRGBComponents(hex: "#F3F4F6")
        XCTAssertEqual(rgb.r, 243.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(rgb.g, 244.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(rgb.b, 246.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(rgb.a, 1.0, accuracy: 1e-12)

        let rgba = Color.sRGBComponents(hex: "12345680")
        XCTAssertEqual(rgba.r, 18.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(rgba.a, 128.0 / 255.0, accuracy: 1e-12)
    }
}
