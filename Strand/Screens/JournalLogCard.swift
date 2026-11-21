import SwiftUI
import StrandDesign

/// Native journal logging, yes/no chips and numeric fields for the merged behaviour catalog plus a
/// custom-question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// chip again clears the answer. Day attribution follows the importer's wake-day convention, answers
/// describe the night and day leading into the selected morning, so logged days line up with imported
/// history.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only (drives the chip state).
    let answers: [String: Bool]
    /// question → numeric value for the selected day, native rows only (drives the numeric fields).
    let numericAnswers: [String: Double]
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], dayOffset: Binding<Int>,
         onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self._dayOffset = dayOffset
        self.onChanged = onChanged
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    /// The resolved, grouped catalog for the current imported set. Hidden items included only while
    /// editing (so they can be restored in place).
    private var resolved: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: editing)
    }

    /// Items grouped by their group, each group ordered by sortIndex then display.
    private func items(in group: JournalGroup) -> [JournalCatalogItem] {
        resolved.filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .center) {
                SectionHeader("Journal", overline: "Log")
                Spacer()
                if editing {
                    pillButton("Done", selected: true) { editing = false }
                } else {
                    pillButton("Edit", selected: false) { editing = true }
                }
            }
            // Day picker (#656): a bounded, scrollable range — Tomorrow back through the last 7 days — so
            // any recent day can be backfilled (was Yesterday/Today/Tomorrow only). Chronological
            // left→right; snaps to the selected day, so a deep-link from the Today journal widget lands on
            // that day's pill. Only when not editing.
            if !editing {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.journalDayOffsets, id: \.self) { off in
                                dayPill(journalDayLabel(off), offset: off).id(off)
                            }
                        }
                        .padding(.horizontal, 1)   // don't clip the selected pill's ring
                    }
                    // Defer the initial scroll a tick: scrollTo in onAppear can no-op before the pills lay
                    // out, which would leave the picker on the oldest day instead of the selected one.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(dayOffset, anchor: .center) } }
                    // onChangeCompat, not onChange: the zero/two-arg onChange is macOS 14+, and this card
                    // is shared with the macOS 13 target.
                    .onChangeCompat(of: dayOffset) { _ in proxy.scrollTo(dayOffset, anchor: .center) }
                }
            }
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing
                         ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                         : dayOffset == -1
                         ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                         : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group)
                    }

                    Divider().overlay(StrandPalette.hairline)
                    addRow
                }
            }
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup) -> some View {
        let groupItems = items(in: group)
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            let collapsed = collapsedGroups.contains(group.rawValue)
            VStack(alignment: .leading, spacing: 8) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: 6) {
                        Text(group.title.uppercased())
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(groupItems.count)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed {
                    ForEach(groupItems) { item in itemRow(item) }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        HStack {
            Text(verbatim: item.display)   // display = rename ?? translated starter ?? canonical; already resolved
                .font(StrandFont.body)
                .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Spacer()
            if editing {
                editControls(item)
            } else if item.kind.isNumeric {
                numericField(item)
            } else {
                answerPill("Yes", q: item.canonical, value: true)
                answerPill("No", q: item.canonical, value: false)
            }
        }
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[item.canonical]
        return HStack(spacing: 6) {
            stepperButton("minus", q: item.canonical, current: current)
            NumericLogField(
                value: current,
                placeholder: "—",
                onCommit: { v in commitNumeric(item.canonical, value: v) })
            .frame(width: 64)
            if let unit = item.kind.unitLabel, !unit.isEmpty {
                Text(verbatim: unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            stepperButton("plus", q: item.canonical, current: current)
            if current != nil {
                Button {
                    Task { await repo.clearJournalAnswer(day: dayKey, question: item.canonical); onChanged() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(item.display)")
            }
        }
    }

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            let base = current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            commitNumeric(q, value: next)
        } label: {
            Image(systemName: "\(symbol).circle")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    private func commitNumeric(_ q: String, value: Double) {
        Task {
            await repo.saveJournalNumeric(day: dayKey, question: q, value: value)
            onChanged()
        }
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(item.display)")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { catalog.remove(item.canonical) } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(item.display)" : "Hide \(item.display)")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Rename item").font(StrandFont.headline)
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(NoopMetrics.space4)
        .frame(minWidth: 320)
    }

    // MARK: - Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a custom item…", text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                pillButton(customIsNumeric ? "Number" : "Yes/No", selected: customIsNumeric) {
                    customIsNumeric.toggle()
                }
                Button("Add") {
                    let t = customDraft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    catalog.addCustom(t,
                                      kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                      group: customGroup)
                    customDraft = ""
                }
                .buttonStyle(.bordered)
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Group", selection: $customGroup) {
                ForEach(JournalGroup.displayOrder, id: \.self) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("New item group")
        }
    }

    // MARK: - Controls

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        pillButton(label, selected: dayOffset == offset) {
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
    }

    /// The bounded day-picker range (#656): Tomorrow (-1) plus today and the 6 prior days, chronological
    /// oldest → newest left-to-right. Bounded on purpose — journal answers feed the correlation engine, so
    /// unbounded backfill of stale days would distort it (matches WHOOP's limited retroactive window).
    private static let journalDayOffsets: [Int] = Array((-1...6).reversed())

    /// Short pill label for a day-picker offset (daysBack; -1 = Tomorrow). "%lld days ago" is a String
    /// Catalog key, so 2–6 stay localized just like the twin "%lld nights ago" (#527/#656).
    private func journalDayLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case -1: return "Tomorrow"
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[q] == value
        return pillButton(label, selected: selected) {
            Task {
                // Tri-state: re-tapping the filled chip clears the answer (natural-key delete,
                // scoped to "noop-journal", imported rows can never be removed this way).
                if selected {
                    await repo.clearJournalAnswer(day: dayKey, question: q)
                } else {
                    await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.restColor : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.restColor : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the current value or a ghost placeholder, commits a Double on
/// return / focus-out. Kept small so the numeric row reads like the yes/no pills.
private struct NumericLogField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double) -> Void

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(StrandFont.number(15))
            .onAppear { text = value.map(Self.format) ?? "" }
            .onChangeCompat(of: value) { v in text = v.map(Self.format) ?? "" }
            .onSubmit { commit() }
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned) { onCommit(v) }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
