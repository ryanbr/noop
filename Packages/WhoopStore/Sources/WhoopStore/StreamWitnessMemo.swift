import Foundation
import GRDB

/// Where and when rows of the raw streams changed, bucketed by `(table, deviceId, ts / 3600)`.
///
/// Each bucket keeps the hull `[lo, hi]` of the timestamps that changed in it and the newest stamp that
/// touched it. Merging into a hull can only report a change that did not reach a window, never miss one
/// that did: a row at `ts` inside `[from, to]` lands in bucket `ts / 3600`, which is one of the window's
/// own buckets because truncating division is monotonic. A false report costs one recount, never a
/// wrong witness.
struct StreamChangeSpans {
    private struct Span { var lo: Int; var hi: Int; var stamp: Int }
    private struct PerDevice { var latest = 0; var byHour: [Int: Span] = [:] }
    private var tables: [String: [String: PerDevice]] = [:]

    /// How many buckets a holder keeps before it gives up and starts over (about two years of hours on
    /// one stream). Starting over is always safe: every memo is recounted once.
    static let hourLimit = 20_000

    /// Buckets held, across every table and device.
    private(set) var hours = 0

    /// Kotlin twin: `StreamChangeSpans.record`.
    mutating func record(table: String, deviceId: String, lo: Int, hi: Int, stamp: Int) {
        var device = tables[table]?[deviceId] ?? PerDevice()
        device.latest = max(device.latest, stamp)
        for hour in (lo / 3600)...(hi / 3600) {
            if var span = device.byHour[hour] {
                span.lo = min(span.lo, lo); span.hi = max(span.hi, hi); span.stamp = max(span.stamp, stamp)
                device.byHour[hour] = span
            } else {
                device.byHour[hour] = Span(lo: lo, hi: hi, stamp: stamp)
                hours += 1
            }
        }
        tables[table, default: [:]][deviceId] = device
    }

    /// Whether any of `tables` changed for `deviceId` inside `[from, to]` after `stamp`. Kotlin twin:
    /// `StreamChangeSpans.changed`.
    func changed(after stamp: Int, tables names: [String], deviceId: String, from: Int, to: Int) -> Bool {
        guard from <= to else { return false }
        for name in names {
            guard let device = tables[name]?[deviceId], device.latest > stamp else { continue }
            let first = from / 3600, last = to / 3600
            // Walk whichever is shorter: the window's hours, or the hours this device has changed in. A
            // test window can span the whole epoch; a pass window spans about 55 hours.
            if last - first < device.byHour.count {
                for hour in first...last {
                    if let span = device.byHour[hour], span.stamp > stamp, span.lo <= to, span.hi >= from {
                        return true
                    }
                }
            } else {
                for (hour, span) in device.byHour where hour >= first && hour <= last
                    && span.stamp > stamp && span.lo <= to && span.hi >= from {
                    return true
                }
            }
        }
        return false
    }

    /// Drop every bucket no later than `stamp`: nothing that asks `changed(after:)` with a stamp at or past
    /// it can see them. Kotlin twin: `StreamChangeSpans.prune`.
    mutating func prune(through stamp: Int) {
        for (name, devices) in tables {
            for (deviceId, device) in devices {
                let kept = device.byHour.filter { $0.value.stamp > stamp }
                hours -= device.byHour.count - kept.count
                tables[name]?[deviceId] = kept.isEmpty ? nil : PerDevice(latest: device.latest, byHour: kept)
            }
            if tables[name]?.isEmpty == true { tables[name] = nil }
        }
    }

    /// Kotlin twin: `StreamChangeSpans.clear`.
    mutating func removeAll() { tables = [:]; hours = 0 }
}

