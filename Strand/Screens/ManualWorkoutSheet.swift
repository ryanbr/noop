import SwiftUI
import StrandDesign
import WhoopStore

/// Carries the measured natural height of the Sport picker's floating suggestion panel up to the
/// view, so the overlay can size itself to its content (capped) rather than to the text field.
private struct SuggestionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Manual workout sheet
//
// Add a workout you tracked elsewhere, or edit one you already logged. Six inputs — sport,
// start, duration, distance, average HR, calories — validated by WorkoutSource.buildManualRow (the same
// honest-row rules the engine uses). On save the caller persists it under the strap source via
// Repository.saveManualWorkout. Captured-but-unexposed fields (maxHr / strain / zones) on an edited
// row are carried over by WorkoutSource.preservingCaptured so editing a live-tracked session's
// sport/duration never silently wipes its real strain.
//
// `editing` is non-nil when editing an existing row (its values pre-fill the form and it is passed
// as `replacing:` so a changed natural key deletes the old row). nil = a fresh add.

struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a new manual workout.
    let editing: WorkoutRow?
    /// Called with the validated row (and the original, when editing) once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sport: String
    @State private var start: Date
    @State private var durationMin: Int
    @State private var avgHrText: String
    @State private var kcalText: String
    /// Distance as ENTERED, in the user's unit (km or mi) — converted to stored metres on save (#1195).
    @State private var distanceText: String

    /// The length unit system, so the Distance field reads/writes in the user's unit. Read live for the
    /// field label + parse; the init pre-fill reads the same key straight from UserDefaults (@AppStorage
    /// isn't available before `self` is formed).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnit: String { unitSystem == .imperial ? "mi" : "km" }

    /// Focus for the numeric (Avg HR / Calories / Distance) fields so the keyboard Done button can resign
    /// them — the decimal pad has no return key. iOS-only effect; the enum keeps both platforms compiling.
    private enum NumberField: Hashable { case avgHr, calories, distance }
    @FocusState private var focusedField: NumberField?

    /// Whether the Sport text field is being edited — drives whether the catalogue suggestions show
    /// beneath it. The list also stays hidden once the typed text exactly matches a catalogue sport
    /// (a settled choice), so the form isn't permanently half-covered.
    @FocusState private var sportFocused: Bool

    /// Measured natural height of the floating suggestion panel's content, so the overlay can size
    /// itself (capped at 168) instead of being squeezed to the text field's height. See `suggestionList`.
    @State private var suggestionsHeight: CGFloat = 0

    init(editing: WorkoutRow? = nil,
         onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // Pre-fill from the edited row (display "detected" as "Activity" so a re-label starts clean).
        let e = editing
        // Seeds the LOCALE-STABLE editable form, not the localized display: the field's content is
        // persisted verbatim on save, and a translated word would split cross-source dedup per language.
        _sport = State(initialValue: e.map { WorkoutSource.editableSport($0.sport) } ?? "")
        _start = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) } ?? Date())
        _durationMin = State(initialValue: e.map { max(1, Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded())) } ?? 45)
        _avgHrText = State(initialValue: e?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: e?.energyKcal.map { String(Int($0.rounded())) } ?? "")
        // Pre-fill the distance in the user's unit so an untouched edit round-trips the stored metres
        // (buildManualRow then re-stores exactly what's shown). @AppStorage isn't usable pre-init, so read
        // the same key directly.
        let sys = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        _distanceText = State(initialValue: e?.distanceM.map { Self.distanceEntryString($0, system: sys) } ?? "")
    }

    /// The stored metres shown as a clean editable number in `system`'s unit (km/mi) — trailing zeros and a
    /// dangling decimal trimmed so the field reads "5.2", not "5.20". Two decimals (~10 m) is plenty for a
    /// hand-entered distance; the field's purpose is manual entry, not preserving GPS's metre precision.
    private static func distanceEntryString(_ meters: Double, system: UnitSystem) -> String {
        let km = meters / 1000.0
        let value = system == .imperial ? km * UnitFormatter.milesPerKilometer : km
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        #if os(macOS)
        formContent
            .padding(NoopMetrics.space6)
            .frame(width: 420)
            .background(NoopChromeSurface())
            // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add.
            .keyboardDoneToolbar($focusedField)
        #else
        // #450 raised the sheet to .large so the keyboard had room, but the body was still a bare
        // fixed-height VStack — with no ScrollView to absorb the squeeze, iOS's own keyboard-avoidance
        // had no choice but to rigidly shift the WHOLE block up to keep the focused Sport field clear
        // of the keyboard. That shift could push the header + Sport field (and the top of its floating
        // suggestion overlay) off the top of the screen entirely — "recents still clip" — and could also
        // carry the footer's Add/Cancel row up into the same band where the system's own keyboard
        // "Done" accessory renders, producing the floating Fertig/Hinzufügen overlap. Wrapping in a
        // ScrollView gives keyboard-avoidance somewhere to scroll INSTEAD of rigidly displacing fixed
        // content, so nothing needs to leave its own bounds to stay clear of the keyboard.
        ScrollView {
            formContent
                .padding(NoopMetrics.space6)
        }
        .scrollDismissesKeyboard(.interactively)
        // A fixed 420pt is right for the free-floating macOS sheet, but on iPhone it's wider than
        // the screen, so the Avg HR/Calories row, the Start DatePicker and the footer ran off the
        // right edge (#185, same fix as WhatsNewView/ScoringGuideView). iOS fills the presented
        // sheet's width and sizes to content height instead.
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: true)
        .background(NoopChromeSurface())
        // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add.
        .keyboardDoneToolbar($focusedField)
        #endif
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                field(String(localized: "Sport")) {
                    sportPicker
                }
                // Raise the Sport field above the following rows so its floating suggestion dropdown
                // (an overlay, see `sportPicker`) draws ON TOP of Start / Duration instead of behind them.
                .zIndex(1)
                field(String(localized: "Start")) {
                    DatePicker("", selection: $start, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .accessibilityLabel("Start date and time")
                }
                field(String(localized: "Duration")) {
                    HStack(spacing: 12) {
                        Stepper(value: $durationMin, in: 1...(24 * 60), step: 5) {
                            Text(durationLabel)
                                .font(StrandFont.number(16))
                                .foregroundStyle(StrandPalette.effortBright)
                        }
                        .accessibilityLabel("Duration in minutes")
                    }
                }
                field(String(localized: "Distance")) {
                    numberInput(String(localized: "optional"), text: $distanceText, unit: distanceUnit, field: .distance)
                        .accessibilityLabel("Distance, optional")
                }
                HStack(spacing: 14) {
                    field(String(localized: "Avg HR")) {
                        numberInput(String(localized: "optional"), text: $avgHrText, unit: "bpm", field: .avgHr)
                            .accessibilityLabel("Average heart rate in beats per minute, optional")
                    }
                    field(String(localized: "Calories")) {
                        numberInput(String(localized: "optional"), text: $kcalText, unit: "kcal", field: .calories)
                            .accessibilityLabel("Calories in kilocalories, optional")
                    }
                }
            }
            if let validationNote { noteRow(validationNote) }
            if avgHrEditedNote { noteRow(String(localized: "Avg HR is shown as typed. The HR graph, zones and Effort stay from the recorded session.")) }
            footer
        }
    }

    // MARK: - Sport picker
    //
    // A searchable PICKER over the shared WorkoutCatalog (the same named-sport list the live tracker
    // uses, incl. Padel) with a free-text FALLBACK: the text field IS the value, so an unusual sport
    // NOOP doesn't enumerate still saves exactly as typed (#519). Typing filters the catalogue
    // beneath the field; tapping a match fills it; the list collapses on a settled / off-catalogue
    // entry so the short form isn't permanently covered. Mirrors Android WorkoutsScreen.SportPickerField.

    /// Suggestions for the current text — the whole catalogue while empty, else a case-insensitive
    /// name filter. Empty list ⇒ a free-typed sport with no match (keeps whatever was typed).
    private var sportSuggestions: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(sport) }

    /// Show the list only while the field is focused, there are matches, and the text isn't already an
    /// exact catalogue name (a settled choice collapses it).
    private var showSportSuggestions: Bool {
        sportFocused && !sportSuggestions.isEmpty && WorkoutCatalog.sport(named: sport) == nil
    }

    /// #297: the user's last selections, one tap away above the full catalogue. Raw stored names —
    /// this picker allows free text, so an off-catalogue recent stays selectable here (it just
    /// carries no GPS hint). Only rendered while the field is empty (typing means searching).
    private var recentSports: [String] { RecentSportsPrefs.recent() }

    private var showRecentSports: Bool {
        sport.trimmingCharacters(in: .whitespaces).isEmpty && !recentSports.isEmpty
    }

    private var sportPicker: some View {
        TextField("e.g. Running", text: $sport)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($sportFocused)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .accessibilityLabel("Sport")
            // The suggestion list FLOATS below the field as an overlay instead of sitting inline in the
            // form. Inline it was the only height-flexible element, so on iPhone with the keyboard up
            // the fixed-height fields below won the vertical space and squeezed it to nothing — the
            // #297 Recent block (and even the catalogue matches) never showed. As an overlay it doesn't
            // take part in the form's layout, so it renders at full height over the rows below; the
            // parent raises this field's zIndex so it draws on top of them.
            .overlay(alignment: .bottom) {
                if showSportSuggestions {
                    suggestionList
                        // Pin the panel's TOP to the field's BOTTOM (its own top stands in as the
                        // bottom-alignment anchor), then nudge it down for a small gap.
                        .alignmentGuide(.bottom) { $0[.top] }
                        .offset(y: 6)
                }
            }
    }

    /// The floating suggestion panel (Recent + full catalogue). An overlay proposes the field's small
    /// height to its content, which would re-squeeze a plain `.frame(maxHeight:)` ScrollView — so we
    /// MEASURE the content's natural height and set an explicit frame capped at 168, letting it scroll
    /// only past that. This is the same list the inline version rendered, just floated + self-sized.
    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showRecentSports {
                    Text("Recent").strandOverline()
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(recentSports, id: \.self) { name in
                        suggestionRow(name, isDistance: WorkoutCatalog.sport(named: name)?.isDistanceSport == true)
                    }
                    Text("All activities").strandOverline()
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                ForEach(sportSuggestions) { sp in
                    suggestionRow(sp.name, isDistance: sp.isDistanceSport)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: SuggestionsHeightKey.self, value: geo.size.height)
            })
        }
        .frame(height: min(max(suggestionsHeight, 1), 168))
        .onPreferenceChange(SuggestionsHeightKey.self) { suggestionsHeight = $0 }
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    /// One tappable suggestion row — shared by the #297 Recent block and the full catalogue list.
    private func suggestionRow(_ name: String, isDistance: Bool) -> some View {
        Button {
            sport = name
            sportFocused = false
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if isDistance {
                    Text("· GPS")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pick \(name)")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // A small Effort-world glyph so the sheet reads as part of the workouts (amber) world.
            Image(systemName: "figure.run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 30, height: 30)
                .background(StrandPalette.effortColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Add Workout" : "Edit Workout")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(editing == nil
                     ? "Log a session you tracked elsewhere."
                     : "Adjust this session's details.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton("Cancel", kind: .tertiary) { dismiss() }
            Spacer()
            NoopButton(editing == nil ? "Add" : "Save", systemImage: "checkmark", kind: .primary) {
                save()
            }
            .disabled(builtRow == nil)
            .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                // Numeric entry → decimal pad on iOS (digits + "."), not the QWERTY default; no-op on macOS.
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        // Fill the field column so the Avg HR / Calories boxes share an identical width — left to
        // their intrinsic size the two boxes rendered unequal (the "bpm"/"kcal" units differ in
        // length), so the side-by-side row read as lopsided (#234).
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var durationLabel: String {
        let h = durationMin / 60, m = durationMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Parsed avg-HR — nil for blank, an out-of-band sentinel handled by buildManualRow otherwise.
    private var avgHr: Int? { Int(avgHrText.trimmingCharacters(in: .whitespaces)) }
    private var kcal: Double? { Double(kcalText.trimmingCharacters(in: .whitespaces)) }

    /// Parsed distance in stored METRES — nil for blank (no distance), or when the typed value can't be a
    /// non-negative number. The user enters km/mi; convert to metres for the row. (#1195)
    private var distanceMeters: Double? {
        let t = distanceText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        let km = unitSystem == .imperial ? v / UnitFormatter.milesPerKilometer : v
        return km * 1000.0
    }

    /// The validated row, or nil when the inputs can't make an honest one (drives the disabled Save +
    /// the inline note). Built through the same WorkoutSource.buildManualRow the engine trusts.
    private var builtRow: WorkoutRow? {
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — guard before building.
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty && avgHr == nil { return nil }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty && kcal == nil { return nil }
        if !distanceText.trimmingCharacters(in: .whitespaces).isEmpty && distanceMeters == nil { return nil }
        guard let base = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                      sport: sport, avgHr: avgHr, energyKcal: kcal,
                                                      distanceM: distanceMeters)
        else { return nil }
        // Carry over captured-but-unexposed fields when editing an existing strap session.
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    /// #18: true when this edit changes the Avg HR on a row that carries CAPTURED strain/zones from a
    /// recorded session. preservingCaptured keeps the old strain/zonesJSON verbatim, so a typed Avg HR is
    /// saved while the HR graph, zones and Effort stay from the recording. That mismatch is silent, so we
    /// surface a one-line note. We do NOT re-score from a single number (that would fabricate a strain),
    /// this is purely an honest disclosure. nil for a fresh add, or when nothing captured would go stale.
    private var avgHrEditedNote: Bool {
        guard let editing, let built = builtRow else { return false }
        let captured = editing.strain != nil || editing.zonesJSON != nil
        return captured && built.avgHr != editing.avgHr
    }

    private var validationNote: String? {
        guard builtRow == nil else { return nil }
        if sport.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a sport.") }
        if start > Date() { return String(localized: "Start can't be in the future.") }
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty, avgHr == nil || !(25...250).contains(avgHr ?? -1) {
            return String(localized: "Average HR must be 25-250 bpm.")
        }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return String(localized: "Calories must be 0-20,000.")
        }
        if !distanceText.trimmingCharacters(in: .whitespaces).isEmpty,
           distanceMeters == nil || (distanceMeters ?? -1) < 0 || (distanceMeters ?? 0) > 1_000_000 {
            return String(localized: "Distance must be 0–1,000 km.")
        }
        return String(localized: "Check the values and try again.")
    }

    private func save() {
        guard let row = builtRow else { return }
        // #297: a confirmed save is a real selection — fold the (validated) sport into the recents.
        RecentSportsPrefs.recordSelection(row.sport)
        onSave(row, editing)
        dismiss()
    }
}

#if DEBUG
#Preview("Add") {
    ManualWorkoutSheet { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Edit") {
    ManualWorkoutSheet(editing: WorkoutRow(
        startTs: Int(Date().timeIntervalSince1970) - 3600, endTs: Int(Date().timeIntervalSince1970),
        sport: "Running", source: "manual", durationS: 3600, energyKcal: 540,
        avgHr: 148, maxHr: 172, strain: 12.4, distanceM: nil, zonesJSON: nil, notes: nil)) { _, _ in }
        .preferredColorScheme(.dark)
}
#endif
