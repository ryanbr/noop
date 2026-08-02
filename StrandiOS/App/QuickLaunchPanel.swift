#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Quick Launch Panel
//
// A liquid-glass rectangle that materializes above the split tab bar when the "+" circle is tapped.
// Five horizontal pages (Favourites · Insights · Body · Data · App), each a 3×3 grid of
// icon circles + labels. Swiping left/right flips pages; dots below track the current one.
// Long-pressing the Favourites page enters edit mode (iOS home-screen jiggle parity): every
// tile wobbles, a minus badge appears top-leading, and the header swaps to Add / Cancel — Add
// opens a full picker (currently-selected first, then everything else) to swap tiles in.

// MARK: Panel view

struct QuickLaunchPanel: View {
    @Binding var isOpen: Bool
    @Binding var currentPage: Int
    /// Called with the tapped item's id; caller dismisses the panel and routes to the destination.
    var onSelect: (String) -> Void
    /// Honour Reduce Motion: the open/close spring, page transitions, and the edit-mode jiggle all
    /// collapse to an instant (or fade) when the user has minimised motion. `StrandMotion.panel` is
    /// the shared open/close/pull-down spring (formerly a private `transitionAnimation` constant).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var scaledHeaderHeight = NoopMetrics.LaunchChrome.headerHeight
    @ScaledMetric(relativeTo: .caption2) private var scaledTileLabelHeight = NoopMetrics.LaunchChrome.tileLabelHeight

    /// Seeded 3×3 default so Favourites isn't empty on first launch: the things a new user reaches for
    /// most that AREN'T already a primary tab — Settings, Backup & Sync, Workouts, Stress, Coach,
    /// Journal, Automations, Alarms, Compare.
    static let defaultFavourites = LaunchItem.defaultFavouriteIDs.joined(separator: ",")
    @AppStorage("noop.launchFavourites") private var favouritesCSV: String = QuickLaunchPanel.defaultFavourites
    @State private var isEditing: Bool = false
    /// Keeps edit presentation alive for a few frames while its chrome leaves before the wiggle
    /// settles. This avoids the perceptual "icons stop, then badges disappear" ordering.
    @State private var isEndingEditing: Bool = false
    @State private var showAddSheet: Bool = false
    /// Interactive pull-down distance while the user dismisses the panel from its title bar.
    @State private var dismissDragY: CGFloat = 0

    // MARK: Slot-based favourites storage
    //
    // Exactly 9 fixed positions, matching the 3×3 grid one-to-one — unlike a compact ordered list, a
    // slot can be EMPTY, so dragging a tile away leaves a real gap instead of everything sliding to
    // close it up. Stored as 9 comma-separated tokens (an empty token = an empty slot); a pre-existing
    // compact save (no gaps) parses the same way and just leaves the trailing slots empty, so this
    // needs no migration. The drag-to-rearrange interaction itself lives in `FavouritesSlotGrid`,
    // which both this panel (in edit mode) and the Edit-Favourites sheet share — both bound to the
    // same storage, so they stay in sync.

    private var favouriteSlots: [String?] {
        var tokens = favouritesCSV.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if tokens.count < 9 { tokens += Array(repeating: "", count: 9 - tokens.count) }
        if tokens.count > 9 { tokens = Array(tokens.prefix(9)) }
        return tokens.map { $0.isEmpty ? nil : $0 }
    }
    private var favouriteSlotsBinding: Binding<[String?]> {
        Binding(
            get: { favouriteSlots },
            set: { newSlots in
                var padded = newSlots
                if padded.count < 9 { padded += Array(repeating: nil, count: 9 - padded.count) }
                if padded.count > 9 { padded = Array(padded.prefix(9)) }
                favouritesCSV = padded.map { $0 ?? "" }.joined(separator: ",")
            }
        )
    }

    private var favouriteIds: [String] { favouriteSlots.compactMap { $0 } }
    private var favouriteItems: [LaunchItem] {
        favouriteIds.compactMap { id in LaunchItem.all.first { $0.id == id } }
    }

