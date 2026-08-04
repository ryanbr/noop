import Foundation
import StrandAnalytics
import WhoopProtocol

// sleepbench — replay the sleep stagers over real recorded nights and score them against every
// independent reference the database carries.
//
// USAGE:  sleepbench --db /path/to/whoop.sqlite [--device my-whoop-noop] [--pad 3600] [--csv out.csv]
//                     [--exclude <startTs,…>]
//
// The database is never written to and never lives in this repository. Pass a COPY; never point this at
// a device's live database.

struct Args {
    var db = ""
    /// The `sleepSession.deviceId` whose nights are scored.
    var device = "my-whoop-noop"
    /// The `deviceId` the raw streams are stored under. These genuinely differ in a real database — the
    /// session rows carry the app's own device identity while the decoded streams carry the strap's — so
    /// the two are separate arguments rather than one assumed-shared value.
    var streamDevice = "my-whoop"
    var pad = 3600
    var csv: String?
    /// Session `startTs` values held out of the stage-locked calibration set in section E.
    ///
    /// Section E's reference set has to stay FIXED across the two builds of a before/after comparison, or
    /// the denominator moves underneath the delta. That is why it keys on `stagelock` rather than on
    /// section B's recipe-dependent exclusion. But `stagelock` alone does not guarantee the row is
    /// independent of V2 (see the self-comparison warning below), and the honest fix for a contaminated row
    /// is to name it ONCE and pass the same `--exclude` list to every build being compared. Excluding by
    /// explicit timestamp keeps the set frozen; excluding by "matches this build's V2" would not.
    var exclude: Set<Int> = []
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--db": a.db = it.next() ?? ""
    case "--device": a.device = it.next() ?? a.device
    case "--stream-device": a.streamDevice = it.next() ?? a.streamDevice
    case "--pad": a.pad = Int(it.next() ?? "") ?? a.pad
    case "--csv": a.csv = it.next()
    case "--exclude": a.exclude = Set((it.next() ?? "").split(separator: ",").compactMap { Int($0) })
    default: FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2)
    }
}
guard !a.db.isEmpty else {
    print("""
    usage: sleepbench --db <sqlite> [--device <id>] [--stream-device <id>] [--pad <s>] [--csv <path>]
                      [--exclude <startTs,startTs,…>]

      --exclude   session startTs values held out of section E's calibration reference set. Pass the SAME
                  list to every build in a before/after comparison; section E names the candidates.
    """)
    exit(2)
}

let db = try ReadOnlyDB(path: a.db)
let rows = try db.sessions(device: a.device)
guard !rows.isEmpty else { print("no sessions for device \(a.device)"); exit(1) }
// Which `userEdited` rows carry a HUMAN-AUTHORED hypnogram rather than machine stages re-derived over a
// human-corrected window. Only the former can serve as a stage-level reference.
let stageLocked = try db.stageLockedStarts(device: a.device).subtracting(a.exclude)
let editedCount = rows.filter { $0.userEdited }.count
print("""

================================================================================
0. GROUND-TRUTH PROVENANCE
================================================================================
sessions \(rows.count)   userEdited \(editedCount)   of which stage-locked (human-authored stages) \(rows.filter { $0.userEdited && stageLocked.contains($0.startTs) }.count)

A `userEdited` row alone does NOT prove human stage labels: the local editor corrects bed/wake BOUNDS and
then re-derives the hypnogram from raw, so its stages are machine output over a human-chosen window. Only
a row carrying a `stagelock` cursor had its stages authored directly (the cloud `edit_sleep_stages` path).
Rows without the lock are reported below but are not treated as a stage-level reference.
""")

func nightLabel(_ ts: Int) -> String {
    // Name each night by its local-ish calendar date. -7 h keeps a post-midnight start on the prior
    // night, matching how the app groups a night to a day. Display only; nothing scores on it.
    let d = Date(timeIntervalSince1970: Double(ts - 7 * 3600))
    let fm = DateFormatter()
    fm.dateFormat = "yyyy-MM-dd"; fm.timeZone = TimeZone(identifier: "UTC")
    return fm.string(from: d)
}

/// A mirror of PR #738's `SleepStager.applyBandStateWakeVeto`, which is `internal` and so unreachable
/// from this executable. Logic is transcribed line-for-line from that PR: only band state 2 ("asleep")
/// vetoes, only INTERIOR wake (between the first and last sleep epoch) is touched, and wake only ever
/// becomes sleep. `SleepStagerTests` pins the real implementation; this mirror exists purely so the
/// veto's effect can be scored on the isolated staging path as well as end-to-end.
func bandVetoMirror(_ labels: [String], bandEpochs: [Int]) -> [String] {
    guard !bandEpochs.isEmpty, labels.count == bandEpochs.count else { return labels }
    guard let onset = labels.firstIndex(where: { $0 != "wake" }),
          let final = labels.lastIndex(where: { $0 != "wake" }), onset <= final else { return labels }
    var out = labels
    for i in onset...final where out[i] == "wake" && bandEpochs[i] == SleepStager.bandStateAsleep {
        out[i] = "light"
    }
    return out
}

