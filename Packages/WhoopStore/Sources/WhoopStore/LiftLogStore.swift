import Foundation
import GRDB

// MARK: - v45 store: the in-app strength log (programs, sessions, sets)
//
// Mirrors the established LabMarkerStore / AppleStepHourStore idiom precisely: plain Codable row
// structs, raw `Row` fetch + manual decode, idempotent upserts keyed by the natural key, all GRDB
// work through the actor's `syncWrite` / `syncRead` helpers.
//
// The four tables are flat and deviceId-keyed, joined manually by id — this schema carries no
// foreign keys. A logged session also exists as an ordinary `workout` row; the two find each other
// through the workout table's natural key (deviceId, startTs, sport), which `liftSession` pins with
// a UNIQUE index.
//
// Nothing here computes or stores a load score. `workout.strain` remains the HR-measured number the
// analytics engine produces; volume is derived on read from the sets, where the arithmetic is
// visible (`LiftSetRow.volumeKg`).

// MARK: - Rows

/// One exercise in the user's own vocabulary. NOOP ships no catalogue: an exercise is whatever the
/// user typed, remembered here the first time it is used so it can be offered back with the muscle
/// group they gave it. Keeping the name→group mapping in one place is what makes a per-muscle-group
/// rollup mean the same thing from one session to the next.
public struct LiftExerciseRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Exactly as the user typed it. The natural key is (deviceId, name), so case and spacing are
    /// preserved rather than normalised — their vocabulary, shown back verbatim.
    public var name: String
    /// Canonical classification. Nil until the user has classified this exercise.
    public var primaryMuscle: LiftMuscle?
    /// Also-worked muscles, in the order the user listed them. Never contains `primaryMuscle`.
    public var secondaryMuscles: [LiftMuscle]
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds; most-recently-used floats to the top of the picker. Nil until first used.
    public var lastUsedTs: Int?

    public init(
        id: String,
        deviceId: String,
        name: String,
        primaryMuscle: LiftMuscle?,
        secondaryMuscles: [LiftMuscle] = [],
        createdAt: Int,
        lastUsedTs: Int?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = LiftMuscle.decodeList(
            LiftMuscle.encodeList(secondaryMuscles, excluding: primaryMuscle))
        self.createdAt = createdAt
        self.lastUsedTs = lastUsedTs
    }

    static func decode(_ row: Row) -> LiftExerciseRow {
        LiftExerciseRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            primaryMuscle: LiftMuscle(rawValue: row["primaryMuscle"] ?? ""),
            secondaryMuscles: LiftMuscle.decodeList(row["secondaryMuscles"]),
            createdAt: row["createdAt"],
            lastUsedTs: row["lastUsedTs"]
        )
    }
}

/// A saved program — the reusable plan ("Upper A"), not a session run from it.
public struct LiftProgramRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var note: String?
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds. Drives most-recently-touched-first ordering in the programs list.
    public var updatedAt: Int
    /// Hidden from the picker but kept, so old sessions still resolve their program.
    public var archived: Bool

    public init(
        id: String,
        deviceId: String,
        name: String,
        note: String?,
        createdAt: Int,
        updatedAt: Int,
        archived: Bool
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }

    static func decode(_ row: Row) -> LiftProgramRow {
        LiftProgramRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            note: row["note"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            archived: row["archived"]
        )
    }
}

/// One exercise line in a program: the TARGETS. What actually happened lives in `LiftSetRow`.
public struct LiftProgramItemRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var programId: String
    /// Position within the program, 0-based.
    public var ord: Int
    /// The exercise NAME. Its muscle classification lives in `liftExercise`, resolved by name —
    /// one owner, so a program line and the vocabulary can never disagree.
    public var exercise: String
    public var targetSets: Int?
    /// Rep range low end — the 8 of "8-10". Nil when the line has no rep target.
    public var targetRepsLow: Int?
    public var targetRepsHigh: Int?
    /// Target RPE on the user's own 1-10 scale.
    public var targetRpe: Double?
    /// Planned working weight in kilograms (v41). A program line plans a weight, not only reps.
    public var targetWeightKg: Double?
    /// Intended rest after each set, seconds.
    public var restSec: Int?
    /// The user's own technique cue, stored and shown back verbatim.
    public var note: String?

    public init(
        id: String,
        deviceId: String,
        programId: String,
        ord: Int,
        exercise: String,
        targetSets: Int?,
        targetRepsLow: Int?,
        targetRepsHigh: Int?,
        targetRpe: Double?,
        targetWeightKg: Double?,
        restSec: Int?,
        note: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.programId = programId
        self.ord = ord
        self.exercise = exercise
        self.targetSets = targetSets
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetRpe = targetRpe
        self.targetWeightKg = targetWeightKg
        self.restSec = restSec
        self.note = note
    }

    static func decode(_ row: Row) -> LiftProgramItemRow {
        LiftProgramItemRow(
            id: row["id"],
            deviceId: row["deviceId"],
            programId: row["programId"],
            ord: row["ord"],
            exercise: row["exercise"],
            targetSets: row["targetSets"],
            targetRepsLow: row["targetRepsLow"],
            targetRepsHigh: row["targetRepsHigh"],
            targetRpe: row["targetRpe"],
            targetWeightKg: row["targetWeightKg"],
            restSec: row["restSec"],
            note: row["note"]
        )
    }
}

