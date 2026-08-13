import Foundation
import WhoopProtocol

// whoop-re — offline reverse-engineering aids over captured WHOOP frames, using the SAME
// WhoopProtocol decoder the app runs. The companion to `whoop-decode`: where that dumps one frame at
// a time, this reasons across a whole capture to guide decode work. Everything here is offline over
// already-captured data — no device, no BLE, no capture mode, zero battery/perf cost.
//
// Subcommands:
//   coverage  FILE                 per (type,version) byte-coverage map + unknown-byte variance
//   inventory FILE                 census: types/versions, counts, ok/crc rates, ts span, lengths
//   diff      FILE_A FILE_B        value-set diff of shared layouts (flag-on vs flag-off → the bytes)
//   truth     --field N --truth T FILE   score a decoded field against timestamped ground truth
//
// Input FILE is the same capture/fixture JSON `whoop-decode` reads: an array of {"hex", …} objects
// (the richer {"hex","char","hr","ts_ms"} capture records are a superset and read too). TRUTH is a
// JSON array of {"ts_ms", "value"} — what the official app displayed, for the `truth` scorer.
//
// Usage:
//   whoop-re coverage capture.json
//   whoop-re diff spo2_off.json spo2_on.json
//   whoop-re truth --field hrv_rmssd --truth app_hrv.json --max-dt 90000 capture.json

// MARK: - Input model (mirrors whoop-decode; the executables share no code by design)

struct CaptureRecord: Decodable {
    let hex: String
    let char: String?
    let hr: Int?
    let tsMs: Int?
    enum CodingKeys: String, CodingKey { case hex, char, hr; case tsMs = "ts_ms" }
}

struct TruthRecord: Decodable {
    let tsMs: Int
    let value: Double
    enum CodingKeys: String, CodingKey { case tsMs = "ts_ms"; case value }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(2)
}

let helpText = """
whoop-re — offline reverse-engineering aids over captured WHOOP frames.

USAGE:
  whoop-re coverage  [--family whoop4|whoop5|auto] FILE
  whoop-re inventory [--family whoop4|whoop5|auto] FILE
  whoop-re diff      [--family whoop4|whoop5|auto] FILE_A FILE_B
  whoop-re gravity2  [--family whoop4|whoop5|auto] FILE
  whoop-re truth     [--family …] --field NAME --truth TRUTH.json [--max-dt MS] FILE

FILE is a capture/fixture JSON array of {"hex", …} (the {"hex","char","hr","ts_ms"}
capture records are read too). TRUTH is a JSON array of {"ts_ms","value"}.
Family defaults to auto (derived per-frame from `char`, falling back to whoop5).
"""

func bytes(fromHex hex: String) -> [UInt8]? {
    let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count % 2 == 0 else { return nil }
    var out = [UInt8](); out.reserveCapacity(s.count / 2)
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        out.append(b); idx = next
    }
    return out
}

enum FamilyMode { case whoop4, whoop5, auto }

func resolveFamily(_ rec: CaptureRecord, _ mode: FamilyMode) -> DeviceFamily {
    switch mode {
    case .whoop4: return .whoop4
    case .whoop5: return .whoop5
    case .auto:
        if let c = rec.char?.lowercased() {
            if c.hasPrefix("fd4b") { return .whoop5 }
            if c.hasPrefix("6108") { return .whoop4 }
        }
        return .whoop5
    }
}

/// Load a capture file and decode every frame into a `ReTools.Record` with the same decoder the app
/// uses (opting into per-field metadata, as the coverage map needs field spans).
func loadRecords(_ path: String, _ family: FamilyMode) -> [ReTools.Record] {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read file: \(path)") }
    let caps: [CaptureRecord]
    do { caps = try JSONDecoder().decode([CaptureRecord].self, from: data) }
    catch { die("could not parse capture JSON \(path): \(error)") }
    var out: [ReTools.Record] = []
    for (n, c) in caps.enumerated() {
        guard let b = bytes(fromHex: c.hex) else {
            FileHandle.standardError.write(Data("skipping bad hex at \(path)[\(n)]\n".utf8)); continue
        }
        let frame = parseFrame(b, family: resolveFamily(c, family), collectFields: true)
        out.append(ReTools.Record(frame: frame, bytes: b, tsMs: c.tsMs, hr: c.hr))
    }
    return out
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    if s.count >= w { return s }
    let fill = String(repeating: " ", count: w - s.count)
    return right ? fill + s : s + fill
}

func fmt(_ d: Double?) -> String {
    guard let d else { return "—" }
    return String(format: "%.4f", d)
}

// MARK: - Arg parsing

var args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { print(helpText); exit(0) }
if sub == "-h" || sub == "--help" { print(helpText); exit(0) }
args.removeFirst()

var family: FamilyMode = .auto
var field: String?
var truthPath: String?
var maxDt = 60_000
var positional: [String] = []

var i = 0
while i < args.count {
    switch args[i] {
    case "--family":
        i += 1; guard i < args.count else { die("--family needs a value") }
        switch args[i] {
        case "whoop4": family = .whoop4
        case "whoop5": family = .whoop5
        case "auto": family = .auto
        default: die("--family must be whoop4|whoop5|auto")
        }
    case "--field":
        i += 1; guard i < args.count else { die("--field needs a value") }; field = args[i]
    case "--truth":
        i += 1; guard i < args.count else { die("--truth needs a value") }; truthPath = args[i]
    case "--max-dt":
        i += 1; guard i < args.count, let v = Int(args[i]) else { die("--max-dt needs an integer (ms)") }; maxDt = v
    case let a where a.hasPrefix("-"): die("unknown option: \(a)")
    default: positional.append(args[i])
    }
    i += 1
}

// MARK: - Subcommands

