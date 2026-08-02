#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: Item cell

struct LaunchItemCell: View {
    let item: LaunchItem
    var showRemoveBadge: Bool = false
    var isJiggling: Bool = false
    /// Whether the long-press-to-enter-editing gesture recognizer should be attached at all. Once
    /// already editing, this is false so the circle-only rearrangement gesture owns that interaction.
    var enableLongPress: Bool = false
    /// Rearrangement deliberately begins only on the visible icon circle. The rest of the cell keeps
    /// its generous tap/long-press area without becoming an invisible drag handle during edit mode.
    var enableCircleDrag: Bool = false
    var onTap: () -> Void = {}
    var onRemove: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onAccessibilityMoveEarlier: (() -> Void)? = nil
    var onAccessibilityMoveLater: (() -> Void)? = nil
    var onCircleDragChanged: (DragGesture.Value) -> Void = { _ in }
    var onCircleDragEnded: () -> Void = {}

    /// Reduce Motion suppresses the home-screen jiggle entirely — the tile still shows its remove
    /// badge in edit mode, it just doesn't wobble.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var scaledTileLabelHeight = NoopMetrics.LaunchChrome.tileLabelHeight

    /// The rendered angle is stored directly so leaving edit mode can animate from whatever point
    /// the repeating wiggle reached back to zero. Gating `rotationEffect` with `isJiggling` made the
    /// rotation jump to zero before the stop animation could run.
    @State private var renderedWiggleAngle: Double = 0
    @State private var renderedWiggleOffset: CGSize = .zero

    // Deterministic-per-item angle/duration/start-delay so tiles don't all wobble in lockstep — the
    // varied values drift them out of phase, mirroring the real iOS home-screen edit mode. A stable
    // FNV-1a hash of the id (NOT Swift's per-launch-randomized `hashValue`) keeps a given tile's wobble
    // identical across launches. `%`-safe because the hash is unsigned.
    private var wiggleSeed: Int { Int(fnv1a(item.id) % 100) }
    private var wiggleAngle: Double { 1.6 + Double(wiggleSeed % 3) * 0.25 }
    // The original natural-feeling version lived around 0.12–0.16s per half-swing. This keeps that
    // middle cadence (well below the later 0.09s nervous shake, but less floaty than 0.18–0.22s).
    private var wiggleDuration: Double { 0.135 + Double(wiggleSeed % 5) * 0.008 }
    private var wiggleDelay: Double { Double(wiggleSeed % 7) * 0.018 }
    private var wiggleDistance: CGFloat { 0.45 + CGFloat(wiggleSeed % 3) * 0.15 }
    private var wiggleStartOffset: CGSize {
        let direction: CGFloat = wiggleSeed.isMultiple(of: 2) ? -1 : 1
        return CGSize(width: direction * wiggleDistance,
                      height: -direction * wiggleDistance * 0.35)
    }

