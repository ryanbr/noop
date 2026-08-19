import Foundation
import GRDB

// MARK: - v8 cache: journal entries, workouts, and Apple-Health daily aggregates
// Mirrors the MetricsCache pattern: Codable structs, idempotent ON CONFLICT upserts keyed by
// natural key, and range-read accessors. All write/read GRDB work runs via the actor's
// syncWrite/syncRead helpers (off the main thread).

/// One journal answer. Natural key (deviceId, day, question).
public struct JournalEntry: Equatable, Codable {
    public let day: String          // YYYY-MM-DD
    public let question: String
    public let answeredYes: Bool
    public let notes: String?
    /// Optional numeric reading for a numeric journal item (e.g. caffeine mg, alcohol units).
    /// nil for a plain yes/no answer and for every imported WHOOP row (#322). A numeric log writes
    /// answeredYes=true AND numericValue=v, so the BehaviorInsights with/without split is unchanged.
    public let numericValue: Double?
    public init(day: String, question: String, answeredYes: Bool, notes: String?,
                numericValue: Double? = nil) {
        self.day = day; self.question = question
        self.answeredYes = answeredYes; self.notes = notes
        self.numericValue = numericValue
    }
}

/// One workout. Natural key (deviceId, startTs, sport). All metric columns nullable.
/// `zonesJSON` is verbatim JSON of HR-zone percentages, stored as a string so the cache stays
/// schema-agnostic about the zone shape.
public struct WorkoutRow: Equatable, Codable {
    public let startTs: Int          // unix seconds
    public let endTs: Int            // unix seconds
    public let sport: String
    public let source: String
    public let durationS: Double?
    public let energyKcal: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let strain: Double?
    public let distanceM: Double?
    public let zonesJSON: String?
    public let notes: String?
    public let steps: Int?               // #1058: per-session steps (activity-file foot sports); nil otherwise
    /// NO DEFAULTS HERE, deliberately (#1444). Swift rebuilds a row field by field, so a defaulted
    /// parameter lets an existing call site keep compiling while it silently starts writing nothing.
    /// That is exactly how `steps` was dropped at six sites — two of which persisted the loss — with
    /// nothing in the read path able to tell "never had steps" from "had steps, then lost them".
    /// Requiring every field makes each call site state its intent and turns the next added column into
    /// a compile error instead of silent data loss. Keep it that way: add a field WITHOUT a default and
    /// fix the call sites the compiler points at. (Kotlin needs no equivalent rule because `copy()`
    /// carries unmentioned fields — but note that only protects a rebuild whose receiver IS the stored
    /// row, which is why the Android edit sheet lost `steps` anyway.)
    public init(startTs: Int, endTs: Int, sport: String, source: String, durationS: Double?,
                energyKcal: Double?, avgHr: Int?, maxHr: Int?, strain: Double?, distanceM: Double?,
                zonesJSON: String?, notes: String?, steps: Int?) {
        self.startTs = startTs; self.endTs = endTs; self.sport = sport; self.source = source
        self.durationS = durationS; self.energyKcal = energyKcal; self.avgHr = avgHr
        self.maxHr = maxHr; self.strain = strain; self.distanceM = distanceM
        self.zonesJSON = zonesJSON; self.notes = notes; self.steps = steps
    }
}

/// One Apple-Health daily-aggregate row. Natural key (deviceId, day). All metric columns nullable.
public struct AppleDaily: Equatable, Codable {
    public let day: String           // YYYY-MM-DD
    public let steps: Int?
    public let activeKcal: Double?
    public let basalKcal: Double?
    public let vo2max: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let walkingHr: Int?
    public let weightKg: Double?
    public init(day: String, steps: Int?, activeKcal: Double?, basalKcal: Double?, vo2max: Double?,
                avgHr: Int?, maxHr: Int?, walkingHr: Int?, weightKg: Double?) {
        self.day = day; self.steps = steps; self.activeKcal = activeKcal; self.basalKcal = basalKcal
        self.vo2max = vo2max; self.avgHr = avgHr; self.maxHr = maxHr
        self.walkingHr = walkingHr; self.weightKg = weightKg
    }
}

extension WhoopStore {

    // MARK: - Upserts (idempotent by natural key; latest value wins on conflict)

