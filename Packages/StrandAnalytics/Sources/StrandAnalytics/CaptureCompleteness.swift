import Foundation

// CaptureCompleteness.swift - the report-completeness guard (#812, generalised).
//
// #812 taught us that a Test Centre report can ship THIN: the mode was on, the user filled the
// questionnaire, but the killer trace for that domain never landed in the log (a dead emitter, a gate that
// never fired, an offload that produced only console frames). The report looked complete at submit time and
// only revealed itself as empty days later when a maintainer opened it. This guard makes that self-evident
// AT EXPORT: for every domain that was ACTIVE during the capture, it scans the redacted report text for that
// domain's expected key-trace token(s) and reports OK (token present, with a count) or INCOMPLETE (mode was
// on but produced no trace, naming the missing token). The result is written into report.txt as a "Capture
// check" section and into meta.json as a machine-readable `capture_check` field, so a thin report is obvious
// the moment it is assembled rather than after a round-trip.
//
// Everything here is PURE and side-effect-free: it takes the active-domain set and the already-redacted
// report text and returns values. No I/O, no clock, no PII (it only counts token occurrences). The token map
// is the single declarative source of truth shared by the report renderer and the meta field. No em-dashes.
// Android's `ReportCompleteness` in
// `android/app/src/main/java/com/noop/testcentre/ReportCompleteness.kt` is the architectural counterpart;
// it has its own status vocabulary, token maps, and domain-selection rules.

/// Whether a domain that was active during the capture produced its killer trace.
public enum CaptureStatus: String, Sendable, Codable, Equatable {
    case ok          // at least one expected token was found
    case incomplete  // the mode was active but NONE of its expected tokens appear (the dead-trace warning)
}

/// One domain's completeness verdict: which domain, OK/INCOMPLETE, how many matching token lines were
/// found, and which token(s) we looked for (so an INCOMPLETE result names exactly what is missing).
public struct CaptureCheck: Sendable, Codable, Equatable {
    public let domain: String          // TestDomain.id
    public let status: CaptureStatus
    public let count: Int              // total matching token-bearing lines found across this domain's tokens
    public let tokens: [String]        // the expected token(s) for this domain (what we scanned for)
    public init(domain: String, status: CaptureStatus, count: Int, tokens: [String]) {
        self.domain = domain; self.status = status; self.count = count; self.tokens = tokens
    }
}

public enum CaptureCompleteness {

    /// The declarative map {domain -> expected killer-trace token(s)}. A domain is OK at export when the
    /// redacted report contains at least one line carrying ANY of its tokens. The tokens are the verbatim
    /// leading words the per-domain emitters write (verified against the live emitters, not guessed):
    ///
    ///   sleep       -> the gate-run trace ("gate run=...") and the sleep-provenance line
    ///   connection  -> the promoted clock-drift summary and the bond-state line
    ///   workouts    -> the auto-detect verdict line, the session lifecycle line, and the engine detected-bout decision
    ///   display     -> the data-volume line and the frame-time digest
    ///   import      -> the per-stage rowsIn/rowsOut line
    ///   steps       -> the raw step-counter trace, INCLUDING its no-counter sentinel
    ///   battery     -> the banked SoC series line
    ///   recovery    -> the Charge term-breakdown line
    ///   hrv         -> the rMSSD / spot-reading result line
    ///   universal   -> the dayOwner self-diagnostic that rides every export
    ///
    /// Tokens are matched as plain substrings against each line. Each entry lists every acceptable token;
    /// a domain matches if a line contains any one of them. The "steps" entry deliberately lists both the
    /// computed delta line ("stepsRaw") and the explicit no-data sentinel, because a steps capture that
    /// found no raw counter STILL emits an honest "noRawCounter"-style line and that counts as a real
    /// trace (the mode worked; the strap just had nothing), not an INCOMPLETE.
    public static let tokens: [TestDomain: [String]] = [
        // `sleep day=` (#127): the always-on per-day provenance line (from the diagnostic sink, not the
        // SLEEP-gated gate/provenance traces). A night scored on the backfill pass, or already scored so
        // analyzeRecent skips the traced gate, still emits it and proves sleep was computed — so a valid
        // capture is not flagged INCOMPLETE just because the deeper `gate run=`/`sleepProvenance` traces
        // didn't re-fire. Same "the mode worked even if the strap had nothing" rule as `steps` below.
        .sleep:      ["gate run=", "sleepProvenance", "sleep day="],
        .connection: ["clockDrift", "bondState"],
        .workouts:   ["autoDetect", "session event=", "detectedBout"],
        .display:    ["dataVolume", "frameSummary"],
        .dataImport: ["import stage=", "rowsIn="],
        .steps:      ["stepsRaw", "stepsCal"],
        .battery:    ["bank soc=", "socSeries"],
        // "charge day=" for the same reason as the Kotlin twin: IntelligenceEngine re-emits every
        // recovery trace line as `charge day=<day> ` + the body, so none of the three variants this
        // used to name could ever match and the domain reported MISSING on every capture.
        .recovery:   ["charge day="],
        .hrv:        ["hrv rmssd=", "hrv result=", "hrv nightSummary"],
        .universal:  ["dayOwner ", "strapClock "],
    ]

