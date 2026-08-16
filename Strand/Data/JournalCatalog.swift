import Foundation

/// The user's custom journal questions plus the starter behaviour catalog. Question strings are
/// opaque exact-match labels to BehaviorInsights, so imported question strings (merged in at load
/// time, ahead of these) always take precedence, adopting the export's exact wording is what
/// joins a logged day and an imported day into one behaviour. UserDefaults-backed (single user).
///
/// v2 (#322 / task #53): a journal item can now be renamed (display-only, the stored key stays put
/// so imported WHOOP history still lines up), typed as numeric (a value + unit, not just yes/no),
/// grouped (Nutrition / Supplements / Lifestyle / Health / Behaviour / Other), and reordered. The
/// `canonical` string is the verbatim DB/engine key and is NEVER localised or rewritten; only
/// `displayName` changes on a rename. The legacy custom/hidden UserDefaults arrays are folded into
/// the v2 items once, then read-only.
/// The UserDefaults keys `JournalCatalogStore` persists under, exposed so the backup bridge
/// (`DataBackup`, which runs OFF the main actor) can read/write them directly without driving the
/// `@MainActor` store. Kept beside the store so the key strings can never drift (#1361). A restore
/// writes the restored custom names to `legacyCustom` and clears `items`; the store's init then
/// re-migrates them into v2 on the relaunch a restore forces.
enum JournalCatalogBackupKeys {
    static let items = "journal.catalog.v2"
    static let legacyCustom = "journal.customQuestions"
    static let legacyHidden = "journal.hiddenQuestions"
}

@MainActor
final class JournalCatalogStore: ObservableObject {

    /// Mirrors Android STARTER_JOURNAL_QUESTIONS value-for-value (JournalLog.kt). These are DATA,
    /// not UI literals, stored verbatim in the journal table and rendered verbatim, so they must
    /// never be localised (a translated key would start a new, disconnected behaviour).
    nonisolated static let starterQuestions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine late in the day?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    /// The default group for each starter question (canonical → group). Mirrors Android
    /// STARTER_JOURNAL_GROUPS value-for-value. Anything not listed falls to `.other`.
    nonisolated static let starterGroups: [String: JournalGroup] = [
        "Did you drink any alcohol?": .nutrition,
        "Did you have caffeine late in the day?": .nutrition,
        "Did you eat close to bedtime?": .nutrition,
        "Did you take magnesium?": .supplements,
        "Did you view a screen in bed?": .lifestyle,
        "Did you use a sauna?": .lifestyle,
        "Did you share your bed?": .lifestyle,
        "Did you read before bed?": .lifestyle,
        "Did you feel sick or ill?": .health,
        "Did you feel stressed?": .behaviour,
    ]

    /// The v2 catalog: one item per journal question the user has customised (renamed, retyped,
    /// regrouped, reordered, or hidden). Starter questions with default settings are NOT stored here:
    /// they are synthesised at merge time, so this only holds the user's deltas plus their customs.
    /// Persisted as a single JSON blob under `journal.catalog.v2`.
    @Published var items: [JournalCatalogItem] { didSet { persistItems() } }

    private let d = UserDefaults.standard
    private enum K {
        static let items = JournalCatalogBackupKeys.items
        // Legacy (v1) keys, read once for the one-time migration, never written again.
        static let custom = JournalCatalogBackupKeys.legacyCustom
        static let hidden = JournalCatalogBackupKeys.legacyHidden
    }

