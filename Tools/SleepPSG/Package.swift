// swift-tools-version:5.9
import PackageDescription

// SleepPSG — score `SleepStagerV2` against POLYSOMNOGRAPHY truth.
//
// `Tools/SleepBench` replays the stagers against the references a wearer's own database carries: their
// manual restages, the strap's band `sleep_state`, Apple Health. Every one of those is either the recipe's
// own output fed back to it, or another vendor's black box. None of them is truth.
//
// This tool supplies the missing reference. It replays the SHIPPED `SleepStagerV2` over PhysioNet
// `sleep-accel` (Walch et al., SLEEP 2019) — 31 subjects of wrist accelerometer + heart rate with
// concurrent, human-scored PSG hypnograms — and scores it epoch-for-epoch against those hypnograms.
//
// The dataset is NEVER committed and is ALWAYS a command-line argument (`--dataset`). See README.md for
// the download step and the licence attribution both the dataset and its companion code require.
//
// Nothing here reads or writes a NOOP database, and no health data of any wearer's lives in this repo.
let package = Package(
    name: "sleeppsg",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "sleeppsg", dependencies: ["StrandAnalytics", "WhoopProtocol"]),
        // The port-equivalence check and every scoring primitive are pure functions — they need neither the
        // dataset nor a database, so `swift test` here runs anywhere the packages build, with no arguments
        // and no downloads. That is deliberate: the check that keeps this harness honest (the recipe port
        // reproducing the shipped stager label-for-label) has to run in CI, where the dataset never exists.
        .testTarget(name: "sleeppsgTests", dependencies: ["sleeppsg"]),
    ]
)
