#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Favourites slot grid (shared by the panel and the edit sheet)

/// The 3×3, gap-aware, drag-to-rearrange Favourites grid. Renders exactly 9 cells regardless of how
/// many are filled — an empty slot is a real, addressable position (a dashed placeholder while
/// editing), not "the array is shorter." Dragging a tile is a genuine `DragGesture` that offsets the
/// ACTUAL view under the finger (no `.onDrag` snapshot, so the jiggle keeps animating), not a native
/// drag/drop (which can't express "leave this slot empty"). Bound to `slots`, so the panel and the
/// edit sheet — which both instantiate this with the same storage binding — stay perfectly in sync.
struct FavouritesSlotGrid: View {
    /// Icon identity is deliberately independent from slot identity. Keeping a tile view alive while
    /// only its `slot` changes prevents SwiftUI from briefly drawing the previous occupant when a
    /// swap commits.
    private struct SlottedItem: Identifiable {
        let id: String
        let item: LaunchItem
        let slot: Int
    }

    @Binding var slots: [String?]
    /// Enables the edit affordances: jiggle, remove badges, dashed empty-slot wireframes, drag.
    var editing: Bool
    /// Optional presentation override used by the panel's coordinated edit exit. The sheet leaves
    /// this nil because it is continuously editable for its whole lifetime.
    var editingChromeVisible: Bool? = nil
    /// Fires when a filled tile is tapped while NOT editing (panel → launch; sheet passes nothing).
    var onTapItem: (String) -> Void = { _ in }
    /// Fires on a long-press while NOT editing (panel → enter edit mode; sheet is always editing).
    var onLongPressItem: () -> Void = {}
    /// Reduce Motion: reposition/lift/settle springs collapse to instant moves.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var scaledTileLabelHeight = NoopMetrics.LaunchChrome.tileLabelHeight

    private var showsEditingChrome: Bool { editingChromeVisible ?? editing }
    private var scaledTileFootprint: CGFloat {
        NoopMetrics.LaunchChrome.tileFootprint
            + max(0, scaledTileLabelHeight - NoopMetrics.LaunchChrome.tileLabelHeight)
    }

    @State private var slotFrames: [Int: CGRect] = [:]
    @State private var draggingItemId: String? = nil
    /// The slot this drag STARTED from. The dragged tile stays LOGICALLY here for the whole gesture —
    /// nothing reshuffles mid-drag; the slot renders as an empty wireframe hole (the tile floats above
    /// it), and the actual placement/bump is committed on drop.
    @State private var dragOriginSlot: Int? = nil
    /// The slot the finger is currently over (for the "drop here" highlight), or nil.
    @State private var dragHoverSlot: Int? = nil
    @State private var dragTranslation: CGSize = .zero
    /// Separating lift from drag identity lets the tile scale down during its settling glide, instead
    /// of staying enlarged until the data commit and then popping smaller one frame later.
    @State private var dragIsLifted: Bool = false
    /// True after release while the floating tile glides to its final centre. The live swap remains
    /// active during this phase, but its target wireframe is hidden so it cannot flash beneath the
    /// seated icon before the model commit lands.
    @State private var isSettlingDrop: Bool = false