/// One gym session. Pairs 1:1 with a `workout` row through (deviceId, startTs, sport).
public struct LiftSessionRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Unix seconds; the same instant as the paired `workout.startTs`.
    public var startTs: Int
    /// Nil while the session is still running.
    public var endTs: Int?
    /// The same string as the paired `workout.sport`.
    public var sport: String
    /// Nil for a freehand session with no program behind it.
    public var programId: String?
    /// The program's name AS IT WAS when the session ran, so a later rename never rewrites history.
    public var programName: String?
    /// Session RPE, 0-10 Borg CR10 (v41). A NUMBER, not a note: Foster's session load is sRPE x
    /// duration, so the rating has to be computable. Nil when the user skipped rating the session.
    public var sessionRpe: Double?
    public var note: String?

    public init(
        id: String,
        deviceId: String,
        startTs: Int,
        endTs: Int?,
        sport: String,
        programId: String?,
        programName: String?,
        sessionRpe: Double?,
        note: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.startTs = startTs
        self.endTs = endTs
        self.sport = sport
        self.programId = programId
        self.programName = programName
        self.sessionRpe = sessionRpe
        self.note = note
    }

    static func decode(_ row: Row) -> LiftSessionRow {
        LiftSessionRow(
            id: row["id"],
            deviceId: row["deviceId"],
            startTs: row["startTs"],
            endTs: row["endTs"],
            sport: row["sport"],
            programId: row["programId"],
            programName: row["programName"],
            sessionRpe: row["sessionRpe"],
            note: row["note"]
        )
    }
}

/// One set. Stored as its own row rather than folded into the session, because per-exercise history
/// ("what did I lift for this last time") has to be answerable from an index.
public struct LiftSetRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var sessionId: String
    /// Order within the whole session, 0-based — reconstructs the order the sets were performed in.
    public var ord: Int
    /// Denormalised deliberately: a session stays readable after its program is edited or deleted.
    public var exercise: String
    /// The classification this set was counted under, snapshotted at log time.
    public var primaryMuscle: LiftMuscle?
    public var secondaryMuscles: [LiftMuscle]
    /// 1-based within this exercise, so "set 3 of 4" survives.
    public var setIndex: Int
    /// Kilograms. Display units convert at the edge; storage is always kg.
    public var weightKg: Double?
    public var reps: Int?
    /// RPE on the user's own 1-10 scale.
    public var rpe: Double?
    /// Warmup sets are recorded but excluded from volume.
    public var isWarmup: Bool
    public var startTs: Int?
    public var endTs: Int?
    /// Rest ACTUALLY taken after this set, seconds — not the target from the program.
    public var restSec: Int?
    public var note: String?

    public init(
        id: String,
        deviceId: String,
        sessionId: String,
        ord: Int,
        exercise: String,
        primaryMuscle: LiftMuscle?,
        secondaryMuscles: [LiftMuscle] = [],
        setIndex: Int,
        weightKg: Double?,
        reps: Int?,
        rpe: Double?,
        isWarmup: Bool,
        startTs: Int?,
        endTs: Int?,
        restSec: Int?,
        note: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.ord = ord
        self.exercise = exercise
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = LiftMuscle.decodeList(
            LiftMuscle.encodeList(secondaryMuscles, excluding: primaryMuscle))
        self.setIndex = setIndex
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.startTs = startTs
        self.endTs = endTs
        self.restSec = restSec
        self.note = note
    }

    /// Volume for this set: weight x reps, in kilograms. Nil unless BOTH are present, and zero for a
    /// warmup — a transparent arithmetic figure, never a physiological claim.
    public var volumeKg: Double? {
        guard !isWarmup, let weightKg, let reps else { return nil }
        return weightKg * Double(reps)
    }

    static func decode(_ row: Row) -> LiftSetRow {
        LiftSetRow(
            id: row["id"],
            deviceId: row["deviceId"],
            sessionId: row["sessionId"],
            ord: row["ord"],
            exercise: row["exercise"],
            primaryMuscle: LiftMuscle(rawValue: row["primaryMuscle"] ?? ""),
            secondaryMuscles: LiftMuscle.decodeList(row["secondaryMuscles"]),
            setIndex: row["setIndex"],
            weightKg: row["weightKg"],
            reps: row["reps"],
            rpe: row["rpe"],
            isWarmup: row["isWarmup"],
            startTs: row["startTs"],
            endTs: row["endTs"],
            restSec: row["restSec"],
            note: row["note"]
        )
    }
}

