import Foundation
import StrandAnalytics
import WhoopStore

/// Assembles the Test Centre export bundle: gathers report.txt, meta.json, raw-capture and last-crash,
/// runs the redaction pass over EVERY file, applies the 20 MB cap, and hands the entries to
/// FileExport.exportBundle. This is the orchestrator behind the Report button.
///
/// The CRITICAL fix (spec section 5.3): today only the append(log:) sink scrubs (LiveState.swift:308),
/// so a serial embedded in raw-capture console text would ship unredacted. We re-run LiveState.redactPii
/// over every entry's text here, the single scrub point, and stamp meta.redaction = "v2" so a maintainer
/// can trust the scrub. Redaction stays the only scrub point; we just guarantee it covers the whole bundle.
enum TestBundleAssembler {

    /// The redaction stamp written into meta.json so a maintainer knows the whole-bundle scrub ran.
    static let redactionVersion = "v2"

    /// The bundle's hard byte cap (spec section 5.4; under GitHub's 25 MB attachment limit). Shared by
    /// `capEntries` (what finally ships) and `ouraDiagnosticEntries` (how much it is worth reading), so the
    /// read ceiling can never drift above the budget it feeds.
    static let defaultCapBytes = 20 * 1024 * 1024

    /// The Oura Diagnostics-dir sidecar kinds the bundle attaches — the SINGLE source of truth
    /// `normalizedOuraEntryName`/`ouraDiagnosticEntries`/`trimmableNames`/`ouraSidecarNames` all derive
    /// from, so a new dump writer (`Strand/BLE/Oura*Dump.swift`) needs exactly one line added here to be
    /// picked up everywhere instead of silently missing the export bundle. (Landed after `cva-ppg` and
    /// `real-steps` shipped their writers but not their kind entry — both wrote real files on-device that
    /// the bundler's hardcoded 3-kind list then dropped from every export.)
    static let ouraSidecarKinds: [String] = ["raw", "ibihr", "activity", "cva-ppg", "motion", "real-steps"]

    /// The bundle files that may be trimmed to fit the cap (newest-tail kept). The strap-log tail and
    /// meta.json are already bounded, so only these raw research streams can blow the budget: the WHOOP
    /// frame capture plus the Oura ring's Tier-B JSONL sidecars (raw notifications / IBI-HR / activity MET /
    /// CVA-PPG / motion / real-steps). Everything NOT listed here is kept whole and its bytes are reserved
    /// before the trimmable group is given the remainder. NORMALIZED entry names (ring id dropped).
    static let trimmableNames: Set<String> = Set(["raw-capture.jsonl"] + ouraSidecarKinds.map { "oura-\($0).jsonl" })

    /// #572 follow-up: the Oura Tier-B sidecars carry the ring id in a `"deviceId"` JSON field. The
    /// whole-bundle UUID scrub (`LiveState.redactPii`) masks it only when it is a CANONICAL dashed
    /// `uuidString`; a dashless or truncated id would leak verbatim into a bundle the user shares. For these
    /// sidecars we ALSO mask the `deviceId` VALUE by field name — format-independent, so any id shape is
    /// covered, and (unlike broadening the UUID regex to dashless hex) it CANNOT touch the raw `hex` capture
    /// field, which a greedier rule would shred. Scoped to the sidecars so a non-PII logical `deviceId`
    /// (e.g. "my-whoop") elsewhere in the bundle stays readable. NORMALIZED names (ring id already dropped).
    static let ouraSidecarNames: Set<String> = Set(ouraSidecarKinds.map { "oura-\($0).jsonl" })

    /// `oura-raw.jsonl` is the ONE sidecar whose payload is nothing but hex (`OuraRawDumpLine.encode`) —
    /// `oura-ibihr.jsonl`/`oura-activity.jsonl` encode DECODED numeric fields, so `LiveState.redactHexDump`'s
    /// byte-run heuristic below never sees a hex blob long enough to false-positive on. Only `raw` needs the
    /// exemption `redactEntries` applies via this set.
    private static let rawHexSidecarNames: Set<String> = ["oura-raw.jsonl"]

