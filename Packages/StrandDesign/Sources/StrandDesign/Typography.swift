import SwiftUI

// MARK: - Strand Typography (§9.2)
//
// Helvetica Neue everywhere (Titanium & Gold): a precise, mechanical grotesque
// in place of the old rounded face. Tabular/monospaced digits on every numeric
// role so live values don't reflow. SF Mono stays for raw/log views. Overline =
// sparing ALL-CAPS w/ wide tracking.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    /// The house family — Helvetica Neue, a built-in system face. Weight is applied
    /// via `.weight()` since `Font.custom` ignores the design's default weight.
    private static let family = "Helvetica Neue"

    /// Helvetica Neue at a FIXED size/weight — used by the big gauge/tile numerals (`display`,
    /// `rounded`, `number`) that live in fixed-geometry rings/tiles where unbounded growth would
    /// overflow. Prose and inline-number roles use `helveticaScaled` instead.
    private static func helvetica(_ size: CGFloat, weight: Font.Weight) -> Font {
        .custom(family, size: size).weight(weight)
    }

    /// Like `helvetica`, but the size SCALES with the user's Dynamic Type / Larger Text setting,
    /// anchored to a matching text style. The plain `.custom(_:size:)` overload produces a FROZEN
    /// point size, so every prose/label role used to ignore Dynamic Type entirely — this routes them
    /// through `.custom(_:size:relativeTo:)` so they scale (available on the iOS 16 / macOS 13 floor).
    private static func helveticaScaled(_ size: CGFloat, weight: Font.Weight,
                                        relativeTo style: Font.TextStyle) -> Font {
        .custom(family, size: size, relativeTo: style).weight(weight)
    }

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number. Helvetica Neue 700 with tight
    /// tracking (≈ -0.04em), tabular digits so a changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        helvetica(size, weight: .bold).monospacedDigit()
    }

    /// The tight tracking for big display numbers (≈ -0.04em). Apply alongside
    /// `display(_:)` at the use site, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// A Helvetica-Neue numeric style at an arbitrary size/weight — the house
    /// numeral. Tabular so live values align. Use anywhere a score/number is shown.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        helvetica(size, weight: weight).monospacedDigit()
    }

    /// Title1 28 / Bold. Scales with Dynamic Type.
    public static let title1 = helveticaScaled(28, weight: .bold, relativeTo: .title)

    /// Title2 22 / Semibold. Scales with Dynamic Type.
    public static let title2 = helveticaScaled(22, weight: .semibold, relativeTo: .title2)

    /// Headline 17 / Semibold. Scales with Dynamic Type.
    public static let headline = helveticaScaled(17, weight: .semibold, relativeTo: .headline)

    /// Body 15 / Regular. Scales with Dynamic Type.
    public static let body = helveticaScaled(15, weight: .regular, relativeTo: .body)

    /// Subhead 13. Scales with Dynamic Type.
    public static let subhead = helveticaScaled(13, weight: .regular, relativeTo: .subheadline)

    /// Caption 12. Scales with Dynamic Type.
    public static let caption = helveticaScaled(12, weight: .regular, relativeTo: .caption)

    /// Caption2 10 — the smallest label role (e.g. launch-tile captions). Scales with Dynamic Type.
    public static let caption2 = helveticaScaled(10, weight: .regular, relativeTo: .caption2)

    /// Footnote 11. Scales with Dynamic Type.
    public static let footnote = helveticaScaled(11, weight: .regular, relativeTo: .footnote)

    /// Overline 11 / Bold, +1.4 tracking (apply `.tracking(1.4)` at use site;
    /// `overlineText(_:)` does it for you). Sparing ALL-CAPS labels. Scales with Dynamic Type.
    public static let overline = helveticaScaled(11, weight: .bold, relativeTo: .caption2)

    /// `overline` at a custom point size — same Helvetica face, weight and Dynamic-Type scaling
    /// (relativeTo `.caption2`), just smaller. Passing 11 returns exactly `.overline`. Lets a caller
    /// shrink an ALL-CAPS label to fit a small container without losing accessibility text-scaling.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        helveticaScaled(size, weight: .bold, relativeTo: .caption2)
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight, for live values — Helvetica
    /// Neue, tabular digits. This is the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        helvetica(size, weight: weight).monospacedDigit()
    }

    /// Helvetica-Neue body number — for inline live values that should align. Scales with Dynamic
    /// Type alongside its sibling `body`/`caption` labels so a value and its label stay matched.
    public static let bodyNumber = helveticaScaled(15, weight: .medium, relativeTo: .body).monospacedDigit()

    /// Helvetica-Neue caption number — for small live values (sparklines, chips). Scales with Dynamic Type.
    public static let captionNumber = helveticaScaled(12, weight: .medium, relativeTo: .caption).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Symbol sizing for icon-only chrome. Geometry comes from `NoopMetrics`; this helper keeps
    /// screen files from constructing ad-hoc system fonts while preserving the native symbol face.
    public static func symbol(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The recommended tracking for overline text (wide ALL-CAPS labels, ≈ 0.13em).
    public static let overlineTracking: CGFloat = 1.4
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, bold, +1.4 tracking, tertiary text.
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
