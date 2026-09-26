import SwiftUI
import StrandDesign
import WhoopStore

struct WeightHistoryView: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitRaw = UnitSystem.metric.rawValue
    @State private var history: [WeightEntry] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var range = 90
    @State private var showEditor = false
    @State private var editing: WeightEntry?
    @State private var deleting: WeightEntry?
    private var system: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var today: String { Repository.localDayKey(Date()) }
    private var visible: [WeightEntry] {
        let start = Calendar.current.date(byAdding: .day, value: -(range - 1), to: Date()) ?? Date()
        return history.filter { range == 0 || $0.day >= Repository.localDayKey(start) }
    }

    var body: some View {
        ScreenScaffold(title: "Weight history", onRefresh: { await load() }, lazy: true, trailing: {
            Button { editing = nil; showEditor = true } label: { Label("Add weight", systemImage: "plus") }
                .disabled(busy)
        }) {
            if loading { ProgressView() }
            if let error {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text(error).font(StrandFont.body).foregroundStyle(StrandPalette.statusCritical)
                        Button("Try again") { Task { await load() } }
                    }
                }
            }
            SegmentedPillControl([30, 90, 0], selection: $range) { value in
                value == 0 ? String(localized: "All") : String(format: String(localized: "%lld days"), value)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if let latest = visible.last {
                        Text(UnitFormatter.massFromKilograms(latest.kilograms, system: system))
                            .font(StrandFont.title1).monospacedDigit()
                        Text(dayLabel(latest.day)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        if visible.count > 1 {
                            TrendChart(points: chartPoints, gradient: Gradient(colors: [StrandPalette.accent]),
                                       valueRange: chartRange, showsArea: false, height: NoopMetrics.chartHeight,
                                       valueFormat: { value in
                                           UnitFormatter.massFromKilograms(system == .imperial ? value / UnitFormatter.kgToPounds(1) : value, system: system)
                                       }, accessibilityLabel: String(localized: "Weight history"))
                        }
                    } else {
                        Text("No data").font(StrandFont.headline)
                        Text("Log a weight or import weight history.").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            Text("Logged weights do not change your profile weight.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            ForEach(visible.reversed(), id: \.day) { entry in
                NoopCard {
                    HStack(spacing: NoopMetrics.gap) {
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            Text(UnitFormatter.massFromKilograms(entry.kilograms, system: system))
                                .font(StrandFont.headline).monospacedDigit()
                            Text(dayLabel(entry.day)).font(StrandFont.caption)
                            Text(sourceLabel(entry.source)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        if entry.isManual {
                            Button { editing = entry; showEditor = true } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("Edit").disabled(busy)
                            Button { deleting = entry } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete").disabled(busy)
                        }
                    }
                }
            }
        }
        .tint(StrandPalette.accent)
        .task { await load() }
        .sheet(isPresented: $showEditor) {
            WeightEntryEditor(entry: editing, system: system, busy: busy, error: error,
                              onCancel: { showEditor = false; error = nil },
                              onSave: { day, kg in
                                  Task { await change { store in try await store.saveWeight(day: day, kilograms: kg) } }
                              })
        }
        .alert("Delete this weight entry?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let entry = deleting else { return }
                Task { await change { store in try await store.deleteWeight(day: entry.day) } }
            }
        } message: {
            if let deleting { Text(dayLabel(deleting.day) + " · " + UnitFormatter.massFromKilograms(deleting.kilograms, system: system)) }
        }
    }

    private var chartPoints: [TrendPoint] {
        visible.compactMap { entry in
            guard let date = Self.dayFormatter.date(from: entry.day) else { return nil }
            return TrendPoint(date: date, value: system == .imperial ? UnitFormatter.kgToPounds(entry.kilograms) : entry.kilograms)
        }
    }
    private var chartRange: ClosedRange<Double> {
        let values = chartPoints.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let padding = max(1, (high - low) * 0.1)
        return max(0, low - padding)...(high + padding)
    }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private func dayLabel(_ day: String) -> String {
        Self.dayFormatter.date(from: day)?.formatted(date: .abbreviated, time: .omitted) ?? day
    }
    private func sourceLabel(_ source: String) -> String {
        switch source {
        case WeightHistory.manualSource: return String(localized: "Manual")
        case "apple-health": return String(localized: "Apple Health")
        case "health-connect": return String(localized: "Health Connect")
        default: return String(localized: "Imported")
        }
    }
    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            guard let store = await repo.storeHandle() else { throw WeightHistoryError.invalidEntry }
            history = try await store.weightHistory(through: today)
            error = nil
        } catch is CancellationError { }
        catch { self.error = String(localized: "Could not load weight history.") }
    }
    @MainActor private func change(_ action: (WhoopStore) async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let store = await repo.storeHandle() else { throw WeightHistoryError.invalidEntry }
            try await action(store)
            showEditor = false
            deleting = nil
            await load()
        } catch is CancellationError { }
        catch { self.error = String(localized: "Could not save this change. Try again.") }
    }
}

private struct WeightEntryEditor: View {
    let entry: WeightEntry?
    let system: UnitSystem
    let busy: Bool
    let error: String?
    let onCancel: () -> Void
    let onSave: (String, Double) -> Void
    @State private var amount: String
    @State private var date: Date
    private let initial: String

    init(entry: WeightEntry?, system: UnitSystem, busy: Bool, error: String?,
         onCancel: @escaping () -> Void, onSave: @escaping (String, Double) -> Void) {
        self.entry = entry; self.system = system; self.busy = busy; self.error = error
        self.onCancel = onCancel; self.onSave = onSave
        let initial = entry.map { String(system == .imperial ? UnitFormatter.kgToPounds($0.kilograms) : $0.kilograms) } ?? ""
        self.initial = initial
        _amount = State(initialValue: initial)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        _date = State(initialValue: entry.flatMap { formatter.date(from: $0.day) } ?? Date())
    }
    private var kilograms: Double? {
        if amount == initial, let entry { return entry.kilograms }
        let normalized = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Double(normalized.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return system == .imperial ? value / UnitFormatter.kgToPounds(1) : value
    }
    private var valid: Bool { kilograms.map(WeightHistory.validKilograms) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(entry == nil ? String(localized: "Add weight") : String(localized: "Edit"))
                .font(StrandFont.title2)
            DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                .disabled(entry != nil || busy)
            HStack(spacing: NoopMetrics.gap) {
                TextField("Weight", text: $amount)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .disabled(busy)
                Text(system == .imperial ? "lb" : "kg").font(StrandFont.body)
            }
            if !amount.isEmpty && !valid { Text("Enter a valid weight.").foregroundStyle(StrandPalette.statusCritical) }
            Text("One manual entry per date. Saving replaces an existing entry for that date.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if let error { Text(error).font(StrandFont.body).foregroundStyle(StrandPalette.statusCritical) }
            HStack(spacing: NoopMetrics.gap) {
                Button("Cancel", action: onCancel).disabled(busy)
                Spacer()
                Button("Save") {
                    if let kilograms { onSave(entry?.day ?? Repository.localDayKey(date), kilograms) }
                }.disabled(!valid || busy)
            }
        }
        .padding(NoopMetrics.screenPadding)
        .interactiveDismissDisabled(busy)
        .tint(StrandPalette.accent)
    }
}
