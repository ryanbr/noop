import Foundation
import OuraProtocol

// oura-decode: replay captured raw Oura records into decoded events with the SAME OuraProtocol
// decoder the macOS/iOS app uses, from the command line on any platform (Linux included). This is the
// headless protocol-RE workflow's Swift half: a capture tool records raw TLV records off a ring into a
// capture JSON file, and this decodes them, guaranteeing the RE path and the app agree byte for byte
// (no second decoder to drift). Mirrors whoop-decode.
//
// Usage:
//   oura-decode [options] [FILE]
//   cat capture.json | oura-decode --gen gen3
//   oura-decode --hex 600e0100000000010401000000000000
//
// Input (any one of):
//   FILE            a capture/fixture JSON file: an array of {"hex": ...} objects. The richer capture
//                   format ({"hex","kind","ts_ms"}) is a superset and is read too.
//   (stdin)         the same JSON, piped in, when no FILE is given.
//   --hex HEX ...   one or more raw record hex strings instead of a file.
//
// Options:
//   --gen G         gen3 | gen4 | gen5   (default: gen3, the verified-corpus generation)
//   --allow-tier-b  also decode Tier-B (UNVERIFIED) tags. OFF by default so Tier-B never ships values.
//   --json          emit decoded events as JSON instead of a text dump
//   -h, --help      show this help

// MARK: - Input model

/// One input record. `hex` is required; `kind`/`tsMs` are provenance the decoder ignores.
struct CaptureRecord: Decodable {
    let hex: String
    let kind: String?
    let tsMs: Int?
    enum CodingKeys: String, CodingKey { case hex, kind; case tsMs = "ts_ms" }
}

// MARK: - Arg parsing (dependency-free)

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let helpText = """
oura-decode: decode captured Oura records with the OuraProtocol decoder.

USAGE:
  oura-decode [--gen gen3|gen4|gen5] [--allow-tier-b] [--json] [FILE]
  cat capture.json | oura-decode --gen gen3
  oura-decode --hex 600e0100000000010401000000000000

Reads a capture/fixture JSON array of {"hex": ...} from FILE or stdin, or raw
records from --hex. Generation defaults to gen3. Tier-B (UNVERIFIED) tags are
dropped unless --allow-tier-b is passed, so unverified layouts never feed values.
"""

var gen: OuraRingGen = .gen3
var allowTierB = false
var jsonOut = false
var hexArgs: [String] = []
var filePath: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        print(helpText); exit(0)
    case "--json": jsonOut = true
    case "--allow-tier-b": allowTierB = true
    case "--gen":
        i += 1
        guard i < args.count else { die("--gen needs a value") }
        switch args[i] {
        case "gen3": gen = .gen3
        case "gen4": gen = .gen4
        case "gen5": gen = .gen5
        default: die("--gen must be gen3|gen4|gen5")
        }
    case "--hex":
        i += 1
        while i < args.count && !args[i].hasPrefix("--") {
            hexArgs.append(args[i]); i += 1
        }
        continue
    default:
        if a.hasPrefix("-") { die("unknown option: \(a)") }
        filePath = a
    }
    i += 1
}

// MARK: - Gather input records

func loadJSON(_ data: Data) -> [CaptureRecord] {
    do {
        return try JSONDecoder().decode([CaptureRecord].self, from: data)
    } catch {
        die("could not parse capture JSON: \(error)")
    }
}

var records: [CaptureRecord] = []
if !hexArgs.isEmpty {
    records = hexArgs.map { CaptureRecord(hex: $0, kind: nil, tsMs: nil) }
} else if let path = filePath {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read file: \(path)") }
    records = loadJSON(data)
} else {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { die(helpText) }
    records = loadJSON(data)
}

// MARK: - Decode helpers

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

/// Left- or right-justify `s` to `width` with spaces (manual, to avoid String(format:) on Linux).
func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    if s.count >= width { return s }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

