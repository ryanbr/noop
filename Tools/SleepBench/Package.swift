// swift-tools-version:5.9
import PackageDescription

// SleepBench — an offline scoring harness for the sleep stagers.
//
// Replays `SleepStager` (V1) and `SleepStagerV2` over real, already-decoded nights held in a NOOP
// SQLite database and scores each hypnogram against whichever independent references that database
// carries: the wearer's own manual restages (`sleepSession.userEdited = 1`), the strap's own band
// sleep_state (`sleepStateSample`, the v18 @81 high nibble), and Apple Health sleep.
//
// The database path is ALWAYS a command-line argument — no health data lives in this repository, and
// none is ever written back. The tool is read-only (`SQLITE_OPEN_READONLY` + `immutable=1`).
let package = Package(
    name: "sleepbench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
        // For `OuraRespScale` only: the one seam that decides which respiration rows a stager may read.
        // A bench that fed an Oura ring's per-window RATE rows to the stager as if they were a WHOOP's
        // raw ADC waveform would report numbers the app can never produce.
        .package(path: "../../Packages/WhoopStore"),
    ],
    targets: [
        .executableTarget(name: "sleepbench", dependencies: ["StrandAnalytics", "WhoopProtocol", "WhoopStore"]),
        // The scoring primitives are pure functions over label arrays, so they are unit-testable without a
        // database. `swift test` here needs no health data and no `--db` argument.
        .testTarget(name: "sleepbenchTests", dependencies: ["sleepbench"]),
    ]
)