    private let pageLabels = ["Favourites", "Insights", "Body", "Data", "App"]
    /// The 4 static catalogue pages (Favourites is handled separately — it's the only editable/gap-
    /// aware one).
    private var cataloguePages: [[LaunchItem]] {
        [LaunchItem.insights, LaunchItem.body, LaunchItem.data, LaunchItem.app]
    }

    /// Only the caption allowance grows with Dynamic Type; icon geometry remains visually stable.
    private var scaledGridHeight: CGFloat {
        NoopMetrics.LaunchChrome.gridHeight
            + 3 * max(0, scaledTileLabelHeight - NoopMetrics.LaunchChrome.tileLabelHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                // One uniform inset makes each chip's top and nearest side margin optically identical.
                .padding(NoopMetrics.rowSpacing)
                .contentShape(Rectangle())
                // Keep dismissal on the header: it feels like pulling the panel by its handle and
                // cannot fight the horizontal page gesture or the favourites grid's tile drag.
                .simultaneousGesture(pullDownToDismissGesture)

            TabView(selection: $currentPage) {
                favouritesGrid()
                    // Top-align the grid inside the fixed-height page — pages with fewer than 7
                    // items (2 rows) were vertically centring instead, drifting up under the title.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tag(0)
                    .padding(.horizontal, NoopMetrics.space2)
                ForEach(Array(cataloguePages.enumerated()), id: \.offset) { offset, items in
                    itemGrid(items: items)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .tag(offset + 1)
                        .padding(.horizontal, NoopMetrics.space2)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // A full 3×3 grid needs 3×(52pt circle + 6pt spacing + 26pt two-line label) + 2×12pt row
            // gaps ≈ 276pt. The previous 266pt was a hair short, so the bottom of the last row (and,
            // combined with the tighter header above, the top row too) rendered clipped.
            .frame(height: scaledGridHeight)

            pageDots
                // Preserve the panel's total height while lifting the indicator 4pt: the extra space
                // below balances the distance from the final-row labels to the panel's bottom edge.
                .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space4)
        }
        // The panel's rounded rectangle remains the final visual boundary for an active tile drag.
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        // Exactly the same canonical material/rim/elevation stack used by the split navigation bar.
        .noopLiquidGlassSurface(
            in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        )
        .offset(y: dismissDragY)
        .sheet(isPresented: $showAddSheet) {
            LaunchFavouritesPickerSheet(slots: favouriteSlotsBinding)
        }
        // Edit mode only makes sense ON the Favourites page — swiping away must drop it immediately
        // (the header otherwise kept showing Add/Cancel on pages that have nothing to add or cancel).
        .onChange(of: currentPage) { _, _ in
            if isEditing {
                endEditing()
            }
        }
        .onDisappear {
            dismissDragY = 0
            isEditing = false
            isEndingEditing = false
        }
    }

    // MARK: Title bar

    private var editControlsVisible: Bool { isEditing && !isEndingEditing }

    private var titleBar: some View {
        ZStack {
            // The title never gets removed/reinserted when edit mode changes, so it remains perfectly
            // still while the two controls arrive from their respective edges. `LocalizedStringKey`
            // (not a bare `String`) so the page name is looked up in the string catalogue, not shown verbatim.
            Text(LocalizedStringKey(pageLabels[currentPage]))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)

            HStack {
                headerChip(favouriteItems.count >= 9 ? "Change" : "Add", tint: StrandPalette.accent) {
                    openFavouritesEditor()
                }
                .offset(x: editControlsVisible ? 0 : -6)
                Spacer()
                headerChip("Cancel", tint: StrandPalette.textSecondary) {
                    endEditing()
                }
                .offset(x: editControlsVisible ? 0 : 6)
            }
            .opacity(editControlsVisible ? 1 : 0)
            .scaleEffect(editControlsVisible ? 1 : 0.97)
            .allowsHitTesting(editControlsVisible)
        }
        .animation(reduceMotion ? nil : StrandMotion.calmQuick, value: editControlsVisible)
        .frame(minHeight: scaledHeaderHeight)
    }

    private func beginEditing() {
        isEndingEditing = false
        withAnimation(reduceMotion ? nil : StrandMotion.calmQuick) { isEditing = true }
    }