/// A one-line human description of a decoded event.
func describe(_ e: OuraEvent) -> String {
    switch e {
    case .hr(let v): return "HR bpm=\(v.bpm) ibi=\(v.ibiMs)ms rt=\(v.ringTimestamp)"
    case .ibi(let v): return "IBI \(v.ibiMs)ms amp=\(v.amplitude.map(String.init) ?? "-") rt=\(v.ringTimestamp)"
    case .hrv(let v): return "HRV idx=\(v.index) hr=\(v.hrBpm)bpm rmssd=\(v.rmssdMs)ms rt=\(v.ringTimestamp)"
    case .spo2(let v): return "SPO2 \(v.value) (\(v.unit)) rt=\(v.ringTimestamp)"
    case .temp(let v): return "TEMP \(v.celsius)C rt=\(v.ringTimestamp)"
    case .battery(let v): return "BATTERY \(v.percent)% mv=\(v.voltageMv.map(String.init) ?? "-")"
    case .sleepPhase(let v): return "SLEEP_PHASE [\(v.index)]=\(v.stage) rt=\(v.ringTimestamp)"
    case .motion(let v): return "MOTION [\(v.index)]=\(v.state) rt=\(v.ringTimestamp)"
    case .motionEvent(let v): return "MOTION_EVENT orient=\(v.orientation) motionS=\(v.motionSeconds) xyz=(\(v.avgX),\(v.avgY),\(v.avgZ)) lo=\(v.lowIntensity.map(String.init) ?? "-") hi=\(v.highIntensity.map(String.init) ?? "-") rt=\(v.ringTimestamp)"
    case .state(let v): return "STATE code=\(v.stateCode) text=\(v.text ?? "-") rt=\(v.ringTimestamp)"
    case .timeSync(let v): return "TIME_SYNC epochMs=\(v.epochMs) tz=\(v.tzOffsetSeconds)s"
    case .rtcBeacon(let v): return "RTC_BEACON unix=\(v.unixSeconds)"
    case .debugText(_, let t): return "DEBUG \(t)"
    case .tierB(let v): return "TIER_B[UNVERIFIED] tag=0x\(String(v.tag, radix: 16)) kind=\(v.kind) bytes=\(v.rawPayload.count)"
    case .activityInfo(let v): return "ACTIVITY[TIER-B,UNVERIFIED] state=\(v.state) met=\(v.met) rt=\(v.ringTimestamp)"
    }
}

// MARK: - Run

let driver = OuraDriver(ringGen: gen, authKey: nil, allowTierB: allowTierB)
let reassembler = OuraReassembler()

struct JSONLine: Encodable { let index: Int; let kind: String; let detail: String }
var jsonLines: [JSONLine] = []
var total = 0
var decodedCount = 0
var tagCounts: [String: Int] = [:]

for (n, rec) in records.enumerated() {
    guard let raw = bytes(fromHex: rec.hex) else {
        FileHandle.standardError.write(Data("skipping bad hex at index \(n)\n".utf8))
        continue
    }
    total += 1
    let events = driver.ingest(notification: raw, reassembler: reassembler)
    if events.isEmpty {
        // Show the raw tag so an undecoded record is visible (the RE worklist), without guessing.
        let tagHex = raw.first.map { "0x" + String($0, radix: 16) } ?? "?"
        tagCounts["undecoded(\(tagHex))", default: 0] += 1
        if !jsonOut {
            print("[\(n)] gen=\(gen.rawValue) tag=\(tagHex) -> (no event)")
        } else {
            jsonLines.append(JSONLine(index: n, kind: "undecoded", detail: tagHex))
        }
        continue
    }
    for e in events {
        decodedCount += 1
        let line = describe(e)
        let key = line.split(separator: " ").first.map(String.init) ?? "?"
        tagCounts[key, default: 0] += 1
        if jsonOut {
            jsonLines.append(JSONLine(index: n, kind: key, detail: line))
        } else {
            print("[\(n)] " + line)
        }
    }
}

if jsonOut {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? enc.encode(jsonLines), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
} else {
    var summary = "\n\(decodedCount) events from \(total) records (tier-b \(allowTierB ? "on" : "off"))\n"
    for (t, c) in tagCounts.sorted(by: { $0.value > $1.value }) {
        summary += "  \(pad(String(c), 5, right: true))  \(t)\n"
    }
    FileHandle.standardError.write(Data(summary.utf8))
}
