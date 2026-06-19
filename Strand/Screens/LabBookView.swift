import SwiftUI
import Foundation
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Lab Book (Health Records pillar — v5)
//
// "Your own logbook." NOOP gives you a private place to KEEP the numbers you already
// get from your doctor or pharmacy — bloods, blood pressure, body measurements — and
// SEE them next to your wearable signals, entirely on this device. NOOP never tests
// you, never reads a result for you, and never tells you what a number means medically.
// (Spec: docs/superpowers/specs/2026-06-19-v5-health-records-design.md.)
//
// This screen is SELF-CONTAINED: it takes the repo via the environment (the same one
// every other screen binds to) and reads/writes markers through `repo.storeHandle()` —
// the on-device WhoopStore, where the LabMarkerStore extension lives (v17 `labMarker`
// table). Raw readings are stored under the strap device id (`repo.deviceId`); every
// write also projects a daily series under the `lab-book` source so Compare/Explore/
// Coach see markers unchanged. The "Compare with a signal" surface reuses the same
// Pearson idiom + restrained copy as CompareView's pairCard.
//
// NON-CLINICAL (load-bearing, spec §"Non-clinical / legal framing"): no word here
// asserts a clinical judgement — never "abnormal/high/low/normal" as NOOP's own
// statement; any reference range shown is EXACTLY what the user typed from their own
// report; correlation copy says "association, not a medical finding". The full
// disclaimer shows on the screen and (Wave 3) links to the consolidated About & Legal.

struct LabBookView: View {
    @EnvironmentObject var repo: Repository

    /// All readings, grouped + ordered for display. Loaded off the store on appear/refresh.
    @State private var markers: [LabMarkerRow] = []
    @State private var loaded = false

    /// The marker whose detail sheet is open (nil = none).
    @State private var detailKey: String?
    /// Whether the add/edit editor sheet is open.
    @State private var showingEditor = false
    /// Whether the first-use disclaimer sheet is open.
    @State private var showingDisclaimer = false