    init() {
        if let blob = d.data(forKey: K.items),
           let decoded = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            items = decoded
        } else {
            // One-time fold of the legacy two-array store into v2 items. Custom questions become
            // `.bool` items in `.other`; hidden ones keep their hidden flag. Idempotent: after this
            // runs it persists the v2 blob, and the legacy keys are never read again.
            items = Self.migrateLegacy(
                custom: d.stringArray(forKey: K.custom) ?? [],
                hidden: d.stringArray(forKey: K.hidden) ?? [])
            persistItems()
        }
    }

    private func persistItems() {
        if let blob = try? JSONEncoder().encode(items) { d.set(blob, forKey: K.items) }
    }

    /// Build the v2 item list from the legacy custom/hidden arrays. Custom questions → `.bool`
    /// items in `.other`, ordered as they were; hidden starter/imported ones → hidden marker items.
    nonisolated static func migrateLegacy(custom: [String], hidden: [String]) -> [JournalCatalogItem] {
        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var i = 0
        for q in custom {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty, seen.insert(key).inserted else { continue }
            out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                          group: .other, sortIndex: i, hidden: false, custom: true))
            i += 1
        }
        for q in hidden {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty else { continue }
            if let idx = out.firstIndex(where: { norm($0.canonical) == key }) {
                out[idx].hidden = true   // a hidden custom question
            } else if seen.insert(key).inserted {
                out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                              group: Self.starterGroups[t] ?? .other,
                                              sortIndex: i, hidden: true, custom: false))
                i += 1
            }
        }
        return out
    }

    // MARK: - Legacy-shape accessors (kept so existing call sites keep working)

    /// The user's custom question canonicals (v1 API shape). Derived from the v2 items.
    var customQuestions: [String] {
        get { items.filter { $0.custom }.sorted { $0.sortIndex < $1.sortIndex }.map(\.canonical) }
        set {
            // Append any new customs as `.bool`/`.other` items; drop customs no longer present.
            let keys = Set(newValue.map { Self.norm($0) })
            items.removeAll { $0.custom && !keys.contains(Self.norm($0.canonical)) }
            let existing = Set(items.map { Self.norm($0.canonical) })
            var next = nextSortIndex()
            for q in newValue {
                let key = Self.norm(q)
                let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !existing.contains(key) else { continue }
                items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                                group: .other, sortIndex: next,
                                                hidden: false, custom: true))
                next += 1
            }
        }
    }

    /// The user's hidden question canonicals (v1 API shape). Derived from the v2 items.
    var hiddenQuestions: [String] {
        items.filter { $0.hidden }.map(\.canonical)
    }

    private func nextSortIndex() -> Int { (items.map(\.sortIndex).max() ?? -1) + 1 }

    /// Dedup/identity key for a question. Normalises ALL whitespace, leading/trailing AND internal
    /// runs collapse to a single space (not just ASCII space/tab), then lowercases. A WHOOP export
    /// commonly leaves a trailing newline or non-breaking space on a journal cell, which a bare
    /// `.whitespaces` trim leaves in place: that's what let "Did you take magnesium?\n" (imported)
    /// sit beside the starter "Did you take magnesium?" as two rows (#224). Collapsing here folds
    /// them onto one key. The DISPLAYED string is still the original verbatim text, only the match
    /// key is normalised, so the stored behaviour key (which the effects engine joins on) is intact.
    /// Kept value-for-value in step with Android `normJournalKey` (JournalLog.kt).
    nonisolated static func norm(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// imported > starter > custom; case-insensitive dedupe, first casing wins, with `hidden`
    /// questions filtered out. Imported questions lead so the export's exact strings (which the
    /// effects engine keys on) survive verbatim and pull the matching starter/custom out of the list.
    nonisolated static func mergeCatalog(imported: [String], custom: [String],
                                         hidden: [String] = []) -> [String] {
        let hiddenSet = Set(hidden.map(norm))
        var seen = Set<String>()
        var out: [String] = []
        for q in imported + starterQuestions + custom {
            // Display text trims surrounding whitespace/newlines; the dedup key normalises ALL
            // whitespace (see `norm`) so an imported "…magnesium?\n" folds onto the starter (#224).
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            if !t.isEmpty, !hiddenSet.contains(key), seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    /// The merged catalog resolved into full v2 items, grouped and ordered for display. Imported +
    /// starter + custom questions are folded onto one canonical key (norm dedupe, #224); each carries
    /// the user's saved displayName / kind / group / sortIndex (a starter with no saved item gets its
    /// default group and `.bool`). Hidden items are dropped unless `includeHidden`. The `custom` flag
    /// is preserved so the edit UI can offer "Delete" vs "Hide".
    ///
    /// This is the display-side twin of `mergeCatalog(imported:custom:hidden:)`: same fold + dedupe,
    /// but returning the typed items instead of bare strings. `canonical` is always the verbatim key
    /// the engine joins on; `displayName ?? canonical` is what the UI renders (rename is display-only).
    func resolvedItems(imported: [String], includeHidden: Bool = false) -> [JournalCatalogItem] {
        var byKey: [String: JournalCatalogItem] = [:]
        for it in items { byKey[Self.norm(it.canonical)] = it }

        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var fallbackIndex = (items.map(\.sortIndex).max() ?? -1) + 1
        for q in imported + Self.starterQuestions {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.norm(q)
            guard !t.isEmpty, seen.insert(key).inserted else { continue }
            if let saved = byKey[key] {
                out.append(saved)
            } else {
                out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                              group: Self.starterGroups[t] ?? .other,
                                              sortIndex: fallbackIndex, hidden: false, custom: false))
                fallbackIndex += 1
            }
        }
        // Custom items (present only in `items`, never in imported/starter) come after the merge.
        for it in items where it.custom && !seen.contains(Self.norm(it.canonical)) {
            seen.insert(Self.norm(it.canonical))
            out.append(it)
        }
        if !includeHidden { out.removeAll { $0.hidden } }
        return out
    }

    // MARK: - Item lookup / edits (v2)

    /// The saved item for a canonical key, if the user has customised it.
    func item(for canonical: String) -> JournalCatalogItem? {
        let key = Self.norm(canonical)
        return items.first { Self.norm($0.canonical) == key }
    }

    /// Upsert the saved item for `canonical`, applying `mutate` to a fresh-or-existing item. Used by
    /// rename / retype / regroup / reorder so a starter question the user touches gets materialised
    /// into `items` with its defaults, then edited. NEVER changes `canonical`.
    private func edit(_ canonical: String, mutate: (inout JournalCatalogItem) -> Void) {
        let key = Self.norm(canonical)
        if let idx = items.firstIndex(where: { Self.norm($0.canonical) == key }) {
            mutate(&items[idx])
        } else {
            let t = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            var fresh = JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                           group: Self.starterGroups[t] ?? .other,
                                           sortIndex: nextSortIndex(), hidden: false, custom: false)
            mutate(&fresh)
            items.append(fresh)
        }
    }

    /// Rename an item: sets a display-only label. The stored `canonical` (the DB/engine key) is
    /// untouched, so all history, logged AND imported, stays joined under the original question.
    /// A blank / whitespace-only name clears the rename (falls back to the canonical).
    func rename(_ canonical: String, to displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(canonical) { $0.displayName = trimmed.isEmpty ? nil : trimmed }
    }

    /// Move an item to a different group (display + organisation only, no scoring change).
    func setGroup(_ canonical: String, to group: JournalGroup) {
        edit(canonical) { $0.group = group }
    }

    /// Change an item's type. `.numeric` carries an optional unit label (e.g. "mg", "units").
    func setKind(_ canonical: String, to kind: JournalKind) {
        edit(canonical) { $0.kind = kind }
    }

    /// Set an item's sort index within its group (drag-reorder).
    func setSortIndex(_ canonical: String, to sortIndex: Int) {
        edit(canonical) { $0.sortIndex = sortIndex }
    }

    // MARK: - Custom add / remove / restore (v1 API preserved)

    /// The display label for a canonical key: the user's rename, or the verbatim canonical.
    func displayName(for canonical: String) -> String {
        item(for: canonical)?.displayName ?? canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `q` is a user-added custom question (not a starter/imported one).
    func isCustom(_ q: String) -> Bool {
        let key = Self.norm(q)
        return items.contains { Self.norm($0.canonical) == key && $0.custom }
    }

    /// Add a custom question of the given type and group (defaults: yes/no, Other).
    func addCustom(_ q: String, kind: JournalKind = .bool, group: JournalGroup = .other) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = Self.norm(t)
        guard !items.contains(where: { Self.norm($0.canonical) == key }) else { return }
        items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: kind,
                                        group: group, sortIndex: nextSortIndex(),
                                        hidden: false, custom: true))
    }

    /// Remove `q` from the journal: a custom question is deleted outright; a starter/imported one is
    /// hidden (restorable). Either way it leaves the merged catalog.
    func remove(_ q: String) {
        let key = Self.norm(q)
        if isCustom(q) {
            items.removeAll { Self.norm($0.canonical) == key }
        } else {
            edit(q) { $0.hidden = true }
        }
    }

    /// Un-hide a previously hidden starter/imported question.
    func restore(_ q: String) {
        let key = Self.norm(q)
        if let idx = items.firstIndex(where: { Self.norm($0.canonical) == key }) {
            items[idx].hidden = false
        }
    }
}