// MARK: - Replay every night

struct Night {
    let row: SessionRow
    let night: String
    let truth: [String]?          // the wearer's manual restage, when this night was edited
    let v1: [String]
    let v2: [String]
    let v1Veto: [String]
    let v2Veto: [String]
    let band: [Int]               // per-epoch band sleep_state, [] when the strap banked none
    let meanHR: Double
    let machineWakeMin: Double?   // wake implied by the STALE pre-edit efficiency column
    let hasSteps: Bool
}

var nights: [Night] = []
FileHandle.standardError.write(Data("replaying \(rows.count) sessions…\n".utf8))

for r in rows {
    let st = try db.streams(device: a.streamDevice, from: r.startTs - a.pad, to: r.endTs + a.pad)
    // Both stagers take the same window and the same streams; only the recipe differs.
    let v1 = SleepStager.stageSession(start: r.startTs, end: r.endTs, grav: st.grav,
                                      hr: st.hr, rr: st.rr, resp: st.resp)
    let v2 = SleepStagerV2.stageSession(start: r.startTs, end: r.endTs, grav: st.grav,
                                        hr: st.hr, rr: st.rr, resp: st.resp)
    let n = epochCount(start: r.startTs, end: r.endTs)
    let bandEpochs = SleepStager.sessionEpochSleepState(start: r.startTs, end: r.endTs,
                                                        sleepState: st.band)
    let l1 = epochLabels(v1, start: r.startTs, end: r.endTs)
    let l2 = epochLabels(v2, start: r.startTs, end: r.endTs)
    let truth = r.userEdited ? epochLabels(r.stages, start: r.startTs, end: r.endTs) : nil
    let hrS = try db.hrStats(device: a.streamDevice, from: r.startTs, to: r.endTs)
    // The stale `efficiency` column is the machine's own pre-edit verdict on an edited night.
    let machineWake = r.userEdited ? r.efficiency.map { (1 - $0) * r.durMin } : nil

    nights.append(Night(
        row: r, night: nightLabel(r.startTs), truth: truth,
        v1: l1, v2: l2,
        v1Veto: bandVetoMirror(l1, bandEpochs: bandEpochs),
        v2Veto: bandVetoMirror(l2, bandEpochs: bandEpochs),
        band: bandEpochs.count == n ? bandEpochs : [],
        meanHR: hrS?.mean ?? .nan,
        machineWakeMin: machineWake,
        hasSteps: !st.steps.isEmpty))
    FileHandle.standardError.write(Data(".".utf8))
}
FileHandle.standardError.write(Data("\n".utf8))

// MARK: - A. Which stager actually produced the stored hypnograms?

print("""

================================================================================
A. WHICH STAGER PRODUCED THE STORED NIGHTS?
================================================================================
On an unedited night the stored `stagesJSON` is whatever the live stager emitted. Replaying V1 and V2
over the identical window + streams and comparing epoch-for-epoch identifies the live recipe. On an
edited night `stagesJSON` is the wearer's restage, so those are excluded here.
""")
var v1Match = 0, v2Match = 0, neither = 0
/// An edited night whose stored hypnogram is BYTE-IDENTICAL to a fresh V2 replay cannot serve as an
/// independent reference for V2, whatever produced it: scoring V2 against it would be self-comparison.
/// This says nothing about HOW the row came to match — the harness reports the fact and excludes the
/// night, and deliberately does not assert a mechanism it has not established.
var indistinguishableFromV2: Set<String> = []
/// Per-night epoch agreement between the STORED hypnogram and a fresh V2 replay, by `startTs`. Section E
/// reads it to warn when its own reference set contains rows V2 cannot be scored against independently.
var v2AgreePct: [Int: Double] = [:]
print("night        edited  epochs  V1 agree  V2 agree  verdict")
for nt in nights {
    let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
    let a1 = zip(stored, nt.v1).filter { $0 == $1 }.count
    let a2 = zip(stored, nt.v2).filter { $0 == $1 }.count
    let p1 = Double(a1) / Double(stored.count) * 100, p2 = Double(a2) / Double(stored.count) * 100
    v2AgreePct[nt.row.startTs] = p2
    let verdict = p2 >= 99.9 ? "V2 exact" : (p1 >= 99.9 ? "V1 exact" : (p2 > p1 ? "V2 closer" : "V1 closer"))
    if !nt.row.userEdited {
        if p2 >= 99.9 { v2Match += 1 } else if p1 >= 99.9 { v1Match += 1 } else { neither += 1 }
    } else if p2 >= 99.9 {
        indistinguishableFromV2.insert(nt.night + "@\(nt.row.startTs)")
    }
    print("\(nt.night.padding(toLength: 12, withPad: " ", startingAt: 0)) \(nt.row.userEdited ? "   yes" : "    no") \(String(format: "%7d", stored.count)) \(f(p1, 8, 2))% \(f(p2, 8, 2))%  \(verdict)")
}
print("""
--------------------------------------------------------------------------------
UNEDITED nights — exact-V1 reproductions: \(v1Match)   exact-V2 reproductions: \(v2Match)   neither exact: \(neither)
EDITED nights whose stored hypnogram is a byte-exact V2 replay (excluded as a V2 reference): \(indistinguishableFromV2.count) of \(nights.filter { $0.row.userEdited }.count)
""")