    /// Re-run the redaction sink over every entry. Text entries are decoded as UTF-8, scrubbed via the same
    /// LiveState.redactPii used by the live sink, and re-encoded. A non-UTF-8 entry (none today) passes
    /// through untouched rather than risk corrupting binary. meta.json and report.txt have no PII shapes so
    /// they pass through byte-identical; raw-capture is where the embedded serials live.
    ///
    /// `oura-raw.jsonl` skips the `redactPii` sweep entirely (see `rawHexSidecarNames`) — its `hex` field is
    /// the ring's UNDECODED TLV bytes, and `redactPii`'s `redactHexDump` helper (built for #1833: a WHOOP
    /// serial hiding as ASCII inside a hex-dumped console line) decodes hex back to bytes and masks any 9+
    /// byte run that spells alnum ASCII starting with a letter. Every Oura record is nothing but such runs,
    /// so that heuristic fires on ordinary sensor bytes and on the `0x43`/`0x61` debug-text channel (ASCII by
    /// design) — found 2026-09-11 via a real user capture: 38 of 3112 lines had bytes silently replaced with
    /// `•` placeholders that are not even valid hex, breaking any offline tool that reframes the file. The
    /// actual identity leak this heuristic was hoped to also catch here — the ring's SERIAL, arriving in
    /// plain digits via a `0x18`/`0x19` GetProductInfo reply — is invisible to it anyway (no letter in an
    /// all-numeric run), and is instead filtered at the SOURCE by `OuraLiveSource.rawDumpBytes` before the
    /// frame ever reaches this file. The `deviceId` field mask below still runs unconditionally, so the one
    /// piece of identity `oura-raw.jsonl`'s JSON envelope carries is still scrubbed.
    static func redactEntries(_ entries: [FileExport.BundleEntry]) -> [FileExport.BundleEntry] {
        entries.map { entry in
            guard let text = String(data: entry.data, encoding: .utf8) else { return entry }
            var scrubbed = rawHexSidecarNames.contains(entry.name) ? text : LiveState.redactPii(text)
            // #572 follow-up: field-aware deviceId mask for the Oura sidecars (see `ouraSidecarNames`). Runs
            // AFTER redactPii, so it catches a non-canonical id that the dash-anchored UUID rule misses; on an
            // already-canonical id redactPii turned into `<device>`, this is a no-op. Key-anchored to
            // "deviceId", so it never touches the raw `hex` field. `[^"]*` stops at the value's closing quote.
            if ouraSidecarNames.contains(entry.name) {
                scrubbed = scrubbed.replacingOccurrences(
                    of: "(\"deviceId\"\\s*:\\s*\")[^\"]*(\")",
                    with: "$1<device>$2", options: .regularExpression)
            }
            return FileExport.BundleEntry(name: entry.name, data: Data(scrubbed.utf8))
        }
    }

    /// Hard cap the bundle at `capBytes` (20 MB default, under GitHub's 25 MB; spec section 5.4). The
    /// strap-log tail and meta.json are already bounded, so only the `trimmableNames` research streams can
    /// exceed. We reserve the whole size of every non-trimmable file, then share the remaining budget across
    /// the trimmable files, keeping the MOST-RECENT tail of each (newest data is the most diagnostic) and
    /// trimming from the front. Returns the capped entries plus whether any truncation happened, which the
    /// caller writes to meta.truncated.
    ///
    /// ALLOCATION: **max-min fair** (water-filling), NOT proportional-to-size. Each stream is offered an
    /// equal share of what is left; a stream smaller than its share is kept WHOLE and its unused remainder
    /// flows to the streams that are still over. See `fairAllowances` for why, and for the measured export
    /// that motivated it. With a single trimmable file this is still identical to the original
    /// raw-capture-only behaviour: its share is the whole remainder.
    static func capEntries(_ entries: [FileExport.BundleEntry],
                           capBytes: Int = defaultCapBytes) -> (entries: [FileExport.BundleEntry], truncated: Bool) {
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total > capBytes else { return (entries, false) }
        // Reserve the non-trimmable files (kept whole), then share the remainder across the trimmable ones.
        let nonTrimmable = entries.filter { !trimmableNames.contains($0.name) }.reduce(0) { $0 + $1.data.count }
        let budget = max(0, capBytes - nonTrimmable)
        let allowance = fairAllowances(
            sizes: entries.filter { trimmableNames.contains($0.name) }.map { ($0.name, $0.data.count) },
            budget: budget)
        var truncated = false
        let capped = entries.map { entry -> FileExport.BundleEntry in
            guard trimmableNames.contains(entry.name) else { return entry }
            let share = allowance[entry.name] ?? 0
            guard entry.data.count > share else { return entry }
            truncated = true
            // Keep the tail (most recent): the last `share` bytes, then snap forward to the next full
            // JSONL line. A raw byte-count tail can (and in production did - a real export shipped
            // oura-cva-ppg.jsonl/oura-real-steps.jsonl/oura-motion.jsonl each with a corrupted first
            // line) land mid-record; every trimmable name is newline-delimited JSONL, so dropping the
            // partial line at the front keeps every kept line honest.
            return FileExport.BundleEntry(name: entry.name,
                                          data: Self.trimToLineBoundary(entry.data.suffix(share)))
        }
        return (capped, truncated)
    }

