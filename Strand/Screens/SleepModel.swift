import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Shared sleep model
//
// The value types and the pure derivation pipeline behind the Sleep tab. Extracted out of
// `SleepView` so the SAME model can be built by another host (e.g. the Today tab's hosted sleep
// card) without a `SleepView` instance. Nothing here reads view state: `SleepModel.build(_:)` is a
// pure function of its `SleepModelInputs`. The Sleep-tab renderers still live on `SleepView` and read
// the fields below; only the DATA-BUILDING moved here. Behaviour is byte-identical to the previous
// `SleepView.buildModel()` — see that call site's history for the per-line rationale.

struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil
    /// The actual stored block(s) this merged Night was built from. `session` above is a SYNTHETIC
    /// merge for display; an edit must target a real row, so it resolves it from here by identity
    /// rather than re-scanning by wake time. (#318)
    var sourceBlocks: [CachedSleepSession] = []

    /// Per-epoch MOTION for the MAIN-night GROUP, laid fragment-by-fragment in the SAME order `intervals`
    /// lays the group's stage timeline (#407). Empty when no group fragment has a persisted `motionJSON`
    /// (older rows) — the Sleep tab then shows an honest empty state instead of a fabricated zero trace.
    /// This is read off the already-resolved group, NOT a re-resolution of the night.
    var motionEpochs: [Double] = []

    /// The LEARNED habitual midsleep (local time-of-day seconds) the owning view loaded for the user — the
    /// SAME value the engine threaded into the daily total — so `editTarget` resolves the SAME main block
    /// the hero and the analytics rollup did, for a shift/late sleeper too. nil = cold-start band. (#547)
    var habitualMidsleepSec: Int? = nil

    /// The real stored block a sleep-time edit writes against — the day's MAIN block, resolved by the
    /// SAME shared selector (`SleepView.mainNightSession` → `SleepStageTotals.mainNightIndex`) the hero,
    /// the naps card, and `AnalyticsEngine.analyzeDay` use, so all of them and the edit affordance agree
    /// (no re-derived overnight gate). Passes the same learned habitual the hero used, so the edit target
    /// matches the hero block even for a shift/late sleeper. Its `startTs` is a genuine detected key, so
    /// `applySleepEdit` matches. nil when there's no underlying block (a synthetic stub) — the edit
    /// affordance is then hidden. (#318, #518, #547)
    var editTarget: CachedSleepSession? {
        SleepView.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The `startTs` of every block in the day's bridged MAIN-night GROUP (the winning block plus the
    /// fragments bridged into it, #561), so the naps card excludes ALL of them — only blocks OUTSIDE the
    /// group are naps. Without this the tab treated every block except the single winner as a nap and a
    /// biphasic night rendered as phantom naps. (#555)
    var mainGroupStarts: Set<Int> {
        Set(SleepView.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map { $0.startTs })
    }

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    /// A unix-second timestamp as a device-locale clock string ("11:42 PM" / "23:42"). Shared so the nap
    /// rows format their windows identically to the Asleep/Woke row. (#508)
    static func clockString(_ ts: Int) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // Clock for the Asleep/Woke row — the times people read at a glance. The "jmm" skeleton
    // follows the device's 12-/24-hour setting ("11:42 PM" or "23:42") instead of forcing one
    // on everyone, matching the HR-tooltip / workout times (#337).
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `SleepModel.build(_:)` and read by the subviews, so full passes over the day rows / sleep sessions
/// and the Night.intervals reconstruction no longer run on every render.
struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView's per-tile series.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool
    /// True when `night` is the stage-less STUB for a newest day that failed to merge (#940: e.g.
    /// an impossible hand-edit staged all-awake). The hero then renders the honest no-stage-data
    /// header for it, exactly as the navigated ◀/▶ stub path does, while the tiles / ledger /
    /// trends (all full-history) stay up. It must NEVER blank the whole tab: every older night is
    /// still in the DB and the edit/delete affordance must stay reachable to fix the bad night.
    let isStubNight: Bool

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

/// Explicit inputs for `SleepModel.build(_:)` — a snapshot of the repository state the builder reads.
/// The Sleep tab fills these from its `Repository` + loaded session/motion state; another host can
/// supply the same fields to get a byte-identical model.
struct SleepModelInputs {
    /// The cached per-day metric rows (`Repository.days`).
    let days: [DailyMetric]
    /// One-per-night sessions (`Repository.sleeps`) — the `navSessions` fallback and the
    /// consistency bedtime-spread series read this directly.
    let sleeps: [CachedSleepSession]
    /// Every un-deduplicated sleep block (`SleepView.allSessions`); empty until the fuller list loads,
    /// in which case the builder falls back to `sleeps` exactly as `navSessions` did.
    let allSessions: [CachedSleepSession]
    /// Per-day imported WHOOP figures (`Repository.importedSleep`) — export-verbatim tile values.
    let importedSleep: [String: ImportedSleepFigures]
    /// The learned habitual midsleep (local seconds) the engine threaded into the daily totals.
    let habitualMidsleepSec: Int?
    /// Per-epoch motion keyed by detected block start (`SleepView.motionByStart`).
    let motionByStart: [Int: [Double]]
}

// MARK: - Pure derivation pipeline
//
// Every static below is the pure form of a computed that previously lived on `SleepView` and read
// `self`/`repo`. They now take their inputs explicitly, so `build(_:)` and the Sleep-tab renderer/nav
// wrappers on `SleepView` share ONE source of truth for the math (no duplication). The stage-decode
// seams (`SleepView.decodeStages` / `decodeSegments` / `decodedAsleepMinutes`) and the shared
// main-night selectors (`SleepView.mainNightGroup`, `napSleepMinutes`, `stubDaySession`) stay on
// `SleepView` because they are reused by other screens/tests; these statics call them.
extension SleepModel {

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop. Mirrors the former `SleepView.navDays`. (#170)
    static func navDays(navSessions: [CachedSleepSession]) -> [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
    }

    /// The night's DISPLAYED onset (bedtime): the first fragment that is NOT a spurious leading
    /// pre-onset awake stub, falling back to the earliest onset when the whole group is stub-like.
    /// Mirrors the former `SleepView.nightOnsetTs`. (#736, #259)
    static func nightOnsetTs(_ group: [CachedSleepSession]) -> Int {
        guard let first = group.first else { return 0 }
        let refAsleepMin = group.map {
            SleepView.decodedAsleepMinutes($0.stagesJSON, effectiveStartTs: $0.effectiveStartTs)
        }.max() ?? 0
        for frag in group {
            if !isPreOnsetAwakeStub(frag, refAsleepMin: refAsleepMin) { return frag.effectiveStartTs }
        }
        return first.effectiveStartTs
    }

    /// Fragment-level spurious-stub test, decoding the fragment's span + asleep minutes and delegating
    /// to the shared pure rule on `SleepView`. Mirrors the former `SleepView.isPreOnsetAwakeStub(_:)`. (#736)
    static func isPreOnsetAwakeStub(_ frag: CachedSleepSession, refAsleepMin: Double = 0) -> Bool {
        let spanMin = Double(frag.endTs - frag.effectiveStartTs) / 60.0
        let asleepMin = SleepView.decodedAsleepMinutes(frag.stagesJSON,
                                                       effectiveStartTs: frag.effectiveStartTs)
        return SleepView.isPreOnsetAwakeStub(spanMin: spanMin, asleepMin: asleepMin, refAsleepMin: refAsleepMin)
    }

    /// Build the hero `Night` for a day around its MAIN-night GROUP, bridged the way
    /// `AnalyticsEngine.analyzeDay` bridges it. Mirrors the former `SleepView.mergeDay`. Returns nil
    /// if the group decodes to no usable stages. (#170, #318, #518, #555, #561, #736, #364, #407)
    static func mergeDay(_ sessions: [CachedSleepSession],
                         habitualMidsleepSec: Int?,
                         motionByStart: [Int: [Double]]) -> Night? {
        let fullGroup = SleepView.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let last = fullGroup.last else { return nil }
        let onset = nightOnsetTs(fullGroup), wake = last.endTs
        let group = fullGroup.drop { $0.effectiveStartTs < onset }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        var motion: [Double] = []
        for frag in group {
            if let seg = SleepView.decodeSegments(frag.stagesJSON, sessionStart: frag.effectiveStartTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                let shift = TimeInterval(frag.effectiveStartTs - onset)
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start + shift, end: iv.end + shift))
                }
            } else if let st = SleepView.decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        let orderedFrags = Array(group)
        for (prev, next) in zip(orderedFrags, orderedFrags.dropFirst()) {
            let gapStart = prev.endTs, gapEnd = next.effectiveStartTs
            guard gapEnd > gapStart else { continue }
            segs.append(SleepInterval(stage: .awake,
                                      start: TimeInterval(gapStart - onset),
                                      end: TimeInterval(gapEnd - onset)))
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Mirrors the former `SleepView.decodedNight(at:)`. (#160, #170)
    static func decodedNight(at offset: Int, navDays: [[CachedSleepSession]],
                             habitualMidsleepSec: Int?, motionByStart: [Int: [Double]]) -> Night? {
        guard offset >= 0, offset < navDays.count else { return nil }
        return mergeDay(navDays[offset], habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    /// Per-local-wake-day nap credit, derived from the same day grouping and main-night selector the
    /// hero/naps card use. Mirrors the former `SleepView.napSleepMinutesByDay`.
    static func napSleepMinutesByDay(navDays: [[CachedSleepSession]], habitualMidsleepSec: Int?) -> [String: Double] {
        var result: [String: Double] = [:]
        for blocks in navDays {
            guard let endTs = blocks.first?.endTs else { continue }
            let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
            result[day] = SleepView.napSleepMinutes(blocks, habitualMidsleepSec: habitualMidsleepSec)
        }
        return result
    }

    // MARK: Typical / need

    static func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    static func typicalTotalMin(days: [DailyMetric]) -> Double? {
        mean(days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    static func typicalStageMin(days: [DailyMetric], _ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    static func sleepNeedMin(days: [DailyMetric]) -> Double {
        Swift.max(450, typicalTotalMin(days: days) ?? 450)   // 450 min = 7.5h
    }

    // MARK: Per-tile series (latest, typical mean, sparkline history)

    /// Build a metric from a per-day transform, keeping only finite values.
    static func metric(days: [DailyMetric], _ transform: (DailyMetric) -> Double?) -> Metric {
        let series = days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure when the export carried one for that day;
    /// else the REAL resolved Rest composite for that day. (#614 follow-up)
    static func performanceSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        return metric(days: days) { d in
            if let p = imported[d.day]?.performancePct { return p }   // export-verbatim
            return AnalyticsEngine.Rest.composite(daily: d)            // real resolved Rest composite
        }
    }

    static func efficiencySeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency: prefer the imported sleep_consistency series when it covers the latest night;
    /// else the APPROXIMATE rolling bedtime-spread score.
    static func consistencySeries(days: [DailyMetric], sleeps: [CachedSleepSession],
                                  importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        if let lastDay = days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need. The imported sleep_need_min wins per day; else the
    /// APPROXIMATE personal-mean need.
    static func hoursVsNeededSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        let fallbackNeed = sleepNeedMin(days: days)
        return metric(days: days) { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    static func restorativeSeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    static func respiratorySeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else the
    /// APPROXIMATE per-night need − (main sleep + nap sleep), floored at 0.
    static func sleepDebtSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures],
                                napSleepMinByDay: [String: Double]) -> Metric {
        let imported = importedSleep
        let need = sleepNeedMin(days: days)
        let series = days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = SleepDebt.creditedSleepMin(
                mainSleepMin: d.totalSleepMin,
                napSleepMin: napSleepMinByDay[d.day] ?? 0), need > 0 else { return nil }
            return Swift.max(0, need - asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    // MARK: Trend points

    /// Trailing total-sleep trend, plotted in HOURS. Single source of truth shared with the Today
    /// host (`AsleepDurationCard`), so the Sleep-tab trend and the hosted copy are byte-identical.
    static func durationTrendPoints(days: [DailyMetric]) -> [TrendPoint] {
        AsleepDurationData.build(days: days).points
    }

    // MARK: Sleep-debt ledger

    /// The rolling 14-night sleep-debt ledger from the cached daily metrics. Uses the SAME personal
    /// sleep need the tiles use (`sleepNeedMin`), measured against each main night's `totalSleepMin`
    /// plus actual asleep minutes from separately-recorded naps. (#242)
    static func debtLedger(days: [DailyMetric], napSleepMinByDay: [String: Double]) -> SleepDebtLedger {
        SleepDebt.ledger(
            series: days.map { day in
                (day: day.day, totalSleepMin: SleepDebt.creditedSleepMin(
                    mainSleepMin: day.totalSleepMin,
                    napSleepMin: napSleepMinByDay[day.day] ?? 0))
            },
            needHours: sleepNeedMin(days: days) / 60.0)
    }

    // MARK: - Build

    /// Build every expensive derivation exactly once, as a pure function of `inputs`. Returns nil when
    /// there is no usable latest night (the caller renders the empty state). This is the former
    /// `SleepView.buildModel()` body, re-expressed over explicit inputs. (#940)
    static func build(_ inputs: SleepModelInputs) -> SleepModel? {
        // Replicate `navSessions`: fall back to the one-per-night list until the fuller list loads.
        let navSessions = inputs.allSessions.isEmpty ? inputs.sleeps : inputs.allSessions
        let dayGroups = navDays(navSessions: navSessions)
        let habitual = inputs.habitualMidsleepSec

        // #940: ONE un-mergeable newest day must not blank the whole tab. Degrade to the SAME honest
        // stage-less stub the ◀/▶ browse shows, keeping the edit/delete affordances reachable. nil
        // only when there is genuinely no day to show.
        let night: Night
        let isStub: Bool
        if let merged = decodedNight(at: 0, navDays: dayGroups,
                                     habitualMidsleepSec: habitual, motionByStart: inputs.motionByStart) {
            night = merged
            isStub = false
        } else {
            let blocks0 = dayGroups.indices.contains(0) ? dayGroups[0] : []
            if let stubSession = SleepView.stubDaySession(blocks0, habitualMidsleepSec: habitual) {
                night = Night(session: stubSession, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                              sourceBlocks: blocks0, habitualMidsleepSec: habitual)
                isStub = true
            } else {
                return nil
            }
        }

        let napSleepMinByDay = napSleepMinutesByDay(navDays: dayGroups, habitualMidsleepSec: habitual)
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            isStubNight: isStub,
            performance: performanceSeries(days: inputs.days, importedSleep: inputs.importedSleep),
            efficiency: efficiencySeries(days: inputs.days),
            consistency: consistencySeries(days: inputs.days, sleeps: inputs.sleeps, importedSleep: inputs.importedSleep),
            hoursVsNeeded: hoursVsNeededSeries(days: inputs.days, importedSleep: inputs.importedSleep),
            restorative: restorativeSeries(days: inputs.days),
            respiratory: respiratorySeries(days: inputs.days),
            sleepDebt: sleepDebtSeries(days: inputs.days, importedSleep: inputs.importedSleep, napSleepMinByDay: napSleepMinByDay),
            typicalTotalMin: typicalTotalMin(days: inputs.days),
            typicalDeepMin: typicalStageMin(days: inputs.days, \.deepMin),
            typicalRemMin: typicalStageMin(days: inputs.days, \.remMin),
            typicalLightMin: typicalStageMin(days: inputs.days, \.lightMin),
            trendPoints: durationTrendPoints(days: inputs.days),
            sleepDebtLedger: debtLedger(days: inputs.days, napSleepMinByDay: napSleepMinByDay))
    }
}