/// True when this night's stored hypnogram survived as the wearer left it.
func isGenuineEdit(_ nt: Night) -> Bool {
    nt.row.userEdited && !indistinguishableFromV2.contains(nt.night + "@\(nt.row.startTs)")
}

// MARK: - B. Accuracy against the wearer's manual restages

// ONLY nights whose stored hypnogram still differs from a fresh V2 replay are usable as human truth.
// Scoring V2 against a row V2 itself wrote would be self-comparison and would inflate every V2 figure.
let edited = nights.filter { $0.truth != nil && isGenuineEdit($0) }
let selfMatchedNights = nights.filter { $0.row.userEdited && !isGenuineEdit($0) }
print("""

================================================================================
B. ACCURACY vs THE WEARER'S MANUAL RESTAGES  (reference (a), n = \(edited.count) nights)
================================================================================
`userEdited = 1` rows carry the hypnogram the wearer corrected by hand — the only human-labelled
reference in the database. `machine` is the ORIGINAL machine wake total, recovered from the stale
pre-edit `efficiency` column; V1/V2 are fresh replays over the same window.
""")
print("night        inbed  truthW  machW   V1 W   V2 W  V1+vetoW V2+vetoW   dMach     dV1     dV2")
var dMach: [Double] = [], dV1: [Double] = [], dV2: [Double] = [], dV1v: [Double] = [], dV2v: [Double] = []
for nt in edited {
    guard let t = nt.truth else { continue }
    let tw = wakeMinutes(t), w1 = wakeMinutes(nt.v1), w2 = wakeMinutes(nt.v2)
    let w1v = wakeMinutes(nt.v1Veto), w2v = wakeMinutes(nt.v2Veto)
    let mw = nt.machineWakeMin
    if let mw { dMach.append(mw - tw) }
    dV1.append(w1 - tw); dV2.append(w2 - tw)
    if !nt.band.isEmpty { dV1v.append(w1v - tw); dV2v.append(w2v - tw) }
    print("\(nt.night) \(f(nt.row.durMin, 6, 0)) \(f(tw, 7, 0)) \(f(mw ?? .nan, 6, 0)) \(f(w1, 6, 0)) \(f(w2, 6, 0)) \(f(w1v, 9, 0)) \(f(w2v, 8, 0)) \(f((mw ?? .nan) - tw, 7, 0)) \(f(w1 - tw, 7, 0)) \(f(w2 - tw, 7, 0))")
}
func summarise(_ name: String, _ v: [Double]) {
    guard !v.isEmpty else { print("  \(name): no data"); return }
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) n=\(v.count)  mean \(f(mean(v), 7, 1))  median \(f(median(v), 7, 1))  sd \(f(sd(v), 6, 1))  range \(f(v.min()!, 6, 0))..\(f(v.max()!, 6, 0))")
}
print("\nWAKE-MINUTE ERROR vs manual restage (positive = OVER-calls wake):")
summarise("machine-as-stored", dMach)
summarise("V1 replay", dV1)
summarise("V2 replay", dV2)
summarise("V1 + band veto", dV1v)
summarise("V2 + band veto", dV2v)