func requireFile(_ n: Int = 1) {
    guard positional.count >= n else { die("\(sub) needs \(n) FILE argument\(n == 1 ? "" : "s")\n\n\(helpText)") }
}

switch sub {
case "coverage":
    requireFile()
    for g in ReTools.coverage(loadRecords(positional[0], family)) {
        let enc = g.likelyEncrypted ? "  ⚠︎ LIKELY ENCRYPTED/RANDOM" : ""
        print("\(g.key)  —  \(g.frameCount) frames, \(g.frameLen)B, "
              + "\(g.coveredBytes)/\(g.totalBytes) named (\(String(format: "%.0f", g.coveragePct))%), "
              + "unknown entropy \(String(format: "%.2f", g.unknownEntropyBits)) bits/byte/pos "
              + "over \(g.unknownSampleCount) frames\(enc)")
        for b in g.unknownBytes {
            let tag = b.constant ? "constant" : "varies (\(b.distinctValues) distinct)"
            print("      @\(pad(String(b.offset), 4, right: true)) unknown  "
                  + "0x\(String(b.minValue, radix: 16))..0x\(String(b.maxValue, radix: 16))  \(tag)")
        }
    }

case "inventory":
    requireFile()
    print(pad("TYPE/VERSION", 24) + pad("COUNT", 8, right: true) + pad("OK", 8, right: true)
          + pad("CRC", 8, right: true) + pad("LEN", 12, right: true) + "  TS SPAN")
    for g in ReTools.inventory(loadRecords(positional[0], family)) {
        let lenCol = g.minLen == g.maxLen ? "\(g.minLen)" : "\(g.minLen)-\(g.maxLen)"
        let span = (g.firstTsMs != nil && g.lastTsMs != nil) ? "\(g.firstTsMs!)..\(g.lastTsMs!)" : "—"
        print(pad(g.key, 24) + pad(String(g.count), 8, right: true) + pad(String(g.okCount), 8, right: true)
              + pad(String(g.crcOkCount), 8, right: true) + pad(lenCol, 12, right: true) + "  \(span)")
    }

case "diff":
    requireFile(2)
    let a = loadRecords(positional[0], family), b = loadRecords(positional[1], family)
    for g in ReTools.diff(a, b) {
        if !g.inA || !g.inB {
            print("\(g.key)  —  ONLY IN \(g.inA ? "A" : "B")")
            continue
        }
        let lenNote = g.lengthDiffers
            ? "  ⚠︎ LENGTH DIFFERS A=\(g.lenA)B B=\(g.lenB)B — extra bytes on the longer side not compared" : ""
        if g.changedOffsets.isEmpty {
            print("\(g.key)  —  identical value sets\(lenNote.isEmpty ? "" : lenNote)")
            continue
        }
        print("\(g.key)  —  \(g.changedOffsets.count) offset(s) changed\(lenNote)")
        for o in g.changedOffsets {
            let flag = o.disjoint ? "  ⟵ DISJOINT (feature-linked)" : ""
            let named = o.covered ? " [named]" : ""
            print("      @\(pad(String(o.offset), 4, right: true))\(named)  A=\(o.aValues)  B=\(o.bValues)\(flag)")
        }
    }

case "truth":
    requireFile()
    guard let field else { die("truth needs --field NAME") }
    guard let truthPath else { die("truth needs --truth TRUTH.json") }
    guard let tdata = FileManager.default.contents(atPath: truthPath) else { die("cannot read truth: \(truthPath)") }
    let traw: [TruthRecord]
    do { traw = try JSONDecoder().decode([TruthRecord].self, from: tdata) }
    catch { die("could not parse truth JSON: \(error)") }
    let truth = traw.map { ReTools.TruthPoint(tsMs: $0.tsMs, value: $0.value) }
    let s = ReTools.groundTruth(records: loadRecords(positional[0], family), truth: truth,
                                fieldName: field, maxDtMs: maxDt)
    print("field=\(s.fieldName)  matched \(s.n)/\(truth.count) truth points (max Δt \(maxDt)ms)")
    print("  MAE=\(fmt(s.meanAbsError))  bias=\(fmt(s.bias))  Pearson r=\(fmt(s.pearson))")
    for r in s.residuals {
        let dec = r.decoded.map { String(format: "%.3f", $0) } ?? "—(no decode)"
        let dt = r.dtMs == Int.max ? "—(no record carries field)" : "\(r.dtMs)ms"
        print("      ts=\(r.tsMs)  truth=\(String(format: "%.3f", r.truth))  decoded=\(dec)  Δt=\(dt)")
    }

case "gravity2":
    requireFile()
    let reports = ReTools.gravityPair(loadRecords(positional[0], family))
    if reports.isEmpty { print("no records carry both gravity and gravity2 triplets") }
    for g in reports {
        let verdict = g.identicalToPrimary
            ? "IDENTICAL to primary gravity (no new info)" : "DIFFERS from primary — carries something distinct"
        let excl = g.excludedOffWrist > 0 ? "  (\(g.excludedOffWrist) off-wrist excluded)" : ""
        print("\(g.key)  —  \(g.sampleCount) paired samples\(excl)  →  \(verdict)")
        for a in g.axes {
            print("      \(a.axis)  meanG1=\(String(format: "%+.4f", a.meanPrimary))  "
                  + "meanG2=\(String(format: "%+.4f", a.meanSecond))  "
                  + "meanΔ=\(String(format: "%+.4f", a.meanDelta))  "
                  + "max|Δ|=\(String(format: "%.4f", a.maxAbsDelta))  "
                  + "r=\(a.correlation.map { String(format: "%+.3f", $0) } ?? "—")")
        }
    }

default:
    die("unknown subcommand: \(sub)\n\n\(helpText)")
}
