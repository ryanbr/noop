import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum NoopMetrics {
    public static let cardRadius: CGFloat = NoopVisualStyle.cardRadius
    public static let cardPadding: CGFloat = NoopVisualStyle.cardPadding
    public static let gap: CGFloat = NoopVisualStyle.itemGap
    public static let sectionGap: CGFloat = NoopVisualStyle.sectionGap
    public static let screenPadding: CGFloat = NoopVisualStyle.pagePadding
    public static let tileHeight: CGFloat = 96   // Design Reset: tighter metric tile
    // Key Metrics grid: one fixed height every tile snaps to, so a sparkline-and-caption tile and a
    // plain value tile read the same. maxHeight: .infinity can't equalise them inside a LazyVGrid (the
    // grid only offers a cell its content height, so there's nothing for the shorter tile to grow into),
    // so we pin a single height that clears the tallest layout (value + inline sparkline + caption).
    public static let keyMetricTileHeight: CGFloat = 122
    public static let chartHeight: CGFloat = 220
    /// Canonical compact provenance-chip height; shared with overlays that align the chip to a border.
    public static let sourceBadgeHeight: CGFloat = 18
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar

    // MARK: Standardised spacing scale (the ONE source of truth for margins)
    //
    // A 4pt-based ramp. Reach for these instead of literal numbers so every gap,
    // inset and margin lines up to the same grid. Note `cardPadding` (16) above is
    // the same value as `space4` — kept as a named alias for the existing call sites.
    public static let space1:  CGFloat = 4
    public static let space2:  CGFloat = 8
    public static let space3:  CGFloat = 12
    public static let space4:  CGFloat = 16
    public static let space5:  CGFloat = 20
    public static let space6:  CGFloat = 24
    public static let space8:  CGFloat = 32
    public static let space10: CGFloat = 40

    // MARK: Named layout constants — the canonical margins/heights screens compose with.
    /// Horizontal page margin (the gutter on the left/right edge of a screen). Use via `.screenPadding()`.
    public static let screenHPadding: CGFloat = NoopVisualStyle.pagePadding
    /// Vertical gap between top-level page sections.
    public static let sectionSpacing: CGFloat = NoopVisualStyle.sectionGap
    /// Interior padding inside a card's content (matches `cardPadding`).
    public static let cardInnerPadding: CGFloat = 16
    /// Vertical gap between stacked elements INSIDE a card.
    public static let cardInnerSpacing: CGFloat = 12
    /// Vertical gap between rows in a list-style card.
    public static let rowSpacing: CGFloat = 10
    /// Standard interactive-control height (buttons, fields, segmented controls).
    public static let controlHeight: CGFloat = 48
    /// Fully-rounded corner radius — pills, chips, capsule buttons.
    public static let pillRadius: CGFloat = NoopVisualStyle.pillRadius
    /// Minimum desktop size for a navigation-based customization sheet.
    public static let editorSheetMinWidth: CGFloat = 440
    public static let editorSheetMinHeight: CGFloat = 600
}

// MARK: - Screen padding

public extension View {
    /// Apply the canonical horizontal page gutter (`NoopMetrics.screenHPadding`). The single
    /// source of truth for left/right screen margins — use this instead of a literal padding so
    /// every screen lines up to the same edge.
    func screenPadding() -> some View {
        self.padding(.horizontal, NoopMetrics.screenHPadding)
    }
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: the drag indicator (the touch affordance that says
    /// "swipe to dismiss") plus detents. macOS sheets are free-floating windows and must
    /// NOT receive this, so the helper is iOS-only and call sites stay shared via #if.
    /// `largeFirst == false` opens at .medium with .large reachable by dragging up (short
    /// forms); `true` opens full-height (long scrolls).
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        self
            .presentationDragIndicator(.visible)
            .presentationDetents(largeFirst ? [.large] : [.medium, .large])
    }
}
#endif

// MARK: - Surface

