import AppIntents
import SwiftUI
import WidgetKit
import StrandDesign

extension QuickLogDestination: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Log type"
    static var caseDisplayRepresentations: [QuickLogDestination: DisplayRepresentation] = [
        .hydration: "Hydration", .caffeine: "Caffeine", .journal: "Journal", .workout: "Workouts"
    ]
}

struct QuickLogConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick Log"
    static var description = IntentDescription("Open NOOP to log water, caffeine, a workout, or your journal.")

    @Parameter(title: "Log type", default: .hydration)
    var destination: QuickLogDestination
}

struct QuickLogEntry: TimelineEntry {
    let date: Date
    let destination: QuickLogDestination
}

struct QuickLogProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickLogEntry {
        QuickLogEntry(date: Date(), destination: .hydration)
    }

    func snapshot(for configuration: QuickLogConfiguration, in context: Context) async -> QuickLogEntry {
        QuickLogEntry(date: Date(), destination: configuration.destination)
    }

    func timeline(for configuration: QuickLogConfiguration, in context: Context) async -> Timeline<QuickLogEntry> {
        let entry = QuickLogEntry(date: Date(), destination: configuration.destination)
        // These are navigation shortcuts, so no periodic refresh or shared health-data snapshot is needed.
        return Timeline(entries: [entry], policy: .never)
    }
}

struct QuickLogWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickLogEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                medium
            case .accessoryCircular:
                Image(systemName: entry.destination.symbol)
                    .font(StrandFont.title2)
                    .accessibilityLabel(Text(entry.destination.title))
            case .accessoryRectangular:
                Label(entry.destination.title, systemImage: entry.destination.symbol)
                    .font(StrandFont.headline)
            default:
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Label("Quick Log", systemImage: "plus.circle.fill")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: entry.destination.symbol)
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.accent)
                    Text(entry.destination.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                }
            }
        }
        .widgetURL(entry.destination.url)
        .containerBackground(for: .widget) { StrandPalette.surfaceBase }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Label("Quick Log", systemImage: "plus.circle.fill")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space2) {
                ForEach(QuickLogDestination.allCases) { destination in
                    Link(destination: destination.url) {
                        VStack(spacing: NoopMetrics.space2) {
                            Image(systemName: destination.symbol)
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.accent)
                            Text(destination.title)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(StrandPalette.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: NoopMetrics.space3))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(destination.title))
                }
            }
        }
    }
}

/// Opens the existing app editors, keeping storage, consent, validation, and edit/delete in one place.
struct QuickLogWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPQuickLog", intent: QuickLogConfiguration.self,
                               provider: QuickLogProvider()) { entry in
            QuickLogWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Log")
        .description("Open NOOP to log water, caffeine, a workout, or your journal.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .systemSmall) { QuickLogWidget() } timeline: {
    QuickLogEntry(date: Date(), destination: .hydration)
}

#Preview(as: .systemMedium) { QuickLogWidget() } timeline: {
    QuickLogEntry(date: Date(), destination: .hydration)
}