    /// The expected tokens for one domain (empty for a domain with no registered emitter, e.g. notifications).
    public static func expectedTokens(for domain: TestDomain) -> [String] {
        tokens[domain] ?? []
    }

    /// Count how many lines of `reportText` carry ANY of `tokens` (plain substring match). One line that
    /// happens to carry two of the tokens counts once, so the figure reads as "trace lines for this domain".
    static func countMatches(reportText: String, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var n = 0
        for line in reportText.split(separator: "\n", omittingEmptySubsequences: false) {
            if tokens.contains(where: { line.contains($0) }) { n += 1 }
        }
        return n
    }

    /// Run the guard over the redacted `reportText` for each domain in `activeDomains`. A domain is OK when
    /// at least one of its expected tokens appears, INCOMPLETE when the mode was on but no token landed (the
    /// dead-trace warning). A domain with no registered tokens (no emitter, e.g. notifications) is SKIPPED
    /// entirely rather than reported INCOMPLETE, so the guard never flags a domain we never promised a trace
    /// for. Results are returned in a stable order (the registry's declaration order, universal last) so the
    /// report and meta read identically every time.
    ///
    /// `activeDomains` is the set of domains that were ACTIVE during the capture (the assembler passes the
    /// TestCentre.active(_:) view). `.universal` is included by the caller when any mode was active, because
    /// the dayOwner line rides every export.
    public static func evaluate(activeDomains: Set<TestDomain>, reportText: String) -> [CaptureCheck] {
        // Stable order: TestDomain.allCases declaration order, but with universal pushed to the end so the
        // per-domain rows read first and the always-present universal row closes the section.
        let ordered = TestDomain.allCases.filter { $0 != .universal } + [.universal]
        return ordered.compactMap { domain -> CaptureCheck? in
            guard activeDomains.contains(domain) else { return nil }
            let toks = expectedTokens(for: domain)
            guard !toks.isEmpty else { return nil }   // no emitter promised => not graded
            let count = countMatches(reportText: reportText, tokens: toks)
            return CaptureCheck(domain: domain.id,
                                status: count > 0 ? .ok : .incomplete,
                                count: count, tokens: toks)
        }
    }

    /// Render the "Capture check" section appended to report.txt. One line per graded domain: an OK row
    /// names the count, an INCOMPLETE row names the missing token(s) so a maintainer (and the tester, in the
    /// review sheet) sees instantly WHICH capture failed. Returns an empty string when nothing was graded
    /// (no active domain had a registered trace), so a non-test export adds no section.
    public static func reportSection(_ checks: [CaptureCheck]) -> String {
        guard !checks.isEmpty else { return "" }
        var lines = ["", String(repeating: "-", count: 40), "Capture check"]
        for c in checks {
            switch c.status {
            case .ok:
                lines.append("  [OK] \(c.domain): \(c.count) trace line\(c.count == 1 ? "" : "s") "
                             + "(\(c.tokens.joined(separator: " / ")))")
            case .incomplete:
                lines.append("  [INCOMPLETE] \(c.domain): mode was on but produced NO trace "
                             + "(expected \(c.tokens.joined(separator: " / ")))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// True when any graded domain came back INCOMPLETE, a one-glance "this report is thin" flag for the
    /// meta and for the review sheet.
    public static func anyIncomplete(_ checks: [CaptureCheck]) -> Bool {
        checks.contains { $0.status == .incomplete }
    }
}