    /// Split `budget` bytes across the named streams **max-min fairly**: walk them smallest-first, offering
    /// each an equal share of whatever budget remains, and let a stream that fits under its share take only
    /// what it needs so the surplus rolls forward to the larger ones. Integer floor keeps the sum at or under
    /// `budget`, so the bundle can never breach the cap. Pure; `sizes` order does not affect the result.
    ///
    /// WHY NOT PROPORTIONAL-TO-SIZE (the original rule): it hands the budget to the BULKIEST stream, and for
    /// these sidecars bulk is close to inversely correlated with diagnostic value. Measured on a real export
    /// (`noop-master-iOS-v9.3.1-260809-0716.zip`, six trimmable sidecars over a 20,863,648-byte budget):
    /// `oura-spo2.jsonl` — a per-sample dump whose values are also in the SQLite the same bundle ships —
    /// took **53.9 %**, while `oura-raw.jsonl` got **1.9 %** (388,064 bytes: 8 min 43 s of an 8.4 h night).
    /// The raw sidecar is the UNDECODED wire bytes, the one file in the bundle from which a protocol fact can
    /// be re-derived independently of our own decoder, so starving it costs a night of verification that
    /// nothing else can supply. Under this rule the ~3.47 MB fair share keeps it whole and the surplus goes
    /// where it is merely bulk. Same 20 MB bundle, no editorial ranking of the streams.
    static func fairAllowances(sizes: [(name: String, bytes: Int)], budget: Int) -> [String: Int] {
        // Smallest-first, name-tiebroken so the result is deterministic regardless of input order.
        let ordered = sizes.sorted { $0.bytes != $1.bytes ? $0.bytes < $1.bytes : $0.name < $1.name }
        var allowance: [String: Int] = [:]
        var left = max(0, budget)
        var unserved = ordered.count
        for stream in ordered {
            let share = unserved > 0 ? left / unserved : 0
            let give = min(max(0, stream.bytes), share)
            allowance[stream.name] = give
            left -= give
            unserved -= 1
        }
        return allowance
    }

    /// Drop bytes up to and including the first newline in `data`, so a raw byte-count tail (from
    /// `capEntries`'s fair-share trim) never starts mid-line for a newline-delimited JSONL sidecar.
    /// Returns `data` unchanged when it contains no newline (a single very-long line, or already empty)
    /// - never worse than the untrimmed behaviour, just not improved. Pure/testable.
    static func trimToLineBoundary(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        let start = data.index(after: newline)
        return data.subdata(in: start..<data.endIndex)
    }

    // MARK: - assemble (the entrypoint behind the Report button, the Group D integration seam)

    /// The build channel string for meta.json. Sideloaded iOS reads "sideload" with `signed=false`; an
    /// App Store / TestFlight iOS install reads "App Store"; macOS and Android are fixed per flavour. We
    /// never fabricate: the iOS read derives from IOSDiagnostics.isSideloaded.
    private static func buildProvenance() -> TestBundleMeta.Build {
        #if os(iOS)
        let sideloaded = IOSDiagnostics.capture().isSideloaded ?? true
        return TestBundleMeta.Build(channel: sideloaded ? "sideload" : "App Store", signed: !sideloaded)
        #elseif os(macOS)
        // The macOS build ships unsigned/un-notarized for anonymity (it's distributed via GitHub / brew).
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #else
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #endif
    }

