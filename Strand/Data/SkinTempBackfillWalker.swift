import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// #1853: the Apple walker that backfills `skinTempC` for nights the 21-night `analyzeRecent` rescore
/// window never reaches. The pure half (session attribution, the plan, rule 3) lives in
/// `StrandAnalytics/SkinTempBackfill.swift`; this file is the I/O layer that reads from / writes to
/// `WhoopStore`.
///
/// The walker mirrors the scoring pass's per-night reads (same window, same stream limits, same
/// device-family / anchor / tolerance resolution) and calls the SAME `skinTempFunnel` the engine
/// uses, so a backfilled absolute is byte-identical to what the scoring pass would have stored.
///
/// Trigger: ON-DEMAND from the Test Centre (the issue's "diagnostic first" + safest trigger). Doing
/// it automatically on upgrade risks a long first launch on a deep history. The caller decides how
/// many pages to run; one page is 50 nights by default.
///
/// Non-negotiable: a fill-only write (`WhoopStore.fillSkinTempC`) that can only fill a NULL, never an
/// upsert of a rebuilt row. `skinTempDevC` and every other scored field are untouched.
@MainActor
final class SkinTempBackfillWalker {

    /// One night that filled — the day and the re-derived absolute.
    struct FilledNight: Sendable {
        let day: String
        let skinTempC: Double
    }

    /// One night that declined — the day and the reason, for the diagnostic report.
    struct DeclinedNight: Sendable {
        let day: String
        let reason: String
    }

    /// The result of one backfill pass (one or more pages).
    struct PassResult: Sendable {
        /// Nights that filled (day → absolute °C).
        let filled: [FilledNight]
        /// Nights that declined (day → reason), for the diagnostic report.
        let declined: [DeclinedNight]
        /// Nights skipped because no raw `skinTempSample` rows exist for the window (the data is gone,
        /// not the backfill's fault — see the issue's "Diagnostic first" note).
        let noRawData: [String]
        /// Whether another page might yield more fills (false when the last page was empty).
        let moreRemaining: Bool

        var totalAttempted: Int { filled.count + declined.count + noRawData.count }
    }

    private let store: WhoopStore
    private let computedId: String

    init(store: WhoopStore) {
        self.store = store
        self.computedId = Repository.whoopSource + "-noop"
    }

