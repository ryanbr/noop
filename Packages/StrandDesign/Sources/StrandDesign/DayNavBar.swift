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
        default: return "\(Self.dayFmt.string(from: selectedDay))"
        }
    }

    public var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button { onSelect(selectedOffset + 1) } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 44, height: 44)        // ≥44pt hit target (HIG); glyph stays 17pt
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Previous day", bundle: .module))

            // Centre accent block — the selected day's label + full date, tappable to jump.
            Button { showingPicker = true } label: {
                VStack(spacing: 2) {
                    Text(label, bundle: .module)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    // On today the label already reads "Today"; the full date would just duplicate the
                    // header, so it's shown only once you've navigated to another day (for orientation).
                    if selectedOffset > 0 {
                        Text(Self.fullDateFmt.string(from: selectedDay))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.accent)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 20)
                // Reads as one of the flat WHOOP-grey cards, not a black bar. On macOS the full-width
                // pill sits over the bright Today day-scene, where the darker inset well read as black;
                // surfaceRaised (the card fill) lifts it to card level so it matches the dashboard
                // cards. No gold wash behind the date — the gold pop lives only on the date text.
                .background(blockFill, in: blockShape)
                .overlay(blockShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pick a date")
            .popover(isPresented: $showingPicker) {
                datePickerPopover
            }

            Button { if canGoNewer { onSelect(selectedOffset - 1) } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(canGoNewer ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)        // ≥44pt hit target (HIG); glyph stays 17pt
                    .contentShape(Rectangle())
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

    private var blockShape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    /// Fill for the centre day block. On macOS the bar spans the bright Today day-scene, so it uses the
    /// raised WHOOP-grey card fill to read as a card rather than a black bar; iOS (which uses the compact
    /// top-bar day-nav, not this control) keeps the inset well fill unchanged.
    private var blockFill: Color {
        #if os(macOS)
        // Compact translucent pill (not a full-width bar) — the scene shows through so it reads as a
        // floating control over the day-scene, never a solid black bar; white label stays legible at 0.72.
        StrandPalette.surfaceBase.opacity(0.72)
        #else
        StrandPalette.surfaceInset
        #endif
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
#endif
