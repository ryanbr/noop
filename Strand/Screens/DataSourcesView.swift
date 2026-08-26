import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore
import WhoopProtocol   // #137: Streams / HRSample, to persist an imported activity's per-sample HR

struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop
    // Nutrition CSV import state — local to this screen (the import is a quick, self-contained
    // metric-series write; it doesn't need AppModel's heavyweight import pipeline).
    @State private var nutritionImporting = false
    @State private var nutritionSummary: String?
    @State private var nutritionFailed = false
    // Lifting (Hevy / Liftosaur) import state — same lightweight, self-contained pattern: parse the
    // file, upsert workout rows under the "lifting" source, refresh. No HR Effort is touched.
    @State private var liftingImporting = false
    @State private var liftingSummary: String?
    @State private var liftingFailed = false
    // Activity-file (GPX / TCX / FIT) import state — same lightweight, self-contained pattern: parse the
    // file, upsert one workout row under the "activity-file" source, and persist optional measured
    // summaries like file steps under that source, refresh. No HR Effort is touched.
    @State private var activityFileImporting = false
    @State private var activityFileSummary: String?
    @State private var activityFileFailed = false
    // Wearable export (Oura / Fitbit / Garmin own-data export) import state — same lightweight,
    // self-contained pattern: parse the file, upsert daily metrics + sleep sessions under the brand's
    // own source, refresh. The brand's own scores are stored as reference only, never NOOP scores.
    @State private var wearableImporting = false
    @State private var wearableSummary: String?
    @State private var wearableFailed = false
    #if OURA_CLOUD_IMPORT
    // Oura history import (compiled in ONLY with OURA_CLOUD_IMPORT): a one-time, user-initiated,
    // foreground OAuth + backfill of the user's own history over the Oura API, as an alternative to
    // the manual "Oura / Fitbit / Garmin export" file above. `OuraConnectModel` takes
    // `repo: Repository` as a call-time parameter (not at construction) — `repo` is an
    // `@EnvironmentObject`, unavailable until after this view's `init()` runs, so storing it at
    // `@StateObject` construction time would either fail to compile or crash at runtime.
    @StateObject private var oura = OuraConnectModel()
    #endif
    // "Remove Apple Health imported data" (ah-delete #616): a destructive escape hatch that purges every
    // row stored under the "apple-health" source via DeviceRegistryStore.deleteAllData. Two-step (a
    // confirmation alert) since it can't be undone. Local to this screen; no live strap data is touched.
    @State private var appleHealthDeleting = false
    @State private var confirmDeleteAppleHealth = false
    @State private var appleHealthDeletedSummary: String?

    // "Broadcast heart rate" (opt-in, OFF by default): make NOOP a standard BLE Heart Rate peripheral
    // (0x180D / 0x2A37) so a gym treadmill / Zwift / Peloton can read the live strap HR NOOP receives.
    // LOCAL Bluetooth only — nothing leaves the device. The toggle is persisted; the broadcaster is owned
    // here (a pure consumer of LiveState, isolated from the WHOOP/central path).
    @AppStorage(HrBroadcaster.defaultsKey) private var broadcastHrEnabled = false

    // The broadcaster's diagnostic sink forwards to THIS box, which `onAppear` points at the screen's
    // `live`. A reference box lets the `@StateObject` capture a stable target at init even though the
    // `@EnvironmentObject` `live` isn't available until the view runs — so the broadcast-out lifecycle
    // lines (advertised / who subscribed / why the radio refused) reach the SAME exported strap log the
    // WHOOP path writes, mirroring Android's `HrBroadcaster(log = { ble.externalLog(it) })`. Every line is
    // already prefixed "HR-out: " inside HrBroadcaster; privacy-safe (statuses + a subscriber COUNT only).
    private final class LogSink { weak var live: LiveState? }
    private let broadcastLogSink: LogSink
    @StateObject private var hrBroadcaster: HrBroadcaster

    init() {
        let sink = LogSink()
        self.broadcastLogSink = sink
        _hrBroadcaster = StateObject(wrappedValue: HrBroadcaster(log: { [weak sink] line in
            // HrBroadcaster is @MainActor, so it only ever calls this closure from the main actor — assume
            // that isolation to forward straight into LiveState (also @MainActor) without an extra runloop
            // hop, matching Android's synchronous `ble.externalLog(it)`.
            MainActor.assumeIsolated { sink?.live?.append(log: line) }
        }))
    }

    var body: some View {
        ScreenScaffold(title: "Data Sources",
                       subtitle: "Everything stays on \(Platform.deviceNounPhrase). Bring your history in once, then it's yours.",
                       onRefresh: { await repo.refresh() },
                       // PERF: a ten-card import/source column (WHOOP, Apple Health, Xiaomi, nutrition,
                       // lifting, activity files, wearables, Oura cloud, broadcast-out, live strap). The LazyVStack
                       // path is byte-identical layout. The cards stay in their inner VStack(sectionSpacing)
                       // for pixel-identical spacing, so the lazy win is partial until they're promoted to
                       // direct children. NOTE: this screen still observes `LiveState` for the broadcaster
                       // lifecycle binding in onAppear/onDisappear, so a ~1 Hz tick still re-evaluates the
                       // built cards — that observation can't be removed here (see the lane-B2 note).
                       lazy: true) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                whoopCard.staggeredAppear(index: 0)
                appleHealthCard.staggeredAppear(index: 1)
                xiaomiCard.staggeredAppear(index: 2)
                nutritionCard.staggeredAppear(index: 3)
                liftingCard.staggeredAppear(index: 4)
                activityFileCard.staggeredAppear(index: 5)
                wearableCard.staggeredAppear(index: 6)
                #if OURA_CLOUD_IMPORT
                ouraCloudCard.staggeredAppear(index: 7)
                #endif
                broadcastHrCard.staggeredAppear(index: 8)
                liveCard.staggeredAppear(index: 9)
            }
        }
        .onAppear {
            // Point the broadcaster's diagnostic sink at this screen's `live` so its broadcast-out
            // lifecycle lines land in the same exported strap log the WHOOP path uses (issue #421 parity).
            broadcastLogSink.live = live
            // Bind the broadcaster to the live HR once, and resume broadcasting if the user left it on.
            hrBroadcaster.bind(to: live)
            if broadcastHrEnabled { hrBroadcaster.start() }
        }
        .onDisappear {
            // The broadcast is a foreground convenience tied to this screen's owned object — release the
            // radio when the screen goes away; toggling it back on (or revisiting) re-starts it.
            hrBroadcaster.stop()
        }
        // A single target-aware importer avoids SwiftUI collapsing competing importers on the same screen.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTarget.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            handleImportResult(result, for: importTarget)
        }
        // ah-delete (#616): strongly-worded confirm before purging the Apple Health source.
        .alert("Remove Apple Health imported data?", isPresented: $confirmDeleteAppleHealth) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { deleteAppleHealthData() }
        } message: {
            Text("This permanently deletes everything imported from Apple Health: heart rate, HRV, sleep, steps, workouts and more. Your live strap data is untouched. This can't be undone.")
        }
    }

    private var whoopCard: some View {
        let hasWhoop = !repo.days.isEmpty
        return card(title: String(localized: "WHOOP Export"), icon: "square.and.arrow.down.fill",
             tint: StrandPalette.accent,
             status: StatePill(hasWhoop ? "Imported" : "Nothing imported",
                               tone: hasWhoop ? .accent : .neutral),
             subtitle: String(localized: "Import your full WHOOP history (recovery, strain, sleep, workouts) from a data export (.zip). Works for WHOOP 4.0, 5.0 and MG. Get one at app.whoop.com → Data Management.")) {
            let importingWhoop = model.isImporting(.whoop)
            HStack(spacing: NoopMetrics.space3) {
                Button {
                    presentImporter(.whoop)
                } label: {
                    Label(importingWhoop ? "Importing…" : "Choose export…",
                          systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if importingWhoop { ProgressView().controlSize(.small) }
            }
            if let s = model.whoopImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.whoopImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
            Text("\(repo.days.count) days · \(repo.sleeps.count) sleeps stored")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var appleHealthCard: some View {
        card(title: "Apple Health", icon: "heart.fill",
             tint: StrandPalette.metricCyan,
             subtitle: String(localized: "Import an Apple Health export (Health app → profile → Export All Health Data → export.zip). 7 years of HR, HRV, sleep, SpO₂, steps and more, streamed locally. Large exports take a minute or two.")) {
            let importingAppleHealth = model.isImporting(.appleHealth)
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.appleHealth) } label: {
                    Label(importingAppleHealth ? "Working…" : "Choose export.zip…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting || appleHealthDeleting)
                if importingAppleHealth { ProgressView().controlSize(.small) }
            }
            if let s = model.appleHealthImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.appleHealthImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
            // ah-delete (#616): a destructive "Remove imported data" action wired to
            // DeviceRegistryStore.deleteAllData(deviceId: "apple-health"). Always offered (the user may
            // have imported in a prior session, so we don't gate on this run's summary), with a
            // confirmation step since it permanently clears every Apple-Health-sourced row.
            HStack(spacing: NoopMetrics.space3) {
                Button(role: .destructive) {
                    confirmDeleteAppleHealth = true
                } label: {
                    Label(appleHealthDeleting ? "Removing…" : "Remove imported data", systemImage: "trash")
                }
                .buttonStyle(NoopButtonStyle(.destructive))
                .disabled(model.hasActiveImport || appleHealthDeleting)
                .accessibilityLabel("Remove Apple Health imported data")
                if appleHealthDeleting { ProgressView().controlSize(.small) }
            }
            if let s = appleHealthDeletedSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusPositive)
            }
        }
    }

    private var xiaomiCard: some View {
        card(title: "Xiaomi Smart Band (Mi Band)", icon: "figure.walk.motion",
             tint: StrandPalette.metricAmber,
             subtitle: String(localized: "Import your Mi Band history (steps, heart rate, resting HR, sleep stages, SpO₂, stress and sleep score) straight from the Mi Fitness app. On your iPhone: Files → On My iPhone → Mi Fitness, long-press the folder → Compress, then choose the .zip here. Fully offline; no Xiaomi account or Bluetooth needed. Smart Band 8/9/10.")) {
            let importingXiaomi = model.isImporting(.xiaomi)
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.xiaomi) } label: {
                    Label(importingXiaomi ? "Importing…" : "Choose Mi Fitness export…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if importingXiaomi { ProgressView().controlSize(.small) }
            }
            if let s = model.xiaomiImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.xiaomiImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var nutritionCard: some View {
        card(title: String(localized: "Nutrition (.csv)"), icon: "fork.knife",
             tint: StrandPalette.metricAmber,
             subtitle: String(localized: "Import daily nutrition totals from a Cronometer or MacroFactor CSV export: calories in, protein, carbs, fat (and weight if present). Other trackers work too if the file has a date column and daily totals.")) {
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.nutrition) } label: {
                    Label(nutritionImporting ? "Importing…" : "Choose .csv…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if nutritionImporting { ProgressView().controlSize(.small) }
            }
            if let s = nutritionSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(nutritionFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var liftingCard: some View {
        card(title: String(localized: "Lifting log (Hevy / Liftosaur)"), icon: "dumbbell.fill",
             tint: DomainTheme.effort.color,
             subtitle: String(localized: "Import your strength-training history from a Hevy CSV export or a Liftosaur JSON export. Each workout becomes a Strength session with a training-volume estimate (weight × reps). It's a volume figure, not a measured strain. It never changes your Effort.")) {
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.lifting) } label: {
                    Label(liftingImporting ? "Importing…" : "Choose export…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if liftingImporting { ProgressView().controlSize(.small) }
            }
            if let s = liftingSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(liftingFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var activityFileCard: some View {
        card(title: String(localized: "Workout file (GPX / TCX / FIT)"), icon: "point.topleft.down.curvedto.point.bottomright.up",
             tint: StrandPalette.metricAmber,
             subtitle: String(localized: "Import a single exported workout file from any brand (Garmin, Coros, Suunto, Wahoo, Polar, Strava, Apple) straight off your device. GPS route, distance, heart rate and calories come in where the file has them. Fully offline; nothing leaves \(Platform.deviceNounPhrase).")) {
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.activityFile) } label: {
                    Label(activityFileImporting ? "Importing…" : "Choose .gpx / .tcx / .fit…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if activityFileImporting { ProgressView().controlSize(.small) }
            }
            if let s = activityFileSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(activityFileFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var wearableCard: some View {
        card(title: String(localized: "Oura / Fitbit / Garmin export"), icon: "figure.mind.and.body",
             tint: StrandPalette.metricPurple,
             subtitle: String(localized: "Import your own data export from Oura, Fitbit or Garmin: sleep, resting heart rate, HRV, steps and more, where the export has them. Download it from the brand's app (Oura: Account → Export Data; Fitbit: Google Takeout; Garmin: Export Your Data), then choose the file here. Fully offline; nothing leaves \(Platform.deviceNounPhrase). Each brand's own readiness or sleep score is kept for reference only. Your scores stay yours.")) {
            HStack(spacing: NoopMetrics.space3) {
                Button { presentImporter(.wearable) } label: {
                    Label(wearableImporting ? "Importing…" : "Choose export…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting || wearableImporting)
                if wearableImporting { ProgressView().controlSize(.small) }
            }
            if let s = wearableSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(wearableFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    #if OURA_CLOUD_IMPORT
    /// Oura history import: a one-time, user-initiated, foreground OAuth + API backfill of the user's
    /// own history — an *import* in the same family as the export-file importers above, not a sync
    /// (nothing runs in the background, on a timer, or at launch). `oura.connectAndImport(repo:)`/
    /// `disconnect(repo:)` take `repo` at call time (see the `@StateObject` declaration's note)
    /// rather than storing it in `OuraConnectModel` at construction.
    private var ouraCloudCard: some View {
        card(title: String(localized: "Oura history import"), icon: "circle.circle", tint: StrandPalette.metricPurple,
             subtitle: String(localized: "A one-time import of your own Oura history over the Oura API. Runs only when you tap it.")) {
            VStack(alignment: .leading, spacing: 8) {
                if oura.isConnected {
                    HStack {
                        Button { oura.connectAndImport(repo: repo) } label: { Label("Import again", systemImage: "arrow.clockwise") }
                            .buttonStyle(NoopButtonStyle(.primary))
                        Button(role: .destructive) { oura.disconnect(repo: repo) } label: { Label("Forget Oura access", systemImage: "xmark.circle") }
                            .buttonStyle(NoopButtonStyle(.destructive))
                    }.disabled(oura.busy)
                } else {
                    Button { oura.connectAndImport(repo: repo) } label: {
                        Label(oura.busy ? "Working…" : "Import your Oura history", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(NoopButtonStyle(.primary))
                    .disabled(oura.busy || !oura.isConfigured)
                    if !oura.isConfigured {
                        Text("Add your Oura app credentials to OuraSecrets.xcconfig to enable this.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let s = oura.statusText { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    #endif // OURA_CLOUD_IMPORT

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        #if os(iOS)
        // iOS: go through UIDocumentPickerViewController with asCopy:true (DocumentPicker) rather than
        // SwiftUI's `.fileImporter` (#179). asCopy makes iOS DOWNLOAD an iCloud-Drive placeholder and
        // hand us a readable local copy — `.fileImporter` instead returns a security-scoped URL that,
        // for an undownloaded iCloud file, can't be read, and the whole import silently did nothing.
        Task {
            guard let url = await DocumentPicker.importFile(target.allowedContentTypes) else { return } // cancelled
            handlePickedURL(url, for: target)
        }
        #else
        showingImporter = true
        #endif
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handlePickedURL(url, for: target)
        case .failure(let error):
            // Surface the failure instead of swallowing it (#179) — a silent return read as
            // "import does nothing", with no clue why.
            NSLog("Import: file picker failed for \(target) — \(error.localizedDescription)")
        }
    }

    private func handlePickedURL(_ url: URL, for target: ImportTarget) {
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        case .xiaomi:
            model.importXiaomi(url: url)
        case .nutrition:
            importNutrition(url: url)
        case .lifting:
            importLifting(url: url)
        case .activityFile:
            importActivityFile(url: url)
        case .wearable:
            importWearable(url: url)
        }
    }

    /// Write one privacy-safe line into the SAME exported strap log the WHOOP path uses, so a tester's
    /// file import is no longer invisible in a shared debug bundle (issue #421 parity). Brand label +
    /// COUNTS only, never a file name, a path, or any health value. Prefixed "Import " so it's
    /// distinguishable from the WHOOP / HR-strap / HR-out lines. Timestamp matches the rest of the log.
    /// The Android twin logs the same shape from DataSourcesScreen.runImport via ble.externalLog.
    private func logImport(_ line: String) {
        live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] Import \(line)")
    }

    /// Parse a daily-nutrition CSV and upsert it into the metric-series store under the
    /// dedicated "nutrition-csv" source, then refresh so Explore/Insights see the new keys.
    private func importNutrition(url: URL) {
        nutritionImporting = true
        nutritionSummary = nil
        nutritionFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = NutritionCsvImporter.parse(data: data)
                guard result.importedDays > 0 else {
                    nutritionSummary = String(localized: "No usable rows found. Check the file has a date column (yyyy-MM-dd) and daily totals.")
                    nutritionFailed = true
                    logImport("Nutrition CSV: no usable rows (\(result.skippedRows) skipped)")
                    nutritionImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    nutritionSummary = String(localized: "Couldn't open the local store.")
                    nutritionFailed = true
                    nutritionImporting = false
                    return
                }
                let points = result.metricPoints.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
                try await store.upsertMetricSeries(points, deviceId: NutritionCsvImporter.sourceId)
                await repo.refresh()
                var msg = String(localized: "Imported \(result.importedDays) days (\(points.count) values)")
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a)-\(b)" }
                if result.skippedRows > 0 {
                    // Whole-phrase variants per count; the separator stays outside the localized key.
                    msg += " · " + (result.skippedRows == 1
                                    ? String(localized: "1 row skipped")
                                    : String(localized: "\(result.skippedRows) rows skipped"))
                }
                nutritionSummary = msg
                nutritionFailed = false
                logImport("Nutrition CSV: \(result.importedDays) days, \(points.count) values, \(result.skippedRows) rejected")
            } catch {
                nutritionSummary = String(localized: "Import failed: \(error.localizedDescription)")
                nutritionFailed = true
                logImport("Nutrition CSV failed: \(error.localizedDescription)")
            }
            nutritionImporting = false
        }
    }

    /// Parse a Hevy CSV / Liftosaur JSON lifting export and upsert each workout as a Strength session
    /// (source "lifting") with a transparent volume-load note. No `strain` is stored, so these never
    /// feed the HR-based Effort — lifting volume is reported alongside it, never folded into it.
    private func importLifting(url: URL) {
        liftingImporting = true
        liftingSummary = nil
        liftingFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = LiftingImporter.parse(data: data)
                guard result.sessionCount > 0 else {
                    liftingSummary = String(localized: "No workouts found. Point at a Hevy CSV export or a Liftosaur JSON export.")
                    liftingFailed = true
                    logImport("Lifting log: no workouts found (\(result.skipped) skipped)")
                    liftingImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    liftingSummary = String(localized: "Couldn't open the local store.")
                    liftingFailed = true
                    liftingImporting = false
                    return
                }
                let rows = result.sessions.map { s in
                    WorkoutRow(
                        startTs: Int(s.start.timeIntervalSince1970),
                        endTs: Int(s.end.timeIntervalSince1970),
                        sport: LiftingImporter.sport,
                        source: LiftingImporter.sourceId,
                        durationS: s.durationS,
                        energyKcal: nil,
                        avgHr: nil,
                        maxHr: nil,
                        strain: nil,                 // never a fabricated cardiovascular strain
                        distanceM: nil,
                        zonesJSON: nil,
                        notes: s.volumeLoadNote(), steps: nil
                    )
                }
                try await store.upsertWorkouts(rows, deviceId: LiftingImporter.sourceId)
                await repo.refresh()
                let totalVolume = result.sessions.reduce(0.0) { $0 + $1.volumeLoadKg }
                // Whole-phrase variants per count so translators never see a stitched plural.
                var msg = result.sessionCount == 1
                    ? String(localized: "Imported 1 workout")
                    : String(localized: "Imported \(result.sessionCount) workouts")
                if totalVolume > 0 {
                    msg += " · " + String(localized: "\(LiftingImporter.groupedKg(totalVolume)) kg total volume")
                }
                if let a = result.earliest, let b = result.latest {
                    let span = liftingDayFormatter
                    let lo = span.string(from: a), hi = span.string(from: b)
                    if lo != hi { msg += " · \(lo)-\(hi)" }
                }
                if result.skipped > 0 { msg += " · " + String(localized: "\(result.skipped) skipped") }
                liftingSummary = msg
                liftingFailed = false
                logImport("Lifting log: \(result.sessionCount) workouts, \(result.skipped) rejected")
            } catch {
                liftingSummary = String(localized: "Import failed: \(error.localizedDescription)")
                liftingFailed = true
                logImport("Lifting log failed: \(error.localizedDescription)")
            }
            liftingImporting = false
        }
    }

    /// Parse a single GPX / TCX / FIT activity file and upsert it as one workout (source
    /// "activity-file"). The route polyline isn't persisted on macOS (the shared WorkoutRow has no route
    /// column), but distance / HR / energy / ascent and an honest "N GPS points · M HR samples" note are.
    ///
    /// #137: the imported ride's REAL per-sample HR is now ALSO persisted as an HR stream under the
    /// `activity-file` deviceId, and `activity-file` is registered as an `.activityFile` device. Together
    /// (A + B1) that lets a strap-less day's ride light the day Effort ring: the per-day owner resolver
    /// (`IntelligenceEngine.resolveDayOwner`) treats `activity-file` as the LOWEST-ranked candidate
    /// (priority 3, below whole-day imports at 2) and — being the only source with HR that day — picks it
    /// as the day owner, so `dayHr` reads the ride's HR and Effort scores from it. On a day the user ALSO
    /// wore the strap, the strap (priority 0/1) wins ownership and the imported HR is ignored for Effort;
    /// on a day a whole-day WHOOP import (priority 2) has HR, that import wins over the ride too. The
    /// workout row itself still stores `strain = nil` (we never fabricate a per-workout strain); the day
    /// Effort is computed from the measured HR stream, exactly as it is for a worn strap.
    private func importActivityFile(url: URL) {
        activityFileImporting = true
        activityFileSummary = nil
        activityFileFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Cap the read so a hostile huge file can't OOM us before the parser's own guards.
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                if data.count > ActivityFileImporter.maxBytes {
                    activityFileSummary = String(localized: "That file is too large to import.")
                    activityFileFailed = true
                    logImport("Workout file failed: file too large")
                    activityFileImporting = false
                    return
                }
                let result = ActivityFileImporter.parse(data: data, filename: url.lastPathComponent)
                guard let activity = result.activity, let s = activity.durationS, s > 0 else {
                    activityFileSummary = String(localized: "No usable activity found. Point at a .gpx, .tcx or .fit workout file.")
                    activityFileFailed = true
                    logImport("Workout file: no usable activity found")
                    activityFileImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    activityFileSummary = String(localized: "Couldn't open the local store.")
                    activityFileFailed = true
                    activityFileImporting = false
                    return
                }
                let sport = ActivityFileImporter.workoutSport(from: activity.sport)
                let row = WorkoutRow(
                    startTs: Int(activity.start.timeIntervalSince1970),
                    endTs: Int(activity.end.timeIntervalSince1970),
                    sport: sport,
                    source: ActivityFileImporter.sourceId,
                    durationS: activity.durationS,
                    energyKcal: activity.energyKcal,
                    avgHr: activity.avgHr,
                    maxHr: activity.maxHr,
                    strain: nil,                         // never a fabricated cardiovascular strain
                    distanceM: activity.distanceM,
                    zonesJSON: nil,
                    notes: activity.importNote(),
                    steps: activity.steps                 // #1058: per-session steps, summed into the day below
                )
                try await store.upsertWorkouts([row], deviceId: ActivityFileImporter.sourceId)

                // #137 (A): persist the ride's real per-sample HR under the activity-file source. The
                // insert is keyed on (deviceId, ts), so re-importing the same file is idempotent (an
                // identical ts overwrites, never duplicates). Skipped when the file carried no
                // timestamped HR (a pure GPS track) — nothing to store, so day Effort stays honestly dark.
                if !activity.hrSamples.isEmpty {
                    let hr = activity.hrSamples.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
                    _ = try? await store.insert(Streams(hr: hr), deviceId: ActivityFileImporter.sourceId)
                }
                // #1058: recompute the day's activity-file step total as the SUM over ALL that day's
                // sessions (now that each carries its own steps), so a second file for the same day ADDS
                // to the first instead of clobbering it. Idempotent on re-import: the file's workout row
                // (keyed on startTs+sport) is replaced, not duplicated, so the re-summed total is unchanged.
                // Only recompute when THIS file contributed steps (a foot sport); a cycling import leaves
                // the day's step total untouched.
                if (activity.steps ?? 0) > 0 {
                    let dayStart = Calendar.current.startOfDay(for: activity.start)
                    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
                        ?? dayStart.addingTimeInterval(86_400)
                    let daySteps = (try? await store.sumWorkoutSteps(
                        deviceId: ActivityFileImporter.sourceId,
                        from: Int(dayStart.timeIntervalSince1970),
                        to: Int(dayEnd.timeIntervalSince1970))) ?? 0
                    if daySteps > 0 {
                        let metric = DailyMetric(
                            day: Repository.localDayKey(activity.start),
                            totalSleepMin: nil,
                            efficiency: nil,
                            deepMin: nil,
                            remMin: nil,
                            lightMin: nil,
                            disturbances: nil,
                            restingHr: nil,
                            avgHrv: nil,
                            recovery: nil,
                            strain: nil,
                            exerciseCount: nil,
                            steps: daySteps
                        )
                        try? await store.upsertDailyMetrics([metric], deviceId: ActivityFileImporter.sourceId)
                    }
                }

                // #137 (B1): register `activity-file` as an `.activityFile` device so the per-day owner
                // resolver can pick it as the day owner on a strap-less day (it iterates the registry's
                // paired devices; an unregistered source is invisible to it). The distinct kind ranks it
                // at priority 3 — below whole-day imports (2) — so a full-day WHOOP import always wins a
                // day it has HR for. status `.paired`, NEVER `.active`, so it can never displace the live
                // strap as the active device; capability `.hr` marks what the source CAN provide (presence
                // per-day is still gated by an actual HR read in the resolver). Idempotent, makeActive: false.
                model.registerDevice(
                    PairedDevice(
                        id: ActivityFileImporter.sourceId,
                        brand: "Workout files",
                        model: "",
                        sourceKind: .activityFile,
                        capabilities: [.hr],
                        status: .paired,
                        addedAt: Int(Date().timeIntervalSince1970),
                        lastSeenAt: Int(Date().timeIntervalSince1970)
                    ),
                    makeActive: false
                )

                await repo.refresh()
                activityFileSummary = ActivityFileImporter.summaryText(activity)
                activityFileFailed = false
                logImport("Workout file (\(sport)): 1 workout imported")
            } catch {
                activityFileSummary = String(localized: "Import failed: \(error.localizedDescription)")
                activityFileFailed = true
                logImport("Workout file failed: \(error.localizedDescription)")
            }
            activityFileImporting = false
        }
    }

    /// Parse a user's own Oura / Fitbit / Garmin data export and upsert it under the brand's own source
    /// (daily metrics + sleep sessions + reference-only metric series). The brand's own readiness/sleep
    /// score is NEVER mapped to a NOOP Charge/Effort/Rest — NOOP recomputes its own from the raw inputs.
    private func importWearable(url: URL) {
        wearableImporting = true
        wearableSummary = nil
        wearableFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    wearableSummary = String(localized: "Couldn't open the local store.")
                    wearableFailed = true
                    wearableImporting = false
                    return
                }
                // Import & Data Ingest test mode: a gated trace sink. The sink is nil when the mode is off
                // (the importer then takes its byte-identical untraced path). The brand is auto-detected, so
                // the kind-bearing file-meta line is emitted AFTER the result lands, with the real detected
                // kind; the size is bucketed in ImportTrace so no path, name or byte-exact size leaves.
                // The importer runs nonisolated, so the sink hops each batch to the main actor (LiveState is
                // @MainActor) before appending, keeping the tagged log append race-free and ordered.
                // Import & Data Ingest test mode: read the gate ONCE for this completion (the trace sink AND
                // the post-result file-meta line below share it), so a mid-import toggle can't make the two
                // reads disagree and the bool is read a single time.
                let importTracing = TestCentre.active(.dataImport)
                let result = try await WearableImporter.importExport(
                    url: url, into: store,
                    trace: importTracing
                        ? { @Sendable [weak live] lines in
                            Task { @MainActor [weak live] in
                                lines.forEach { live?.append(log: $0, domain: .dataImport) }
                            }
                          }
                        : nil)
                if importTracing {
                    let ext = url.pathExtension
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                    live.append(log: ImportTrace.fileMetaLine(sourceKind: result.brand.dataSourceKind,
                                                              ext: ext, sizeBytes: size),
                                domain: .dataImport)
                }
                await repo.refresh()
                wearableSummary = WearableExportImporter.summaryText(result)
                wearableFailed = false
                logImport("\(result.brand.displayName) export: \(result.days.count) days, \(result.sleeps.count) sleeps, \(result.summary.skippedSpans) rejected")
            } catch {
                wearableSummary = String(localized: "Import failed: \(error.localizedDescription)")
                wearableFailed = true
                logImport("Wearable export failed: \(error.localizedDescription)")
            }
            wearableImporting = false
        }
    }

    /// ah-delete (#616): purge every row stored under the "apple-health" source by calling
    /// `DeviceRegistryStore.deleteAllData(deviceId:)` (via the device registry's `deleteDeviceData`,
    /// which clears all `deviceId`-keyed tables in one transaction). The registry row itself is the
    /// seeded WHOOP device — "apple-health" is a source, not a paired device — so nothing in the
    /// Devices list changes; only the imported recordings go. Refresh so Today/Explore/Insights drop
    /// the now-empty source, and clear the import summary so the card reads as "nothing imported".
    private func deleteAppleHealthData() {
        guard !appleHealthDeleting else { return }
        appleHealthDeleting = true
        appleHealthDeletedSummary = nil
        Task {
            guard let store = await repo.storeHandle() else {
                appleHealthDeletedSummary = nil
                appleHealthDeleting = false
                return
            }
            do {
                // Route the purge through the WhoopStore actor's `deleteAllData` so the heavy 16+-table
                // delete runs on the actor's OWN (off-main) executor. Calling the synchronous
                // `DeviceRegistryStore(...).deleteAllData` directly here ran the whole transaction on the
                // main actor and froze the UI on a large Apple Health dataset.
                try await store.deleteAllData(deviceId: model.appleDeviceId)
                await repo.refresh()
                // #833/v7.7.2: this purge clears the body-composition series (weight/body_fat/lean_mass/bmi/
                // vo2max) that live in metricSeries OUTSIDE refresh()'s diff, so refresh() may not bump
                // `refreshSeq` and AppleHealthView's re-mount cache would keep serving the now-DELETED data.
                // Explicitly drop the cache so the next visit re-reads the emptied source. (refresh() alone is
                // insufficient for the body-comp keys.)
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                model.appleHealthImportSummary = nil
                model.appleHealthImportFailed = false
                appleHealthDeletedSummary = String(localized: "Removed all Apple Health imported data.")
                logImport("Apple Health: imported data removed")
            } catch {
                appleHealthDeletedSummary = String(localized: "Couldn't remove the data: \(error.localizedDescription)")
                logImport("Apple Health delete failed: \(error.localizedDescription)")
            }
            appleHealthDeleting = false
        }
    }

    private var liftingDayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")   // sessions are stored at UTC; label the same span
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private enum ImportTarget {
        case whoop
        case appleHealth
        case xiaomi
        case nutrition
        case lifting
        case activityFile
        case wearable

        var allowedContentTypes: [UTType] {
            // `.folder` lets macOS users point at an *unzipped* export directory. On iOS the Files
            // picker can't meaningfully pick a folder here, and including `UTType.folder` in the type
            // list greys out the .zip itself — so the picker opens but nothing is selectable
            // (issue #179). iOS therefore offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            case .xiaomi:
                // The Mi Fitness sandbox is shared as a .zip (or, on macOS, an unzipped
                // folder); the bare `<user_id>.db` is also accepted directly.
                let db = UTType(filenameExtension: "db") ?? .data
                #if os(macOS)
                return [.zip, .folder, db]
                #else
                return [.zip, db]
                #endif
            case .nutrition:
                return [.commaSeparatedText, .plainText]
            case .lifting:
                // Hevy exports .csv, Liftosaur exports .json — accept both (plus plain text, since some
                // share sheets type a .csv as text/plain). The importer sniffs the actual format.
                return [.commaSeparatedText, .json, .plainText]
            case .activityFile:
                // GPX/TCX are XML; FIT is binary. None have a system UTType, so build them by extension
                // (falling back to .xml/.data) and add .data so an untyped share-sheet file is selectable.
                // The importer routes by extension/magic-bytes regardless.
                let gpx = UTType(filenameExtension: "gpx") ?? .xml
                let tcx = UTType(filenameExtension: "tcx") ?? .xml
                let fit = UTType(filenameExtension: "fit") ?? .data
                return [gpx, tcx, fit, .xml, .data]
            case .wearable:
                // Oura is a single .json; Fitbit (Google Takeout) and Garmin (GDPR) are .zip bundles.
                // On macOS an unzipped folder is also accepted. The importer sniffs the brand by content.
                #if os(macOS)
                return [.json, .zip, .folder, .data]
                #else
                return [.json, .zip, .data]
                #endif
            }
        }
    }
    private var broadcastHrCard: some View {
        // Status pill reflects the real broadcast state once it's on: advertising vs starting up.
        let status: StatePill? = broadcastHrEnabled
            ? StatePill(hrBroadcaster.advertising ? "Broadcasting" : "Starting…",
                        tone: hrBroadcaster.advertising ? .positive : .warning,
                        pulsing: !hrBroadcaster.advertising)
            : nil
        return card(title: String(localized: "Broadcast HR from this phone"), icon: "dot.radiowaves.up.forward",
             tint: DomainTheme.effort.color,
             status: status ?? StatePill("Off", tone: .neutral, showsDot: false),
             subtitle: String(localized: "Re-share your live strap heart rate over Bluetooth as a standard heart-rate sensor, so a gym treadmill, bike, Zwift, Peloton or any fitness app nearby can read it. Local Bluetooth only. Nothing leaves \(Platform.deviceNounPhrase). Off by default.")) {
            Toggle(isOn: $broadcastHrEnabled) {
                Text("Broadcast HR from this phone")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(DomainTheme.effort.color)
            .accessibilityLabel("Broadcast heart rate as a Bluetooth sensor")
            .onChangeCompat(of: broadcastHrEnabled) { on in
                if on { hrBroadcaster.start() } else { hrBroadcaster.stop() }
            }
            Text("Acts as a standard Bluetooth heart-rate strap. Pair NOOP from your treadmill, bike or app to see your strap's heart rate there.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // FI-2 (#490) — the 4.0-vs-5.0 explainer. Broadcast works for BOTH strap generations because it
            // re-shares whatever LIVE heart rate NOOP already has off the strap; it doesn't depend on the
            // 5/MG-only deep-data path. The honest distinction is WHERE that live HR comes from (4.0 = the
            // strap's standard HR characteristic; 5/MG = PPG-derived once connected), not whether broadcast
            // works at all. Stated plainly so a 4.0 owner knows this is for them too.
            generationExplainer

            // Honest live status only while it's on: a warning note if the radio can't run, else either
            // who's reading it or that we're waiting (never a fabricated "connected").
            if broadcastHrEnabled {
                if let note = hrBroadcaster.statusNote {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if hrBroadcaster.subscriberCount > 0 {
                    let n = hrBroadcaster.subscriberCount
                    // Whole-phrase variants per count so translators never see a stitched plural.
                    Text(n == 1 ? "1 device reading your heart rate"
                                : "\(n) devices reading your heart rate")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else if let hr = live.heartRate {
                    Text("Sharing \(hr) bpm. Waiting for a device to pair.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("No live heart rate yet. Open Live to pair your strap.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// FI-2 (#490) — a compact, honest "works with both strap generations" explainer under the broadcast
    /// toggle. Two short lines (4.0 / 5.0·MG) frame WHERE the live HR comes from on each, so a WHOOP 4.0
    /// owner knows broadcast is for them and a 5/MG owner understands the PPG-derived source — without
    /// over-promising. Plain copy, no claim that either generation is "better".
    private var generationExplainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            generationRow(title: "WHOOP 4.0",
                          detail: String(localized: "Broadcasts the strap's own live heart rate over Bluetooth."))
            generationRow(title: "WHOOP 5.0 & MG",
                          detail: String(localized: "Broadcasts the live heart rate NOOP derives from the strap once connected."))
        }
        .padding(.top, 2)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DomainTheme.effort.color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func generationRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DomainTheme.effort.color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }

    private var liveCard: some View {
        // Three-state, consistent with the Live screen's connection pill — a connected-but-
        // not-yet-streaming strap (e.g. an experimental WHOOP 5/MG link) no longer reads as
        // "Not connected" on one screen and "Connected" on another (issue #8).
        // Written as statements rather than a ternary chain: five arms of (StrandTone,
        // LocalizedStringKey) tuples is the shape that pushes this expression past the iOS type-check
        // budget, and it fails in CI rather than here.
        let tone: StrandTone
        let label: LocalizedStringKey
        if live.encryptedBond {
            tone = .positive; label = "Bonded, streaming."
        } else if live.bonded {
            tone = .warning; label = "Live HR (not fully paired)"
        } else if live.connected {
            tone = .warning; label = "Connected."
        } else {
            tone = .critical; label = "Not connected. Open Live to pair."
        }
        return card(title: String(localized: "WHOOP Strap (Live BLE)"), icon: "antenna.radiowaves.left.and.right",
             tint: StrandPalette.accent,
             status: StatePill(label, tone: tone, pulsing: live.connected && !live.bonded),
             subtitle: String(localized: "Pairs directly with your strap over Bluetooth: no WHOOP app, no cloud.")) {
            EmptyView()
        }
    }

    /// One source as a frosted, domain-tinted NoopCard: a tinted source glyph + title, an optional
    /// status pill on the trailing edge, the explainer line, then the connect/import action(s). The
    /// glyph + accents take the card's `tint` (its colour world); the status pill carries connection
    /// state. Replaces the old flat surfaceRaised rectangle with the shared Bevel card surface.
    @ViewBuilder
    private func card<C: View, S: View>(title: String, icon: String,
                              tint: Color = StrandPalette.accent,
                              status: S = EmptyView(),
                              subtitle: String,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        NoopCard(padding: 18, tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space2 + 2) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    status
                }
                Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}