    /// Upsert journal entries. Natural key (deviceId, day, question). Returns rows changed.
    @discardableResult
    public func upsertJournal(_ rows: [JournalEntry], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO journal
                        (deviceId, day, question, answeredYes, notes, numericValue)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        answeredYes = excluded.answeredYes,
                        notes = excluded.notes,
                        numericValue = excluded.numericValue
                    """, arguments: [deviceId, r.day, r.question, r.answeredYes ? 1 : 0, r.notes,
                                     r.numericValue])
                n += db.changesCount
            }
            return n
        }
    }

    /// Delete one journal answer by natural key (the native logging card's "clear"). Source-scoped
    /// by deviceId, so clearing a native ("noop-journal") answer never removes an identical imported
    /// row. Returns rows deleted.
    @discardableResult
    public func deleteJournal(deviceId: String, day: String, question: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM journal WHERE deviceId = ? AND day = ? AND question = ?
                """, arguments: [deviceId, day, question])
            return db.changesCount
        }
    }

    /// Atomically replace a device's journal within a day range (#136): clear [from, to] then upsert
    /// `rows`, all in ONE transaction, so the wake-day keying fix leaves no pre-fix onset-keyed duplicates
    /// AND a crash mid-import can't leave the range deleted-but-not-repopulated. Bounded to [from, to] —
    /// journal outside the imported range is never touched. deviceId-scoped (native log untouched).
    @discardableResult
    public func replaceJournalRange(_ rows: [JournalEntry], deviceId: String,
                                    from: String, to: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM journal WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO journal
                        (deviceId, day, question, answeredYes, notes, numericValue)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        answeredYes = excluded.answeredYes,
                        notes = excluded.notes,
                        numericValue = excluded.numericValue
                    """, arguments: [deviceId, r.day, r.question, r.answeredYes ? 1 : 0, r.notes,
                                     r.numericValue])
                n += db.changesCount
            }
            return n
        }
    }

    /// Upsert workouts. Natural key (deviceId, startTs, sport). Returns rows changed.
    @discardableResult
    public func upsertWorkouts(_ rows: [WorkoutRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO workout
                        (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                         avgHr, maxHr, strain, distanceM, zonesJSON, notes, steps)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        source = excluded.source,
                        durationS = excluded.durationS,
                        energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        strain = excluded.strain,
                        distanceM = excluded.distanceM,
                        zonesJSON = excluded.zonesJSON,
                        notes = excluded.notes,
                        steps = excluded.steps
                    """, arguments: [deviceId, r.startTs, r.endTs, r.sport, r.source, r.durationS,
                                     r.energyKcal, r.avgHr, r.maxHr, r.strain, r.distanceM,
                                     r.zonesJSON, r.notes, r.steps])
                n += db.changesCount
            }
            return n
        }
    }

    /// Delete one source's workouts of a given sport whose startTs is in [from, to]
    /// (makes detected-workout re-derivation idempotent). Returns rows deleted.
    /// Port of Android WhoopDao.deleteWorkoutsBySport (#78).
    @discardableResult
    public func deleteWorkouts(deviceId: String, sport: String, from: Int, to: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM workout
                WHERE deviceId = ? AND sport = ? AND startTs >= ? AND startTs <= ?
                """, arguments: [deviceId, sport, from, to])
            return db.changesCount
        }
    }

    /// Upsert Apple-Health daily aggregates. Natural key (deviceId, day). Returns rows changed.
    @discardableResult
    public func upsertAppleDaily(_ rows: [AppleDaily], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO appleDaily
                        (deviceId, day, steps, activeKcal, basalKcal, vo2max,
                         avgHr, maxHr, walkingHr, weightKg)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        steps = excluded.steps,
                        activeKcal = excluded.activeKcal,
                        basalKcal = excluded.basalKcal,
                        vo2max = excluded.vo2max,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        walkingHr = excluded.walkingHr,
                        weightKg = excluded.weightKg
                    """, arguments: [deviceId, r.day, r.steps, r.activeKcal, r.basalKcal, r.vo2max,
                                     r.avgHr, r.maxHr, r.walkingHr, r.weightKg])
                n += db.changesCount
            }
            return n
        }
    }

    // MARK: - Reads

    /// Journal entries for days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first, then by question.
    public func journalEntries(deviceId: String, from: String, to: String) async throws -> [JournalEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, question, answeredYes, notes, numericValue FROM journal
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC, question ASC
                """, arguments: [deviceId, from, to])
                .map {
                    JournalEntry(day: $0["day"], question: $0["question"],
                                 answeredYes: ($0["answeredYes"] as Int) != 0,
                                 notes: $0["notes"],
                                 numericValue: $0["numericValue"])
                }
        }
    }

    /// Workouts overlapping [from, to] (by startTs), oldest first.
    public func workouts(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WorkoutRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes, steps FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                               source: $0["source"], durationS: $0["durationS"],
                               energyKcal: $0["energyKcal"], avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                               strain: $0["strain"], distanceM: $0["distanceM"],
                               zonesJSON: $0["zonesJSON"], notes: $0["notes"], steps: $0["steps"])
                }
        }
    }

    /// #1058: sum per-session `steps` over one source's workouts whose startTs is in [from, to). Used to
    /// recompute an activity-file day's step total from ALL its sessions, so a second file on the same day
    /// adds rather than clobbers — and re-importing a file is idempotent (its row's steps are replaced,
    /// not re-added, by `upsertWorkouts`). Returns 0 when no session in the range carried steps.
    public func sumWorkoutSteps(deviceId: String, from: Int, to: Int) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(steps), 0) FROM workout
                WHERE deviceId = ? AND steps IS NOT NULL AND startTs >= ? AND startTs < ?
                """, arguments: [deviceId, from, to]) ?? 0
        }
    }

    /// Apple-Health daily aggregates for days in [from, to] (lexicographic compare), oldest first.
    public func appleDaily(deviceId: String, from: String, to: String) async throws -> [AppleDaily] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg
                FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    AppleDaily(day: $0["day"], steps: $0["steps"], activeKcal: $0["activeKcal"],
                               basalKcal: $0["basalKcal"], vo2max: $0["vo2max"], avgHr: $0["avgHr"],
                               maxHr: $0["maxHr"], walkingHr: $0["walkingHr"], weightKg: $0["weightKg"])
                }
        }
    }
}