// Per-stage agreement, pooled over every edited night.
print("\n4-CLASS AGREEMENT vs manual restage (epochs pooled over \(edited.count) nights):")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("V1+veto", { (n: Night) in n.v1Veto }), ("V2+veto", { (n: Night) in n.v2Veto })] {
    var c = Confusion(classes: stageOrder)
    var c2 = Confusion(classes: ["wake", "sleep"])
    for nt in edited {
        guard let t = nt.truth else { continue }
        c.merge(confusion(ref: t, pred: get(nt)))
        c2.merge(confusion(ref: toSleepWake(t), pred: toSleepWake(get(nt)), classes: ["wake", "sleep"]))
    }
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) 4-class acc \(f(c.accuracy * 100, 5, 1))%  kappa \(f(c.kappa, 6, 3))   |   sleep/wake acc \(f(c2.accuracy * 100, 5, 1))%  kappa \(f(c2.kappa, 6, 3))")
    for s in stageOrder {
        let (sens, spec, n) = c.sensSpec(s)
        print("      \(s.padding(toLength: 6, withPad: " ", startingAt: 0)) sens \(f(sens * 100, 5, 1))%  spec \(f(spec * 100, 5, 1))%  (ref epochs \(n))")
    }
}

// MARK: - C. Accuracy against the strap's own band sleep_state

let banded = nights.filter { !$0.band.isEmpty }
print("""

================================================================================
C. AGREEMENT WITH THE STRAP'S OWN BAND sleep_state  (reference (b), n = \(banded.count) nights)
================================================================================
The v18 @81 high nibble (0 wake / 1 still / 2 asleep / 3 up) is the strap's OWN scored verdict, not a
re-derivation of NOOP's. It carries no light/deep/REM, so this is a sleep-vs-wake comparison only.
STRICT maps band 2 -> sleep and band 0/3 -> wake, and EXCLUDES band 1 ("still", genuinely ambiguous).
""")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("V1+veto", { (n: Night) in n.v1Veto }), ("V2+veto", { (n: Night) in n.v2Veto }),
                    ("stored", { (n: Night) in epochLabels(n.row.stages, start: n.row.startTs, end: n.row.endTs) })] {
    var c = Confusion(classes: ["wake", "sleep"])
    for nt in banded {
        let pred = toSleepWake(get(nt))
        for (i, b) in nt.band.enumerated() where i < pred.count {
            guard b != 1 else { continue }                       // "still" excluded
            c.add(ref: b == SleepStager.bandStateAsleep ? "sleep" : "wake", pred: pred[i])
        }
    }
    let (sens, spec, n) = c.sensSpec("wake")
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) acc \(f(c.accuracy * 100, 5, 1))%  kappa \(f(c.kappa, 6, 3))  wake sens \(f(sens * 100, 5, 1))%  wake spec \(f(spec * 100, 5, 1))%  (band-wake epochs \(n), total \(c.total))")
}
// How much of what each stager calls wake does the strap itself dispute?
print("\nDISPUTED WAKE — of the epochs each stager calls wake, what fraction did the strap score \"asleep\"?")
for (name, get) in [("V1", { (n: Night) in n.v1 }), ("V2", { (n: Night) in n.v2 }),
                    ("stored", { (n: Night) in epochLabels(n.row.stages, start: n.row.startTs, end: n.row.endTs) })] {
    var wakeEpochs = 0, disputed = 0, sleepEpochs = 0, reverseDisputed = 0
    for nt in banded {
        let pred = get(nt)
        for (i, b) in nt.band.enumerated() where i < pred.count {
            if pred[i] == "wake" {
                wakeEpochs += 1
                if b == SleepStager.bandStateAsleep { disputed += 1 }
            } else {
                sleepEpochs += 1
                if b == 0 || b == 3 { reverseDisputed += 1 }
            }
        }
    }
    let fwd = wakeEpochs == 0 ? Double.nan : Double(disputed) / Double(wakeEpochs) * 100
    let rev = sleepEpochs == 0 ? Double.nan : Double(reverseDisputed) / Double(sleepEpochs) * 100
    print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) stager-wake epochs \(String(format: "%6d", wakeEpochs)), strap says asleep \(f(fwd, 5, 1))%   |   reverse (stager sleep, strap wake/up) \(f(rev, 5, 1))%")
}

// MARK: - D. The supplement-HR hypothesis