    /// Gather the report files for `profile`, redact EVERY file, cap the bundle, then build and append
    /// meta.json (carrying the truncated flag from the cap) and redact-pass it too. Returns the final,
    /// already-redacted + already-capped entries ready for FileExport.exportBundle.
    ///
    /// Group B left this entrypoint to Group D (the Test Centre IA) on purpose: it is the one place that
    /// reaches into the live app (LiveState, TestCentre, the diagnostics) to gather the actual bytes, so
    /// it lives with the screen that binds the Report button. The pure primitives (redactEntries,
    /// capEntries) stay where Group B shipped them; this just composes them in the canonical order.
    /// `storage` / `strapModel` (#1002): the REAL probes, gathered async by TestCentreReport (the DB file
    /// size + per-table row counts come off the store actor, so the sync assembler can't read them
    /// itself). nil means the probe could not run (store unopenable) - meta then carries the zeroed
    /// block, which stays honest: zeros are "nothing readable", never a made-up figure.
    @MainActor
    static func assemble(profile: TestDomain, live: LiveState,
                         storage: TestBundleMeta.Storage? = nil,
                         strapModel: String? = nil) -> [FileExport.BundleEntry] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif

        // 0. The universal clock-drift line (RTC cluster #531/#767/#804/#812): rides EVERY export so a
        //    clock-broken strap self-diagnoses on a Sleep / Battery / any-mode report, not only in Connection
        //    mode. Built from the strap-range snapshot BLEManager banked (LiveState.strapRange). Appended to
        //    the report body BEFORE the completeness scan so its `dayOwner`-sibling token is part of the text
        //    the guard reads. No-op when no range was ever seen this session (no strap reply yet).
        let baseReport = live.exportableLogText()
        // #2117: both universal lines ride every export, appended in a fixed order so two reports from
        // the same strap diff cleanly. Either may be absent (no range reported yet; a device the WHOOP 5
        // unit policy does not govern), and an absent line is simply omitted rather than stubbed, so a
        // WHOOP 4 report is byte-unchanged by this existing.
        let universalLines = [
            universalClockDriftLine(range: live.strapRange),
            universalRRTransportLine(transport: live.rrTransport),
        ].compactMap { $0 }
        let reportText = universalLines.isEmpty
            ? baseReport
            : baseReport + universalLines.map { "\n[universal] " + $0 }.joined()

        // 1. report.txt: the same exportable strap log the strap-log card shares, plus the universal
        //    clock-drift line. Already redacted by the append(log:) sink, but the whole-bundle redactEntries
        //    pass below re-scrubs it anyway (5.3).
        let reportEntry = FileExport.BundleEntry(name: "report.txt", data: Data(reportText.utf8))

        // 1b. Display & Performance: capture a screenshot for the .display profile (or any mode that
        //     declares includesScreenshot) as screenshot.png. The PNG is BINARY image bytes, not text, so it
        //     is kept OUT of the redactEntries pass on purpose: redaction scrubs text identifiers, never
        //     pixels (running raw PNG bytes through a UTF-8 decode/scrub would corrupt them). The screenshot
        //     is still covered by the mandatory review-before-share gate (nothing ships until the user taps
        //     Share), which the gate's note calls out. A capture only happens for the gated profile, so a
        //     non-display report never grabs a shot.
        let wantsShot = profile == .display
            || (TestModeRegistry.mode(profile)?.includesScreenshot ?? false)
        let shot: FileExport.BundleEntry? = wantsShot
            ? DisplayScreenshot.capturePNG().map { FileExport.BundleEntry(name: DisplayScreenshot.bundleName, data: $0) }
            : nil

        // 1c. raw-capture.jsonl: the on-device raw frame capture (when enabled in Settings -> Experimental),
        //     read from disk by URL. It is TEXT (JSON lines) where embedded console strings can carry a
        //     serial, so it IS run through the redactEntries pass below (the #1 reason the whole-bundle scrub
        //     exists, 5.3). Attached only when the file exists; a non-capturing install ships no raw entry.
        let rawCapture: FileExport.BundleEntry? = live.puffinCaptureURL
            .flatMap { fileEntry(at: $0, name: "raw-capture.jsonl") }