    private func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }

    var body: some View {
        // A tile uses a tap gesture rather than an outer Button. An otherwise inert Button remained
        // visually pressed throughout a drag and caused the translucent "ghost" appearance; keeping
        // this hierarchy stable also lets the wiggle animate cleanly back to zero on Cancel.
        tileContent
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityActions {
            if enableLongPress {
                Button("Edit Favourites", action: onLongPress)
            }
            if showRemoveBadge {
                Button("Remove from favourites", action: onRemove)
            }
        }
        .modifier(
            ReorderAccessibilityModifier(
                moveEarlier: onAccessibilityMoveEarlier,
                moveLater: onAccessibilityMoveLater
            )
        )
        .rotationEffect(.degrees(renderedWiggleAngle))
        // Real home-screen jiggle is not a pure pendulum: a sub-point translation running slightly
        // out of phase with rotation gives each icon the subtle physical looseness of iOS edit mode.
        .offset(renderedWiggleOffset)
        .onAppear { startOrStopJiggle(isJiggling) }
        .onChange(of: isJiggling) { _, jiggling in startOrStopJiggle(jiggling) }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                stopJiggleImmediately()
            } else if isJiggling {
                startOrStopJiggle(true)
            }
        }
        .modifier(LongPressToEditModifier(enabled: enableLongPress, onLongPress: onLongPress))
    }

    private var tileContent: some View {
        VStack(spacing: NoopMetrics.LaunchChrome.tileVGap) {
            // iOS keeps the remove badge at the top-LEADING corner of an editable icon.
            ZStack(alignment: .topLeading) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.surfaceRaised)
                        .overlay(
                            Circle().stroke(
                                StrandPalette.hairline,
                                lineWidth: NoopMetrics.LaunchChrome.rimWidth
                            )
                        )
                    Image(systemName: item.icon)
                        .font(StrandFont.symbol(NoopMetrics.LaunchChrome.tileIcon))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(
                    width: NoopMetrics.LaunchChrome.tileCircle,
                    height: NoopMetrics.LaunchChrome.tileCircle
                )
                .contentShape(Circle())
                .highPriorityGesture(
                    DragGesture(
                        minimumDistance: NoopMetrics.LaunchChrome.dragMinimumDistance,
                        coordinateSpace: .named("favouritesGrid")
                    )
                    .onChanged(onCircleDragChanged)
                    .onEnded { _ in onCircleDragEnded() },
                    including: enableCircleDrag ? .all : .none
                )

                // Keep the badge permanently in the hierarchy and explicitly animate its presentation.
                // Conditional removal let SwiftUI reinsert the icon circle above the fading badge on
                // Cancel, producing the visible "badge falls behind, then disappears" glitch.
                Button(action: onRemove) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(
                                width: NoopMetrics.LaunchChrome.removeBadgeHitTarget,
                                height: NoopMetrics.LaunchChrome.removeBadgeHitTarget
                            )
                        Image(systemName: "minus.circle.fill")
                            .font(StrandFont.symbol(NoopMetrics.LaunchChrome.tileIcon))
                            .foregroundStyle(StrandPalette.destructive)
                            .background(
                                Circle()
                                    .fill(StrandPalette.surfaceBase)
                                    .padding(NoopMetrics.LaunchChrome.badgeInset)
                            )
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(
                    x: -NoopMetrics.LaunchChrome.badgeOffset,
                    y: -NoopMetrics.LaunchChrome.badgeOffset
                )
                .opacity(showRemoveBadge ? 1 : 0)
                .scaleEffect(showRemoveBadge ? 1 : 0.86)
                .zIndex(2)
                .allowsHitTesting(showRemoveBadge)
                .accessibilityHidden(!showRemoveBadge)
                .accessibilityLabel(Text(LocalizedStringKey(item.title)))
                .accessibilityHint("Remove from favourites")
                .animation(reduceMotion ? nil : StrandMotion.quick, value: showRemoveBadge)
            }

            Text(LocalizedStringKey(item.title))
                .font(StrandFont.caption2)
                .fontWeight(.medium)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: scaledTileLabelHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func startOrStopJiggle(_ jiggling: Bool) {
        // Reduce Motion: never start the indefinite wobble — hold the tile still (badges still show).
        if jiggling && !reduceMotion {
            renderedWiggleAngle = -wiggleAngle
            renderedWiggleOffset = wiggleStartOffset
            withAnimation(StrandMotion.jiggle(halfCycle: wiggleDuration, delay: wiggleDelay)) {
                renderedWiggleAngle = wiggleAngle
            }
            withAnimation(StrandMotion.jiggle(
                halfCycle: wiggleDuration * 0.91,
                delay: wiggleDelay + 0.018
            )) {
                renderedWiggleOffset = CGSize(width: -wiggleStartOffset.width,
                                              height: -wiggleStartOffset.height)
            }
        } else {
            withAnimation(StrandMotion.quick(reduced: reduceMotion)) {
                renderedWiggleAngle = 0
                renderedWiggleOffset = .zero
            }
        }
    }

    private func stopJiggleImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            renderedWiggleAngle = 0
            renderedWiggleOffset = .zero
        }
    }
}

/// Makes custom fixed-slot reordering operable with VoiceOver. An adjustable element maps swipe up/down
/// to the same earlier/later swap used by pointer dragging, without exposing inert actions at either edge.
private struct ReorderAccessibilityModifier: ViewModifier {
    let moveEarlier: (() -> Void)?
    let moveLater: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if moveEarlier != nil || moveLater != nil {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    moveLater?()
                case .decrement:
                    moveEarlier?()
                @unknown default:
                    break
                }
            }
        } else {
            content
        }
    }
}

/// Keeps the long-press recognizer structurally stable while toggling its gesture mask. Replacing the
/// tile subtree when edit mode changed reset its animation state, which made Cancel stop the wiggle
/// abruptly instead of letting it settle to zero.
private struct LongPressToEditModifier: ViewModifier {
    let enabled: Bool
    let onLongPress: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() },
            including: enabled ? .all : .none
        )
    }
}

/// Reports each Favourites slot's on-screen frame (in the `"favouritesGrid"` coordinate space) so a
/// live drag can hit-test "which slot is my finger over right now" — the whole mechanism the custom
/// `DragGesture`-based reordering is built on.
struct SlotFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#endif