print("""

================================================================================
D. DOES THE WAKE OVER-CALL TRACK OVERNIGHT HR?  (the supplement hypothesis)
================================================================================
The standing inference is that an overnight HR held around 55-60 bpm reads to an HR-led wake detector as
wakefulness. If true, per-night wake error should RISE with mean overnight HR. Tested here on every night
that has a human reference.
""")
print("night        meanHR   truthW   machW    dMach     dV1     dV2")
var hrs: [Double] = [], errM: [Double] = [], errV1: [Double] = [], errV2: [Double] = []
for nt in edited.sorted(by: { $0.meanHR < $1.meanHR }) {
    guard let t = nt.truth, !nt.meanHR.isNaN else { continue }
    let tw = wakeMinutes(t)
    let mw = nt.machineWakeMin ?? .nan
    hrs.append(nt.meanHR); errM.append(mw - tw)
    errV1.append(wakeMinutes(nt.v1) - tw); errV2.append(wakeMinutes(nt.v2) - tw)
    print("\(nt.night) \(f(nt.meanHR, 8, 1)) \(f(tw, 8, 0)) \(f(mw, 7, 0)) \(f(mw - tw, 8, 0)) \(f(wakeMinutes(nt.v1) - tw, 7, 0)) \(f(wakeMinutes(nt.v2) - tw, 7, 0))")
}
for (nm, e) in [("machine-as-stored", errM), ("V1 replay", errV1), ("V2 replay", errV2)] {
    let (r, n, t) = pearson(hrs, e)
    print("  corr(mean overnight HR, \(nm.padding(toLength: 18, withPad: " ", startingAt: 0)) wake error): r = \(f(r, 6, 3))  n = \(n)  t = \(f(t, 6, 2))")
}

// The edited nights span only a narrow HR band, so the test above is underpowered by construction. The
// BAND-disputed-wake fraction needs no human labels, so it can be run over every banded night and covers
// a far wider HR range — a much stronger test of the same hypothesis.
print("""

  WIDER TEST — no human labels needed, so every banded night counts. For each night, the fraction of
  V2's wake epochs that the strap itself scored "asleep" (its false-wake rate by the strap's reckoning)
  against that night's mean overnight HR. If elevated HR drives the over-call, this must rise with HR.
""")
print("  night        meanHR  V2wakeEp  strapDisputed%")
var bhr: [Double] = [], bdisp: [Double] = []
for nt in banded.sorted(by: { $0.meanHR < $1.meanHR }) {
    var wake = 0, disp = 0
    for (i, b) in nt.band.enumerated() where i < nt.v2.count {
        if nt.v2[i] == "wake" { wake += 1; if b == SleepStager.bandStateAsleep { disp += 1 } }
    }
    guard wake >= 10, !nt.meanHR.isNaN else { continue }
    let pct = Double(disp) / Double(wake) * 100
    bhr.append(nt.meanHR); bdisp.append(pct)
    print("  \(nt.night) \(f(nt.meanHR, 7, 1)) \(String(format: "%9d", wake)) \(f(pct, 15, 1))")
}
let (br, bn, bt) = pearson(bhr, bdisp)
print("  corr(mean overnight HR, strap-disputed wake fraction): r = \(f(br, 6, 3))  n = \(bn)  t = \(f(bt, 6, 2))")
if !selfMatchedNights.isEmpty {
    print("""

  NOTE: \(selfMatchedNights.count) `userEdited` night(s) were excluded from the human-reference tests above because
  their stored hypnogram is a byte-exact replay of the CURRENT V2, so scoring V2 against them would be
  self-comparison. The harness asserts no mechanism for the match: \(selfMatchedNights.map { $0.night }.joined(separator: ", "))
""")
}
// Stratify rather than rely on a single correlation — n is small and the relation need not be linear.
let hiCut = 55.0
let hi = edited.filter { $0.meanHR >= hiCut }, lo = edited.filter { $0.meanHR < hiCut }
for (nm, grp) in [("mean HR >= \(Int(hiCut))", hi), ("mean HR <  \(Int(hiCut))", lo)] {
    let e = grp.compactMap { nt -> Double? in
        guard let t = nt.truth, let mw = nt.machineWakeMin else { return nil }
        return mw - wakeMinutes(t)
    }
    guard !e.isEmpty else { print("  \(nm): no nights"); continue }
    print("  \(nm.padding(toLength: 18, withPad: " ", startingAt: 0)) n=\(e.count)  mean machine wake error \(f(mean(e), 7, 1)) min  median \(f(median(e), 7, 1))")
}

// MARK: - E. Per-stage fraction calibration — the guard kappa does not provide

