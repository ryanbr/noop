import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Hydration tracker (MVP) — opt-in, local-only water logging
//
// The user logs water with three quick taps (Sip 30 ml / Cup 237 ml / Bottle 500 ml). The day TOTAL is
// banked in the generic metric-series tall table under a dedicated source/key — the SAME `metricSeries`
// table + `upsertMetricSeries` path every other generic daily series uses (no schema change). Because the
// table holds one row per (deviceId, day, key), a tap reads the day's running total and re-upserts
// total + amount, so the stored value IS "the sum of today's hydration logged for this local day".
//
// This is the BYTE-PARITY twin of the Android `com.noop.analytics.HydrationStore`: identical source id
// ("hydration"), identical key ("hydration"), identical additive-accumulation logic, identical 7-day
// history projection (one row per local calendar day, 0 for empty days, oldest first). Per-tap timestamps
// are intentionally NOT persisted on either platform — the day total is the source of truth and the MVP
// detail shows the honest day figure. Everything stays on-device; nothing is synced.

enum HydrationStore {
    /// Source/device id the hydration total is written under — its own local-only source so it is never
    /// confused with strap-imported or computed metrics. MUST match the Android `SOURCE_ID`.
    static let sourceId = "hydration"

    /// metricSeries key for the daily total (ml). MUST match the Android `KEY`.
    static let key = "hydration"

    /// Settings opt-in key (default OFF). The dashboard card + detail are hidden while this is false.
    /// MUST match the Android `NoopPrefs.KEY_HYDRATION_TRACKING` so the toggle reads the same on both.
    static let enabledKey = "noop.hydrationTracking"

    /// UserDefaults prefix for the per-day entry list (#798). One JSON array per local day, keyed
    /// `noop.hydrationEntries.<yyyy-MM-dd>`. Local-only, on-device, never synced - the same privacy posture
    /// as the day total. The day total in `metricSeries` stays the canonical figure the rest of the app
    /// reads (Today card, ring, 7-day history); the entry list is the editable detail behind it, kept in
    /// sync so deleting/editing an entry re-derives and re-banks the total.
    static let entriesKeyPrefix = "noop.hydrationEntries."

    /// AppStorage key for the user's custom container size (ml) (#798). Default `cupML` until set.
    static let customSizeKey = "noop.hydrationCustomSizeML"

    /// metricSeries key for water IMPORTED from the platform health store — Apple Health on iOS,
    /// Health Connect on Android (#949). MUST match the Android `KEY_IMPORTED`.
    ///
    /// Kept in its own row rather than folded into `key` so the two can never be confused, because they
    /// behave differently on write: `key` ACCUMULATES (each tap adds), while this one is REPLACED with
    /// the platform's recomputed day sum on every sync. That replacement is what makes re-importing
    /// idempotent without tracking a single sample id — HealthKit's `HKStatisticsCollectionQuery` and
    /// Health Connect's day bucket both hand back the whole day's total, so writing it wholesale means a
    /// second sync of the same day stores the same number, and a drink deleted in the source app makes
    /// the figure go DOWN on the next sync instead of being stranded forever.
    ///
    /// The user's own taps are never touched by a sync, and imported water is never editable here — it
    /// is owned by the app that logged it.
    static let importedKey = "hydrationImported"

    static func entriesKey(forDay dayKey: String) -> String { entriesKeyPrefix + dayKey }
}

// MARK: - Per-entry model (#798) - individual logged drinks for edit/delete

/// One logged drink: a stable id, the amount (ml) and the wall-clock time it was logged. Local-only;
/// persisted as a JSON array per local day. `Codable`/`Equatable` so the list round-trips through
/// UserDefaults and is unit-testable.
struct HydrationEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var amountMl: Int
    var loggedAt: Date

    init(id: UUID = UUID(), amountMl: Int, loggedAt: Date = Date()) {
        self.id = id
        self.amountMl = amountMl
        self.loggedAt = loggedAt
    }
}