/// The one card surface — now the Bevel frosted card. PUBLIC API is unchanged
/// (padding + content); an optional `tint` was ADDED (defaulted) so callers can opt
/// into a per-domain accent wash without breaking existing call sites.
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = NoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome (fill + border + shadow) lives in the background so its animation is
            // scoped to the card surface ONLY. It must never animate the content() subtree, or a
            // chart inside re-animates its line every time the cursor crosses the card. (#104)
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static resting frosted surface — no
    // hover @State, no .onHover tracking, no .animation node. That trims the modifier
    // count on every card, which multiplies across long scrolling lists. macOS adds the
    // hover emphasis border on top (with the #104 animation scoping) unchanged.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1).opacity(hover ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.16), value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let overline: LocalizedStringKey?; let title: LocalizedStringKey; let trailing: String?
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil) {
        self.title = title; self.overline = overline; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline { Text(overline).strandOverline() }
                Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

public struct StatTile<Accessory: View>: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent
    /// An optional trailing accessory laid out INLINE in the header row beside the label (e.g. a small
    /// ⓘ that opens a scoring guide). Inline placement — not a corner overlay — so it can never sit on
    /// top of the value, sparkline or trend chip on a narrow tile (#495). Defaults to nothing.
    @ViewBuilder var accessory: () -> Accessory

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
        self.accessory = accessory
    }

    public var body: some View {
        // The tile borrows its accent as a faint card wash, so each metric tile reads as
        // part of its colour world while staying legible on the deep blue-black.
        NoopCard(padding: 14, tint: accent) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row: the metric label, and (right-aligned) the optional accessory laid out in
                // flow so it reserves its own space rather than floating over the value below (#495).
                HStack(alignment: .top, spacing: 4) {
                    Text(label).strandOverline()
                    Spacer(minLength: 0)
                    accessory()
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(StrandFont.number(26)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    // Trend chip — the delta as a tinted pill with a direction arrow.
                    if let delta { TrendChip(text: delta, color: deltaColor) }
                }
                // Sparkline isn't available on watchOS (it relies on chart-hover helpers); the watch
                // doesn't use StatTile, but guard the reference so the file still compiles there.
                #if !os(watchOS)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline, gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]))
                        .frame(height: 22).padding(.top, 4)
                        .accessibilityHidden(true)
                }
                #endif
                if let caption {
                    Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .padding(.top, 2)
                }
            }
        }
        // A FLOOR, not a fixed height: a sparkline tile's content exceeds the 96pt base and must be
        // allowed to grow rather than clip. maxHeight: .infinity lets a caller that DOES hand this tile a
        // bounded height (e.g. the Key Metrics grid pins every cell to NoopMetrics.keyMetricTileHeight)
        // stretch it to fill; in an unbounded parent it resolves to the content's own height, unchanged.
        // Note: inside a LazyVGrid the cell only offers content height, so equal heights come from the
        // caller pinning a fixed height, not from maxHeight: .infinity alone.
        .frame(minHeight: NoopMetrics.tileHeight, maxHeight: .infinity)
        // One VoiceOver stop per tile (label, value, caption, delta) instead of up
        // to four fragmented stops; the decorative sparkline is hidden above.
        .accessibilityElement(children: .combine)
    }
}

// Backward-compatible convenience: a StatTile with NO accessory (the common case) — every existing
// call site keeps working unchanged, and the type defaults `Accessory` to `EmptyView`.
public extension StatTile where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String, caption: String? = nil,
         accent: Color = StrandPalette.textPrimary, delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.init(label: label, value: value, caption: caption, accent: accent, delta: delta,
                  deltaColor: deltaColor, sparkline: sparkline, sparkColor: sparkColor,
                  accessory: { EmptyView() })
    }
}

// MARK: - Trend chip — a small tinted delta pill with a direction arrow.

