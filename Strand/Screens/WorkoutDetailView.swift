import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport
import WhoopStore
import Foundation
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// A READ-ONLY drill-down for one tapped session, built ONLY from the locked Noop component system
// (NoopCard / ChartCard / SectionHeader / StatTile / SegmentBar idiom) so it sits in the same
// instrument-grade, Effort-amber colour world as the Workouts list it opens from.
//
//   • a header (sport displayName · date · duration) with the source badge,
//   • a 3-up StatTile strip (avg HR · max HR · calories / distance),
//   • a GPS route map when the session recorded one on-device (#524) — a MapKit map of the captured
//     polyline with start/end markers, shown only when points were actually captured,
//   • an HR-curve ChartCard fed the workout's 5-min-ish HR buckets over [startTs, endTs],
//   • an HR-zones bar — imported per-workout zones when the row carries them, else the window's raw
//     HR samples binned into age-derived %HRmax zone-minutes (honestly labelled as approximate),
//   • the session's Effort/strain contribution when one was captured.
//
// Presented as a `.sheet` wrapped in a NavigationStack by WorkoutsView — these screens aren't hosted in
// a per-screen NavigationStack, so a sheet is the in-app drill-down idiom (mirrors HealthView opening
// MetricDetailView, StressView opening Breathe).

struct WorkoutDetailView: View {
    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Loaded HR curve over the session window (5-min-ish bucket means). Empty until loaded.
    @State private var hrPoints: [TrendPoint] = []
    /// Per-zone MINUTES for the zones bar: imported zones (duration-weighted) when present, else the
    /// window's raw HR samples binned into age-derived %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zones bar came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var loaded = false
    /// #516: computed from the recorded workout-end + post-workout HR window. nil when the workout was
    /// not intense enough or the strap did not record enough post-workout coverage.
    @State private var heartRateRecovery: HeartRateRecovery.Result?

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var route: [RouteMath.LatLng] = []

    /// Drives the GPX/FIT export chooser for the recorded route.
    @State private var showRouteExport = false

    /// Steps over the session window for an on-foot sport (#398): the count plus whether it came from the
    /// strap's own counter (MG/5.0) or the phone pedometer (fallback for WHOOP 4.0 / not-yet-synced / CSV
    /// import). nil = not an on-foot sport, or no step source had data for the window.
    private struct StepReadout { let count: Int; let fromStrap: Bool }
    @State private var steps: StepReadout?

    var body: some View {
        ScreenScaffold(title: "\(WorkoutSource.displaySport(row.sport))",
                       subtitle: "\(dateLabel(row.startTs))",
                       // PERF: chart/map-heavy column (a MapKit route map, the session HR curve, the
                       // zone-split chart and the effort card). The LazyVStack path builds the off-screen
                       // ones on demand — byte-identical layout — so a tall detail doesn't materialise the
                       // map + both charts before the header is even on screen.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching the Workouts list this detail opens from
                       // and every other liquid screen. Fixed and full-bleed; it does not scroll. This
                       // screen is presented in a sheet wrapped in a NavigationStack by WorkoutsView, so it
                       // needs no extra macOS NavigationStack of its own.
                       topBackground: liquidScaffoldSky()) {
            headerCard
            statStrip
            routeCard
            hrCurveCard
            zonesCard
            heartRateRecoveryCard
            if let strain = row.strain {
                effortCard(strain: strain)
            }
        }
        .toolbar {
            // A Done affordance for the sheet on both platforms (iOS gets the grabber too).
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
    }

    // MARK: - Load

    private func load() async {
        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let routePoints: [RouteMath.LatLng] = {
            guard let r = RouteStore.load(startTs: row.startTs, sport: row.sport) else { return [] }
            let pts = RouteMath.decode(r.polyline)
            return pts.count >= 2 ? pts : []
        }()

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Zones: prefer the imported per-workout percentages (a WHOOP-computed split), and only fall
        // back to deriving zone-minutes from the strap's own raw HR when the row has none — so we
        // never overwrite a real imported split with an on-device approximation.
        var minutes: [Double]?
        var fromImport = false
        if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 {
                minutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: profile.hrZoneSet,
                                                    source: row.source)
        }

        let hrr = await repo.workoutHeartRateRecovery(
            from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax), source: row.source)