/// Pure list operations over the per-day entries (#798). Kept free of persistence/UI so the add / delete /
/// edit / total math is unit-testable in isolation. The day total is ALWAYS the sum of the (clamped to ≥ 0)
/// entry amounts, so deleting or editing an entry can only ever produce a non-negative, self-consistent total.
enum HydrationEntries {
    /// Append a new entry. A non-positive amount is rejected (returns the list unchanged) so a stray 0/negative
    /// can never enter the list, matching `logHydration`'s no-op-on-non-positive contract.
    static func adding(_ entries: [HydrationEntry], amountMl: Int, at date: Date = Date()) -> [HydrationEntry] {
        guard amountMl > 0 else { return entries }
        return entries + [HydrationEntry(amountMl: amountMl, loggedAt: date)]
    }

    /// Remove the entry with `id` (a no-op if absent).
    static func removing(_ entries: [HydrationEntry], id: UUID) -> [HydrationEntry] {
        entries.filter { $0.id != id }
    }

    /// Set an existing entry's amount. A non-positive amount removes the entry (an edit to 0 is a delete),
    /// keeping the list free of zero rows. Unknown ids are ignored.
    static func updating(_ entries: [HydrationEntry], id: UUID, amountMl: Int) -> [HydrationEntry] {
        guard amountMl > 0 else { return removing(entries, id: id) }
        return entries.map { $0.id == id ? HydrationEntry(id: $0.id, amountMl: amountMl, loggedAt: $0.loggedAt) : $0 }
    }

    /// The day total (ml) = sum of the entry amounts, each clamped ≥ 0. Always non-negative.
    static func total(_ entries: [HydrationEntry]) -> Double {
        entries.reduce(0) { $0 + Double(max(0, $1.amountMl)) }
    }
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    /// The total fluid (ml) for a local day (yyyy-MM-dd) as the user should SEE it: what they logged by
    /// hand plus whatever was imported from Apple Health / Health Connect (#949). 0 when neither exists.
    /// Mirrors Android `HydrationStore.total`.
    ///
    /// Everything that DISPLAYS a day figure (Today card, ring, detail) wants this. Everything that
    /// WRITES a hand-logged drink must use `hydrationManualTotal` instead — see there.
    func hydrationTotal(day: String) async -> Double {
        await hydrationManualTotal(day: day) + hydrationImportedTotal(day: day)
    }

    /// Only what the user logged by hand — the row `logHydration` accumulates into.
    ///
    /// The write path MUST read this and not `hydrationTotal`: a quick-add stores `current + amount`, so
    /// reading the combined figure would fold every imported millilitre into the manual row, and the next
    /// sync would then add the imported water on top of the copy it had just made. One tap after an
    /// import would silently double the day, and it would compound on every tap after that.
    func hydrationManualTotal(day: String) async -> Double {
        await metricSeriesValue(key: HydrationStore.key, day: day)
    }

    /// Only what came from the platform health store (#949). Replaced wholesale by each sync.
    func hydrationImportedTotal(day: String) async -> Double {
        await metricSeriesValue(key: HydrationStore.importedKey, day: day)
    }