    /// Run one page of the backfill. The caller calls this repeatedly with increasing `page` until
    /// `moreRemaining` is false or a budget is reached.
    ///
    /// - Parameters:
    ///   - page: 0-based page index (rule 2: page the candidates so the sweep doesn't latch on the
    ///     oldest N).
    ///   - pageSize: nights per page (default 50).
    ///   - windowAnchorRaw: the per-device WHOOP 4.0 anchor learned from the CURRENT scoring window
    ///     (rule 3). The caller obtains this from the same window-wide scan the scoring pass uses.
    ///     nil for a 5/MG or when the current window couldn't learn one.
    ///   - tzOffsetSeconds: seconds east of UTC, for local-day → unix-seconds conversion.
    func runPage(page: Int, pageSize: Int = 50,
                 windowAnchorRaw: Double?,
                 tzOffsetSeconds: Int) async -> PassResult {
        // 1. Find candidate nights: computed rows with a deviation but no absolute.
        let candidates = await candidateNights()
        let pageCandidates = SkinTempBackfill.page(candidates, page: page, pageSize: pageSize)
        if pageCandidates.isEmpty {
            return PassResult(filled: [], declined: [], noRawData: [], moreRemaining: false)
        }

        // 2. Resolve the device family + worn tolerance for the owner (single-owner install: the
        //    canonical "my-whoop"). The registry is read once, mirroring the scoring pass.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let regDevices = (try? registry.all()) ?? []
        let activeId = (try? registry.activeDeviceId()) ?? Repository.whoopSource

        var filled: [FilledNight] = []
        var declined: [DeclinedNight] = []
        var noRawData: [String] = []

        for candidate in pageCandidates {
            // Resolve the day owner for this night (same resolver the scoring pass uses).
            let owner = await IntelligenceEngine.resolveDayOwner(
                day: candidate.day, from: candidate.from, to: candidate.to,
                store: store, devices: regDevices, activeId: activeId,
                registry: registry, fallbackDeviceId: Repository.whoopSource)

            let family = IntelligenceEngine.skinTempFamily(forOwner: owner, devices: regDevices)
            let tolerance = IntelligenceEngine.skinTempWornToleranceSec(forOwner: owner, devices: regDevices)

            // Read the raw streams for this night's window — same limits the scoring pass uses.
            let skin = (try? await store.skinTempSamples(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: StreamReadCap.skin)) ?? []
            if skin.isEmpty {
                noRawData.append(candidate.day)
                continue
            }
            let hr = (try? await store.hrSamples(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: StreamReadCap.hr)) ?? []
            // Read stored sleep sessions for the window (the backfill takes the night's stored sleep
            // window, no re-detection — the issue's "take the night's stored sleep window from
            // sleepSession").
            let persisted = (try? await store.sleepSessions(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: 4000)) ?? []
            let sessions = persisted.compactMap { AnalyticsEngine.sleepSession(fromProvided: $0) }

            // Compute the local-midnight unix seconds for this day (the day key is local, so the
            // midnight is the UTC midnight of (dayStart + tzOffset)). The scoring pass uses the same
            // shift: `dayString(ts, offsetSec:) == day` ⇔ `(ts + offsetSec) ∈ [dayStart, +86400)`.
            let dayStart = Self.localMidnightUnix(forDay: candidate.day, tzOffsetSeconds: tzOffsetSeconds)

            let result = SkinTempBackfill.computeNight(
                candidate: candidate,
                sessions: sessions,
                hr: hr,
                skinTemp: skin,
                family: family,
                windowAnchorRaw: windowAnchorRaw,
                dayStart: dayStart,
                wornToleranceSec: tolerance)

            if let abs = result.skinTempC {
                // Fill-only write: can only fill a NULL, never overwrite a measured value.
                _ = try? await store.fillSkinTempC(deviceId: computedId, day: candidate.day, skinTempC: abs)
                filled.append(FilledNight(day: candidate.day, skinTempC: abs))
            } else {
                declined.append(DeclinedNight(day: candidate.day, reason: result.declineReason ?? "unknown"))
            }
        }

        let moreRemaining = pageCandidates.count == pageSize
        return PassResult(filled: filled, declined: declined, noRawData: noRawData,
                          moreRemaining: moreRemaining)
    }

    /// Find computed `DailyMetric` rows that have a `skinTempDevC` but no `skinTempC` — the nights
    /// the backfill can fill. Oldest-first (the issue pages oldest→newest so the sweep reaches the
    /// newer nights that can fill).
    private func candidateNights() async -> [SkinTempBackfill.NightCandidate] {
        // Read all computed rows (the backfill window is unbounded — the issue's "how far back" is
        // every night with samples). A wide day range covers the full local-history span.
        let rows = (try? await store.dailyMetrics(
            deviceId: computedId, from: "0000-01-01", to: "9999-12-31")) ?? []
        let tzOffset = TimeZone.current.secondsFromGMT()
        let now = Int(Date().timeIntervalSince1970)
        // Candidate: has a deviation (the night was scored) but no absolute (the column was null).
        // Build the night's read window the same way the scoring pass does.
        return rows
            .filter { $0.skinTempDevC != nil && $0.skinTempC == nil }
            .sorted { $0.day < $1.day }
            .map { row in
                let dayStart = Self.localMidnightUnix(forDay: row.day, tzOffsetSeconds: tzOffset)
                let from = dayStart - StreamReadCap.lookbackSeconds
                let to = min(dayStart + 86_400, now)  // don't read past now for today's partial night
                return SkinTempBackfill.NightCandidate(day: row.day, from: from, to: to,
                                                        owner: Repository.whoopSource)
            }
    }

    /// Local-midnight unix seconds for a yyyy-MM-dd day key. The day key is LOCAL, so midnight is the
    /// UTC midnight of `(dayStart + tzOffset)`: `dayString(ts, offsetSec:) == day` ⇔
    /// `(ts + offsetSec) ∈ [dayStart, +86400)`, so `dayStart = utcMidnight(day) - tzOffset`.
    static func localMidnightUnix(forDay day: String, tzOffsetSeconds: Int) -> Int {
        // Parse the yyyy-MM-dd key to a UTC midnight, then shift by the tz offset to get local midnight.
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return 0 }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let utcMidnight = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
        return Int(utcMidnight.timeIntervalSince1970) - tzOffsetSeconds
    }
}
