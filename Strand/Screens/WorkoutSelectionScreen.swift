import SwiftUI
import StrandDesign

// MARK: - Workout selection browser
//
// Full-screen activity picker for live start (and the merge-name reuse). Catalogue, recents, GPS
// flags, and `onStart` / `RecentSportsPrefs` are unchanged — only the presentation is rebuilt into
// large destination cards with native Liquid Glass search.

/// Public entry used by Live / Workouts. Keeps the prior `onStart` + optional title overrides so the
/// merge-name prompt can reuse the same browser.
struct StartWorkoutSheet: View {
    let onStart: (_ sport: String) -> Void
    private let heading: String
    private let explainer: String
    private let actionVerb: String

    init(title: String? = nil, subtitle: String? = nil, actionVerb: String? = nil,
         onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        self.heading = title ?? String(localized: "Choose a workout")
        self.explainer = subtitle
            ?? String(localized: "Pick an activity to begin recording heart rate, effort, peak, and average.")
        self.actionVerb = actionVerb ?? String(localized: "Start")
    }

    var body: some View {
        WorkoutSelectionScreen(heading: heading, explainer: explainer, actionVerb: actionVerb,
                               onStart: onStart)
    }
}

// MARK: - Screen

struct WorkoutSelectionScreen: View {
    let heading: String
    let explainer: String
    let actionVerb: String
    let onStart: (_ sport: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }
    private var recentSports: [WorkoutCatalog.Sport] {
        RecentSportsPrefs.recent().compactMap { WorkoutCatalog.sport(named: $0) }
    }
    private var showRecent: Bool { trimmedQuery.isEmpty && !recentSports.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    headerCopy
                    WorkoutSearchField(query: $query, isFocused: $searchFocused)
                        .padding(.top, NoopMetrics.space1)

                    if showRecent {
                        recentSection
                    }

                    if filtered.isEmpty {
                        emptyResults
                            .padding(.top, NoopMetrics.space8)
                    } else {
                        LazyVStack(spacing: NoopMetrics.space4) {
                            ForEach(filtered) { sport in
                                WorkoutSelectionCard(sport: sport, actionVerb: actionVerb) {
                                    select(sport.name)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.space5)
                .padding(.top, NoopMetrics.space2)
                .padding(.bottom, NoopMetrics.space10)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                StrandPalette.surfaceBase.ignoresSafeArea()
            }
            .navigationBarTitleDisplayModeCompat()
            .toolbar {
                ToolbarItem(placement: .topBarTrailingCompat) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .nativeLiquidGlassWorkoutSelectionControl()
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(heading)
                .font(StrandFont.rounded(34, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(explainer)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Recent")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(recentSports) { sport in
                        RecentWorkoutChip(sport: sport) { select(sport.name) }
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: NoopMetrics.space3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No workouts found")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Try a different activity name.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space8)
        .accessibilityElement(children: .combine)
    }

    private func select(_ name: String) {
        searchFocused = false
        RecentSportsPrefs.recordSelection(name)
        onStart(name)
        dismiss()
    }
}

// MARK: - Search

struct WorkoutSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        NoopLiquidGlassSearchField(text: $query,
                                   prompt: String(localized: "Search workouts"),
                                   isFocused: isFocused)
    }
}

// MARK: - Recent chip

struct RecentWorkoutChip: View {
    let sport: WorkoutCatalog.Sport
    let onTap: () -> Void

    private var accent: Color { StrandPalette.effortColor }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NoopMetrics.space2) {
                WorkoutTypeIcon(workoutType: sport.name, size: 18, weight: .semibold, color: accent)
                Text(sport.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .nativeLiquidGlassWorkoutSelectionControl(capsule: true)
        .accessibilityLabel(Text("\(sport.name) workout"))
        .accessibilityHint(Text("Double tap to start"))
    }
}

// MARK: - Activity card

struct WorkoutSelectionCard: View {
    let sport: WorkoutCatalog.Sport
    let actionVerb: String
    let onSelect: () -> Void

    private var accent: Color { StrandPalette.effortColor }
    private var meta: [WorkoutActivityMeta.Item] {
        WorkoutActivityMeta.items(for: sport)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                WorkoutTypeIcon(workoutType: sport.name, size: 42, weight: .medium, color: accent)
                    .frame(width: 52, height: 52)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(sport.name)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.isEmpty {
                        WorkoutActivityMetadataView(items: meta)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(StrandPalette.goldDeepText)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(StrandPalette.accent))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NoopMetrics.space5)
            .padding(.vertical, NoopMetrics.space5)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background {
                NoopPanelSurface(tint: accent, cornerRadius: 28, elevated: true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text("Double tap to \(actionVerb.lowercased())"))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabelText: String {
        let labels = meta.map(\.text)
        if labels.isEmpty { return "\(sport.name) workout" }
        return "\(sport.name) workout, \(labels.joined(separator: ", "))"
    }
}

// MARK: - Metadata

enum WorkoutActivityMeta {
    struct Item: Equatable {
        var symbol: String?
        var text: String
    }

    /// Labels derived only from catalogue flags / known types — no invented capabilities.
    static func items(for sport: WorkoutCatalog.Sport) -> [Item] {
        var items: [Item] = []
        if sport.isDistanceSport {
            items.append(Item(symbol: "location.fill", text: "GPS"))
        }
        if let type = KnownWorkoutType.exact(matching: sport.name) {
            switch type {
            case .treadmillRun, .treadmillWalk, .indoorCycle, .poolSwim, .rowMachine, .elliptical:
                items.append(Item(symbol: nil, text: "Indoor"))
            case .running, .walking, .hiking, .cycling, .openWaterSwim, .rowing, .skiing, .snowboarding:
                items.append(Item(symbol: nil, text: "Outdoor"))
            case .strength, .bodybuilding, .weightlifting:
                items.append(Item(symbol: nil, text: "Strength"))
            case .yoga, .pilates, .stretching:
                items.append(Item(symbol: nil, text: "Mindfulness"))
            case .hiit:
                items.append(Item(symbol: nil, text: "Cardio"))
            default:
                break
            }
        }
        return items
    }
}

struct WorkoutActivityMetadataView: View {
    let items: [WorkoutActivityMeta.Item]

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(item.text)
                        .font(StrandFont.footnote)
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Presentation helper

extension View {
    /// Full-screen workout browser on iOS; plain sheet on macOS (no fullScreenCover there).
    @ViewBuilder
    func workoutSelectionCover(isPresented: Binding<Bool>,
                               @ViewBuilder content: @escaping () -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func workoutSelectionCover<Item: Identifiable>(item: Binding<Item?>,
                                                   @ViewBuilder content: @escaping (Item) -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

// MARK: - Native Liquid Glass chrome (selection browser)

private extension View {
    /// Circular (or capsule) interactive Liquid Glass for close / recent chips. iOS 26 uses the
    /// platform glass button; macOS and older iOS keep circular geometry with the shared material
    /// fallback already used by Home header / live-workout controls.
    @ViewBuilder
    func nativeLiquidGlassWorkoutSelectionControl(capsule: Bool = false) -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .regular, capsule: capsule) {
            self
                .buttonStyle(LiquidPressStyle())
                .background {
                    if capsule {
                        Capsule().fill(.ultraThinMaterial)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
        }
    }

    /// Native Liquid Glass search field chrome. iOS 26 uses `glassEffect`; macOS / older OS use a
    /// raised solid surface (not a simulated glass stack).
    @ViewBuilder
    func nativeLiquidGlassSearchField() -> some View {
        self.nativeLiquidGlassSearchChrome()
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeCompat() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private extension ToolbarItemPlacement {
    static var topBarTrailingCompat: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

#if DEBUG
#Preview("Choose a workout") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
