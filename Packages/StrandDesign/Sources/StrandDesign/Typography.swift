import SwiftUI

// MARK: - Strand Typography (§9.2)
//
// SF Pro (Display ≥20pt, Text <20pt); tabular/monospaced digits everywhere for
// live values. SF Mono for raw/log views. Overline = sparing ALL-CAPS w/ tracking.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number. SF Pro **Rounded** (Bevel),
    /// tabular digits so a changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    /// A rounded-design numeric style at an arbitrary size/weight — the Bevel house
    /// numeral. Tabular so live values align. Use anywhere a score/number is shown.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Title1 28 / Bold.
    public static let title1 = Font.system(size: 28, weight: .bold)

    /// Title2 22 / Semibold.
    public static let title2 = Font.system(size: 22, weight: .semibold)

    /// Headline 17 / Semibold.
    public static let headline = Font.system(size: 17, weight: .semibold)

    /// Body 15 / Regular.
    public static let body = Font.system(size: 15, weight: .regular)

    /// Subhead 13.
    public static let subhead = Font.system(size: 13, weight: .regular)

    /// Caption 12.
    public static let caption = Font.system(size: 12, weight: .regular)

    /// Footnote 11.
    public static let footnote = Font.system(size: 11, weight: .regular)

    /// Overline 11 / Semibold, +0.8 tracking (apply `.tracking(0.8)` at use site;
    /// `overlineText(_:)` does it for you). Sparing ALL-CAPS labels.
    public static let overline = Font.system(size: 11, weight: .semibold)

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight, for live values — SF Pro
    /// **Rounded** (Bevel), tabular digits. This is the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Rounded-design body number — for inline live values that should align.
    public static let bodyNumber = Font.system(size: 15, weight: .medium, design: .rounded).monospacedDigit()

    /// Rounded-design caption number — for small live values (sparklines, chips).
    public static let captionNumber = Font.system(size: 12, weight: .medium, design: .rounded).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The recommended tracking for overline text.
    public static let overlineTracking: CGFloat = 0.8
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, semibold, +0.8 tracking, tertiary text.
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
            Text("88").font(StrandFont.display(72)).foregroundStyle(StrandPalette.textPrimary)
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