/// A journal item's type: a plain yes/no toggle, or a numeric value with an optional unit label.
enum JournalKind: Equatable, Codable {
    case bool
    case numeric(unitLabel: String?)

    var isNumeric: Bool { if case .numeric = self { return true } else { return false } }
    var unitLabel: String? { if case let .numeric(u) = self { return u } else { return nil } }
}

/// A user-visible grouping for related journal items (display + organisation only, never a scoring
/// change). Mirrors Android `JournalGroup` value-for-value. `rawValue` is the stable persisted key;
/// `title` is the localised display label.
enum JournalGroup: String, CaseIterable, Codable {
    case supplements
    case nutrition
    case lifestyle
    case health
    case behaviour
    case other

    /// Fixed display order (matches Android). Groups render in this order; empty ones hide outside edit.
    static let displayOrder: [JournalGroup] = [.nutrition, .supplements, .lifestyle, .health, .behaviour, .other]

    var title: String {
        switch self {
        case .supplements: return String(localized: "Supplements")
        case .nutrition:   return String(localized: "Nutrition")
        case .lifestyle:   return String(localized: "Lifestyle")
        case .health:      return String(localized: "Health")
        case .behaviour:   return String(localized: "Behaviour")
        case .other:       return String(localized: "Other")
        }
    }
}