    var body: some View {
        ScreenScaffold(
            title: "Lab Book",
            subtitle: "Your bloods, BP and body numbers — kept private, on \(Platform.deviceNounPhrase).",
            onRefresh: { await load() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                headerCard
                importCard
                if !loaded {
                    ComingSoon(what: "Reading your logbook…", symbol: "books.vertical")
                } else if markers.isEmpty {
                    emptyState
                } else {
                    ForEach(orderedCategories, id: \.self) { category in
                        categorySection(category)
                    }
                }
                disclaimerNote
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $showingEditor) {
            MarkerEditorView { drafts in
                await save(drafts)
            }
        }
        .sheet(item: detailBinding) { key in
            MarkerDetailView(markerKey: key.id,
                             readings: readings(for: key.id),
                             onDelete: { id in await delete(id) })
        }
        .sheet(isPresented: $showingDisclaimer) {
            LabBookDisclaimerView()
        }
    }

    // MARK: - Header (count + scope + actions)

    private var headerCard: some View {
        NoopCard(tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.metricCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(countLine).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("All stays on \(Platform.deviceNounPhrase). Nothing is sent anywhere.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showingDisclaimer = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What Lab Book is — and isn't")
                }
                Text("It's a notebook, not a lab. NOOP lines up the numbers you enter — it doesn't test, read, or judge them. Not medical advice.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingEditor = true
                } label: {
                    Label("Add a reading", systemImage: "plus")
                }
                .buttonStyle(.noopPrimary)
                .accessibilityLabel("Add a marker reading")
            }
        }
    }

    private var countLine: String {
        let keys = Set(markers.map(\.markerKey)).count
        let markerWord = keys == 1 ? "marker" : "markers"
        let readingWord = markers.count == 1 ? "reading" : "readings"
        return "\(keys) \(markerWord) tracked · \(markers.count) \(readingWord)"
    }

    // MARK: - Import entry (reuses the Data Sources import-card idiom)
    //
    // The cross-platform floor is manual entry (above). A bulk "Markers CSV" import is a Phase-2
    // engine (LabMarkerCsvImport, spec §"Phasing"); until it lands the card honestly points the
    // user at Data Sources, where every file importer lives, rather than fabricating a flow.

    private var importCard: some View {
        NoopCard(padding: 18, tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricAmber)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.metricAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Import readings").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    StatePill("Coming soon", tone: .neutral, showsDot: false)
                }
                Text("A bulk markers CSV import (date, marker, value, unit) lands with the file importers in Data Sources — same as nutrition and lifting. For now, add readings one at a time above. Everything you import stays on \(Platform.deviceNounPhrase).")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Empty state (honest)

    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.metricCyan)
                    .accessibilityHidden(true)
                Text("Keep your own numbers here")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Type in a blood-pressure reading or a cholesterol value from your last appointment. It stays on \(Platform.deviceNounPhrase), and over time you'll see how it lines up with your sleep, heart rate and recovery.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Category sections

    /// Categories present in the data, in the spec's display order.
    private var orderedCategories: [LabMarkerCategory] {
        let present = Set(markers.compactMap { LabMarkerCategory(rawValue: $0.category) })
        return LabBookView.categoryOrder.filter { present.contains($0) }
    }

    private static let categoryOrder: [LabMarkerCategory] = [
        .bloodPanel, .bloodPressure, .bodyMeasurement, .imaging, .appointmentNote, .other,
    ]

    @ViewBuilder
    private func categorySection(_ category: LabMarkerCategory) -> some View {
        let keys = markerKeys(in: category)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(category.displayName),
                          overline: keys.count == 1 ? "1 marker" : "\(keys.count) markers")
            ForEach(keys, id: \.self) { key in
                markerRow(key)
            }
        }
    }

    /// Distinct marker keys in a category, alphabetised by display name.
    private func markerKeys(in category: LabMarkerCategory) -> [String] {
        let keys = Set(markers.filter { $0.category == category.rawValue }.map(\.markerKey))
        return keys.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// One marker as a tappable card: name, latest reading + unit, a tiny sparkline, last-taken date.
    private func markerRow(_ key: String) -> some View {
        let series = readings(for: key)
        let numeric = series.compactMap { $0.value }
        let latest = series.last
        return Button {
            detailKey = key
        } label: {
            NoopCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: key))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Text(lastTakenCaption(latest))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if numeric.count > 1 {
                        Sparkline(values: numeric, gradient: Gradient(colors: [StrandPalette.metricCyan.opacity(0.5), StrandPalette.metricCyan]),
                                  showsHover: false)
                            .frame(width: 64, height: 28)
                            .accessibilityHidden(true)
                    }
                    Text(latestLabel(latest, key: key))
                        .font(StrandFont.number(18))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName(for: key)), latest \(latestLabel(latest, key: key)), \(series.count) readings")
    }

    // MARK: - Disclaimer (always visible footnote + link)

    private var disclaimerNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lab Book is a private notebook, not a medical service. NOOP stores and lines up the numbers you enter — it doesn't test, read, diagnose, or advise. Your records never leave \(Platform.deviceNounPhrase); there's no account or cloud, so it isn't \"HIPAA-covered.\" Always rely on your doctor or pharmacist to interpret results.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Read the full note") { showingDisclaimer = true }
                .buttonStyle(.plain)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Read the full Lab Book note")
        }
    }

    // MARK: - Data helpers

    /// Marker definition lookup → display name (catalog, else the key humanised).
    private func displayName(for key: String) -> String {
        if let def = MarkerCatalog.definition(for: key) { return def.displayName }
        return LabBookView.humanise(key)
    }

    static func humanise(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Readings for one marker, oldest-first (the store already returns them sorted by takenAt).
    private func readings(for key: String) -> [LabMarkerRow] {
        markers.filter { $0.markerKey == key }
    }

    private func latestLabel(_ row: LabMarkerRow?, key: String) -> String {
        guard let row else { return "—" }
        if let v = row.value { return "\(LabBookFormat.value(v, key: key)) \(row.unit)" }
        return row.valueText ?? "—"
    }

    private func lastTakenCaption(_ row: LabMarkerRow?) -> String {
        guard let row else { return "no readings yet" }
        return "last taken \(LabBookFormat.day(row.takenAt))"
    }

    private var detailBinding: Binding<MarkerKeyID?> {
        Binding(
            get: { detailKey.map(MarkerKeyID.init) },
            set: { detailKey = $0?.id }
        )
    }

    // MARK: - Load / save / delete (through the shared on-device store)

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        // Read by category so we cover them all; markers are stored under the strap device id.
        var all: [LabMarkerRow] = []
        for category in LabMarkerCategory.allCases {
            let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
            all.append(contentsOf: rows)
        }
        markers = all.sorted { $0.takenAt < $1.takenAt }
        loaded = true
    }

    private func save(_ drafts: [LabMarkerRow]) async {
        guard !drafts.isEmpty, let store = await repo.storeHandle() else { return }
        try? await store.upsertLabMarkers(drafts)
        await repo.refresh()   // re-resolves the lab-book projection into Compare/Explore/Coach
        await load()
    }

    private func delete(_ id: String) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLabMarker(id: id)
        await repo.refresh()
        await load()
    }
}