/// The stream changes a rowid frontier cannot see, noted by the code that makes them.
///
/// `StreamWitnessMemo` learns of inserts by reading rows above each table's rowid frontier, which catches
/// every insert from any connection, a backfill of an old night included. Two kinds of change leave the
/// frontier where it was. An in-place UPDATE of a stream row (the R-R source promotion and fill flag in
/// `insert`) keeps its rowid, so it is noted here per device and span, after its write commits. A DELETE or
/// re-key can also hand a freed rowid to the next insert, below a frontier already read, so it brackets its
/// write with `noteRemoval()` before AND after: each bumps `epoch`, which re-bases every tracker and
/// invalidates every memo, a witness taken while the write runs carries the first bump, and the second
/// moves it again once the rows are gone.
///
/// Process-wide rather than per store, because the app opens more than one `WhoopStore` on the same file
/// (BLEManager's backfill writer and the repository the engine reads through), and an edit made through
/// one must invalidate the memo of the other. A note from an unrelated database only costs a recount.
final class StreamEditJournal: @unchecked Sendable {
    static let shared = StreamEditJournal()

    struct Mark: Equatable { let epoch: Int; let clock: Int }

    private let lock = NSLock()
    private var epoch = 0
    private var clock = 0
    private var edits = StreamChangeSpans()

    /// Read BEFORE the snapshot a witness is counted from. An edit noted after this has a later stamp, so
    /// whether or not the snapshot saw it, the memo it guards is recounted next time. Kotlin twin:
    /// `StreamEditJournal.mark`.
    func mark() -> Mark {
        lock.lock(); defer { lock.unlock() }
        return Mark(epoch: epoch, clock: clock)
    }

    /// Call after the edit's transaction committed, never inside it. Kotlin twin: `StreamEditJournal.noteEdit`.
    func noteEdit(table: String, deviceId: String, from: Int, to: Int) {
        lock.lock(); defer { lock.unlock() }
        clock += 1
        let lo = min(from, to), hi = max(from, to)
        // A span too wide to bucket, or a journal at its bound, is noted the way a removal is: every memo
        // is recounted once. The bump comes after the edit committed, so no witness can miss it.
        if hi / 3600 - lo / 3600 >= StreamChangeSpans.hourLimit
            || edits.hours >= StreamChangeSpans.hourLimit {
            epoch += 1
            edits.removeAll()
            return
        }
        edits.record(table: table, deviceId: deviceId, lo: lo, hi: hi, stamp: clock)
    }

    /// Call before a removal's write and again, from a `defer`, once it is done. Kotlin twin:
    /// `StreamEditJournal.noteRemoval`, which Kotlin brackets with `StreamEditJournal.removing`.
    func noteRemoval() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        clock += 1
        edits.removeAll()
    }

    /// Kotlin twin: `StreamEditJournal.edited`.
    func edited(since mark: Mark, tables: [String], deviceId: String, from: Int, to: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch != mark.epoch
            || edits.changed(after: mark.clock, tables: tables, deviceId: deviceId, from: from, to: to)
    }
}

/// Answers a per-window witness from memory while its window provably has not changed (#2314).
///
/// The `analyzeRecent` pass asks for three witnesses per cached night — `dayHrFingerprint`,
/// `dayStreamFingerprint` and `gravityFingerprint` — and each is a `COUNT(*)` over a window of 1 Hz
/// streams. `COUNT(*)` walks every index entry in its range, so a pass over sixteen unchanged nights walked
/// all sixteen again: about 509 MB of reads on a 3.85 GB store, which missed the page cache even two
/// minutes apart. The values themselves are not changed here. A witness is still that `COUNT`/`MAX`
/// result, byte for byte; this only decides when it has to be counted again.
///
/// The decision comes from each stream's rowid frontier. Every stream inserts with `ON CONFLICT DO
/// NOTHING`, and an insert takes a rowid above every existing one, so the rows above the frontier read
/// last time are exactly what landed since, wherever in time they belong. One statement per call reads
/// each table's frontier and groups any new rows by device and hour; nothing that has not changed is
/// walked. A memo is reused while no landing, no noted edit and no removal reached its tables, device and
/// window (`StreamEditJournal`). A frontier that went backwards means a delete nobody noted: the tracker
/// re-bases and every memo is recounted.
///
/// Per store and in memory only. The memo dies with the process, like the day cache it serves, so the
/// first pass after a launch counts every window once, as before.
struct StreamWitnessMemo {
    /// Which witness, which tables it counts, and so which changes can stale it.
    enum Kind: Hashable {
        case hr, gravity, dayStreams