        // 1d. last-crash.txt: the most recent crash report, when one is present on disk. It is TEXT, so it
        //     ALSO rides the redactEntries pass. There is no crash producer wired yet, so this is normally
        //     absent; the lookup is a no-op then. Pluggable via `crashLogURL` so a future crash handler need
        //     only drop a file at the known path for it to start attaching, fully redacted, automatically.
        let crash: FileExport.BundleEntry? = crashLogURL()
            .flatMap { fileEntry(at: $0, name: "last-crash.txt") }

        // 1e. Oura ring diagnostics: the Tier-B JSONL sidecars (raw notifications / IBI-HR / activity MET)
        //     the ring writes to <App Support>/OpenWhoop/Diagnostics whenever it connects. Attached WHEN
        //     PRESENT — exactly like raw-capture.jsonl, NOT behind a test domain: they cut across Sleep /
        //     HRV / Connection / Sources, and file presence is the honest gate (no ring used → no files →
        //     nothing attached, so an Experimental ring needs no separate brand check here). They are TEXT
        //     (JSON lines) whose only PII is the ring UUID inside each line, which the redactEntries pass
        //     below masks to <device>; the ENTRY name is normalized (id dropped) since redaction never
        //     touches names. Trimmed to the cap alongside raw-capture via `trimmableNames`.
        let ouraDiagnostics = ouraDiagnosticEntries()

        // 2. Redact the TEXT files (report.txt, raw-capture.jsonl, last-crash.txt, oura-*.jsonl), then cap. The screenshot
        //    is included in the cap input (NOT the redact input) so its bytes COUNT against the 20 MB cap:
        //    capEntries budgets raw-capture as capBytes - (everything else), so a large/retina PNG shrinks
        //    the raw-capture tail rather than breaching the cap. Only raw-capture is trimmed; report.txt and
        //    last-crash are bounded and the PNG is kept whole.
        let textEntries = [reportEntry] + (rawCapture.map { [$0] } ?? []) + (crash.map { [$0] } ?? []) + ouraDiagnostics
        let redacted = redactEntries(textEntries)
        let (capped, truncated) = capEntries(redacted + (shot.map { [$0] } ?? []))
        var entries = capped

        // 2b. REPORT-COMPLETENESS GUARD (#812, generalised): for each domain ACTIVE during this capture,
        //     scan the redacted report.txt for its killer-trace token(s) and produce OK / INCOMPLETE. This
        //     makes a thin/empty report self-evident at submit time (the section is in the report the review
        //     gate shows) and names WHICH capture failed. Run over the REDACTED report so it sees exactly the
        //     bytes that ship. `.universal` is graded whenever any mode was active (the dayOwner +
        //     clock-drift lines ride every export). Re-read the redacted report.txt from `capped` so the scan
        //     and the shipped text can never diverge.
        let redactedReport = capped.first { $0.name == "report.txt" }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? reportText
        let active = activeDomains()
        let checks = CaptureCompleteness.evaluate(activeDomains: active, reportText: redactedReport)
        let section = CaptureCompleteness.reportSection(checks)
        if !section.isEmpty {
            // Append the Capture-check section to the shipped report.txt and re-redact (the section carries
            // no PII shapes, so the scrub is byte-identical, but it keeps the single-scrub-point invariant).
            let appended = redactedReport + "\n" + section
            entries = entries.map { e in
                e.name == "report.txt"
                    ? redactEntries([FileExport.BundleEntry(name: "report.txt", data: Data(appended.utf8))])[0]
                    : e
            }
        }