/// The stage-level reference set for calibration: rows carrying a `stagelock` cursor, i.e. rows whose
/// stages a human authored directly.
///
/// This is deliberately NOT section B's set. B excludes an edited night whose stored hypnogram is a
/// byte-exact replay of the CURRENT V2, which is the right call for B's question but is version-dependent
/// by construction: change the recipe and a night can enter or leave the exclusion, silently swapping the
/// denominator underneath a before/after comparison. The `stagelock` set comes from `cursors` and does not
/// move when the recipe moves, which is what makes a calibration delta between two builds legitimate.
///
/// The cost of that choice, and why the warning below exists: a `stagelock` cursor proves the stages
/// arrived through the `edit_sleep_stages` path, NOT that they differ from what V2 would emit. A row whose
/// stored hypnogram replays byte-exact from V2 carries no information about V2 — it hands the incumbent a
/// free perfect night and charges every alternative for the same nights. Section B drops such rows; section
/// E cannot drop them the same way without reintroducing the version-dependence it exists to avoid. So the
/// harness NAMES them and leaves the choice to the operator, who freezes it with `--exclude`.
let calRef = nights.filter { $0.truth != nil && stageLocked.contains($0.row.startTs) }
/// The cohort PR #348 broke: a plausible full sleep opportunity. #437's field symptom was a HEALTHY night
/// re-scored 6% -> 23% awake, and an aggregate that pools short and fragmented nights hides exactly that.
let healthyMinutes = 300.0
func isHealthy(_ nt: Night) -> Bool { nt.row.durMin >= healthyMinutes }
let calRefHealthy = calRef.filter(isHealthy)
let healthyNights = nights.filter(isHealthy)

/// The recipes scored below, in the order the rest of the harness uses them.
let variants: [(String, (Night) -> [String])] = [
    ("V1", { $0.v1 }), ("V2", { $0.v2 }), ("V1+veto", { $0.v1Veto }), ("V2+veto", { $0.v2Veto }),
]

print("""

================================================================================
E. PER-STAGE FRACTION CALIBRATION  (reference (a), stage-locked, n = \(calRef.count) nights)
================================================================================
Cohen's kappa scores whether the label at an epoch matches; it does not constrain how much of the night a
recipe spends at each stage. PR #348 fitted the stager to DREAMT, raised kappa on all three benchmarks with
a held-out gap of -0.027, and was reverted 48 h later by PR #437 for re-scoring a healthy night from 6% to
23% awake. The revert's own words: "kappa doesn't guard stage-fraction calibration." This section is that
guard. Bias is signed, in percentage points of the night: POSITIVE = the recipe spends more of the night at
that stage than the human did.
""")

// SELF-COMPARISON AUDIT of this section's own reference set. A stage-locked row whose stored hypnogram is a
// byte-exact V2 replay scores V2 against itself: it is a guaranteed 100% for the incumbent and a guaranteed
// loss for any alternative, so it biases a before/after delta toward "change nothing" by an amount nobody
// reading only the kappa line would see. The audit reports the contamination rather than silently absorbing
// it, and names the timestamps so the same held-out set can be pinned across both builds with `--exclude`.
let selfMatched = calRef.filter { (v2AgreePct[$0.row.startTs] ?? 0) >= 99.9 }
let nearMatched = calRef.filter {
    let p = v2AgreePct[$0.row.startTs] ?? 0
    return p >= 95.0 && p < 99.9
}
print("  E.-1 SELF-COMPARISON AUDIT of the reference set")
if selfMatched.isEmpty && nearMatched.isEmpty {
    print("    clean — no stage-locked night replays from V2 at >= 95% agreement.")
} else {
    print("    night                      stored-vs-V2 agreement    verdict")
    for nt in (selfMatched + nearMatched).sorted(by: { $0.row.startTs < $1.row.startTs }) {
        let p = v2AgreePct[nt.row.startTs] ?? 0
        print("    \(nt.night) (startTs \(nt.row.startTs)) \(f(p, 12, 2))%    \(p >= 99.9 ? "BYTE-EXACT — carries no information about V2" : "near-exact — nearly none")")
    }
    let pct = Double(selfMatched.count) / Double(max(1, calRef.count)) * 100
    print("""
        \(selfMatched.count) of \(calRef.count) reference nights (\(f(pct, 0, 0))%) are byte-exact V2 replays; \(nearMatched.count) more sit at >= 95%.
        These inflate every V2 figure in E.0-E.4 and penalise any alternative recipe by construction. To
        compare two builds honestly, pass the SAME list to BOTH:
          --exclude \(selfMatched.map { String($0.row.startTs) }.joined(separator: ","))
        The harness asserts no mechanism for the match; it reports only that the row cannot serve as an
        independent reference for the recipe it replays.
    """)
}
if !a.exclude.isEmpty {
    print("    HELD OUT by --exclude this run: \(a.exclude.sorted().map(String.init).joined(separator: ", "))")
}