        // Steps for an on-foot session (#398), computed at display time over the exact window so it
        // "fills in after sync": prefer the strap's own counter (MG/5.0) once it has offloaded the window,
        // else the phone pedometer (any strap, incl. WHOOP 4.0 / CSV-import). Never shown for non-foot
        // sports (cycling/rowing/… have no footfalls). Both sources return nil for "no data", so an empty
        // window stays "–" rather than a fabricated 0.
        var stepReadout: StepReadout? = nil
        if WorkoutCatalog.isOnFoot(row.sport) {
            if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
                // Same per-user ticks-per-step calibration the daily total applies (#139), floor 0.5.
                let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
                if scaled > 0 { stepReadout = StepReadout(count: scaled, fromStrap: true) }
            }
            if stepReadout == nil,
               let ped = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), ped > 0 {
                stepReadout = StepReadout(count: ped, fromStrap: false)
            }
        }

        await MainActor.run {
            self.route = routePoints
            self.hrPoints = points
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.heartRateRecovery = hrr
            self.steps = stepReadout
            self.loaded = true
        }
    }

    // MARK: - Heart-rate recovery (#516)

    @ViewBuilder private var heartRateRecoveryCard: some View {
        if let recovery = heartRateRecovery {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate Recovery", overline: "After high-intensity effort",
                              trailing: String(localized: "Peak \(recovery.endHR) bpm"))
                NoopCard(tint: StrandPalette.metricRose) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            recoveryStat(String(localized: "1 min"), value: recovery.after1Minute)
                            recoveryStat(String(localized: "2 min"), value: recovery.after2Minutes)
                            recoveryStat(String(localized: "5 min"), value: recovery.after5Minutes)
                        }
                        Divider().overlay(StrandPalette.hairline)
                        Text("The change from your heart rate at the end of exercise. Positive values mean your heart rate fell; a dash means the strap did not record enough data around that minute.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recoveryStat(_ label: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value.map { "\($0)" } ?? "–")
                .font(StrandFont.number(24))
                .foregroundStyle(value.map { $0 >= 0 ? StrandPalette.statusPositive
                                                     : StrandPalette.statusWarning }
                                 ?? StrandPalette.textTertiary)
            Text("bpm")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { String(localized: "Heart rate recovery at \(label), \($0) beats per minute") }
                            ?? String(localized: "Heart rate recovery at \(label), not available"))
    }

    // MARK: - Header

    private var headerCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: sportSymbol(row.sport))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 44, height: 44)
                    .background(StrandPalette.effortColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(dateLabel(row.startTs)) · \(timeRangeLabel(row.startTs, row.endTs))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                sourceBadge(row.source)
            }
        }
    }

    // MARK: - Stat strip

    @ViewBuilder private var statStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                  alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Duration",
                     value: durationLabel(row.durationS),
                     caption: String(localized: "active"),
                     accent: StrandPalette.effortColor)
            StatTile(label: "Avg HR",
                     value: row.avgHr.map { "\($0)" } ?? "–",
                     caption: row.avgHr != nil ? "bpm" : nil,
                     accent: row.avgHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            StatTile(label: "Max HR",
                     value: row.maxHr.map { "\($0)" } ?? "–",
                     caption: row.maxHr != nil ? "bpm" : nil,
                     accent: row.maxHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            StatTile(label: "Calories",
                     value: row.energyKcal.map { grouped($0) } ?? "–",
                     caption: row.energyKcal != nil ? "kcal" : nil,
                     accent: row.energyKcal != nil ? StrandPalette.metricAmber : StrandPalette.textTertiary)
            if row.distanceM != nil {
                StatTile(label: "Distance",
                         value: distanceLabel(row.distanceM),
                         caption: String(localized: "covered"),
                         accent: StrandPalette.metricCyan)
            }
            // Steps for an on-foot sport (#398). Shown for the on-foot set even before the value lands, so
            // the tile doesn't pop in; "–" until a source has data. Caption is honest about the source.
            if WorkoutCatalog.isOnFoot(row.sport) {
                StatTile(label: "Steps",
                         value: steps.map { grouped(Double($0.count)) } ?? "–",
                         caption: steps.map { $0.fromStrap ? String(localized: "strap")
                                                          : String(localized: "phone") },
                         accent: steps != nil ? StrandPalette.metricCyan : StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - GPS route (#524)

    /// The captured-route card: a MapKit map of the polyline with start/end markers, plus distance and
    /// pace read off the route. Shown ONLY when ≥2 points were captured — honest "no map" otherwise (a
    /// Mac with no GPS, denied permission, or a non-distance sport never produce a route).
    @ViewBuilder private var routeCard: some View {
        if route.count >= 2 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Route", overline: "Recorded on device",
                              trailing: distanceLabel(row.distanceM))
                NoopCard(padding: 0, tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 0) {
                        WorkoutRouteMap(points: route)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius,
                                                        style: .continuous))
                            .accessibilityLabel(routeAccessibilityLabel)
                        HStack(spacing: 0) {
                            routeStat(String(localized: "Distance"), distanceLabel(row.distanceM),
                                      tint: StrandPalette.metricCyan)
                            routeStat(String(localized: "Avg pace"), paceLabel, tint: StrandPalette.effortBright)
                            routeStat(String(localized: "Points"), "\(route.count)", tint: StrandPalette.textSecondary)
                        }
                        .padding(NoopMetrics.cardPadding)
                    }
                }
                Text("Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showRouteExport = true
                } label: {
                    Label("Export route", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .confirmationDialog("Export route", isPresented: $showRouteExport, titleVisibility: .visible) {
                    Button("GPX — Strava, Garmin, most apps") { exportRoute(.gpx) }
                    Button("FIT — Garmin Connect") { exportRoute(.fit) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Save this route as a standard file you can import into Strava, Garmin Connect, and other apps.")
                }
            }
        }
    }

    /// Write the route to a GPX/FIT file and hand it to the system share sheet (or a Save panel on macOS).
    /// Points are decoded lat/lon only (the stored polyline), so the exporter interpolates per-point times
    /// across the session window and carries the workout's summary (sport, distance, calories, HR).
    ///
    /// The build + disk write run OFF the main actor (a long route is a non-trivial encode, and blocking
    /// file IO must never stall the UI); only the share-sheet present hops back to the main actor.
    @MainActor private func exportRoute(_ format: RouteExporter.Format) {
        guard route.count >= 2 else { return }
        let points = route.map { RoutePoint(lat: $0.lat, lon: $0.lon) }
        // Name the file by the workout's start (not export time) so it's stable + matches the Android twin.
        let name = "noop-route-\(row.startTs).\(format.ext)"
        let startTs = row.startTs, endTs = row.endTs, sport = row.sport
        let distanceM = row.distanceM, energyKcal = row.energyKcal, avgHr = row.avgHr, maxHr = row.maxHr
        Task.detached(priority: .userInitiated) {
            let data = RouteExporter.render(
                format, route: points, startTs: startTs, endTs: endTs, sport: sport,
                distanceM: distanceM, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do { try data.write(to: url) } catch { return }
            await MainActor.run { FileExport.exportFile(at: url, suggestedName: name) }
        }
    }

    private func routeStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).strandOverline()
            Text(value)
                .font(StrandFont.number(15))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Avg pace from the row's GPS distance + duration, in the user's unit system: "m:ss /km" (metric) or
    /// "m:ss /mi" (imperial). "–" when distance or duration is missing/zero (pace undefined — honest).
    private var paceLabel: String {
        guard let m = row.distanceM, m > 0 else { return "–" }
        let secs = row.durationS ?? Double(row.endTs - row.startTs)
        guard secs > 0 else { return "–" }
        let km = m / 1000.0
        let (perUnit, label): (Double, String) = unitSystem == .imperial
            ? (km * UnitFormatter.milesPerKilometer, "/mi")
            : (km, "/km")
        guard perUnit > 0 else { return "–" }
        let secsPerUnit = Int((secs / perUnit).rounded())
        return "\(secsPerUnit / 60):\(String(format: "%02d", secsPerUnit % 60)) \(label)"
    }

    private var routeAccessibilityLabel: String {
        let dist = distanceLabel(row.distanceM)
        return String(localized: "Map of your \(WorkoutSource.displaySport(row.sport)) route, \(dist).")
    }

    // MARK: - HR curve

    @ViewBuilder private var hrCurveCard: some View {
        if hrPoints.count > 1 {
            let values = hrPoints.map(\.value)
            let lo = max(0, (values.min() ?? 60) - 8)
            let hi = (values.max() ?? 180) + 8
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ChartCard(
                    title: "HEART RATE",
                    subtitle: String(localized: "Beats per minute across the session"),
                    trailing: row.avgHr.map { String(localized: "avg \($0)") },
                    tint: StrandPalette.effortColor
                ) {
                    TrendChart(
                        points: hrPoints,
                        gradient: StrandPalette.effortGradient,
                        valueRange: lo...hi,
                        showsArea: true,
                        valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                        dateFormat: { Self.tooltipTime.string(from: $0) },
                        accessibilityLabel: String(localized: "Heart rate during \(WorkoutSource.displaySport(row.sport))")
                    )
                } footer: {
                    ChartFooter([
                        ("Avg", row.avgHr.map { String(localized: "\($0) bpm") } ?? "–"),
                        ("Peak", row.maxHr.map { String(localized: "\($0) bpm") } ?? String(localized: "\(Int((values.max() ?? 0).rounded())) bpm")),
                        ("Low", String(localized: "\(Int((values.min() ?? 0).rounded())) bpm")),
                    ])
                }
                // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Effort
                // stay from the recorded session (preservingCaptured keeps the captured strain/zones). When
                // the typed average disagrees materially with this trace's own mean AND the row carries that
                // captured strain/zones, say so plainly. We do NOT re-score from the typed number.
                if avgHrEditedDisclosure(traceMean: values.reduce(0, +) / Double(values.count)) {
                    Text("The average above was edited. The graph, zones and Effort stay from the recorded session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if loaded {
            NoopCard {
                emptyNote("No heart-rate samples were recorded over this session's window.")
            }
        }
    }

    /// #18: whether the displayed Avg HR was edited away from what this HR trace implies. True only when the
    /// row carries CAPTURED strain or zones (so the graph/zones/Effort are from a real recording, not the
    /// typed value) AND the row's avgHr differs from the trace mean by more than a small tolerance. The
    /// tolerance absorbs ordinary rounding/bucketing drift so an unedited session never trips the note.
    private func avgHrEditedDisclosure(traceMean: Double) -> Bool {
        guard let avg = row.avgHr, row.strain != nil || row.zonesJSON != nil else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: - HR zones

    @ViewBuilder private var zonesCard: some View {
        if let z = zoneMinutes, z.reduce(0, +) > 0 {
            let total = z.reduce(0, +)
            let busiest = z.indices.max(by: { z[$0] < z[$1] }) ?? 0
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("HR Zones",
                              overline: zonesFromImport ? "Whoop import" : "From strap HR",
                              trailing: String(localized: "\(Int(total.rounded()))m in zone"))
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in
                                    Rectangle()
                                        .fill(StrandPalette.hrZoneColor(i + 1))
                                        .frame(width: max(0, CGFloat(z[i] / total) * geo.size.width))
                                        .overlay {
                                            if i == busiest {
                                                Rectangle()
                                                    .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                                            }
                                        }
                                }
                            }
                        }
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z[$0 - 1] / total * 100).rounded())) percent") }.joined(separator: ", "))"))
                        Divider().overlay(StrandPalette.hairline)
                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { i in
                                zoneStat(i + 1, minutes: z[i], total: total)
                            }
                        }
                        Text(zonesFromImport
                             ? "WHOOP's imported per-zone split for this session."
                             : "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationLabel(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Effort contribution

    private func effortCard(strain: Double) -> some View {
        // The session's Effort as the signature liquid gauge: a `LiquidVessel` tinted Effort, filled to the
        // session's contribution on the user's selected scale, with the value counting up over it — the
        // same hero language as the Workouts list's Typical Effort gauge and the Sleep Rest hero. The
        // explanatory sentence keeps its place beside the gauge.
        let displayValue = UnitFormatter.effortValue(strain, scale: effortScale)
        let scaleMax: Double = effortScale == .whoop ? 21 : 100
        let fraction = max(0, min(1, displayValue / scaleMax))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Effort", overline: "This session")
            NoopCard(tint: StrandPalette.effortColor) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        // Static (posed) vessel — a compact liquid gauge inside a card, so it costs a single
                        // cached frame rather than a live canvas (same call as Trends' pip vessels).
                        LiquidVessel(value: fraction, tint: StrandPalette.effortColor, animated: false)
                            .frame(width: 88, height: 88)
                        VStack(spacing: 0) {
                            // The session's Effort contribution ticks up to its value — the NOOP signature.
                            CountUpText(value: displayValue,
                                        format: { String(format: "%.1f", $0) },
                                        font: StrandFont.rounded(28),
                                        color: StrandPalette.textPrimary)
                                .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
                            Text(effortScale == .whoop ? "of 21" : "of 100")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Effort \(UnitFormatter.effortDisplay(strain, scale: effortScale)) \(effortScale == .whoop ? "of 21" : "of 100")"))
                    Spacer(minLength: 0)
                    Text("This session's contribution to the day's Effort, as captured during the workout.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Bits

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceBadge(_ source: String) -> some View {
        let (label, tint): (String, Color) = {
            switch WorkoutSource.classify(source) {
            case .whoop:    return (String(localized: "Whoop"), StrandPalette.accent)
            case .apple:    return (String(localized: "Apple"), StrandPalette.metricCyan)
            case .detected: return (String(localized: "Detected"), StrandPalette.metricPurple)
            case .manual:   return (String(localized: "Manual"), StrandPalette.statusWarning)
            case .lifting:  return (String(localized: "Lifting"), StrandPalette.zone2)
            case .activityFile: return (String(localized: "File"), StrandPalette.metricAmber)
            }
        }()
        return SourceBadge("\(label)", tint: tint)
    }

    // MARK: - Formatting (kept local, matching WorkoutsView's rhythm)

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMM yyyy"
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let tooltipTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))-\(timeLabel(end))" : timeLabel(start)
    }
    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }
    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: unitSystem)
    }
    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
}

