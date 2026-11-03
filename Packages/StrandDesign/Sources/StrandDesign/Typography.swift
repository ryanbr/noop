import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography (§9.2)
//
// SF Pro (the default system design) for all text: a clean, geometric grotesque that suits the slate
// dashboard. Score numerals use SF Pro's CONDENSED width at heavy weights, which gives the tall, narrow,
// engineered digits of a dashboard instrument. Named text styles retain Dynamic Type scaling. Labels
// above data are bold ALL-CAPS with wide (0.1em) tracking. SF Mono remains reserved for logs.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    /// The text face: SF Pro at a fixed size. (The name predates the switch away from SF Rounded and is
    /// kept so the scale below reads unchanged.)
    private static func roundedSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// The numeral face: SF Pro condensed, for score and metric values.
    private static func numeralSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .default).width(.condensed)
    }

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number. Helvetica Neue 700 with tight
    /// tracking (≈ -0.04em), tabular digits so a changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        numeralSystem(size, weight: .bold).monospacedDigit()
    }

    /// The tight tracking for big display numbers (≈ -0.04em). Apply alongside
    /// `display(_:)` at the use site, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// A Helvetica-Neue numeric style at an arbitrary size/weight — the house
    /// numeral. Tabular so live values align. Use anywhere a score/number is shown.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        numeralSystem(size, weight: weight).monospacedDigit()
    }

    /// Title1 28 / Bold. Scales with Dynamic Type.
    public static let title1 = Font.system(.title, design: .default, weight: .bold)

    /// Title2 22 / Semibold. Scales with Dynamic Type.
    public static let title2 = Font.system(.title2, design: .default, weight: .bold)

    /// Headline 17 / Semibold. Scales with Dynamic Type.
    public static let headline = Font.system(.headline, design: .default, weight: .semibold)

    /// Body 15 / Regular. Scales with Dynamic Type.
    public static let body = Font.system(.body, design: .default, weight: .regular)

    /// Subhead 13. Scales with Dynamic Type.
    public static let subhead = Font.system(.subheadline, design: .default, weight: .regular)

    /// Caption 12. Scales with Dynamic Type.
    public static let caption = Font.system(.caption, design: .default, weight: .regular)

    /// Footnote 11. Scales with Dynamic Type.
    public static let footnote = Font.system(.footnote, design: .default, weight: .regular)

    /// Overline 11 / Bold, +1.4 tracking (apply `.tracking(1.4)` at use site;
    /// `overlineText(_:)` does it for you). Sparing ALL-CAPS labels. Scales with Dynamic Type.
    ///
    /// Also the face for compact status copy in constrained chrome (the Today header's sync capsule),
    /// used there WITHOUT the tracking — that is sentence case, not an overline, and the letter-spacing
    /// is what makes an overline read as one.
    public static let overline = Font.system(.caption2, design: .default, weight: .bold)

    /// `overline` at a custom point size — same Helvetica face, weight and Dynamic-Type scaling
    /// (relativeTo `.caption2`), just smaller. Passing 11 returns exactly `.overline`. Lets a caller
    /// shrink an ALL-CAPS label to fit a small container without losing accessibility text-scaling.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        return Font(UIFontMetrics(forTextStyle: .caption2).scaledFont(for: base))
        #elseif canImport(AppKit)
        return Font(NSFont.systemFont(ofSize: size, weight: .bold))
        #else
        return roundedSystem(size, weight: .bold)
        #endif
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight, for live values — Helvetica
    /// Neue, tabular digits. This is the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        numeralSystem(size, weight: weight).monospacedDigit()
    }

    /// Helvetica-Neue body number — for inline live values that should align. Scales with Dynamic
    /// Type alongside its sibling `body`/`caption` labels so a value and its label stay matched.
    public static let bodyNumber = Font.system(.body, design: .default, weight: .semibold).monospacedDigit()

    /// Helvetica-Neue caption number — for small live values (sparklines, chips). Scales with Dynamic Type.
    public static let captionNumber = Font.system(.caption, design: .default, weight: .medium).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The tracking for overline text: wide ALL-CAPS labels at 0.1em of the 11pt overline.
    public static let overlineTracking: CGFloat = 1.1

    /// Tracking for an ALL-CAPS heading at `size` points (0.1em), for `SectionHeader` titles and other
    /// uppercase headings that are larger than an overline.
    public static func headingTracking(_ size: CGFloat) -> CGFloat {
        size * 0.1
    }
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, bold, 0.1em tracking, secondary text.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
