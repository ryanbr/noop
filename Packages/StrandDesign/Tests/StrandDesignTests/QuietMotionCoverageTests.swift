import XCTest
@testable import StrandDesign

/// A source census: every never-settling animation in the Apple UI must consult the quiet-motion gate.
///
/// This is the Apple twin of Android's `PoseStillCoverageTest` (#911), and it exists for the reason
/// that test gives: a survey done by eye misses surfaces. #909 gated the liquid layer and stopped
/// there, so the day-cycle atmosphere drift, the guardian breath, the two connection-dot halos and
/// the onboarding glows all kept looping in Low Power Mode — and `RecordingStatusLight` looped under
/// system Reduce Motion too, which was already a bug. None of that was visible in review.
///
/// It also pins that the gate keeps reading all three signals. Losing one half is invisible: the
/// screen looks right in whichever mode still works.
///
/// Lives in the StrandDesign package because `swift-packages.yml` runs it by default, while the app
/// targets' `StrandTests` only runs under `xcodebuild` (and `app-build.yml` is disabled).
final class QuietMotionCoverageTests: XCTestCase {

    /// Directories that ship Apple UI. `android/` has its own census in `PoseStillCoverageTest`.
    private static let uiRoots = [
        "Strand",
        "StrandiOS",
        "StrandiOSShared",
        "StrandiOSWidgets",
        "Packages/StrandDesign/Sources",
        "NOOPWatch",
        "NOOPWatchComplications",
    ]

    /// A loop that never settles: an indefinitely repeating implicit animation, or a per-frame
    /// `TimelineView` clock. `TimelineView(.periodic…)` is deliberately NOT censused — a 1 s or 60 s
    /// clock is a label ticking over, not the per-frame drawing this gate exists to stop.
    private static let loopMarkers = ["repeatForever(", "TimelineView(.animation"]

    /// Files allowed to contain a marker without naming the gate, each with the reason.
    private static let exemptions: [String: String] = [
        // Defines `StrandMotion.breathe` (and demonstrates it in a `#if DEBUG` preview). Every
        // shipping call site of it is censused separately by `testBreatheCallSitesConsultTheGate`.
        "Packages/StrandDesign/Sources/StrandDesign/Motion.swift":
            "declares the breathe primitive; call sites are censused separately",
    ]

    private func repoRoot() throws -> URL {
        // .../Packages/StrandDesign/Tests/StrandDesignTests/QuietMotionCoverageTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StrandDesignTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // StrandDesign
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
        // FAIL rather than skip when the tree cannot be found: a census that silently passes because
        // it censused nothing is worse than no census (the Android twin makes the same choice).
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) else {
            throw Failure("repo root not found from #filePath (looked at \(root.path))")
        }
        return root
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private func swiftFiles(under root: URL) -> [(rel: String, text: String)] {
        var out: [(String, String)] = []
        for dir in Self.uiRoots {
            let base = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                out.append((rel, text))
            }
        }
        return out
    }

    /// Strip `//` line comments so a marker merely *described* in prose is not censused as code.
    private func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }
    }

    // MARK: - The census

    func testEveryNeverSettlingAnimationConsultsTheQuietMotionGate() throws {
        let root = try repoRoot()
        let files = swiftFiles(under: root)
        XCTAssertGreaterThan(files.count, 100, "census found almost no Swift — the roots are wrong")

        var offenders: [String] = []
        var censused = 0
        for (rel, text) in files {
            let code = codeLines(text)
            let hits = code.enumerated().filter { _, line in
                Self.loopMarkers.contains { line.contains($0) }
            }
            guard !hits.isEmpty else { continue }
            censused += 1
            if Self.exemptions[rel] != nil { continue }
            guard !text.contains("NoopMotionState") else { continue }
            for (i, line) in hits {
                offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // The census must actually find the known loops; a zero-hit run means the markers drifted.
        XCTAssertGreaterThanOrEqual(censused, 6, "expected to census the known frame loops, found \(censused)")
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) never-settling animation(s) do not consult NoopMotionState. Gate them \
            with `motion.poseStill(reduceMotion)`, or add the file to `exemptions` WITH a reason:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// `StrandMotion.breathe` is the shared `repeatForever` primitive, so a call site can loop forever
    /// without the marker appearing on its own line. Census the call sites too.
    func testBreatheCallSitesConsultTheGate() throws {
        let root = try repoRoot()
        var offenders: [String] = []
        var sites = 0
        for (rel, text) in swiftFiles(under: root) where rel != "Packages/StrandDesign/Sources/StrandDesign/Motion.swift" {
            // The call site must name the composed condition AND the file must reach the shared
            // monitor — checking only for the token would pass a `poseStill` that is a local alias
            // for `reduceMotion`, which is exactly the state this change is fixing.
            let reachesMonitor = text.contains("NoopMotionState")
            for (i, line) in codeLines(text).enumerated() where line.contains("StrandMotion.breathe") {
                sites += 1
                if !line.contains("poseStill") || !reachesMonitor {
                    offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(sites, 0, "no StrandMotion.breathe call sites censused — the marker drifted")
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) StrandMotion.breathe call site(s) are gated on Reduce Motion alone (or \
            not at all). Pass the composed `poseStill` instead:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - The gate itself

    /// Losing one signal is invisible in the app — the screen looks right in whichever mode still
    /// works — so pin that all three are read, and that the OS flag stays live.
    func testGateReadsAllThreeSignalsAndStaysLive() throws {
        let root = try repoRoot()
        let src = try String(contentsOf: root.appendingPathComponent(
            "Packages/StrandDesign/Sources/StrandDesign/NoopMotion.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("reduceMotion || isLowPower || quietMotion"),
                      "poseStill must OR all three signals")
        XCTAssertTrue(src.contains("isLowPowerModeEnabled"), "must read Low Power Mode")
        XCTAssertTrue(src.contains("NSProcessInfoPowerStateDidChange"),
                      "Low Power Mode must stay live without a relaunch")
        XCTAssertTrue(src.contains("UserDefaults.didChangeNotification"),
                      "the in-app toggle must stay live — @AppStorage writes straight to UserDefaults")
        // The key string is the cross-platform contract — it travels in .noopbak by key, not by symbol
        // name — so it is pinned here even though Android has not adopted it yet (#941). Pinning it now is
        // the point: whoever writes the Kotlin side must match this string exactly, and a later edit here
        // would silently break a round-trip that by then has real users.
        XCTAssertEqual(QuietMotionPrefs.enabledKey, "noop.quietMotion",
                       "the key Android must adopt verbatim when the third signal lands (#941)")
    }

    /// Posing the picture still while the sensor keeps running saves nothing. `onDisappear` is not
    /// called when the app is backgrounded, and NOOP declares background modes, so without an
    /// explicit app-boundary stop a decorative 60 Hz device-motion feed ran all day behind the lock
    /// screen.
    func testDecorativeMotionSensorStopsAtTheAppBoundary() throws {
        let root = try repoRoot()
        let src = try String(contentsOf: root.appendingPathComponent(
            "Strand/Liquid/LiquidCore.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("startDeviceMotionUpdates"), "this file owns the decorative sensor")
        XCTAssertTrue(src.contains("didEnterBackgroundNotification"),
                      "the sensor must stop when the app leaves the foreground")
        XCTAssertTrue(src.contains("stopDeviceMotionUpdates"), "and must actually stop it")
        XCTAssertTrue(src.contains("LiquidMotion.quietNow"),
                      "starting the sensor must consult the quiet-motion gate, not only the view branch")
    }
}