/// One journal catalog item. `canonical` is the verbatim DB/engine key (the exact question string
/// the effects engine and the `journal` table join on), it is NEVER localised or rewritten, so a
/// rename or a re-import always folds onto one behaviour. `displayName` (a rename) and `kind` /
/// `group` / `sortIndex` are display + organisation only. Mirrors Android `JournalCatalogItem`.
struct JournalCatalogItem: Equatable, Codable, Identifiable {
    /// The stable key. Rename NEVER touches this, so history (logged + imported) is preserved.
    var canonical: String
    /// The renamed display label, or nil to render the canonical verbatim.
    var displayName: String?
    var kind: JournalKind
    var group: JournalGroup
    var sortIndex: Int
    var hidden: Bool
    /// True for a user-added question (deletable); false for a starter/imported one (hideable only).
    var custom: Bool

    var id: String { canonical }

    /// What the UI renders: the rename if present, else the verbatim canonical.
    var display: String {
        displayName ?? canonical
    }

    init(canonical: String, displayName: String?, kind: JournalKind, group: JournalGroup,
         sortIndex: Int, hidden: Bool, custom: Bool) {
        self.canonical = canonical
        self.displayName = displayName
        self.kind = kind
        self.group = group
        self.sortIndex = sortIndex
        self.hidden = hidden
        self.custom = custom
    }
}
