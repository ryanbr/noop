import Foundation

/// The mandatory review-before-share gate (spec sections 9 and 12): nothing leaves the device until the
/// user has seen the exact redacted report.txt they are about to share and explicitly confirmed. The
/// gate is a small value type so its clear/cancel logic is unit-tested; the SwiftUI review sheet binds
/// to `previewText` and calls `confirm()` / `cancel()`. It is NOT skippable: the only path to cleared
/// is an explicit confirm.
struct ReportReviewGate {
    /// The bundle the user is about to share, already redacted by TestBundleAssembler.
    let entries: [FileExport.BundleEntry]
    private(set) var isCleared: Bool = false

    init(entries: [FileExport.BundleEntry]) { self.entries = entries }

    /// The bundle files that are NEVER shown inline in the review sheet by NAME: the binary screenshot plus
    /// the large raw research streams (WHOOP raw-capture + the Oura Tier-B sidecars — each up to the 25 MB
    /// cap `OuraActivityDump.maxBytes` / `OuraMotionDump.maxBytes` actually enforce; this said 20 MB). Rendering megabytes of text as a single SwiftUI `Text` pins the main thread in CoreText glyph
    /// layout — a ~12 MB `oura-raw.jsonl` allocated >1 GB and hung the review sheet indefinitely. They are
    /// already PII-scrubbed and are NAMED in the "attached" note below, so the review stays honest without
    /// trying to lay them out.
    static let notShownInline: Set<String> = [
        "screenshot.png", "raw-capture.jsonl", "oura-raw.jsonl", "oura-ibihr.jsonl", "oura-activity.jsonl",
    ]

    /// Belt-and-braces size guard: ANY entry larger than this is named, never inlined, even one NOT in
    /// `notShownInline` (a future stream, or a pathologically large report.txt). 1 MiB sits far above a
    /// normal report.txt / meta.json (so those still show in full) yet well below the layout-choke point,
    /// so no single Text can ever pin the main thread again regardless of which files a branch attaches.
    static let maxInlineBytes = 1024 * 1024

    /// Every text file the user is about to share, shown in the review sheet so they can read the WHOLE
    /// bundle (not just report.txt) and cancel if anything looks personal , the gate promises the user sees
    /// exactly what they share. Each text entry is prefixed with a `=== <name> ===` header so the files
    /// (report.txt, meta.json, and last-crash.txt when present) are clearly delimited. The large raw streams
    /// (by name, or anything over `maxInlineBytes`) are excluded: they are bounded research captures, not a
    /// report surface, already PII-scrubbed, and far too large to lay out inline. Order is the natural
    /// bundle order. Empty string if there is nothing text-decodable to show.
    var previewText: String {
        let textBlocks = entries.compactMap { entry -> String? in
            guard !Self.notShownInline.contains(entry.name), entry.data.count <= Self.maxInlineBytes,
                  let text = String(data: entry.data, encoding: .utf8) else { return nil }
            return "=== \(entry.name) ===\n\(text)"
        }.joined(separator: "\n\n")
        // Binary / large attachments (screenshot.png, raw-capture.jsonl, the oura-*.jsonl sidecars, anything
        // oversized) are not shown inline. Name them so the review is honest about EVERYTHING in the bundle:
        // the user sees that a screenshot / raw capture / ring dump is attached and can cancel if unwanted.
        let binaryNames = entries.compactMap { entry -> String? in
            if Self.notShownInline.contains(entry.name) || entry.data.count > Self.maxInlineBytes { return entry.name }
            return String(data: entry.data, encoding: .utf8) == nil ? entry.name : nil
        }
        guard !binaryNames.isEmpty else { return textBlocks }
        let note = "=== attached (not shown above) ===\n" + binaryNames.joined(separator: "\n")
        return textBlocks.isEmpty ? note : textBlocks + "\n\n" + note
    }

    /// Explicit user confirmation: the only way the gate clears.
    mutating func confirm() { isCleared = true }
    /// Explicit cancel: leaves the gate uncleared so the share never fires.
    mutating func cancel() { isCleared = false }
}