// MARK: - Route map (#524)
//
// A MapKit map of the captured route polyline, drawn with start (green) + end (red) markers — the Apple
// analogue of Android's `RouteCanvas`, but on real map tiles. Built as a platform-bridged representable
// around `MKMapView` so it runs on BOTH iOS 17 and macOS 13 (SwiftUI's newer `Map { MapPolyline }` needs
// iOS 17 / macOS 14, and the macOS deployment target is 13). The map is offline-capable: MapKit caches
// tiles locally and the route itself is on-device — NOOP never sends the route anywhere.

#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteMap: RouteMapRepresentable {
    let points: [RouteMath.LatLng]

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        configure(map)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coords = coordinates
        guard coords.count >= 2 else { return }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(line)

        let start = MKPointAnnotation(); start.coordinate = coords.first!; start.title = String(localized: "Start")
        let end = MKPointAnnotation(); end.coordinate = coords.last!; end.title = String(localized: "Finish")
        map.addAnnotations([start, end])

        // Frame the whole route with a little padding so the line isn't flush to the edges.
        let rect = line.boundingMapRect
        let inset = UIEdgeInsetsLikePadding
        map.setVisibleMapRect(rect, edgePadding: inset, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // Effort-amber world, matching the rest of the workout detail. A platform colour (the
            // renderer needs a UIColor/NSColor, not a SwiftUI Color); kept close to the Effort accent.
            r.strokeColor = RoutePlatformColor.effort
            r.lineWidth = 4
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }
    }

    #if canImport(UIKit)
    private var UIEdgeInsetsLikePadding: UIEdgeInsets { UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { configure(map) }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map) }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`). A fixed
/// Effort-amber so it reads in the same colour world as the rest of the screen on both platforms.
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static let effort = UIColor(red: 0.98, green: 0.62, blue: 0.16, alpha: 1.0)
    #elseif canImport(AppKit)
    static let effort = NSColor(red: 0.98, green: 0.62, blue: 0.16, alpha: 1.0)
    #endif
}
#else
/// Platforms without MapKit (none we ship, but keeps the type resolvable): no route map.
struct WorkoutRouteMap: View {
    let points: [RouteMath.LatLng]
    var body: some View { Color.clear }
}
#endif

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil))
            .environmentObject(Repository(deviceId: "preview"))
    }
    .frame(width: 1040, height: 940)
    .preferredColorScheme(.dark)
}
#endif