/// A compact trend pill: an up/down/flat arrow + the delta text, tinted to `color`.
/// Inferred direction comes from a leading +/− in the text (else flat). Sits in the
/// corner of a StatTile or beside a metric value.
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        // No sign → a plain magnitude (e.g. a workout's "874 kcal"), not a trend: show NO direction
        // glyph. Previously this fell to "minus", whose leading dash read as a negative ("-874 kcal" — #41).
        return nil
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            // One line, always: a long chip (e.g. a workout's kcal) truncates rather than wraps, so
            // the pill never grows a tile past its floor. Matches Android's unconditional ellipsize (#934).
            Text(text).font(StrandFont.captionNumber).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    var tint: Color? = nil
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight, tint: Color? = nil,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).strandOverline()
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).textCase(.uppercase).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    /// Extra trailing inset reserved on the overline + status rows so a caller's
    /// `.overlay(alignment: .topTrailing)` (greeting + state pill) doesn't run over the
    /// card's own title text on a narrow screen (#69). Defaults to 0 — no effect unless set.
    var titleTrailingInset: CGFloat = 0
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil, titleTrailingInset: CGFloat = 0) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint; self.titleTrailingInset = titleTrailingInset
    }
    public var body: some View {
        // Defaults the card wash to the status colour so the coaching card sits in the
        // same colour world as the score it summarises (e.g. gold for Charge). The
        // insight card reads a touch stronger than a tile: an explicit hue wash
        // (.14 → .04) + a matching .22 hue border on top of the frosted surface.
        let hue = tint ?? statusColor
        // Apple-flat: a plain flat card. Identity comes from the COLOURED status headline alone — no extra
        // hue-gradient wash, no border (so it reads identical to every other card on the page).
        return NoopCard(padding: 18, tint: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                    .padding(.trailing, titleTrailingInset)
                Text(status).font(StrandFont.rounded(28, weight: .bold)).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, titleTrailingInset)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    /// When requested, keep the regular intrinsic control wherever it fits and fall back to
    /// equal-width segments inside the parent's available width on compact screens. This prevents
    /// long option sets from widening an entire page beyond the viewport while leaving the many
    /// shorter segmented controls byte-identical.
    let adaptsToAvailableWidth: Bool
    /// Per-segment availability (#943): a disabled segment stays visible (so users learn the
    /// option exists) but renders extra-dim and ignores taps; VoiceOver announces it dimmed.
    /// Defaults to everything enabled; ADDED additively, no existing call site touched.
    let isEnabled: (T) -> Bool
    let fillsAvailableWidth: Bool
    @Binding var selection: T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                label: @escaping (T) -> String) {
        self.init(items, selection: selection, adaptsToAvailableWidth: adaptsToAvailableWidth,
                  fillsAvailableWidth: fillsAvailableWidth,
                  isEnabled: { _ in true }, label: label)
    }
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                isEnabled: @escaping (T) -> Bool,
                label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.adaptsToAvailableWidth = adaptsToAvailableWidth
        self.fillsAvailableWidth = fillsAvailableWidth
        self.isEnabled = isEnabled
        self.label = label
    }
    @ViewBuilder
    public var body: some View {
        if fillsAvailableWidth {
            track(equalWidth: true)
        } else if adaptsToAvailableWidth {
            if dynamicTypeSize > .large {
                ScrollView(.horizontal, showsIndicators: false) {
                    track(equalWidth: false)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    track(equalWidth: false)
                    track(equalWidth: true)
                }
            }
        } else {
            track(equalWidth: false)
        }
    }

    private func track(equalWidth: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                let enabled = isEnabled(item)
                Button {
                    guard selection != item else { return }   // re-tapping the active segment stays silent
                    StrandHaptic.selection.play()
                    withAnimation(StrandMotion.interactive) { selection = item }
                } label: {
                    Text(label(item))
                        .font(StrandFont.captionNumber)
                        .lineLimit(equalWidth ? 1 : nil)
                        // Range selection stays deliberately neutral so the control works above charts
                        // from every metric colour world without borrowing their green/blue/amber tint.
                        // Disabled segments drop to a fainter tertiary so the lock reads at a glance.
                        .foregroundStyle(sel ? StrandPalette.textPrimary
                                             : StrandPalette.textTertiary.opacity(enabled ? 1 : 0.35))
                        // Fill the segment height so the selected pill has EQUAL margins to the track
                        // on every side. (The old compact pill inside a taller 44pt touch frame left
                        // more vertical margin than horizontal — it read as off-centre.)
                        .frame(minWidth: equalWidth ? nil : 26,
                               maxWidth: equalWidth ? .infinity : nil,
                               maxHeight: .infinity)
                        .padding(.horizontal, equalWidth ? NoopMetrics.space1 : 9)
                        .background {
                            if sel {
                                let selectedShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                                selectedShape
                                    .fill(
                                        LinearGradient(
                                            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surface],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        selectedShape.strokeBorder(
                                            NoopVisualStyle.borderHighlight.opacity(0.62),
                                            lineWidth: 0.75
                                        )
                                    )
                                    .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: equalWidth ? .infinity : nil)
                .frame(height: 32)   // segment height; the pill fills it for an even inset
                .disabled(!enabled)
                // Announce the active range to VoiceOver and give a non-colour cue.
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: equalWidth ? .infinity : nil)
        .background {
            let trackShape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            trackShape
                .fill(
                    LinearGradient(
                        colors: [NoopVisualStyle.inset, NoopVisualStyle.canvas.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    trackShape.strokeBorder(
                        LinearGradient(
                            colors: [NoopVisualStyle.borderHighlight.opacity(0.48), NoopVisualStyle.border],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        // `.frame(height:)` centres its content by default, so the label sits mid-capsule for free. Noted
        // because the Android twin pinned the same 18 with `heightIn` applied to the label itself, which
        // top-aligns — same number, different render. That one is matched to this, not the reverse.
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(0.5)
            .padding(.horizontal, 9).frame(height: NoopMetrics.sourceBadgeHeight)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .foregroundStyle(tint)
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.34), lineWidth: 1))
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for whole-number-or-decimal entry on iOS: the decimal-pad
    /// keyboard (handles both integer Avg-HR and decimal calories). No-op on macOS
    /// (hardware keyboard), so the SAME shared view compiles on both. Pair with
    /// `.keyboardDoneToolbar(...)` on the enclosing view to add a Done button (the decimal
    /// pad has no return key).
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a single trailing "Done" button to the software-keyboard accessory bar that
    /// resigns the given focus binding. iOS-only; the keyboard toolbar is hosted by the
    /// keyboard itself, so it works inside a sheet with no NavigationStack. No-op on macOS.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Titanium & Gold) — ADDED additively, no existing API touched.
//
// Three house button styles for primary actions, secondary chrome and ghost/gold
// CTAs. Drop in via `.buttonStyle(.noopPrimary)` etc. on any `Button`. All read off
// the new gold tokens so they match Apple ⇄ Android. Pressed = subtle dim + scale.

/// Primary call-to-action: gold-gradient fill, dark gold-deep ink (700), rounded 13.
public struct NoopPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(StrandFont.body.weight(.bold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(gradient: StrandPalette.goldGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // A crisp, subtle NEUTRAL elevation — the gold cast-glow read as too much against the
            // clean design, so it's a soft dark lift now, no bloom.
            .shadow(color: .black.opacity(pressed ? 0.08 : 0.16), radius: 6, x: 0, y: 3)
            .opacity(pressed ? 0.9 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: inset well + 1px white-12 border + primary text. Quieter than gold.
public struct NoopSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost / gold: transparent + 1px gold@.3 hairline + gold text. Tertiary CTA.
public struct NoopGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.gold)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.gold.opacity(pressed ? 0.10 : 0)))
            .overlay(shape.strokeBorder(StrandPalette.gold.opacity(0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == NoopPrimaryButtonStyle {
    /// Gold-gradient primary CTA.
    static var noopPrimary: NoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: NoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopGhostButtonStyle {
    /// Transparent gold-outline ghost button.
    static var noopGhost: NoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// ADDED additively — the existing `StatePill` (tone-based, in StatePill.swift) is
// untouched. This is the score-lifecycle chip the new design calls for: SOLID = gold
// fill, BUILDING = blue, CALIBRATING = slate, LIVE = gold dot with a pulsing halo.

public enum ScoreState: Sendable, Equatable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's hue, drawn from the re-pointed palette (gold / blue / slate).
    public var color: Color {
        switch self {
        case .solid:        return StrandPalette.statusPositive // settled / trustworthy — WHOOP green
        case .live:         return StrandPalette.accent          // streaming now — WHOOP blue
        case .building:     return StrandPalette.sleepLight   // #4A90E2 blue
        case .calibrating:  return StrandPalette.textTertiary // #8A94A4 slate
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip: dot + hue@.12 fill + hue@.32 border + hue text. LIVE
/// pulses its dot. `text` overrides the default state label (e.g. "Building — 2 of 4").
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        let hue = state.color
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .font(StrandFont.overline)
                .tracking(0.4)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(hue.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(hue.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// A small dot with an optional breathing pulse halo (LIVE). Honours Reduce Motion.
/// Local to the score pill so it doesn't disturb StatePill.swift's ConnectionDot.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP". This halo is a `repeatForever` loop that never
    /// settles and is on screen for long stretches — a connected strap in Settings, a backfill on
    /// every scaffolded screen — so it belongs behind the same gate as the liquid surfaces.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            // Dark-mode only (#review): AdditiveBloom used to hide this expanding ring on light
            // (content.opacity(0)); now that we drop the offscreen bloom, gate it explicitly so light
            // mode stays ring-free (the resting dot + its shadow carry the live state there).
            if pulsing && scheme == .dark {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every
                    // frame of the repeatForever pulse, a continuous cost while a strap is backfilling
                    // (exactly when this live dot is on screen). The expanding/fading ring reads the
                    // same without it; the resting dot's shadow still carries the "live" glow.
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing && !poseStill { animate = true } }
        .animation(pulsing && !poseStill ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}
