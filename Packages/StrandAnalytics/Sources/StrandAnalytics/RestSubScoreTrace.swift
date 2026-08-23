import Foundation
import WhoopProtocol   // DeviceFamily (sleepMotionLine)

// RestSubScoreTrace.swift - the Sleep & Rest test-mode diagnostic for the Rest composite.
//
// Recomputes the four weighted sub-scores from the SAME inputs AnalyticsEngine.Rest.composite
// reads, and reuses Rest.composite for the final value so the trace can never disagree with the
// score. Pure and side-effect-free. No em-dashes. Counts and ratios only.

/// Where the night that drove this day's sleep figures came from (CAPTURE-C / #799). The measured BLE
/// path (`AnalyticsEngine.analyzeDay`) emits `.measured`; the caller passes `.imported(...)` when a
/// previously-imported sleep row WON the daily merge over the on-device night, so the trace shows the
/// import winning instead of silently replacing the measured number. The raw wire string is the contract
/// shape `measured` / `imported:whoop` / `imported:apple`.
public enum SleepProvenance: Equatable, Sendable {
    case measured
    case imported(String)   // source tag, e.g. "whoop" / "apple"

    /// The verbatim provenance token for the trace line: "measured", or "imported:<source>".
    public var wire: String {
        switch self {
        case .measured: return "measured"
        case .imported(let src): return "imported:\(src)"
        }
    }
}

extension AnalyticsEngine {

    /// One per-day sleep PROVENANCE line for the Sleep & Rest test mode (CAPTURE-C / #799). It rides the
    /// SAME trace sink as the Rest sub-score line, right after it, so an imported row winning the merge is
    /// visible in the export instead of silently substituting the measured night. `hoursAsleepMin` is the
    /// scored night's total sleep in MINUTES (the same `tstS/60` the daily rollup uses); `sourceRowId` is a
    /// stable id for the winning row (the measured main-night's start ts, or the imported row's id). PURE.
    public static func sleepProvenanceLine(provenance: SleepProvenance,
                                           hoursAsleepMin: Double,
                                           sourceRowId: String) -> String {
        "sleepProvenance provenance=\(provenance.wire) "
            + "hoursAsleep=\(Int(hoursAsleepMin.rounded())) sourceRowId=\(sourceRowId)"
    }

    /// #1567: the pass-level warning that this scoring run has no device registry behind it.
    ///
    /// Twin of Kotlin `IntelligenceEngine.ownerSourceAbsentLine` — same grammar, deliberately different
    /// cause token, because the two platforms reach this state by genuinely different routes. Kotlin's
    /// `analyzeRecent` takes an OPTIONAL owner source and a caller could omit it (`ownerSource=absent`);
    /// Swift's reads the registry itself, so the only way in is that read FAILING (`registry=unavailable`).
    /// Forcing one identical string would hide which of the two actually happened, which is the one thing a
    /// reader of this line needs to know.
    ///
    /// Worth having on both because the underlying flaw is shared: an unresolvable device family does not
    /// error, it silently becomes WHOOP5 — and on a WHOOP 4.0 that reads a raw skin-temp ADC as
    /// centidegrees, missing the 28–42 °C worn gate, so the night yields nothing at all. A pass that scored
    /// against fallbacks was previously indistinguishable from one that scored against the real registry.
    ///
    /// PURE. Counts and an id only, same privacy class as the sibling `sleep day=` line.
    public static func registryUnavailableLine(importedDeviceId: String) -> String {
        "analyzeRecent registry=unavailable owner->\(importedDeviceId) skinTempScale->whoop5"
    }

    /// #319 diagnostic (Sleep & Rest test mode): the motion-coverage + staging context behind the Rest
    /// number, so a high score on a poor night can be explained straight from an export. `grav`/`hr` are the
    /// night-window sample counts; `sparse` is the gravity-sparse gate (WHOOP 4.0 banks motion coarsely, so
    /// most epochs default to sleep → over-counted duration → high Rest); `stager` says which engine ran;
    /// `family` the day's owner. PURE; byte-identical to Android `AnalyticsEngine.sleepMotionLine`.
    public static func sleepMotionLine(day: String, grav: Int, hr: Int, sparse: Bool,
                                       useSleepStagerV2: Bool, family: DeviceFamily) -> String {
        "sleep-motion day=\(day) grav=\(grav) hr=\(hr) sparse=\(sparse) "
            + "stager=\(useSleepStagerV2 ? "V2" : "V1") family=\(family.rawValue)"
    }