    /// Native-feeling edit exit: chrome begins leaving, then the motion settles 40ms later. The
    /// overlap makes both finish as one event instead of the badges visibly trailing stopped icons.
    private func endEditing(afterExit: (() -> Void)? = nil) {
        guard isEditing else { afterExit?(); return }
        guard !isEndingEditing else { return }
        if reduceMotion {
            isEndingEditing = false
            isEditing = false
            afterExit?()
            return
        }
        withAnimation(reduceMotion ? nil : StrandMotion.quick) { isEndingEditing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.editExitLeadDelay) {
            guard isEndingEditing else { return }
            withAnimation(reduceMotion ? nil : StrandMotion.quick) { isEditing = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.editExitCompletionDelay) {
            guard isEndingEditing else { return }
            isEndingEditing = false
            afterExit?()
        }
    }

    /// Let the panel finish its edit exit before presenting the system sheet. Presenting immediately
    /// snapshots/freezes the underlying repeating animations, which looked like a stalled grid during
    /// the modal's startup delay.
    private func openFavouritesEditor() {
        endEditing { showAddSheet = true }
    }

    /// Pulling the title down toward the tab bar tracks the panel under the finger and dismisses it
    /// once the drag is decisive. A quick downward flick also closes without requiring the full
    /// distance, while an accidental short pull springs back into place.
    private var pullDownToDismissGesture: some Gesture {
        // Measure against the fixed screen rather than this moving title bar. In local space the
        // panel's own offset changes the next gesture sample, producing a feedback loop where a
        // smooth pull alternates above/below the finger and visibly jitters.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dy > 0, abs(dy) > abs(dx) else { return }
                dismissDragY = dy
            }
            .onEnded { value in
                let dy = value.translation.height
                let predictedY = value.predictedEndTranslation.height
                let isVerticalPull = dy > 0 && abs(dy) > abs(value.translation.width)
                if isVerticalPull && (dy > 76 || predictedY > 140) {
                    withAnimation(StrandMotion.panel(reduced: reduceMotion)) {
                        isOpen = false
                    }
                } else {
                    withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
                        dismissDragY = 0
                    }
                }
            }
    }

    /// Compact, symmetric header action. A quiet raised fill reads more cleanly inside the already-glass
    /// panel than nesting another refractive glass surface inside it.
    private func headerChip(_ title: LocalizedStringKey, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(minWidth: NoopMetrics.LaunchChrome.chipMinWidth, minHeight: scaledHeaderHeight)
                .background(StrandPalette.surfaceRaised.opacity(0.82), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        StrandPalette.hairlineStrong,
                        lineWidth: NoopMetrics.LaunchChrome.rimWidth)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: Static catalogue grid (Insights / Body / Data / App — not editable, no gaps)

    private func itemGrid(items: [LaunchItem]) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: NoopMetrics.space3) {
            ForEach(items) { item in
                LaunchItemCell(item: item, onTap: {
                    dismissAndSelect(item.id)
                })
            }
        }
        .padding(.top, NoopMetrics.LaunchChrome.gridTopInset)
    }

    // MARK: Favourites grid (the shared 9-slot editor)

    private func favouritesGrid() -> some View {
        FavouritesSlotGrid(
            slots: favouriteSlotsBinding,
            editing: isEditing,
            editingChromeVisible: editControlsVisible,
            onTapItem: { id in
                dismissAndSelect(id)
            },
            onLongPressItem: {
                beginEditing()
            }
        )
        .padding(.top, NoopMetrics.LaunchChrome.gridTopInset)
    }

    private func dismissAndSelect(_ id: String) {
        withAnimation(reduceMotion ? nil : StrandMotion.tap) { isOpen = false }
        if reduceMotion {
            onSelect(id)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.durationFast) {
                onSelect(id)
            }
        }
    }

    // MARK: Page dots

    private var pageDots: some View {
        HStack(spacing: NoopMetrics.LaunchChrome.dotGap) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(i == currentPage ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.35))
                    .frame(
                        width: i == currentPage
                            ? NoopMetrics.LaunchChrome.dotActiveWidth
                            : NoopMetrics.LaunchChrome.dotWidth,
                        height: NoopMetrics.LaunchChrome.dotWidth
                    )
                    .animation(reduceMotion ? nil : StrandMotion.interactive, value: currentPage)
            }
        }
    }
}

#endif