// MARK: - Identifiable wrapper so a String marker key can drive `.sheet(item:)`

private struct MarkerKeyID: Identifiable { let id: String }

// MARK: - Category display names + ordering

extension LabMarkerCategory {
    /// Human label for the Lab Book grouping header. Organisational only — never a clinical panel name.
    var displayName: String {
        switch self {
        case .bloodPanel:      return "Blood panel"
        case .bloodPressure:   return "Blood pressure"
        case .bodyMeasurement: return "Body"
        case .imaging:         return "Imaging"
        case .appointmentNote: return "Notes"
        case .other:           return "Custom"
        }
    }
}

// MARK: - Shared formatting (decimals from the catalog; UTC day labels)

enum LabBookFormat {
    /// Format a numeric value with the marker's catalog decimals (default 1 for custom markers).
    static func value(_ v: Double, key: String) -> String {
        let decimals = MarkerCatalog.definition(for: key)?.decimals ?? 1
        return decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "12 Jun 2026" for a takenAt epoch-seconds value.
    static func day(_ epoch: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// The `yyyy-MM-dd` day key the projection uses (LOCAL day of the reading).
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }
}

// MARK: - Marker detail (history + trend + "compare with a signal")

private struct MarkerDetailView: View {
    let markerKey: String
    let readings: [LabMarkerRow]
    let onDelete: (_ id: String) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The wearable metric chosen to correlate against (nil until the user picks one).
    @State private var signal: MetricDescriptor?
    /// The trailing-window width for the windowed-aggregate pairing.
    @State private var window: LabWindow = .fortnight
    /// The computed correlation result, recomputed when signal/window change.
    @State private var pairs: [WindowedPair] = []
    @State private var correlation: Correlation?
    @State private var computing = false

    private var displayName: String {
        MarkerCatalog.definition(for: markerKey)?.displayName ?? LabBookView.humanise(markerKey)
    }
    private var unit: String { readings.last?.unit ?? MarkerCatalog.definition(for: markerKey)?.canonicalUnit ?? "" }
    private var numericReadings: [LabMarkerRow] { readings.filter { $0.value != nil } }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(displayName),
                       subtitle: "\(readings.count) reading\(readings.count == 1 ? "" : "s") · your own entries") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                trendSection
                if !numericReadings.isEmpty { compareSection }
                historySection
                Text("These are your own numbers shown back to you. NOOP doesn't decide whether any value is normal, high or low.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Trend (descriptive arithmetic, never interpretation)

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trend", overline: "your readings over time")
            NoopCard(tint: StrandPalette.metricCyan) {
                VStack(alignment: .leading, spacing: 10) {
                    let nums = numericReadings.compactMap { $0.value }
                    if nums.count > 1 {
                        Sparkline(values: nums,
                                  gradient: Gradient(colors: [StrandPalette.metricCyan.opacity(0.5), StrandPalette.metricCyan]),
                                  valueFormat: { "\(LabBookFormat.value($0, key: markerKey)) \(unit)" })
                            .frame(height: 64)
                    }
                    Text(trendSentence)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let ref = latestReferenceText {
                        HStack(spacing: 6) {
                            SourceBadge("from your report", tint: StrandPalette.textTertiary)
                            Text(ref)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    /// "Your last 3 LDL readings: 3.4 → 3.1 → 2.9 mmol/L, trending down." — descriptive only.
    private var trendSentence: String {
        let nums = numericReadings
        guard let last = nums.last?.value else {
            return readings.last?.valueText.map { "Latest entry: \($0)." } ?? "No numeric readings yet."
        }
        guard nums.count >= 2 else {
            return "One reading so far: \(LabBookFormat.value(last, key: markerKey)) \(unit). Log a few more to see a trend."
        }
        let shown = nums.suffix(3).compactMap { $0.value }
        let arrowed = shown.map { LabBookFormat.value($0, key: markerKey) }.joined(separator: " → ")
        let first = shown.first ?? last
        let direction: String
        if last > first { direction = "trending up" }
        else if last < first { direction = "trending down" }
        else { direction = "holding steady" }
        return "Your last \(shown.count) readings: \(arrowed) \(unit), \(direction)."
    }

    private var latestReferenceText: String? {
        readings.last(where: { ($0.referenceText?.isEmpty == false) })?.referenceText
    }

    // MARK: - Compare with a signal (reuses the Pearson idiom + restrained copy)

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Compare with a signal", overline: "side by side · \(window.phrase) before each reading")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Signal picker + window control.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            signalMenu
                            Spacer()
                            SegmentedPillControl(LabWindow.allCases, selection: $window) { $0.label }
                                .accessibilityLabel("Trailing window")
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            signalMenu
                            SegmentedPillControl(LabWindow.allCases, selection: $window) { $0.label }
                                .accessibilityLabel("Trailing window")
                        }
                    }

                    if signal == nil {
                        Text("Pick a wearable signal (resting HR, HRV, sleep, Charge, weight…) to line it up against this marker. NOOP averages the signal over the \(window.phrase) before each reading.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        resultBlock
                    }
                }
            }
        }
        .task(id: "\(signal?.id ?? "")|\(window.rawValue)|\(repo.refreshSeq)") {
            await recompute()
        }
    }

