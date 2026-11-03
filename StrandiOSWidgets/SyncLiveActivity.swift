import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for a strap history sync — the Lock Screen banner and the Dynamic Island.
///
/// Shows what the app's own Today sync control shows: that a sync is running, how many chunks it has
/// pulled, how long it has been going, and the strap's connect-time backlog when it reported one. No
/// progress bar, because there is no total to draw one against (see `SyncActivityAttributes`).
struct SyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 14) {
                syncGlyph(context.state.phase)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text(context.state.status)
                        .font(.system(size: 20, weight: .bold, design: .default))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let detail = context.state.detail {
                        Text(detail).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer()
                if isActive(context.state.phase) {
                    elapsed(since: context.state.startedAt)
                        .font(.system(.headline, design: .default).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            // ONE line, deliberately. iOS shows the expanded layout for a few seconds whenever an activity
            // starts and offers no way to start compact, so the only lever on that flash is how tall the
            // expanded layout is: no bottom or centre region, so it is a short pill rather than a card.
            // The backlog detail and title live on the Lock Screen banner instead.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(context.state.status) } icon: { syncGlyph(context.state.phase) }
                        .font(.subheadline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isActive(context.state.phase) {
                        elapsed(since: context.state.startedAt)
                            .font(.system(.subheadline, design: .default).monospacedDigit())
                    }
                }
            } compactLeading: {
                // Same footprint as the live-HR island's heart: one symbol, no label, so the compact pill
                // stays as narrow as that one does.
                syncGlyph(context.state.phase)
            } compactTrailing: {
                // "…" while connecting and until the first chunk lands; then the chunk count, the only
                // live number a sync has. Never "0", so the island never claims progress the strap has
                // not made.
                Text(context.state.chunks > 0 ? "\(context.state.chunks)" : "…")
                    .monospacedDigit()
            } minimal: {
                syncGlyph(context.state.phase)
            }
        }
    }
}

private func isActive(_ phase: SyncActivityAttributes.Phase) -> Bool {
    phase == .connecting || phase == .syncing
}

/// Counts up on its own from the run's start; no pushes needed to keep it moving.
private func elapsed(since start: Date) -> some View {
    Text(timerInterval: start...Date.distantFuture, countsDown: false)
}

/// One glyph per phase. The sync arrows in the positive (green) colour for both active phases — the
/// connecting/syncing distinction is carried by the trailing "…" vs count, not by swapping symbols, which
/// kept the compact pill's width steady — then a tick once done, and the critical colour when the strap
/// went quiet.
@ViewBuilder
private func syncGlyph(_ phase: SyncActivityAttributes.Phase) -> some View {
    switch phase {
    case .connecting, .syncing:
        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(StrandPalette.statusPositive)
    case .done:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.statusPositive)
    case .interrupted:
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(StrandPalette.statusCritical)
    }
}