    var body: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: NoopMetrics.space3) {
            ForEach(0..<9, id: \.self) { slot in
                slotLayoutGuide(slot)
            }
        }
        // Slot backgrounds stay in the fixed grid; icon views live in this identity-keyed layer and
        // move between the measured slot centres. This makes the drag preview and committed layout
        // use the SAME persistent views on both the panel and the editor sheet.
        .overlay(alignment: .topLeading) { tilesLayer }
        .coordinateSpace(name: "favouritesGrid")
        .onPreferenceChange(SlotFramePreferenceKey.self) { slotFrames = $0 }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { resetDrag(animated: false) }
        }
    }

    @ViewBuilder
    private func slotLayoutGuide(_ slot: Int) -> some View {
        let snapshot = normalizedSlots()
        let itemId = snapshot[slot]
        let isDraggedSlot = itemId != nil && draggingItemId == itemId
        let hoveringOccupiedTarget: Bool = {
            guard let origin = dragOriginSlot,
                  let hover = dragHoverSlot,
                  hover != origin else { return false }
            return snapshot[hover] != nil
        }()
        let isSettlingTarget = isSettlingDrop && dragHoverSlot == slot
        let shouldShowPlaceholder = !isSettlingTarget && (
            itemId == nil ||
            (isDraggedSlot && !hoveringOccupiedTarget) ||
            (dragHoverSlot == slot && dragOriginSlot != slot)
        )
        ZStack {
            // Always reserve the exact footprint of a tile, even when the slot is empty or tiles are
            // rendered in the identity-keyed overlay above.
            Color.clear.frame(height: scaledTileFootprint)
            // While a tile is lifted, its ORIGIN slot immediately reads as an empty hole — the wireframe
            // sits here, behind the floating tile. Every empty slot shows the same wireframe; the one
            // the finger is over highlights.
            if editing && shouldShowPlaceholder {
                emptySlotPlaceholder(highlighted: dragHoverSlot == slot && draggingItemId != nil)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SlotFramePreferenceKey.self,
                    value: [slot: proxy.frame(in: .named("favouritesGrid"))]
                )
            }
        )
    }

    private var slottedItems: [SlottedItem] {
        normalizedSlots().enumerated().compactMap { slot, itemId in
            guard let itemId,
                  let item = LaunchItem.all.first(where: { $0.id == itemId }) else { return nil }
            return SlottedItem(id: itemId, item: item, slot: slot)
        }
    }

    private var tilesLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slottedItems) { entry in
                if let frame = slotFrames[entry.slot] {
                    tile(entry, frame: frame)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ entry: SlottedItem, frame: CGRect) -> some View {
        let isDragged = draggingItemId == entry.id
        let position = tilePosition(for: entry, isDragged: isDragged)
        return LaunchItemCell(
            item: entry.item,
            showRemoveBadge: showsEditingChrome,
            isJiggling: editing && !isDragged,
            enableLongPress: !editing,
            enableCircleDrag: editing,
            onTap: {
                guard !editing else { return }
                onTapItem(entry.id)
            },
            onRemove: {
                withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
                    setSlot(entry.slot, to: nil)
                }
            },
            onLongPress: {
                guard !editing else { return }
                onLongPressItem()
            },
            onAccessibilityMoveEarlier: editing && entry.slot > 0 ? {
                commitPlacement(from: entry.slot, to: entry.slot - 1)
            } : nil,
            onAccessibilityMoveLater: editing && entry.slot < 8 ? {
                commitPlacement(from: entry.slot, to: entry.slot + 1)
            } : nil,
            onCircleDragChanged: { value in
                handleDragChanged(value, startSlot: entry.slot, itemId: entry.id)
            },
            onCircleDragEnded: {
                handleDragEnded()
            }
        )
        .frame(width: frame.width, height: frame.height)
        .position(position)
        // Only resting/displaced icons animate between slot centres. The dragged icon's position is
        // updated without an implicit animation so it remains exactly under the finger; Reduce Motion
        // snaps every tile to its slot centre with no spring.
        .animation(
            isDragged || reduceMotion ? nil : StrandMotion.interactive,
            value: position
        )
        .scaleEffect(isDragged && dragIsLifted ? 1.05 : 1)
        // Keep the real, identity-preserving tile visible throughout the drag. A previous panel-level
        // duplicate used an anchor preference to escape page clipping, but that second coordinate
        // conversion could jump to a neighbouring slot and render out of sync with the finger.
        .zIndex(isDragged ? 10 : 0)
    }

    /// Persistent tile views move between explicit slot centres. During a live occupied-slot hover,
    /// the covered tile previews the swap at the origin while the dragged tile follows its translation.
    private func tilePosition(for entry: SlottedItem, isDragged: Bool) -> CGPoint {
        guard let ownFrame = slotFrames[entry.slot] else { return .zero }
        if isDragged, let origin = dragOriginSlot, let originFrame = slotFrames[origin] {
            return CGPoint(x: originFrame.midX + dragTranslation.width,
                           y: originFrame.midY + dragTranslation.height)
        }
        if entry.slot == dragHoverSlot,
           let origin = dragOriginSlot,
           origin != entry.slot,
           let originFrame = slotFrames[origin] {
            return CGPoint(x: originFrame.midX, y: originFrame.midY)
        }
        return CGPoint(x: ownFrame.midX, y: ownFrame.midY)
    }

    private func emptySlotPlaceholder(highlighted: Bool = false) -> some View {
        VStack(spacing: NoopMetrics.LaunchChrome.tileVGap) {
            Circle()
                .stroke(highlighted ? StrandPalette.accent : StrandPalette.hairlineStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(highlighted ? Circle().fill(StrandPalette.accent.opacity(0.12)) : nil)
                .frame(
                    width: NoopMetrics.LaunchChrome.tileCircle,
                    height: NoopMetrics.LaunchChrome.tileCircle
                )
                .animation(reduceMotion ? nil : StrandMotion.tap, value: highlighted)
            Color.clear.frame(height: scaledTileLabelHeight)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Drag handling

    private func handleDragChanged(_ value: DragGesture.Value, startSlot: Int, itemId: String) {
        if draggingItemId == nil {
            draggingItemId = itemId
            dragOriginSlot = startSlot
            withAnimation(reduceMotion ? nil : StrandMotion.lift) { dragIsLifted = true }
        }
        dragTranslation = value.translation
        // Hit-test the actual finger location. Reconstructing it from the origin cell's CENTRE plus
        // translation only worked when the tile was grabbed dead-centre; an off-centre grab highlighted
        // the wrong wireframe and could commit into a neighbouring slot.
        dragHoverSlot = slotFrames.first(where: { $0.value.contains(value.location) })?.key
    }

    private func handleDragEnded() {
        guard let origin = dragOriginSlot else { resetDrag(animated: true); return }
        guard let target = dragHoverSlot, target != origin,
              let originFrame = slotFrames[origin], let targetFrame = slotFrames[target] else {
            // Dropped back on (or near) the origin, or on nothing — spring the tile home, then reset.
            if reduceMotion {
                resetDrag(animated: false)
                return
            }
            withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
                dragTranslation = .zero
                dragIsLifted = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.interactiveSettleDelay) {
                resetDrag(animated: false)
            }
            return
        }
        if reduceMotion {
            commitPlacement(from: origin, to: target)
            resetDrag(animated: false)
            return
        }
        // GLIDE-then-commit: animate the floating tile from wherever the finger released to the exact
        // centre of the target slot FIRST, and only then mutate the data model + clear the drag state.
        // If we mutate immediately, the tile's view jumps cells (origin→target) with no position
        // animation — the "ghost freezes where you dropped, then re-spawns in place" glitch. Gliding
        // to the target first means the data swap happens while the tile is already sitting on target,
        // so the swap is visually invisible.
        let delta = CGSize(width: targetFrame.midX - originFrame.midX,
                           height: targetFrame.midY - originFrame.midY)
        isSettlingDrop = true
        withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
            dragTranslation = delta
            dragIsLifted = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.interactiveSettleDelay) {
            commitPlacement(from: origin, to: target)
            resetDrag(animated: false)
        }
    }

    private func resetDrag(animated: Bool) {
        let apply = {
            draggingItemId = nil
            dragOriginSlot = nil
            dragHoverSlot = nil
            dragTranslation = .zero
            dragIsLifted = false
            isSettlingDrop = false
        }
        if animated { withAnimation(reduceMotion ? nil : StrandMotion.interactive, apply) } else { apply() }
    }

    /// Fixed-slot semantics are a true swap. An empty target trades places with the origin's item and
    /// therefore leaves a gap behind; an occupied target always moves back into the exact origin slot.
    /// This matches the live displacement preview above and avoids deleting/re-spawning an icon in an
    /// unrelated "nearest empty" position.
    private func commitPlacement(from origin: Int, to target: Int) {
        var next = normalizedSlots()
        next.swapAt(origin, target)
        slots = next
    }

    // MARK: Slot helpers (defensive against a binding that isn't exactly 9 long)

    private func normalizedSlots() -> [String?] {
        var s = slots
        if s.count < 9 { s += Array(repeating: nil, count: 9 - s.count) }
        if s.count > 9 { s = Array(s.prefix(9)) }
        return s
    }

    private func setSlot(_ index: Int, to value: String?) {
        var s = normalizedSlots()
        s[index] = value
        slots = s
    }
}

