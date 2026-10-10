import SwiftUI
import WidgetKit
import StrandDesign

struct TrainingEntry: TimelineEntry {
    var date: Date
    var snapshot: TrainingSnapshot
    var favorite: Int
}
struct TrainingWidgetProvider: AppIntentTimelineProvider {
    private var preview: TrainingSnapshot {
        var favorites = TrainingFavorite.defaults
        favorites[0].name = String(localized: "Strength training")
        favorites[1].name = String(localized: "Running workout")
        favorites[2].name = String(localized: "Configure")
        return .init(favorites: favorites, sessions: [], labels: [:])
    }
    func placeholder(in context: Context) -> TrainingEntry { .init(date: .now, snapshot: preview, favorite: 0) }
    func snapshot(for configuration: TrainingWidgetConfiguration, in context: Context) async -> TrainingEntry {
        let saved = TrainingSnapshot.load()
        return .init(date: .now, snapshot: context.isPreview && saved.favorites.isEmpty ? preview : saved,
                     favorite: configuration.favorite.rawValue)
    }
    func timeline(for configuration: TrainingWidgetConfiguration, in context: Context) async -> Timeline<TrainingEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let confirmationEnd = entry.snapshot.sessions.compactMap(\.confirmationUntil).filter { $0 > Date() }.min()
        let next = confirmationEnd ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }
}
struct TrainingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPTrainingWidget", intent: TrainingWidgetConfiguration.self, provider: TrainingWidgetProvider()) { entry in
            TrainingWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Training")
        .description("Start a favorite or control your running training.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}
struct TrainingWidgetView: View {
    let entry: TrainingEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var textColor: Color { renderingMode == .fullColor ? StrandPalette.textPrimary : StrandPalette.onDarkPrimary }
    private var iconColor: Color { renderingMode == .fullColor ? StrandPalette.accent : StrandPalette.onDarkPrimary }
    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessory
            } else if let training = selectedSession {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if training.isConfirming() || training.error != nil {
                        Text(training.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                        TrainingControls(training: training, labels: entry.snapshot.labels)
                    } else {
                        HStack(spacing: NoopMetrics.space3) {
                            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                                Text(training.title).font(StrandFont.caption.weight(.semibold)).lineLimit(1)
                                TrainingClock(training: training).font(StrandFont.title2).multilineTextAlignment(.leading)
                                status(training)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            TrainingControls(training: training, labels: entry.snapshot.labels, iconsOnly: true)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        favorites(compact: true)
                    }
                }
            } else if entry.snapshot.favorites.isEmpty {
                configurationLink
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Training").font(StrandFont.headline)
                    favorites(compact: false)
                }
            }
        }
        .foregroundStyle(textColor)
        .tint(StrandPalette.accent)
    }
    @ViewBuilder private var accessory: some View {
        if let training = selectedSession {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                if !training.isConfirming() && training.error == nil {
                    HStack(spacing: NoopMetrics.space1) {
                        Text(training.title).lineLimit(1)
                        TrainingClock(training: training).multilineTextAlignment(.trailing)
                    }
                    .font(StrandFont.caption.weight(.semibold))
                }
                TrainingControls(training: training, labels: entry.snapshot.labels,
                                 compact: training.isConfirming(), iconsOnly: !training.isConfirming())
            }
        } else if let favorite = selectedFavorite {
            if favorite.sport != nil || favorite.programID != nil {
                Button(intent: TrainingActionIntent(.start, favorite: favorite.id)) {
                    HStack(spacing: NoopMetrics.space2) {
                        favoriteIcon(favorite)
                        Text(favorite.name).font(StrandFont.caption.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle.fill").font(StrandFont.title2)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Link(destination: TrainingFavorite.configurationURL) {
                    HStack(spacing: NoopMetrics.space2) {
                        favoriteIcon(favorite)
                        Text("Configure").font(StrandFont.caption.weight(.semibold)).lineLimit(2)
                    }
                }
                .accessibilityLabel(Text("Configure training favorites in NOOP"))
            }
        } else {
            configurationLink
        }
    }
    private var configurationLink: some View {
        Link(destination: TrainingFavorite.configurationURL) {
            Text("Open NOOP to configure training").font(StrandFont.footnote)
        }
    }
    private func status(_ training: TrainingDisplay) -> some View {
        Label(entry.snapshot.labels[training.pausedAt == nil ? "running" : "paused"] ?? "",
              systemImage: training.pausedAt == nil ? "record.circle" : "pause.circle")
            .font(StrandFont.footnote)
            .foregroundStyle(training.pausedAt == nil ? StrandPalette.accent : StrandPalette.metricAmber)
    }
    private func favorites(compact: Bool) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(entry.snapshot.favorites) { favorite in
                let configured = favorite.sport != nil || favorite.programID != nil
                if configured {
                    Button(intent: TrainingActionIntent(.start, favorite: favorite.id)) {
                        favoriteTile(favorite, configured: true, compact: compact)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favorite.name)
                } else {
                    Link(destination: TrainingFavorite.configurationURL) {
                        favoriteTile(favorite, configured: false, compact: compact)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Configure training favorites in NOOP"))
                }
            }
        }
    }
    private func favoriteTile(_ favorite: TrainingFavorite, configured: Bool, compact: Bool) -> some View {
        Group {
            if compact {
                favoriteTitle(favorite, configured: configured).lineLimit(2)
            } else {
                VStack(spacing: NoopMetrics.space2) {
                    favoriteIcon(favorite)
                    favoriteTitle(favorite, configured: configured).lineLimit(2, reservesSpace: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .padding(NoopMetrics.space2)
        .frame(minHeight: NoopButtonMetrics.minHitTarget)
        .background(renderingMode == .fullColor ? StrandPalette.surfaceRaised : StrandPalette.hairlineStrong,
                    in: RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth))
    }
    @ViewBuilder private func favoriteTitle(_ favorite: TrainingFavorite, configured: Bool) -> some View {
        Group {
            if configured { Text(favorite.name) } else { Text("Configure") }
        }
        .font(StrandFont.caption.weight(.semibold)).minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .foregroundStyle(configured ? textColor : StrandPalette.textTertiary)
    }
    @ViewBuilder private func favoriteIcon(_ favorite: TrainingFavorite) -> some View {
        if let sport = favorite.sport {
            WorkoutTypeIcon(workoutType: sport, size: NoopMetrics.space6, color: iconColor)
        } else {
            Image(systemName: favorite.programID == nil ? "plus" : "dumbbell.fill")
                .resizable().scaledToFit()
                .font(StrandFont.bodyNumber)
                .frame(width: NoopMetrics.space6, height: NoopMetrics.space6)
                .foregroundStyle(favorite.programID == nil ? StrandPalette.textTertiary : iconColor)
        }
    }
    // A widget addresses one session. Each simultaneous session retains its own Live Activity.
    private var selectedFavorite: TrainingFavorite? { entry.snapshot.favorites.first { $0.id == entry.favorite } }
    private var selectedSession: TrainingDisplay? {
        let kind = selectedFavorite?.programID == nil ? "workout" : "lift"
        return entry.snapshot.sessions.first { $0.kind == kind } ?? entry.snapshot.sessions.first
    }
}
