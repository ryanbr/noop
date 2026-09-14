import Foundation

/// Pure, deterministic selection rule for WHICH Oura diagnostics files a Test Centre export ships.
///
/// The dumps (`Strand/BLE/Oura*Dump.swift`) keep a per-session generation ring: the live file
/// `oura-<kind>-<ringId>.jsonl` is the CURRENT session, and finished sessions roll into
/// `…jsonl.1` (newest retained) … `…jsonl.N` (oldest). Several files therefore map to one bundle
/// entry name, and the assembler must decide what to do about that.
///
/// WHY THIS EXISTS — the rule it replaces was `LARGEST WINS`, and largest is the wrong criterion.
/// The wake drain flushes the whole night's bank in one burst, so on an ordinary morning the biggest
/// generation is whichever session happened to drain the most — routinely NOT the one holding the
/// night. Measured on `noop-master-iOS-v11.1.1-260905-0714.zip`: the shipped `oura-raw.jsonl` spanned
/// `2026-09-04 10:58:22 → 12:03:47 UTC` — the previous day's post-reinstall backfill, which was
/// simply the fattest file on disk. That morning's own 07:08 drain, the one carrying the night's
/// banked records (including the single `0x5c` of the day and the hypnogram), was in a different
/// generation and never left the device. Over the whole `Sleep Nights` corpus this cost **11 of 31
/// nights**, which is the single biggest limit on the hypnogram ledger.
///
/// THE RULE: do not pick at all — **concatenate the generations, oldest → newest**, and let the
/// bundle cap keep the tail. The cap already trims from the FRONT and keeps the most-recent bytes,
/// so merging in chronological order makes "the newest capture survives" a property of the two rules
/// composed, rather than a guess made blind at selection time. The morning drain is by construction
/// the newest data, so it can no longer be the thing that gets dropped.
///
/// WHY NOT ship every generation as its own entry (the other candidate in the issue draft): each
/// extra entry competes for the same 20 MB cap under max-min fair allocation, so N generations of a
/// bulk sidecar would shrink every other stream's share — starving exactly the file this exists to
/// preserve. Merging costs one entry, keeps the bundle listing stable, and needs no new names.
///
/// SAFE TO MERGE: generations are disjoint app sessions, and the raw capture deliberately keeps no
/// dedup high-water (a re-served record is itself evidence the ring re-sent it). Every line carries
/// its own `utc`/`iso`, and the offline reframer collapses duplicates by `(tag, ring-time)`, so a
/// concatenation reads exactly like the longer single capture it stands in for.
public enum OuraSidecarGenerations {

    /// Bundle entry name for a sidecar kind — the ring id is dropped, because bundle redaction scrubs
    /// file CONTENT and never file NAMES.
    public static func entryName(kind: String) -> String { "oura-\(kind).jsonl" }

    /// Classify a diagnostics filename as `(kind, generation)`, or nil when it is not one of `kinds`.
    ///
    /// `generation` is 0 for the live file and `n` for `…jsonl.n`, matching the dumps' own ring where
    /// **1 is the NEWEST retained** session and higher indices are older. So a smaller generation is
    /// always the more recent capture, and 0 (live) is the most recent of all — that single ordering
    /// fact is what `mergePlan` sorts on.
    ///
    /// Rejects anything that is not exactly the ring's shape: no suffix at all beyond `.jsonl`, or a
    /// dot followed by digits only. `oura-raw.txt`, `oura-raw-<id>.jsonl.bak` and a bare
    /// `oura-raw.jsonl` (no ring id) are all nil.
    public static func classify(filename: String, kinds: [String]) -> (kind: String, generation: Int)? {
        for kind in kinds where filename.hasPrefix("oura-\(kind)-") {
            guard let range = filename.range(of: ".jsonl") else { continue }
            let tail = filename[range.upperBound...]      // "" for the live file, ".3" for a generation
            if tail.isEmpty { return (kind, 0) }
            guard tail.hasPrefix("."), tail.count > 1 else { continue }
            let digits = tail.dropFirst()
            guard digits.allSatisfy(\.isNumber), let n = Int(digits) else { continue }
            return (kind, n)
        }
        return nil
    }

    /// One bundle entry and the files that make it up, already in concatenation order.
    public struct Plan: Equatable {
        /// Normalized bundle entry name, e.g. `oura-raw.jsonl`.
        public let entryName: String
        /// Filenames to concatenate, **OLDEST → NEWEST**. Never empty.
        public let files: [String]
        public init(entryName: String, files: [String]) {
            self.entryName = entryName
            self.files = files
        }
    }

    /// Plan the merge for every sidecar kind present in `files`.
    ///
    /// Files are grouped by kind, ordered newest-first (live, then generation 1, 2, …), and taken
    /// until their cumulative size reaches `ceilingBytes`; the file that crosses the ceiling is
    /// INCLUDED (so the boundary never silently drops the run that spans it) and everything older is
    /// left on the device. The kept run is then returned oldest → newest, ready to concatenate.
    ///
    /// `ceilingBytes` is a READ bound, not a budget: the bundle cap is the thing that decides what
    /// finally ships, and it can never keep more than the whole cap for one entry — so reading beyond
    /// that is pure wasted memory. Pass the bundle's cap. A non-positive ceiling still yields the
    /// single newest file per kind, because shipping nothing would be worse than shipping the tail.
    ///
    /// Deterministic: the result does not depend on the order of `files`, and ties between two files
    /// of the same kind and generation (impossible from one ring, possible if two rings wrote the same
    /// kind) break on the filename so the bundle listing stays stable.
    ///
    /// Returns one `Plan` per kind, in `kinds` order, so the bundle listing is deterministic too.
    public static func mergePlan(files: [(name: String, bytes: Int)],
                                 kinds: [String],
                                 ceilingBytes: Int) -> [Plan] {
        var byKind: [String: [(generation: Int, name: String, bytes: Int)]] = [:]
        for file in files {
            guard let hit = classify(filename: file.name, kinds: kinds) else { continue }
            byKind[hit.kind, default: []].append((hit.generation, file.name, max(0, file.bytes)))
        }
        return kinds.compactMap { kind -> Plan? in
            guard let group = byKind[kind], !group.isEmpty else { return nil }
            // Newest first: generation 0 (live), then 1 (newest retained), … N (oldest).
            let newestFirst = group.sorted {
                $0.generation != $1.generation ? $0.generation < $1.generation : $0.name < $1.name
            }
            var kept: [String] = []
            var accumulated = 0
            for file in newestFirst {
                kept.append(file.name)
                accumulated += file.bytes
                if accumulated >= ceilingBytes { break }
            }
            return Plan(entryName: entryName(kind: kind), files: kept.reversed())
        }
    }
}
