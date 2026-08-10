import Foundation
import WhoopStore

// MARK: - Apple Watch as a first-class device
//
// Registers the Apple Watch in the same `DeviceRegistry` as every strap, feeding the existing
// `apple-health` source. There is no special-casing in the Devices screen: once this upserts the
// row, it renders through the normal `ForEach` over the registry like any other device.
//
// HONESTY is the whole point. The capability set is TRIMMED to the metrics that have actually
// arrived from HealthKit, not the full theoretical set. So a Series 6 (no wrist temp) reads without
// a "Skin temp" claim, and a newest US unit (SpO2 dropped) reads without "Blood oxygen". We never
// advertise a sensor the user's watch hasn't produced a single sample from.
//
// Apple-only by design (no Android twin). The file lives in shared `Strand/Data/` so the pure
// capability-derivation logic is testable on macOS too, but the live HealthKit read that decides
// `authorized` is supplied by the iOS bridge (`HealthKitBridge`), kept out of here so this stays
// platform-neutral and unit-testable without HealthKit.
enum AppleWatchDevice {

    /// The registry id + sample `deviceId` the watch feeds. Matches `Repository.appleHealthSource`
    /// so the engines and multi-source selection treat watch days exactly like the existing import.
    static let deviceId = Repository.appleHealthSource   // "apple-health"

    /// How far back we look for "recent" data before deciding the watch is genuinely in use. A user
    /// who imported a one-off export months ago shouldn't get a live "Apple Watch" device; a watch
    /// that's been feeding HealthKit this week should.
    static let recentWindowDays = 14

    /// The full set the adapter MAY claim, before trimming to what the data actually shows. The
    /// trimmed result is what lands on the card so an older watch reads honestly.
    static let candidateCapabilities: Set<Metric> = [.hr, .hrv, .sleep, .steps, .spo2, .skinTemp]

    // MARK: - Pure capability derivation (testable, no HealthKit, no store)

    /// Which metrics have ANY data across the supplied recent apple-health rows. This is the honest
    /// trim: a metric is only claimed when at least one row carries a value for it.
    ///
    /// Mapping from the stored shapes:
    ///  - `.hr`       any resting/avg HR (DailyMetric.restingHr or AppleDaily.avgHr/maxHr)
    ///  - `.hrv`      DailyMetric.avgHrv (the SDNN the watch reports)
    ///  - `.sleep`    DailyMetric.totalSleepMin (Apple's sleep stages summed)
    ///  - `.steps`    DailyMetric.steps or AppleDaily.steps
    ///  - `.spo2`     DailyMetric.spo2Pct (absent on the newest US units)
    ///  - `.skinTemp` DailyMetric.skinTempDevC (wrist temp, Series 8+ only)
    static func capabilities(daily: [DailyMetric], apple: [AppleDaily]) -> Set<Metric> {
        var caps: Set<Metric> = []
        if daily.contains(where: { $0.restingHr != nil })
            || apple.contains(where: { $0.avgHr != nil || $0.maxHr != nil }) { caps.insert(.hr) }
        if daily.contains(where: { $0.avgHrv != nil }) { caps.insert(.hrv) }
        if daily.contains(where: { ($0.totalSleepMin ?? 0) > 0 }) { caps.insert(.sleep) }
        if daily.contains(where: { ($0.steps ?? 0) > 0 })
            || apple.contains(where: { ($0.steps ?? 0) > 0 }) { caps.insert(.steps) }
        if daily.contains(where: { $0.spo2Pct != nil }) { caps.insert(.spo2) }
        if daily.contains(where: { $0.skinTempDevC != nil }) { caps.insert(.skinTemp) }
        // Never claim something outside the candidate set, even if a future row carries an extra field.
        return caps.intersection(candidateCapabilities)
    }

    /// Build the Apple Watch `PairedDevice` from recent rows, or nil when it shouldn't appear yet.
    ///
    /// Returns nil when HealthKit isn't authorized, or when no recent apple-health row carries a
    /// single usable metric (a fresh / unused watch). The capability set is the honest trim above.
    /// `now` and `addedAt` are injectable so the logic is deterministic in tests.
    static func device(daily: [DailyMetric], apple: [AppleDaily], authorized: Bool,
                       existing: PairedDevice? = nil, now: Date = Date()) -> PairedDevice? {
        guard authorized else { return nil }
        let caps = capabilities(daily: daily, apple: apple)
        // No usable metric from the watch yet → don't register a device that captures nothing.
        guard !caps.isEmpty else { return nil }

        let ts = Int(now.timeIntervalSince1970)
        return PairedDevice(
            id: deviceId,
            brand: "Apple",
            model: "Apple Watch",
            // Preserve a user-set nickname + an existing pairing date across refreshes; only the
            // capability set, status and last-seen move with the freshest data.
            nickname: existing?.nickname,
            peripheralId: nil,                 // HealthKit source, not a BLE peripheral
            sourceKind: .liveAppleWatch,
            capabilities: caps,
            // Refreshing capabilities must not deactivate a source the user already had active.
            status: existing?.status ?? .paired,
            addedAt: existing?.addedAt ?? ts,
            lastSeenAt: ts)
    }

    /// Apple Health starts feeding Today only when the active source is the seeded WHOOP row
    /// from the migration and that row represents no strap and holds no recent data. So an
    /// explicit Health authorization fixes a strap-less install, but never displaces a
    /// real strap, an Oura, or any other source the user has chosen.
    static func shouldAutoActivate(current: PairedDevice?, currentHasRecentData: Bool) -> Bool {
        guard let current else { return true }
        return current.id == Repository.whoopSource
            && current.status == .active
            && current.sourceKind == .liveBLE
            && current.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            && current.model.caseInsensitiveCompare("WHOOP") == .orderedSame
            && current.peripheralId == nil
            && !currentHasRecentData
    }

    /// Shared calendar window used by the registry and the active-source recency check.
    static func recentDayRange(now: Date = Date()) -> (from: String, to: String) {
        let fromDate = Calendar.current.date(byAdding: .day, value: -recentWindowDays, to: now) ?? now
        return (dayString(fromDate), dayString(now))
    }

    // MARK: - Registration (live; iOS supplies `authorized` from HealthKitBridge)

    /// Upsert the Apple Watch into the registry when HealthKit is authorized and recent apple-health
    /// data exists. Reads the trailing `recentWindowDays` of apple-health daily + apple rows from the
    /// store, derives the honest capability set, and registers (or refreshes) the device. A no-op
    /// when the watch has produced nothing usable yet, so the row never appears empty-handed.
    ///
    /// `authorized` comes from the iOS `HealthKitBridge` (`auth == .authorized`); macOS has no
    /// HealthKit, so callers there simply never pass `true`.
    @MainActor
    static func registerIfAuthorized(registry: DeviceRegistry, store: WhoopStore,
                                     authorized: Bool, now: Date = Date()) async {
        guard authorized else { return }
        let range = recentDayRange(now: now)

        let daily = (try? await store.dailyMetrics(deviceId: deviceId, from: range.from, to: range.to)) ?? []
        let apple = (try? await store.appleDaily(deviceId: deviceId, from: range.from, to: range.to)) ?? []

        let existing = registry.devices.first(where: { $0.id == deviceId })
        guard let device = device(daily: daily, apple: apple, authorized: authorized,
                                  existing: existing, now: now) else { return }
        registry.add(device)
    }

    // MARK: - Day helpers

    /// LOCAL civil day, matching `HealthKitBridge.dayString` / `Repository.dayFormatter` so the
    /// from/to window lines up with the keys the apple-health rows are stored under.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