    /// One day's value for a hydration-source series, or 0 when the row is absent.
    private func metricSeriesValue(key: String, day: String) async -> Double {
        guard let store = await storeHandle() else { return 0 }
        let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                 key: key, from: day, to: day)) ?? []
        return pts.first?.value ?? 0
    }

    /// Replace the imported-water total for each given local day with the platform's recomputed day sum
    /// (#949). Called by the Apple Health sync; the Android twin is `HydrationStore.setImported`.
    ///
    /// REPLACES rather than adds, which is the whole reason this is idempotent — see `importedKey`. Days
    /// the health store has no water for resolve to 0, so water deleted in the source app disappears here
    /// too instead of lingering as a stale row.
    ///
    /// Only days whose value actually MOVED are written. The caller hands over its whole window (31 days
    /// on iOS) on every sync, and `sync` is driven by six hourly `HKObserverQuery` wakes — so writing it
    /// wholesale meant ~31 upserts plus a `hydrationSeq` bump, repeatedly through the day, to store
    /// numbers that were already there. Thirty of those days are historical and immutable; the usual
    /// honest answer is "nothing changed". One ranged read replaces the write burst.
    ///
    /// A day with NO row and a value of 0 is skipped rather than written, because an absent row already
    /// reads as 0 (`hydrationImportedTotal`). That is what keeps a user with no water in Health from
    /// accumulating a wall of zero rows. A day that HAS a row and is now 0 is still written — that is the
    /// deletion propagating, and it must not be mistaken for the no-op case.
    func setImportedHydration(_ mlByDay: [String: Double]) async {
        guard !mlByDay.isEmpty, let store = await storeHandle() else { return }
        let days = mlByDay.keys.sorted()
        guard let from = days.first, let to = days.last else { return }

        // No `?? []` here: a FAILED read must not look like "there are no rows". If it did, a day whose
        // water was just deleted would resolve to the skip-a-zero case below and its stale non-zero row
        // would survive. Bail instead and let the next sync do it properly — the health store is the
        // source of truth, so nothing is lost by waiting.
        guard let existing = try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                           key: HydrationStore.importedKey,
                                                           from: from, to: to) else { return }
        var stored: [String: Double] = [:]
        for p in existing { stored[p.day] = p.value }

        // Return type spelled out rather than inferred: this file is app-target Swift that no CI
        // compiles, so a multi-statement closure leaning on inference is a needless place to be wrong.
        let changed: [MetricPoint] = mlByDay.compactMap { (day, ml) -> MetricPoint? in
            let value = max(0, ml)
            guard let current = stored[day] else {
                // No row yet: only worth creating one if there is actually something to record.
                return value == 0 ? nil : MetricPoint(day: day, key: HydrationStore.importedKey, value: value)
            }
            // Epsilon rather than ==: the same samples re-summed give the same Double, but a value that
            // ever drifted by a float hair would otherwise re-write every sync forever and quietly undo
            // the point of this. Well below a millilitre, so no real change is swallowed.
            guard abs(current - value) > 1e-9 else { return nil }
            return MetricPoint(day: day, key: HydrationStore.importedKey, value: value)
        }
        guard !changed.isEmpty else { return }

        _ = try? await store.upsertMetricSeries(changed, deviceId: HydrationStore.sourceId)
        // Only on a real change — this bump re-reads the Today card, and firing it on every sync made the
        // card redo its hydration read for nothing. Same reason as logHydration: hydration writes never
        // bump refreshSeq, so the card has no other signal.
        noteHydrationChanged()
    }

    /// Log `amountMl` of fluid for `day` (defaults to today's local day). Reads the day's current total
    /// and upserts total + amount, so repeated taps accumulate. A non-positive amount is a no-op. Returns
    /// the new day total (ml). Additive by design — each tap is a quick-add, like the WHOOP buttons.
    /// Mirrors Android `HydrationStore.log`.
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0, let store = await storeHandle() else { return await hydrationTotal(day: dayKey) }
        // MANUAL total, never the combined one (#949) — see `hydrationManualTotal`.
        let current = await hydrationManualTotal(day: dayKey)
        let next = current + Double(amountMl)
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: dayKey, key: HydrationStore.key, value: next)],
            deviceId: HydrationStore.sourceId)
        // #798 - also record the per-entry row so the detail can show, edit and delete this exact drink.
        let entries = HydrationEntries.adding(Self.hydrationEntries(day: dayKey), amountMl: amountMl)
        Self.writeHydrationEntries(entries, day: dayKey)
        // #989: hydration writes never bump refreshSeq, so tell the Today card directly.
        noteHydrationChanged()
        // `next` is the manual row; callers of this return value display it, so hand back the combined
        // figure (#949). Every in-tree caller discards it and re-reads, but a caller that trusted it
        // would otherwise show a total that drops the imported water.
        return next + (await hydrationImportedTotal(day: dayKey))
    }

    // MARK: - Per-entry edit/delete (#798)

    /// Today (or `day`)'s individual logged drinks, oldest first, as persisted in UserDefaults. Empty when
    /// nothing has been logged that day. Local-only; never synced.
    func hydrationEntries(day: String? = nil) -> [HydrationEntry] {
        Self.hydrationEntries(day: day ?? Repository.localDayKey(Date()))
    }

    /// Delete one logged entry by id, then re-derive the day total from the surviving entries and re-bank it
    /// into `metricSeries` so the ring, Today card and 7-day history all reflect the deletion. Returns the
    /// new day total (ml).
    @discardableResult
    func deleteHydrationEntry(id: UUID, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.removing(Self.hydrationEntries(day: dayKey), id: id)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Set an existing entry's amount (a non-positive amount deletes it), then re-derive + re-bank the day
    /// total. Returns the new day total (ml). Backs the "edit a logged drink / set a custom size" flow.
    @discardableResult
    func updateHydrationEntry(id: UUID, amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.updating(Self.hydrationEntries(day: dayKey), id: id, amountMl: amountMl)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Re-derive the day total from `entries` and upsert it into `metricSeries` (the canonical total). The
    /// per-entry list is the source of truth for an edited/deleted day; this keeps the rest of the app in sync.
    @discardableResult
    private func rebankHydrationTotal(entries: [HydrationEntry], day dayKey: String) async -> Double {
        let total = HydrationEntries.total(entries)
        if let store = await storeHandle() {
            _ = try? await store.upsertMetricSeries(
                [MetricPoint(day: dayKey, key: HydrationStore.key, value: total)],
                deviceId: HydrationStore.sourceId)
        }
        // #989: edits/deletes funnel through here; tell the Today card directly (see logHydration).
        noteHydrationChanged()
        // The entry list only ever describes hand-logged drinks, so re-deriving from it must not be
        // allowed to erase the imported row — write the manual figure, return the combined one (#949).
        return total + (await hydrationImportedTotal(day: dayKey))
    }

    // MARK: - Entry persistence (UserDefaults JSON, one array per local day)

    fileprivate static func hydrationEntries(day dayKey: String) -> [HydrationEntry] {
        guard let data = UserDefaults.standard.data(forKey: HydrationStore.entriesKey(forDay: dayKey)),
              let decoded = try? JSONDecoder().decode([HydrationEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.loggedAt < $1.loggedAt }
    }

    fileprivate static func writeHydrationEntries(_ entries: [HydrationEntry], day dayKey: String) {
        let key = HydrationStore.entriesKey(forDay: dayKey)
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The last `days` local-day totals up to and including today, OLDEST first, as (day, ml) pairs — one
    /// entry per calendar day with 0 for days that have no log. Backs the 7-day mini bar history. `days`
    /// is clamped ≥ 1. Mirrors Android `HydrationStore.history` (a single ranged read projected onto the
    /// full day grid so empty days read as 0 rather than vanishing).
    func hydrationHistory(days: Int = 7, now: Date = Date()) async -> [(day: String, value: Double)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = Repository.localDayKey(from)
        let toKey = Repository.localDayKey(now)
        var byDay: [String: Double] = [:]
        if let store = await storeHandle() {
            // Both rows, summed per day (#949) — the bars have to agree with the Today card and the
            // ring, and those read the combined `hydrationTotal`. Reading only the manual key here is
            // what would make an imported day render short.
            for key in [HydrationStore.key, HydrationStore.importedKey] {
                let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                         key: key,
                                                         from: fromKey, to: toKey)) ?? []
                for p in pts { byDay[p.day, default: 0] += p.value }
            }
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key] ?? 0)
        }
    }

    /// Today's hydration goal (ml) from the profile sex + today's Effort score. Pure math in
    /// `HydrationGoal`; this just feeds it the live inputs (today's `strain` is NOOP's 0–100 Effort).
    func hydrationGoalML(profileSex: String) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex, effort: today?.strain)
    }
}
