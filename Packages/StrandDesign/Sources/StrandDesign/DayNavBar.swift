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
    private let onSelect: (Int) -> Void

    @State private var showingPicker = false

    public init(selectedOffset: Int, onSelect: @escaping (Int) -> Void) {
        self.selectedOffset = selectedOffset
        self.onSelect = onSelect
    }

    /// The calendar day the current offset resolves to, counting back from the local day.
    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: -selectedOffset, to: Date()) ?? Date()
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
            Button { onSelect(selectedOffset + 1) } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")

            // Centre accent block — the selected day's label + full date, tappable to jump.
            Button { showingPicker = true } label: {
                VStack(spacing: 2) {
                    Text(label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(Self.fullDateFmt.string(from: selectedDay))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.accent)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(StrandPalette.accent.opacity(0.12), in: blockShape)
                .overlay(blockShape.strokeBorder(StrandPalette.accent.opacity(0.55), lineWidth: 1))
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
            }
            .buttonStyle(.plain)
            .disabled(!canGoNewer)
            .accessibilityLabel("Next day")
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
                let today = cal.startOfDay(for: Date())
                let days = cal.dateComponents([.day], from: start, to: today).day ?? 0
                onSelect(max(0, days))
                showingPicker = false
            }
        )
        return DatePicker("", selection: pickedBinding, in: ...Date(), displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
    }

    private var blockShape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