// MARK: - Add-to-Favourites picker

/// Full picker sheet opened from the Favourites edit header's "Add"/"Change" chip. The top is the
/// SAME `FavouritesSlotGrid` the panel shows — bound to the same slot storage, so arranging here and
/// arranging on the panel are literally the same grid: drag to rearrange (gaps and all), tap the
/// minus badge to remove. Below it, the catalogue (grouped by page) to add into the next free slot.
/// The WHOLE thing scrolls as one — the grid scrolls away with the catalogue rather than being pinned
/// above a separate scroll area — which works because the grid's tile drag is gated behind a short
/// long-press, so a plain vertical flick scrolls and only a press-and-hold picks a tile up.
struct LaunchFavouritesPickerSheet: View {
    @Binding var slots: [String?]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gridReloadToken: Int = 0

    private let maxCount = 9
    private let catalogue: [(String, [LaunchItem])] = [
        ("Insights", LaunchItem.insights), ("Body", LaunchItem.body),
        ("Data", LaunchItem.data), ("App", LaunchItem.app),
    ]

    private var selectedIds: Set<String> { Set(slots.compactMap { $0 }) }
    private var usedCount: Int { slots.compactMap { $0 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("\(usedCount) of \(maxCount) slots — drag to arrange")
                            .strandOverline()
                        FavouritesSlotGrid(slots: $slots, editing: true)
                            .id(gridReloadToken)
                            .padding(.top, NoopMetrics.LaunchChrome.gridTopInset)
                    }

                    ForEach(catalogue, id: \.0) { title, items in
                        let remaining = items.filter { !selectedIds.contains($0.id) }
                        if !remaining.isEmpty {
                            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                                Text(LocalizedStringKey(title)).strandOverline()
                                VStack(spacing: 0) {
                                    ForEach(remaining) { item in addableRow(item) }
                                }
                                .background(StrandPalette.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Edit Favourites")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { resetToDefault() }
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityLabel("Reset favourites to default")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .tint(StrandPalette.accent)
    }

    /// A tappable catalogue row — tapping drops the item into the first free slot (up to the 9 cap).
    /// Draws its own bottom hairline (the grouped card clips the last one) since it's no longer in a List.
    private func addableRow(_ item: LaunchItem) -> some View {
        Button { addToFirstEmptySlot(item.id) } label: {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: item.icon)
                    .font(StrandFont.symbol(NoopMetrics.LaunchChrome.rowIcon))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: NoopMetrics.LaunchChrome.rowIconColumn, alignment: .center)
                Text(LocalizedStringKey(item.title))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(usedCount >= maxCount ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .padding(.horizontal, NoopMetrics.LaunchChrome.rowHInset)
            .frame(minHeight: NoopMetrics.LaunchChrome.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, NoopMetrics.LaunchChrome.rowHInset)
            }
        }
        // Grey out (but don't hide) rows once all 9 slots are full, so it's clear why tapping does
        // nothing rather than silently failing.
        .disabled(usedCount >= maxCount)
        .buttonStyle(.plain)
    }

    private func addToFirstEmptySlot(_ id: String) {
        guard usedCount < maxCount else { return }
        var s = normalized()
        if let empty = s.firstIndex(where: { $0 == nil }) {
            s[empty] = id
            withAnimation(reduceMotion ? nil : StrandMotion.interactive) { slots = s }
        }
    }

    private func resetToDefault() {
        let ids = QuickLaunchPanel.defaultFavourites.split(separator: ",").map(String.init)
        var s: [String?] = ids.map { Optional($0) }
        while s.count < maxCount { s.append(nil) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            slots = Array(s.prefix(maxCount))
            gridReloadToken += 1
        }
    }

    private func normalized() -> [String?] {
        var s = slots
        if s.count < maxCount { s += Array(repeating: nil, count: maxCount - s.count) }
        if s.count > maxCount { s = Array(s.prefix(maxCount)) }
        return s
    }
}
#endif
