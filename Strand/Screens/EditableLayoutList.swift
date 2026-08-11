import SwiftUI
import StrandDesign

/// Shared Shown / Hidden list used by Today sections, Key Metrics, and Your Cards.
struct EditableLayoutList<Item, Options>: View
where Item: Identifiable & Equatable, Options: View {
    @Binding var draft: EditableLayoutDraft<Item>

    let shownTitle: String
    let hiddenTitle: String
    let title: (Item) -> String
    let subtitle: (Item) -> String?
    let icon: (Item) -> String
    let tint: (Item) -> Color
    let configurationLabel: (Item) -> String?
    let onConfigure: (Item) -> Void
    let onReset: () -> Void
    /// Whether the Shown list may go EMPTY. Default false — every visible item can be hidden EXCEPT the
    /// last, so surfaces that need ≥1 item (Today sections, Key Metrics, Your Cards) can't be emptied. The
    /// hosted-cards page (#today-hosted-cards) is opt-in, so it passes `true` to allow un-hosting the last.
    var allowEmpty: Bool = false
    /// Optional grouping key for the Hidden ("Available") list. When set (the hosted-cards page passes the
    /// card's origin, e.g. "Sleep" / "Trends"), the Available items are split into one titled Section per
    /// group so a user browses by origin instead of one flat list. nil (Today sections, Key Metrics, Your
    /// Cards) keeps the single flat Available section. The Shown list stays flat — it is the user's own
    /// cross-origin order.
    var group: ((Item) -> String)? = nil
    @ViewBuilder let options: () -> Options

    var body: some View {
        List {
            options()

            Section {
                ForEach(draft.visible) { item in
                    EditableLayoutRow(
                        title: title(item),
                        subtitle: subtitle(item),
                        icon: icon(item),
                        tint: tint(item),
                        configurationLabel: configurationLabel(item),
                        isVisible: true,
                        canHide: draft.visible.count > (allowEmpty ? 0 : 1),
                        onConfigure: { onConfigure(item) },
                        onVisibilityChange: { hide(item) }
                    )
                }
                .onMove(perform: moveVisible)
            } header: {
                Text(shownTitle)
                    .strandOverline()
            } footer: {
                Text("Drag to reorder. Move an item to Hidden to remove it from Today without deleting it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            if draft.hidden.isEmpty {
                Section {
                    Text("Nothing hidden")
                        .foregroundStyle(StrandPalette.textTertiary)
                } header: {
                    Text(hiddenTitle)
                        .strandOverline()
                } footer: {
                    Text("Hidden items remain available here and can be restored at any time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            } else if group != nil {
                // Grouped Available list: one titled Section per origin (e.g. "Sleep", "Trends"), so the
                // hidden cards read by category. The last group carries the shared restore-hint footer.
                let groups = groupedHidden
                ForEach(groups.indices, id: \.self) { i in
                    Section {
                        ForEach(groups[i].items) { item in hiddenRow(item) }
                    } header: {
                        Text(groups[i].name)
                            .strandOverline()
                    } footer: {
                        if i == groups.count - 1 {
                            Text("Hidden items remain available here and can be restored at any time.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(draft.hidden) { item in hiddenRow(item) }
                } header: {
                    Text(hiddenTitle)
                        .strandOverline()
                } footer: {
                    Text("Hidden items remain available here and can be restored at any time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            Section {
                Button("Reset This Layout", role: .destructive, action: onReset)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityLabel("Reset This Layout")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    /// One Available (hidden) row — the show affordance. Shared by the flat and grouped Available lists.
    @ViewBuilder
    private func hiddenRow(_ item: Item) -> some View {
        EditableLayoutRow(
            title: title(item),
            subtitle: subtitle(item),
            icon: icon(item),
            tint: tint(item),
            configurationLabel: configurationLabel(item),
            isVisible: false,
            canHide: true,
            onConfigure: { onConfigure(item) },
            onVisibilityChange: { show(item) }
        )
    }

    /// The hidden items bucketed by `group`, groups in first-appearance order (which follows the draft's
    /// canonical order). Only read when `group != nil`.
    private var groupedHidden: [(name: String, items: [Item])] {
        guard let group else { return [] }
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in draft.hidden {
            let key = group(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { (name: $0, items: buckets[$0] ?? []) }
    }

    private func moveVisible(from offsets: IndexSet, to destination: Int) {
        draft.moveVisible(from: offsets, to: destination)
    }

    private func hide(_ item: Item) {
        withAnimation(StrandMotion.interactive) {
            draft.hide(item)
        }
    }

    private func show(_ item: Item) {
        withAnimation(StrandMotion.interactive) {
            draft.show(item)
        }
    }
}

private struct EditableLayoutRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let configurationLabel: String?
    let isVisible: Bool
    let canHide: Bool
    let onConfigure: () -> Void
    let onVisibilityChange: () -> Void

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            RoundedRectangle(cornerRadius: NoopMetrics.space2, style: .continuous)
                .fill(StrandPalette.surfaceInset)
                .frame(width: NoopMetrics.space8, height: NoopMetrics.space8)
                .overlay {
                    Image(systemName: icon)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(isVisible ? tint : StrandPalette.textTertiary)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(isVisible ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: NoopMetrics.space2)

            if let configurationLabel {
                Button(configurationLabel, action: onConfigure)
                    .buttonStyle(.plain)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel(String(localized: "Edit \(title)"))
            }

            Button(action: onVisibilityChange) {
                Image(systemName: isVisible ? "minus.circle.fill" : "plus.circle.fill")
                    .font(StrandFont.title2)
                    .foregroundStyle(isVisible ? StrandPalette.textSecondary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(isVisible && !canHide)
            .accessibilityLabel(visibilityLabel)
        }
        .contentShape(Rectangle())
        .listRowBackground(NoopChromeSurface())
    }

    private var visibilityLabel: String {
        isVisible
            ? String(localized: "Hide \(title)")
            : String(localized: "Show \(title)")
    }

}