    /// How long AFTER the detected onset to sample HR for the #271 onset trace (seconds). The first
    /// several minutes of the window: if onset opened on a still-but-awake stretch, HR here is still near
    /// baseline; a real onset has already dipped. 10 min is long enough to average out beat noise.
    public static let onsetTraceWindowSec: Int = 600

    /// Median of a bpm list — the deterministic "sorted, element at count/2" rule (upper-middle on an even
    /// count) so Swift and Kotlin agree byte-for-byte. nil on an empty list. Used to build the #271 onset
    /// trace's baseline + at-onset HR from the SAME rule on both platforms.
    public static func medianBpm(_ bpms: [Int]) -> Int? {
        if bpms.isEmpty { return nil }
        let s = bpms.sorted()
        return s[s.count / 2]
    }

    /// #271 diagnostic (Sleep & Rest test mode): the ONSET decision behind an over-early WHOOP 4.0 bedtime.
    /// `onsetTs` is where the detected sleep window OPENED; `hrAtOnsetBpm` is the median HR in the first
    /// `onsetTraceWindowSec` of it; `baselineHrBpm` is the day's median HR. `hrRatio` = atOnset / baseline:
    /// near 1.0 means HR had NOT dipped when the window opened — the pre-onset-awake over-staging this issue
    /// tracks (sparse 4.0 motion classifies "lying still, awake" as sleep); a real onset dips well below
    /// baseline (cf. the wake-side `morningReonsetRestingHRMult` = 0.90). PURE; byte-identical to Android.
    public static func sleepOnsetLine(onsetTs: Int, hrAtOnsetBpm: Int, baselineHrBpm: Int) -> String {
        let ratio = baselineHrBpm > 0 ? Double(hrAtOnsetBpm) / Double(baselineHrBpm) : 0.0
        let r2 = (ratio * 100.0).rounded() / 100.0
        return "sleep-onset onsetTs=\(onsetTs) hrAtOnset=\(hrAtOnsetBpm) "
            + "baselineHr=\(baselineHrBpm) hrRatio=\(r2)"
    }
}

extension AnalyticsEngine.Rest {

    /// One Rest sub-score diagnostic line. `groupFragments` / `groupInBedSeconds` describe the
    /// main-night GROUP composition (#525/#561): how many detected blocks were bridged into the
    /// scored night and their summed in-bed span. The four term scores mirror `composite`'s own
    /// math; the final `composite=` value is `Rest.composite` verbatim so they cannot diverge.
    public static func subScoreLine(tstSeconds: Double, inBedSeconds: Double, efficiency: Double,
                                    restorativeSeconds: Double, needHours: Double,
                                    consistency: Double?, deepSeconds: Double?,
                                    groupFragments: Int, groupInBedSeconds: Double) -> String {
        func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }
        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        let needSeconds = max(needHours, 0.1) * 3600.0
        let durationScore = clamp01(tstSeconds / needSeconds)
        let efficiencyScore = clamp01(efficiency)
        let deepFactor: Double = {
            guard let deep = deepSeconds, tstSeconds > 0, deepShareTarget > 0 else { return 1.0 }
            let adequacy = clamp01((deep / tstSeconds) / deepShareTarget)
            return deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
        }()
        let restorativeScore = tstSeconds > 0
            ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget) * deepFactor
            : 0.0
        let consistencyScore = clamp01(consistency ?? neutralConsistency)
        let composite = AnalyticsEngine.Rest.composite(
            tstSeconds: tstSeconds, inBedSeconds: inBedSeconds, efficiency: efficiency,
            restorativeSeconds: restorativeSeconds, needHours: needHours,
            consistency: consistency, deepSeconds: deepSeconds)

        return "rest composite=\(r2(composite)) "
            + "dur=\(r2(durationScore))*wDur=\(wDuration) "
            + "eff=\(r2(efficiencyScore))*wEff=\(wEfficiency) "
            + "restor=\(r2(restorativeScore))*wRestor=\(wRestorative) deepFactor=\(r2(deepFactor)) "
            + "consist=\(r2(consistencyScore))*wConsist=\(wConsistency) "
            + "group=\(groupFragments) groupInBedMin=\(Int(groupInBedSeconds / 60))"
    }
}
