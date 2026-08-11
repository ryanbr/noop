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

            Section {
                if draft.hidden.isEmpty {
                    Text("Nothing hidden")
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    ForEach(draft.hidden) { item in
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
                }
            } header: {
                Text(hiddenTitle)
                    .strandOverline()
            } footer: {
                Text("Hidden items remain available here and can be restored at any time.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
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