// Agreement on the SAME nights the calibration below scores, so the two can be read against each other.
// This is the contrast the section exists for: kappa here can rise while the biases below get worse.
print("  E.0 AGREEMENT ON THIS REFERENCE SET — the number that is not sufficient on its own")
for (name, get) in variants {
    var c4 = Confusion(classes: stageOrder), c2 = Confusion(classes: ["wake", "sleep"])
    for nt in calRef {
        guard let t = nt.truth else { continue }
        c4.merge(confusion(ref: t, pred: get(nt)))
        c2.merge(confusion(ref: toSleepWake(t), pred: toSleepWake(get(nt)), classes: ["wake", "sleep"]))
    }
    print("    \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) 4-class acc \(f(c4.accuracy * 100, 5, 1))%  kappa \(f(c4.kappa, 6, 3))   |   sleep/wake acc \(f(c2.accuracy * 100, 5, 1))%  kappa \(f(c2.kappa, 6, 3))  (epochs \(c4.total))")
}

func calibrationTable(_ title: String, _ set: [Night]) {
    print("\n  \(title)")
    guard !set.isEmpty else { print("    no reference nights in this stratum"); return }
    for (name, get) in variants {
        print("    \(name) — stage    pred mean%   ref mean%    bias pp    MAE pp   worst night")
        for s in stageOrder {
            var pred: [Double] = [], ref: [Double] = [], err: [Double] = []
            var worst = ("", 0.0)
            for nt in set {
                guard let t = nt.truth else { continue }
                let p = stagePercentages(get(nt))[s]!, q = stagePercentages(t)[s]!
                pred.append(p); ref.append(q); err.append(p - q)
                if abs(p - q) > abs(worst.1) { worst = (nt.night, p - q) }
            }
            print("          \(s.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f(mean(pred), 12, 2)) \(f(mean(ref), 11, 2)) \(f(mean(err), 10, 2)) \(f(mae(err), 9, 2))   \(worst.0) \(f(worst.1, 7, 1))")
        }
    }
}
calibrationTable("E.1 AGGREGATE — every stage-locked reference night (n = \(calRef.count))", calRef)
calibrationTable("""
E.2 HEALTHY STRATUM — in-bed >= \(Int(healthyMinutes / 60)) h (n = \(calRefHealthy.count) of \(calRef.count))
      Reported separately because the aggregate hides it: a recipe can look calibrated overall while
      blowing out on exactly the nights a healthy sleeper has.
""", calRefHealthy)

// A reference-free view of the same quantity. It needs no human labels, so it runs over every replayed
// night — a far larger n than the reference set, and enough to catch a distribution shift on its own.
print("""

  E.3 SHIPPED POPULATION — V2 stage fractions over all replayed nights, no reference needed
  stage          ALL  n = \(nights.count)                        HEALTHY >= \(Int(healthyMinutes / 60)) h  n = \(healthyNights.count)
                mean%   median%      p10      p90        mean%   median%      p10      p90
""")
for s in stageOrder {
    let all = nights.map { stagePercentages($0.v2)[s]! }
    let hea = healthyNights.map { stagePercentages($0.v2)[s]! }
    print("  \(s.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f(mean(all), 8, 2)) \(f(median(all), 9, 2)) \(f(percentile(all, 0.10), 8, 2)) \(f(percentile(all, 0.90), 8, 2))     \(f(mean(hea), 8, 2)) \(f(median(hea), 9, 2)) \(f(percentile(hea, 0.10), 8, 2)) \(f(percentile(hea, 0.90), 8, 2))")
}

print("\n  E.4 PER NIGHT — V2 signed bias in pp, on the \(calRef.count) stage-locked reference nights")
print("  night        inbed healthy    wake   light    deep     rem")
for nt in calRef {
    // `calRef` filters on `truth != nil`; the guard keeps that guarantee local, because an empty reference
    // would silently turn every predicted fraction into a bias against zero.
    guard let t = nt.truth else { continue }
    let b = stageBias(ref: t, pred: nt.v2)
    print("  \(nt.night) \(f(nt.row.durMin, 6, 0)) \(isHealthy(nt) ? "      Y" : "      -") \(f(b["wake"]!, 7, 1)) \(f(b["light"]!, 7, 1)) \(f(b["deep"]!, 7, 1)) \(f(b["rem"]!, 7, 1))")
}

// MARK: - F. First-REM latency — a stage-timing property kappa is also blind to