        // 3. meta.json: the machine-readable tie. The questionnaire answers are whatever the tester saved
        //    for this profile; profileStartedAt is ISO8601 from TestCentre. Storage + strapModel (#1002)
        //    are the caller's REAL probes (Phase 1 shipped hardcoded zeros here, so every meta.json read
        //    "db_bytes: 0" even on a multi-GB library and maintainers triaged blind); a nil probe falls
        //    back to the zeroed block - zeros mean "unreadable", we still never fabricate. The
        //    capture_check field carries the same OK/INCOMPLETE verdicts as the report section.
        let started = TestCentre.startedAt(profile).map { ISO8601DateFormatter().string(from: $0) }
        let meta = TestBundleMeta(
            schema: 1,
            appVersion: version,
            platform: platform,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            strapModel: strapModel,
            source: ["Live Bluetooth"],
            testProfile: profile.id,
            profileStartedAt: started,
            questionnaire: TestCentre.answers(profile),
            build: buildProvenance(),
            storage: storage ?? TestBundleMeta.Storage(dbBytes: 0, rows: [:], rawCaptureBytes: 0, rowBytes: [:]),
            redaction: redactionVersion,
            truncated: truncated,
            captureCheck: checks)

        // meta.json has no PII shapes, so the redact pass leaves it byte-identical, but we route it through
        // the same sink so the whole bundle is guaranteed to have passed one scrub point (5.3).
        entries += redactEntries([FileExport.BundleEntry(name: "meta.json", data: meta.encoded())])
        return entries
    }

    // MARK: - Helpers (universal clock-drift, bundle gather, active-domain view)

    /// Build the UNIVERSAL clock-drift line from the strap-range snapshot, or nil when no range was seen
    /// this session (no strap reply yet) OR only a firmware-only snapshot exists (newest==0, no real window).
    /// Pure; delegates the format to UniversalTrace so the line can never silently drift. `now` is injectable
    /// so the line is unit-testable without a live clock.
    /// The universal R-R transport line (#2117): what the device banked versus what its unit policy can
    /// score. nil when nothing has been resolved this session, or for a device the policy does not govern.
    /// The judgement is `UniversalTrace.rrTransportLine`, shared byte for byte with Android; this is the
    /// hand-off.
    static func universalRRTransportLine(transport: LiveState.RRTransport?) -> String? {
        guard let transport else { return nil }
        return UniversalTrace.rrTransportLine(strictWhoop5: transport.strictWhoop5,
                                              firstRecordedUnix: transport.firstRecordedUnix,
                                              firstScorableUnix: transport.firstScorableUnix)
    }

    static func universalClockDriftLine(range: LiveState.StrapRange?,
                                        now: Int = Int(Date().timeIntervalSince1970)) -> String? {
        guard let range, range.newestUnix > 0 else { return nil }
        return UniversalTrace.clockDriftLine(newestUnix: range.newestUnix, wallNowUnix: now,
                                             oldestUnix: range.oldestUnix, firmwareLayout: range.firmwareLayout)
    }

    /// The set of domains ACTIVE during this capture, plus `.universal` whenever any mode was on (the
    /// dayOwner + clock-drift lines ride every export). Reads the same zero-cost TestCentre.active gate the
    /// emitters check, so the guard grades exactly the modes that were capturing.
    static func activeDomains() -> Set<TestDomain> {
        var s = Set(TestDomain.allCases.filter { $0 != .universal && TestCentre.active($0) })
        if !s.isEmpty { s.insert(.universal) }
        return s
    }

    /// Read a file at `url` into a redactable bundle entry, or nil when the file is absent / unreadable, so a
    /// missing raw-capture / crash file is never a dead entry. The bytes are returned RAW; the caller runs
    /// them through redactEntries (these are text streams whose embedded console strings can carry a serial).
    static func fileEntry(at url: URL, name: String) -> FileExport.BundleEntry? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return FileExport.BundleEntry(name: name, data: data)
    }

    /// The `OpenWhoop/Diagnostics` directory the Oura dumps write into, mirroring the dumps' own resolver
    /// (`OuraRawDump.resolveURL` et al.): Application Support + `OpenWhoop/Diagnostics`. Read-only — never
    /// creates the directory (a bundle build must not have side effects), so it returns nil when nothing has
    /// ever been captured. iOS and macOS both resolve Application Support here.
    static func ouraDiagnosticsDir() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false) else { return nil }
        return base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
    }

    /// Map a diagnostics filename to a NORMALIZED bundle entry name that drops the ring id, or nil when the
    /// file is not one of the Oura sidecars in `ouraSidecarKinds`. `oura-<type>-<ringId>.jsonl` →
    /// `oura-<type>.jsonl`, which (a) keeps the ring id out of the bundle's filenames (redaction scrubs
    /// content, never names) and (b) lands on the `trimmableNames` set so the cap can trim it.
    ///
    /// A ROLLED GENERATION (`oura-<type>-<ringId>.jsonl.<n>`, written by `OuraRawDump`'s session ring) maps
    /// to the SAME normalized name on purpose — `ouraDiagnosticEntries` merges the generations behind that
    /// one name rather than choosing between them. Before generations were recognised at all, the `.jsonl`
    /// suffix test rejected every one of them and the bundle could only ever ship the live file — which on
    /// 2026-08-10 was a 30-second morning session while the night's 4 MB sat in a generation the export
    /// never looked at.
    ///
    /// Thin wrapper over `WhoopStore.OuraSidecarGenerations`, where the rule is pure and unit-tested under
    /// `swift test`; this file is app-target Swift that no default CI job compiles.
    static func normalizedOuraEntryName(forFile filename: String) -> String? {
        guard let hit = OuraSidecarGenerations.classify(filename: filename, kinds: ouraSidecarKinds)
        else { return nil }
        return OuraSidecarGenerations.entryName(kind: hit.kind)
    }

    /// Gather the Oura ring's Tier-B JSONL sidecars as bundle entries, normalized names and RAW bytes (the
    /// caller redacts + caps). Enumerates the Diagnostics dir rather than reconstructing per-ring filenames,
    /// so it needs no active-ring id and picks up whatever was captured.
    ///
    /// Several files map to one entry name — the live session plus its rolled generations, and (rarely) two
    /// rings that wrote the same kind. We **concatenate them oldest → newest** rather than choosing one, so
    /// that the cap's existing keep-the-tail trim decides what ships. `OuraSidecarGenerations.mergePlan`
    /// holds that rule, pure and unit-tested; see its doc comment for the measured export that motivated it.
    ///
    /// ⚠️ THIS REPLACES `largest-wins`, which was not a buggy pick but the wrong criterion: the wake drain
    /// flushes the night's whole bank at once, so the biggest generation is whichever session drained most
    /// — routinely not the one holding the night. It cost 11 of 31 nights in the `Sleep Nights` corpus.
    ///
    /// Reads are bounded by `capBytes`: an entry can never keep more than the whole bundle cap, so pulling
    /// older generations past that point would be wasted memory. A kind whose newest file already fills the
    /// cap therefore reads exactly one file, as it did before.
    ///
    /// `directory` is injectable so the merge is testable against a temp dir laid out like a real ring;
    /// production passes nil and gets `<Application Support>/OpenWhoop/Diagnostics`.
    static func ouraDiagnosticEntries(capBytes: Int = defaultCapBytes,
                                      directory: URL? = nil) -> [FileExport.BundleEntry] {
        guard let dir = directory ?? ouraDiagnosticsDir(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        let sizes: [(name: String, bytes: Int)] = files.map { url in
            // Size from the directory entry, so planning never reads a file it will not ship.
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url.lastPathComponent, bytes)
        }
        let plans = OuraSidecarGenerations.mergePlan(files: sizes, kinds: ouraSidecarKinds,
                                                     ceilingBytes: capBytes)
        return plans.compactMap { plan in
            var merged = Data()
            for filename in plan.files {
                guard let part = try? Data(contentsOf: dir.appendingPathComponent(filename)),
                      !part.isEmpty else { continue }
                // Every sidecar is newline-delimited JSONL. A file whose last write did not end in a
                // newline would otherwise splice its final record onto the next generation's first one,
                // producing a line that parses as neither. Cheap to guarantee, silent to get wrong.
                if let last = merged.last, last != 0x0A { merged.append(0x0A) }
                merged.append(part)
            }
            guard !merged.isEmpty else { return nil }
            return FileExport.BundleEntry(name: plan.entryName, data: merged)
        }
    }

    /// The on-disk path a crash report would live at, when a crash handler is wired. There is no producer
    /// yet, so this normally points at a non-existent file and `fileEntry` returns nil. Centralised here so a
    /// future handler need only write to this path for the crash log to start attaching (fully redacted)
    /// automatically. Lives in the app's caches dir so it is never iCloud-synced.
    static func crashLogURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("noop-last-crash.txt")
    }
}
