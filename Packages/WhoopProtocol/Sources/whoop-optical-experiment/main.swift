import Foundation
import WhoopProtocol

let help = """
whoop-optical-experiment — compare WHOOP 5/MG v20 optical blocks across marked phases.

USAGE:
  whoop-optical-experiment [--compact] [--settling-seconds N] FILE
  cat puffin-deepbuffers.jsonl | whoop-optical-experiment

Reads NOOP's append-only deep-buffer JSONL, attributes each v20 frame using its strap timestamp
(not delayed log-arrival time), and emits a JSON report containing per-phase block/header/channel
statistics plus adjacent-phase deltas. It does not assign LED wavelengths or calculate SpO2/BP.
The CLI excludes the first 10 seconds after each marker by default so physical transitions do not
contaminate a phase; pass --settling-seconds 0 to retain every frame.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var compact = false
var settlingSeconds = 10
var filePath: String?
let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "-h", "--help":
        print(help)
        exit(0)
    case "--compact":
        compact = true
    case "--settling-seconds":
        index += 1
        guard index < arguments.count,
              let value = Int(arguments[index]), value >= 0 else {
            fail("--settling-seconds needs a non-negative integer")
        }
        settlingSeconds = value
    default:
        if argument.hasPrefix("-") { fail("unknown option: \(argument)") }
        if filePath != nil { fail("only one input file is supported") }
        filePath = argument
    }
    index += 1
}

let data: Data
if let filePath {
    guard let loaded = FileManager.default.contents(atPath: filePath) else {
        fail("cannot read file: \(filePath)")
    }
    data = loaded
} else {
    data = FileHandle.standardInput.readDataToEndOfFile()
}
guard !data.isEmpty else { fail(help) }
guard let jsonl = String(data: data, encoding: .utf8) else { fail("input is not valid UTF-8") }

let report = Whoop5OpticalExperimentAnalyzer.analyze(
    jsonl: jsonl, settlingSeconds: settlingSeconds)
let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
do {
    let encoded = try encoder.encode(report)
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("could not encode report: \(error)")
}