        var tables: [String] {
            switch self {
            case .hr: return ["hrSample"]
            case .gravity: return ["gravitySample"]
            case .dayStreams: return ["ppgHrSample", "rrInterval", "respSample", "spo2Sample", "gravitySample",
                                      "stepSample", "skinTempSample", "sleepStateSample", "event"]
            }
        }
    }

    private struct Key: Hashable { let kind: Kind; let deviceId: String; let from: Int; let to: Int }
    private struct Entry { let values: [Int]; let generation: Int; let landed: Int; let journal: StreamEditJournal.Mark }

    /// The raw streams in the order `refresh` reads them. The letters are `analysisFingerprint`'s.
    static let trackedTables: [(letter: String, table: String)] = [
        ("h", "hrSample"), ("p", "ppgHrSample"), ("r", "rrInterval"), ("x", "respSample"),
        ("g", "gravitySample"), ("s", "sleepStateSample"), ("e", "event"), ("o", "spo2Sample"),
        ("t", "skinTempSample"), ("z", "stepSample"),
    ]

    /// Bounds the memo; a pass keeps about a hundred windows alive. Past it everything is recounted once.
    private static let entryLimit = 1_024

    private var frontier: [String: Int]? = nil
    private var generation = 0
    private var stamp = 0
    private var epochSeen: Int? = nil
    private var landings = StreamChangeSpans()
    private var entries: [Key: Entry] = [:]

    /// The witness for one window: the memo when nothing reached it since it was counted, otherwise
    /// `count(db)`. `mark` must be read before the read transaction `db` belongs to. Kotlin twin:
    /// `StreamWitnessMemo.witness`.
    mutating func witness(_ kind: Kind, deviceId: String, from: Int, to: Int, mark: StreamEditJournal.Mark,
                          db: Database, count: (Database) throws -> [Int]) throws -> [Int] {
        try refresh(db, epoch: mark.epoch)
        let key = Key(kind: kind, deviceId: deviceId, from: from, to: to)
        if let entry = entries[key], entry.generation == generation,
           !landings.changed(after: entry.landed, tables: kind.tables, deviceId: deviceId, from: from, to: to),
           !StreamEditJournal.shared.edited(since: entry.journal, tables: kind.tables, deviceId: deviceId,
                                            from: from, to: to) {
            return entry.values
        }
        let values = try count(db)
        if entries.count >= Self.entryLimit { entries = [:] }
        // Today's window ends at `now`, so it is a new key every pass; keep only the latest per start.
        entries = entries.filter { $0.key.kind != kind || $0.key.deviceId != deviceId || $0.key.from != from }
        entries[key] = Entry(values: values, generation: generation, landed: stamp, journal: mark)
        return values
    }