    private var signalMenu: some View {
        Menu {
            ForEach(LabBookSignals.options) { metric in
                Button {
                    signal = metric
                } label: {
                    Label(metric.title, systemImage: signal?.id == metric.id ? "checkmark" : metric.icon)
                }
            }
            if signal != nil {
                Divider()
                Button(role: .destructive) { signal = nil } label: { Label("Clear", systemImage: "xmark") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text(signal?.title ?? "Choose a signal")
                    .font(StrandFont.subhead)
            }
            .foregroundStyle(StrandPalette.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose a wearable signal to compare")
    }

    @ViewBuilder
    private var resultBlock: some View {
        let n = pairs.count
        if computing {
            Text("Lining them up…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
        } else if n < LabBookSignals.floor {
            // Below the floor: show the points exist, withhold the conclusion sentence.
            Text(n == 0
                 ? "No overlap yet between this marker and \(signal?.title.lowercased() ?? "that signal"). Log a few more readings (and keep wearing your strap)."
                 : "\(n) reading\(n == 1 ? "" : "s") line up so far — not enough to read a trend yet (NOOP waits for \(LabBookSignals.floor)).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let c = correlation {
            pairResult(c, n: n)
        } else {
            Text("\(n) readings line up, but there isn't enough variation to compute a relationship.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One correlation read-out, in the shipped restrained idiom + the mandatory markers clause.
    private func pairResult(_ c: Correlation, n: Int) -> some View {
        let tint = LabBookSignals.correlationColor(c.r)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(displayName) ↔ \(signal?.title ?? "")")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                TrendChip(text: LabBookSignals.signedR(c.r), color: tint)
                Text("r = \(LabBookSignals.signedR(c.r))")
                    .font(StrandFont.number(18))
                    .foregroundStyle(tint)
            }
            Text(LabBookSignals.insightSentence(markerName: displayName,
                                                 signalName: signal?.title ?? "the signal",
                                                 r: c.r))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The mandatory clause for markers (spec §"On-device algorithm").
            Text("\(n) readings used · \(LabBookSignals.strengthWord(c.r)) \(LabBookSignals.directionWord(c.r)) association. This is your own data sitting side by side — it's not a medical finding, and it shows association, not cause.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - History table

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History", overline: "every reading you've entered")
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(readings.reversed().enumerated()), id: \.element.id) { idx, row in
                        historyRow(row)
                        if idx < readings.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ row: LabMarkerRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(valueLabel(row))
                    .font(StrandFont.number(16))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(LabBookFormat.day(row.takenAt))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                Task { await onDelete(row.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(StrandPalette.statusCritical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this reading")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func valueLabel(_ row: LabMarkerRow) -> String {
        if let v = row.value { return "\(LabBookFormat.value(v, key: markerKey)) \(row.unit)" }
        return row.valueText ?? "—"
    }

    // MARK: - Correlation compute (windowed-aggregate pairing → Pearson)

    private func recompute() async {
        guard let signal else { pairs = []; correlation = nil; return }
        computing = true
        defer { computing = false }
        // The marker series, read from the projected `lab-book` daily series (numeric only).
        let markerSeries = await repo.series(key: markerKey, source: WhoopStore.labBookSourceId)
        // The wearable series, freshest-wins through the Explore read path.
        let wearable = await repo.exploreSeries(key: signal.key, source: signal.source)
        let built = LabBookProjection.pairMarkerToWearable(marker: markerSeries,
                                                           wearable: wearable,
                                                           windowDays: window.days)
        pairs = built
        correlation = built.count >= LabBookSignals.floor
            ? CorrelationEngine.pearson(LabBookProjection.correlationInput(built))
            : nil
    }
}

// MARK: - Trailing window control (7 / 14 / 30 days)

enum LabWindow: String, CaseIterable, Identifiable {
    case week, fortnight, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week:      return "7d"
        case .fortnight: return "14d"
        case .month:     return "30d"
        }
    }
    var days: Int {
        switch self {
        case .week:      return 7
        case .fortnight: return 14
        case .month:     return 30
        }
    }
    var phrase: String {
        switch self {
        case .week:      return "7 days"
        case .fortnight: return "14 days"
        case .month:     return "30 days"
        }
    }
}

// MARK: - Wearable signals offered for correlation + the shared insight language
//
// The pickable wearable metrics + the restrained correlation copy, kept here so the
// Lab Book detail's "Compare with a signal" reads in the exact CompareView idiom
// (strength words, tends-to, association-not-cause) plus the mandatory markers clause.

enum LabBookSignals {
    /// The reading-count floor below which NO conclusion sentence renders (spec default 4).
    static let floor = 4

    /// The wearable metrics offered to pair a marker against. Strap-source keys read through the
    /// Explore freshest-wins path; weight resolves from Apple/Health-Connect/strap as available.
    static let options: [MetricDescriptor] = [
        descriptor("rhr"),
        descriptor("hrv"),
        descriptor("recovery"),
        descriptor("sleep_performance"),
        descriptor("sleep_total_min"),
        descriptor("strain"),
        descriptor("skin_temp"),
        descriptor("steps"),
        descriptor("weight"),
    ].compactMap { $0 }

    private static func descriptor(_ key: String) -> MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    static func signedR(_ r: Double) -> String {
        (r >= 0 ? "+" : "−") + String(format: "%.2f", abs(r))
    }

    static func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return "negligible"
        case ..<0.3:  return "weak"
        case ..<0.5:  return "moderate"
        case ..<0.7:  return "strong"
        default:      return "very strong"
        }
    }

    static func directionWord(_ r: Double) -> String {
        if abs(r) < 0.1 { return "" }
        return r >= 0 ? "positive" : "negative"
    }

    /// "When LDL is higher, HRV tends to be lower." — descriptive, no causal language.
    static func insightSentence(markerName: String, signalName: String, r: Double) -> String {
        guard abs(r) >= 0.3 else {
            return "Over your readings, \(markerName) and \(signalName.lowercased()) move largely independently — no clear relationship."
        }
        let verb = r < 0 ? "tends to be lower" : "tends to be higher"
        return "When \(markerName) is higher, \(signalName.lowercased()) \(verb)."
    }

    static func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - First-use / linked disclaimer

private struct LabBookDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold(title: "About Lab Book", subtitle: "A private notebook, not a medical service.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                bullet("NOOP stores and lines up the numbers you enter yourself. It does not test you, read your results, give medical advice, or diagnose anything.")
                bullet("Anything you see here — including any side-by-side trend — is your own information shown back to you. It's an association, never a cause, and never a medical finding.")
                bullet("NOOP never decides whether a value is \"normal,\" \"high,\" or \"low.\" Any reference range shown is exactly what you typed from your own report.")
                bullet("Your records never leave \(Platform.deviceNounPhrase). There's no account, no cloud, no NOOP server. Because NOOP is an independent app you run yourself — not a healthcare provider — it isn't \"HIPAA-covered,\" and that protection doesn't apply here; the safety comes from the data being local-only and yours.")
                bullet("Always rely on your doctor, pharmacist, or a qualified professional to interpret results and make decisions. If a number worries you, talk to them — not to an app.")
                Button("Got it") { dismiss() }
                    .buttonStyle(.noopPrimary)
                    .padding(.top, 4)
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(StrandPalette.metricCyan)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
@MainActor
private func labBookPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Lab Book") {
    LabBookView()
        .environmentObject(labBookPreviewRepo())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