print("""

================================================================================
F. FIRST-REM LATENCY — minutes from staged sleep onset to the first REM epoch
================================================================================
Fraction calibration pins how MUCH REM a recipe emits; it says nothing about WHEN. A recipe can hit the
right REM total at the wrong time — REM in the first minutes after onset is physiologically implausible in
a healthy adult, and a stager that emits it is mislabelling early light sleep whatever its kappa says.
Nights that never reach REM are counted separately rather than folded in as a zero.
""")
print("  set                        n   median     mean      p10      p90      min      max   no-REM")
func latencyRow(_ name: String, _ set: [Night], _ get: (Night) -> [String]) {
    let v = set.compactMap { firstRemLatencyMinutes(get($0)) }
    guard !v.isEmpty else { print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) no nights reach REM"); return }
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%4d", v.count)) \(f(median(v), 8, 1)) \(f(mean(v), 8, 1)) \(f(percentile(v, 0.10), 8, 1)) \(f(percentile(v, 0.90), 8, 1)) \(f(v.min()!, 8, 1)) \(f(v.max()!, 8, 1)) \(String(format: "%8d", set.count - v.count))")
}
for (name, get) in variants { latencyRow("\(name), all nights", nights, get) }
latencyRow("V2, healthy >= \(Int(healthyMinutes / 60)) h", healthyNights, { $0.v2 })
latencyRow("V2, reference nights", calRef, { $0.v2 })
// The human's own latency distribution on the same nights — the target the replay rows above are aiming at.
latencyRow("HUMAN reference", calRef, { $0.truth ?? [] })

print("\n  PER NIGHT — first-REM latency in minutes, on the \(calRef.count) stage-locked reference nights")
print("  night        inbed healthy   human      V2   error")
var latErr: [Double] = []
for nt in calRef {
    guard let t = nt.truth else { continue }
    // n/a in either column means that night never reached REM, which is not an error of zero minutes.
    let h = firstRemLatencyMinutes(t), p = firstRemLatencyMinutes(nt.v2)
    var err = Double.nan
    if let h, let p { err = p - h; latErr.append(err) }
    print("  \(nt.night) \(f(nt.row.durMin, 6, 0)) \(isHealthy(nt) ? "      Y" : "      -") \(f(h ?? .nan, 7, 1)) \(f(p ?? .nan, 7, 1)) \(f(err, 7, 1))")
}
print("  signed error (V2 - human), nights where BOTH reach REM: n=\(latErr.count)  median \(f(median(latErr), 6, 1))  mean \(f(mean(latErr), 6, 1))  MAE \(f(mae(latErr), 6, 1))")

// MARK: - G. Machine cohort split — did anything change mid-history?

print("""

================================================================================
G. PER-NIGHT DETAIL (all \(nights.count) sessions)
================================================================================
""")
print("night        edited band inbed  meanHR storedW    V1 W    V2 W  storedEff")
for nt in nights {
    let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
    print("\(nt.night) \(nt.row.userEdited ? "   yes" : "    no") \(nt.band.isEmpty ? "   -" : "   Y") \(f(nt.row.durMin, 5, 0)) \(f(nt.meanHR, 7, 1)) \(f(wakeMinutes(stored), 7, 0)) \(f(wakeMinutes(nt.v1), 7, 0)) \(f(wakeMinutes(nt.v2), 7, 0)) \(f(nt.row.efficiency ?? .nan, 10, 3))")
}

if let path = a.csv {
    /// Blank rather than a sentinel wherever a night has no value: a night that never reaches REM has no
    /// first-REM latency, and writing 0 there would be a different claim.
    func num(_ v: Double?, _ p: Int = 1) -> String { v.map { String(format: "%.\(p)f", $0) } ?? "" }
    var out = "night,userEdited,stageLocked,healthy,hasBand,inbedMin,meanHR,storedWake,truthWake,machineWake,v1Wake,v2Wake,v1VetoWake,v2VetoWake,storedEff"
    for s in stageOrder { out += ",v2\(s.capitalized)Pct,truth\(s.capitalized)Pct" }
    out += ",v2FirstRemLatMin,truthFirstRemLatMin\n"
    for nt in nights {
        let stored = epochLabels(nt.row.stages, start: nt.row.startTs, end: nt.row.endTs)
        let locked = stageLocked.contains(nt.row.startTs)
        out += "\(nt.night),\(nt.row.userEdited),\(locked),\(isHealthy(nt)),\(!nt.band.isEmpty),\(num(nt.row.durMin)),\(num(nt.meanHR)),\(num(wakeMinutes(stored))),\(num(nt.truth.map { wakeMinutes($0) })),\(num(nt.machineWakeMin)),\(num(wakeMinutes(nt.v1))),\(num(wakeMinutes(nt.v2))),\(num(wakeMinutes(nt.v1Veto))),\(num(wakeMinutes(nt.v2Veto))),\(num(nt.row.efficiency, 4))"
        let pv = stagePercentages(nt.v2), pt = nt.truth.map { stagePercentages($0) }
        for s in stageOrder { out += ",\(num(pv[s], 2)),\(num(pt?[s], 2))" }
        out += ",\(num(firstRemLatencyMinutes(nt.v2))),\(num(nt.truth.flatMap { firstRemLatencyMinutes($0) }))\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
}