    /// Reads the frontiers and what landed above them, and re-bases on a first look, a regression or a
    /// removal. Kotlin twin: `StreamWitnessMemo.refresh`.
    ///
    /// The statement returns each table's rowid frontier (`deviceId` NULL), then the rows above `:<letter>`
    /// grouped by device and hour. Every delta arm is a rowid range seek, so a table with nothing new reads
    /// one page. `NOT INDEXED` keeps it one: left to itself the planner answers the `GROUP BY deviceId` by
    /// walking the narrower `(deviceId, ts)` key index end to end, a whole-stream read on every pass. One
    /// statement, so the frontiers and the deltas come from one snapshot. Kotlin runs the same statement as
    /// STREAM_LANDINGS_SQL.
    private mutating func refresh(_ db: Database, epoch: Int) throws {
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        for (letter, table) in Self.trackedTables { arguments[letter] = frontier?[table] ?? Int.max }
        var tops: [String: Int] = [:]
        var landed: [(table: String, deviceId: String, lo: Int, hi: Int)] = []
        let tableOf = Dictionary(uniqueKeysWithValues: Self.trackedTables.map { ($0.letter, $0.table) })
        let rows = try Row.fetchAll(db, sql: """
            SELECT 'h' AS tbl, NULL AS deviceId, NULL AS lo, NULL AS hi, (SELECT COALESCE(MAX(rowid), 0) FROM hrSample) AS top
            UNION ALL SELECT 'h', deviceId, MIN(ts), MAX(ts), NULL FROM hrSample NOT INDEXED WHERE rowid > :h GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'p', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM ppgHrSample)
            UNION ALL SELECT 'p', deviceId, MIN(ts), MAX(ts), NULL FROM ppgHrSample NOT INDEXED WHERE rowid > :p GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'r', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM rrInterval)
            UNION ALL SELECT 'r', deviceId, MIN(ts), MAX(ts), NULL FROM rrInterval NOT INDEXED WHERE rowid > :r GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'x', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM respSample)
            UNION ALL SELECT 'x', deviceId, MIN(ts), MAX(ts), NULL FROM respSample NOT INDEXED WHERE rowid > :x GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'g', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM gravitySample)
            UNION ALL SELECT 'g', deviceId, MIN(ts), MAX(ts), NULL FROM gravitySample NOT INDEXED WHERE rowid > :g GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 's', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM sleepStateSample)
            UNION ALL SELECT 's', deviceId, MIN(ts), MAX(ts), NULL FROM sleepStateSample NOT INDEXED WHERE rowid > :s GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'e', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM event)
            UNION ALL SELECT 'e', deviceId, MIN(ts), MAX(ts), NULL FROM event NOT INDEXED WHERE rowid > :e GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'o', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM spo2Sample)
            UNION ALL SELECT 'o', deviceId, MIN(ts), MAX(ts), NULL FROM spo2Sample NOT INDEXED WHERE rowid > :o GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 't', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM skinTempSample)
            UNION ALL SELECT 't', deviceId, MIN(ts), MAX(ts), NULL FROM skinTempSample NOT INDEXED WHERE rowid > :t GROUP BY deviceId, ts / 3600
            UNION ALL SELECT 'z', NULL, NULL, NULL, (SELECT COALESCE(MAX(rowid), 0) FROM stepSample)
            UNION ALL SELECT 'z', deviceId, MIN(ts), MAX(ts), NULL FROM stepSample NOT INDEXED WHERE rowid > :z GROUP BY deviceId, ts / 3600
            """, arguments: StatementArguments(arguments))
        for row in rows {
            let letter: String = row["tbl"]
            guard let table = tableOf[letter] else { continue }
            if let deviceId: String = row["deviceId"] {
                landed.append((table, deviceId, row["lo"], row["hi"]))
            } else {
                tops[table] = row["top"]
            }
        }
        let regressed = frontier.map { old in tops.contains { $0.value < (old[$0.key] ?? 0) } } ?? false
        if frontier == nil || regressed || epochSeen != epoch {
            // First look, a frontier that went backwards, or a noted removal: rowids at or below the old
            // frontier may now belong to new rows, so nothing counted against it can be trusted.
            generation += 1
            landings.removeAll()
            entries = [:]
            frontier = tops
            epochSeen = epoch
            return
        }
        frontier = tops
        guard !landed.isEmpty else { return }
        stamp += 1
        for change in landed {
            landings.record(table: change.table, deviceId: change.deviceId, lo: change.lo, hi: change.hi,
                            stamp: stamp)
        }
        // Landings no live memo predates can never be asked about again.
        if let oldest = entries.values.map(\.landed).min() {
            landings.prune(through: oldest)
        } else {
            landings.removeAll()
        }
        // A window nobody asks for any more pins the prune above; past the bound, start over.
        if landings.hours >= StreamChangeSpans.hourLimit {
            generation += 1
            landings.removeAll()
            entries = [:]
        }
    }
}
