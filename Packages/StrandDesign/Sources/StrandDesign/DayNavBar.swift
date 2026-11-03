#if !os(watchOS)
// The watch app never shows the day navigator (no DatePicker(.graphical) / .popover on watchOS),
// so this whole control is excluded there; iOS/macOS are unchanged.
import SwiftUI

// MARK: - DayNavBar — chevron + date-jump day selector
//
// The Today screen's day navigator: ◀/▶ chevrons step one day at a time (◀ older, ▶ newer,
// disabled at today so a future day can't be selected), and the centre accent block shows the
// selected day's label + date and opens a graphical DatePicker capped at today for a direct jump.
// Replaces the fixed three-day strip so navigation reaches arbitrarily far back. The same control
// renders on macOS and iOS — the DatePicker is shown in a popover on both. Mirrors the Android
// DayNavBar (StrandComponents.kt). Offset is days-back-from-today (0 = today).

public struct DayNavBar: View {
    private let selectedOffset: Int
    private let today: Date
    private let onSelect: (Int) -> Void

    @State private var showingPicker = false
    @Environment(\.locale) private var locale

    /// `today` is the caller's LOGICAL day (the same anchor the rest of Today uses, rolling at 04:00),
    /// so every label here counts back from it. Passing it in instead of reading `Date()` keeps the
    /// macOS full-date label in step with the data shown in the 00:00-04:00 window, where a raw
    /// `Date()` already reads the next calendar day while the screen still shows the logical day (#14).
    public init(selectedOffset: Int, today: Date, onSelect: @escaping (Int) -> Void) {
        self.selectedOffset = selectedOffset
        self.today = today
        self.onSelect = onSelect
    }

    /// The calendar day the current offset resolves to, counting back from the caller's logical day.
    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: -selectedOffset, to: today) ?? today
    }

    private var canGoNewer: Bool { selectedOffset > 0 }

    private var label: LocalizedStringKey {
        switch selectedOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let formattedDay = selectedDay.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
            )
            return LocalizedStringKey(formattedDay)
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Button { onSelect(selectedOffset + 1) } label: {
                stepGlyph("chevron.left", enabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Previous day", bundle: .module))

            // Centre accent block — the selected day's label + full date, tappable to jump.
            Button { showingPicker = true } label: {
                VStack(spacing: 2) {
                    // The day as a bold ALL-CAPS label between a calendar glyph and a disclosure chevron,
                    // so the pill reads as a date picker.
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                        Text(label, bundle: .module)
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    // On today the label already reads "Today"; the full date would just duplicate the
                    // header, so it's shown only once you've navigated to another day (for orientation).
                    if selectedOffset > 0 {
                        Text(selectedDay.formatted(
                            .dateTime.day().month(.abbreviated).year().locale(locale)
                        ))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                // Reads as one of the flat WHOOP-grey cards, not a black bar. On macOS the full-width
                // pill sits over the bright Today day-scene, where the darker inset well read as black;
                // surfaceRaised (the card fill) lifts it to card level so it matches the dashboard
                // cards. No gold wash behind the date — the gold pop lives only on the date text.
                .background(blockFill, in: blockShape)
                .overlay(blockShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pick a date", bundle: .module))
            .popover(isPresented: $showingPicker) {
                datePickerPopover
            }

            Button { if canGoNewer { onSelect(selectedOffset - 1) } } label: {
                stepGlyph("chevron.right", enabled: canGoNewer)
            }
            .buttonStyle(.plain)
            .disabled(!canGoNewer)
            .accessibilityLabel(Text("Next day", bundle: .module))
            Spacer(minLength: 0)
        }
    }

    /// Graphical date jump, capped at today so a future day can't be picked. Converting the chosen
    /// date back to a whole-day offset keeps the rest of the screen driven by the single offset value.
    private var datePickerPopover: some View {
        // A local binding so the picker writes straight through to an offset via onSelect.
        let pickedBinding = Binding<Date>(
            get: { selectedDay },
            set: { newValue in
                let cal = Calendar.current
                let start = cal.startOfDay(for: newValue)
                // Offset is measured from the caller's LOGICAL day (not raw Date()), so a date picked in
                // the 00:00-04:00 window maps to the same offset the labels count back from (#14).
                let anchor = cal.startOfDay(for: today)
                let days = cal.dateComponents([.day], from: start, to: anchor).day ?? 0
                onSelect(max(0, days))
                showingPicker = false
            }
        )
        return DatePicker("", selection: pickedBinding, in: ...today, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            // #840 — iPad popover needs an explicit size or the graphical picker clips. Safe on macOS 13
            // and iPhone (the popover/sheet sizes to this); avoids the macOS 13.3-only compact-adaptation API.
            .frame(minWidth: 320, minHeight: 360)
    }

    private var blockShape: Capsule { Capsule(style: .continuous) }

    /// A previous/next step control: a small round card-grey button holding the chevron, inside a ≥44pt
    /// hit target (HIG). A disabled step dims its glyph.
    private func stepGlyph(_ systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            .frame(width: 28, height: 28)
            .background(StrandPalette.surfaceRaised, in: Circle())
            .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// Fill for the centre day block. On macOS the bar spans the bright Today day-scene, so it uses the
    /// raised WHOOP-grey card fill to read as a card rather than a black bar; iOS (which uses the compact
    /// top-bar day-nav, not this control) keeps the inset well fill unchanged.
    private var blockFill: Color {
        #if os(macOS)
        // The card grey, slightly translucent so an optional day-scene backdrop still shows through and
        // the pill reads as a floating control rather than a solid bar.
        StrandPalette.surfaceRaised.opacity(0.92)
        #else
        StrandPalette.surfaceRaised
        #endif
    }

}
#endif