// MARK: - Store

extension WhoopStore {

    // MARK: Exercises (the user's own vocabulary)

    /// Remember exercises. Keyed on the natural key (deviceId, name), so recording the same name
    /// twice updates its classification and recency instead of duplicating it. A muscle field is
    /// only overwritten when the caller supplies one, so merely using an exercise never erases the
    /// classification the user set for it.
    /// How many exercises one device remembers.
    ///
    /// A cap exists because the vocabulary is typo-accumulating by design: every misspelling becomes
    /// a permanent picker entry ("Chest supported row3"). It is set high enough that no real
    /// training history reaches it — a broad lifter's whole vocabulary is well under a hundred — so
    /// hitting it means something has gone wrong, and the honest response is to say so rather than
    /// to silently drop what the user typed or to evict something they still use.
    ///
    /// An EXISTING name always updates, cap or no cap: only genuinely NEW names are refused.
    public static let maxRememberedExercises = 500

    /// Thrown when the vocabulary is full and the name is a new one.
    public struct LiftExerciseVocabularyFull: Error, Equatable {
        public let limit: Int
        public init(limit: Int) { self.limit = limit }
    }

    @discardableResult
    public func upsertLiftExercises(_ rows: [LiftExerciseRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                // Only a NEW name can push the vocabulary over: re-saving one that already exists is
                // an update and must always be allowed, or a user at the cap could no longer correct
                // the classification of an exercise they use every week.
                let known = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM liftExercise WHERE deviceId = ? AND name = ?
                    """, arguments: [r.deviceId, r.name]) ?? 0
                if known == 0 {
                    let total = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM liftExercise WHERE deviceId = ?
                        """, arguments: [r.deviceId]) ?? 0
                    if total >= WhoopStore.maxRememberedExercises {
                        throw LiftExerciseVocabularyFull(limit: WhoopStore.maxRememberedExercises)
                    }
                }
                try db.execute(sql: """
                    INSERT INTO liftExercise
                        (id, deviceId, name, primaryMuscle, secondaryMuscles, createdAt, lastUsedTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, name) DO UPDATE SET
                        primaryMuscle = COALESCE(excluded.primaryMuscle, primaryMuscle),
                        secondaryMuscles = COALESCE(excluded.secondaryMuscles, secondaryMuscles),
                        lastUsedTs = MAX(COALESCE(excluded.lastUsedTs, 0), COALESCE(lastUsedTs, 0))
                    """, arguments: [
                        r.id, r.deviceId, r.name,
                        r.primaryMuscle?.rawValue,
                        LiftMuscle.encodeList(r.secondaryMuscles, excluding: r.primaryMuscle),
                        r.createdAt, r.lastUsedTs,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// The user's exercises, most recently used first and never-used ones after, alphabetical within
    /// each. This is the picker's list — built entirely from what they have typed.
    public func liftExercises(deviceId: String) async throws -> [LiftExerciseRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftExercise
                WHERE deviceId = ?
                ORDER BY COALESCE(lastUsedTs, 0) DESC, name ASC
                """, arguments: [deviceId]).map(LiftExerciseRow.decode)
        }
    }

    /// Forget one exercise from the vocabulary. Sets already logged under that name are untouched —
    /// they carry their own copy of the name and muscle group, so history never loses meaning.
    @discardableResult
    public func deleteLiftExercise(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftExercise WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: Programs

    /// Upsert programs by `id`. Returns rows written.
    @discardableResult
    public func upsertLiftPrograms(_ rows: [LiftProgramRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftProgram
                        (id, deviceId, name, note, createdAt, updatedAt, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        note = excluded.note,
                        updatedAt = excluded.updatedAt,
                        archived = excluded.archived
                    """, arguments: [
                        r.id, r.deviceId, r.name, r.note, r.createdAt, r.updatedAt, r.archived,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Programs for a device, most recently touched first. `includeArchived` defaults false so the
    /// picker shows only live programs.
    public func liftPrograms(deviceId: String, includeArchived: Bool = false) async throws -> [LiftProgramRow] {
        try syncRead { db in
            let sql = includeArchived
                ? """
                  SELECT * FROM liftProgram
                  WHERE deviceId = ?
                  ORDER BY updatedAt DESC
                  """
                : """
                  SELECT * FROM liftProgram
                  WHERE deviceId = ? AND archived = 0
                  ORDER BY updatedAt DESC
                  """
            return try Row.fetchAll(db, sql: sql, arguments: [deviceId]).map(LiftProgramRow.decode)
        }
    }

    /// Delete a program and its item lines. Sessions already run from it are NOT touched — they
    /// carry their own `programName` snapshot, so history survives the program's deletion.
    /// Returns true if a program row was removed.
    @discardableResult
    public func deleteLiftProgram(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftProgramItem WHERE programId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM liftProgram WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: Program items

    /// Replace a program's item lines wholesale. The editor hands back the whole list, and deleting
    /// then reinserting inside one transaction avoids reconciling removals and reorders row by row.
    @discardableResult
    public func replaceLiftProgramItems(programId: String, items: [LiftProgramItemRow]) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftProgramItem WHERE programId = ?", arguments: [programId])
            var n = 0
            for r in items {
                try db.execute(sql: """
                    INSERT INTO liftProgramItem
                        (id, deviceId, programId, ord, exercise, targetSets,
                         targetRepsLow, targetRepsHigh, targetRpe, targetWeightKg, restSec, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        r.id, r.deviceId, r.programId, r.ord, r.exercise, r.targetSets,
                        r.targetRepsLow, r.targetRepsHigh, r.targetRpe, r.targetWeightKg,
                        r.restSec, r.note,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// A program's exercise lines in program order.
    public func liftProgramItems(programId: String) async throws -> [LiftProgramItemRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftProgramItem
                WHERE programId = ?
                ORDER BY ord ASC
                """, arguments: [programId]).map(LiftProgramItemRow.decode)
        }
    }

    // MARK: Sessions

    /// Upsert sessions. Keyed on the NATURAL key (deviceId, startTs, sport) rather than the `id` PK,
    /// so re-saving the same session updates it in place even if the caller minted a fresh id — the
    /// labMarker rule, and what keeps this row paired 1:1 with its `workout` row.
    @discardableResult
    public func upsertLiftSessions(_ rows: [LiftSessionRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftSession
                        (id, deviceId, startTs, endTs, sport, programId, programName,
                         sessionRpe, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        programId = excluded.programId,
                        programName = excluded.programName,
                        sessionRpe = excluded.sessionRpe,
                        note = excluded.note
                    """, arguments: [
                        r.id, r.deviceId, r.startTs, r.endTs, r.sport,
                        r.programId, r.programName, r.sessionRpe, r.note,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Sessions for a device that started within `[fromTs, toTs]` inclusive, most recent first.
    public func liftSessions(deviceId: String, fromTs: Int, toTs: Int) async throws -> [LiftSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs DESC
                """, arguments: [deviceId, fromTs, toTs]).map(LiftSessionRow.decode)
        }
    }

    /// Delete a session and every set in it. Returns true if a session row was removed.
    @discardableResult
    public func deleteLiftSession(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM liftSet WHERE sessionId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM liftSession WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: Sets

    /// Upsert sets by `id`. Called as each set is logged, so a session in progress is durable set by
    /// set rather than only on finish.
    @discardableResult
    public func upsertLiftSets(_ rows: [LiftSetRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO liftSet
                        (id, deviceId, sessionId, ord, exercise, primaryMuscle, secondaryMuscles,
                         setIndex, weightKg, reps, rpe, isWarmup, startTs, endTs, restSec, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        ord = excluded.ord,
                        exercise = excluded.exercise,
                        primaryMuscle = excluded.primaryMuscle,
                        secondaryMuscles = excluded.secondaryMuscles,
                        setIndex = excluded.setIndex,
                        weightKg = excluded.weightKg,
                        reps = excluded.reps,
                        rpe = excluded.rpe,
                        isWarmup = excluded.isWarmup,
                        startTs = excluded.startTs,
                        endTs = excluded.endTs,
                        restSec = excluded.restSec,
                        note = excluded.note
                    """, arguments: [
                        r.id, r.deviceId, r.sessionId, r.ord, r.exercise,
                        r.primaryMuscle?.rawValue,
                        LiftMuscle.encodeList(r.secondaryMuscles, excluding: r.primaryMuscle),
                        r.setIndex, r.weightKg, r.reps, r.rpe, r.isWarmup,
                        r.startTs, r.endTs, r.restSec, r.note,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Every set in a session, in the order they were performed.
    public func liftSets(sessionId: String) async throws -> [LiftSetRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftSet
                WHERE sessionId = ?
                ORDER BY ord ASC
                """, arguments: [sessionId]).map(LiftSetRow.decode)
        }
    }

    /// The sets from the most recent session that contained `exercise`, in performed order.
    ///
    /// This is the read the whole feature exists for: it pre-fills the next session with what you
    /// actually did last time, which the user then confirms or overrides. Empty when the exercise
    /// has never been logged. `before` excludes the session currently in progress (pass its
    /// `startTs`) so a running session never pre-fills from itself.
    public func lastLiftSets(deviceId: String, exercise: String, before: Int? = nil) async throws -> [LiftSetRow] {
        try syncRead { db in
            // Two steps rather than a correlated subquery: find the latest qualifying session, then
            // read its sets in order. Served by idx_liftSet_device_exercise + idx_liftSession_natural.
            let cutoff = before ?? Int.max
            guard let sessionId = try String.fetchOne(db, sql: """
                SELECT s.sessionId FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ? AND s.exercise = ? AND sess.startTs < ?
                ORDER BY sess.startTs DESC
                LIMIT 1
                """, arguments: [deviceId, exercise, cutoff]) else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM liftSet
                WHERE sessionId = ? AND exercise = ?
                ORDER BY ord ASC
                """, arguments: [sessionId, exercise]).map(LiftSetRow.decode)
        }
    }

    /// Per-muscle working-set counts over `[fromTs, toTs]`, from the classification each set was
    /// logged under.
    ///
    /// `fractional` is the headline figure: direct sets count 1, indirect sets count 0.5. That is
    /// not a house convention — the 2025 dose-response meta-regression tested exactly this choice
    /// against counting indirect sets as 1 and as 0, and the evidence was strongest for 0.5, which
    /// its primary models then used. The reference doses NOOP displays come from those models, so
    /// the count and the reference must stay on the same method.
    ///
    /// `direct` and `indirect` are returned alongside so the arithmetic is inspectable rather than
    /// asserted.
    ///
    /// **Warm-ups are excluded; nothing else is.** In particular this does NOT filter by RPE, even
    /// though a hard set is the thing that drives adaptation — because the reference doses were
    /// derived from unfiltered working-set counts, and filtering here would quietly compare a
    /// smaller number against a scale built from a larger one. Proximity to failure is reported
    /// separately by `LiftMetrics.rpeProfile` instead, where it can inform without corrupting the count.
    public func liftSetCounts(
        deviceId: String,
        fromTs: Int,
        toTs: Int
    ) async throws -> (fractional: [LiftMuscle: Double], direct: [LiftMuscle: Int], indirect: [LiftMuscle: Int]) {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.primaryMuscle AS primaryMuscle, s.secondaryMuscles AS secondaryMuscles
                FROM liftSet s
                JOIN liftSession sess ON sess.id = s.sessionId
                WHERE s.deviceId = ?
                  AND sess.startTs >= ? AND sess.startTs <= ?
                  AND s.isWarmup = 0
                """, arguments: [deviceId, fromTs, toTs])

            var direct: [LiftMuscle: Int] = [:]
            var indirect: [LiftMuscle: Int] = [:]
            for row in rows {
                if let token: String = row["primaryMuscle"], let m = LiftMuscle(rawValue: token) {
                    direct[m, default: 0] += 1
                }
                // A muscle listed BOTH as primary and as secondary is credited once, as direct.
                // `LiftMuscle.encodeList(_:excluding:)` already strips the primary on the way in, so
                // today no stored row needs this — but "today no row needs it" is not a guarantee,
                // and without the guard this aggregation and `LiftMetrics.muscleCounts` (which has
                // always had it) would report DIFFERENT numbers for the same set: the hub's weekly
                // card and the session detail, disagreeing, with nothing to catch it. The two are
                // pinned against each other by
                // `LiftMetricsStoreAgreementTests.testBothImplementationsAgree…`.
                let primary: LiftMuscle? = (row["primaryMuscle"] as String?).flatMap(LiftMuscle.init(rawValue:))
                for m in LiftMuscle.decodeList(row["secondaryMuscles"]) where m != primary {
                    indirect[m, default: 0] += 1
                }
            }
            var fractional: [LiftMuscle: Double] = [:]
            for (m, n) in direct { fractional[m, default: 0] += Double(n) * LiftMuscle.directSetCredit }
            for (m, n) in indirect { fractional[m, default: 0] += Double(n) * LiftMuscle.indirectSetCredit }
            return (fractional, direct, indirect)
        }
    }

}
