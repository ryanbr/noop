package com.noop.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * The in-app strength log — the Room half of GRDB's `v46-lift-log`.
 *
 * Five `deviceId`-keyed tables holding saved programs and the sessions run from them. The Apple side
 * ships the screens that read and write these; this is the SCHEMA twin, landed with the migration
 * rather than after it, because `docs/CONTRIBUTING.md` is explicit that a migration cannot land
 * until its twin does and that the oracle's divergence ledger should only ever shrink.
 *
 * WHAT THIS DELIBERATELY IS NOT. There is no DAO and no Compose UI here yet, so nothing on Android
 * reads or writes these tables today. That is a stated gap, not an oversight: the value of a gym log
 * book is entirely in how it feels to tap through between sets with the phone face-down, and screens
 * written without a device to try them on would compile and be bad to use. An Android user should
 * take that half. What is landed here is the half that CAN be proved correct without a device —
 * `SchemaOracleTest` compares Room's KSP-exported schema against the same `schema_oracle.json` the
 * GRDB suite checks, so a column, order, affinity, nullability, default, key or index that drifts
 * from Apple's fails this build.
 *
 * FIELD ORDER IS THE CONTRACT. Room emits columns in declaration order, so each class below follows
 * its GRDB `create(table:)` exactly; a reordering here is a real schema divergence even though every
 * column still exists (`CLAUDE.md`, and the `battery-alter-append-order` ledger entry that records
 * what it costs to fix one after the fact).
 *
 * Two shapes worth naming:
 *  - `archived` and `isWarmup` carry `@ColumnInfo(defaultValue = "0")`. A Kotlin constructor default
 *    never reaches the schema — only the annotation does — and GRDB declares both NOT NULL DEFAULT 0.
 *    Leaving the annotation off would reproduce the `room-omits-sql-default` divergence on brand-new
 *    tables, which is the one chance there is to simply not have it.
 *  - Each `id` is a non-null Kotlin `String`, so Room writes `id TEXT NOT NULL, PRIMARY KEY(id)`
 *    while SQLite's legacy quirk leaves GRDB's `id TEXT PRIMARY KEY` nullable. That is the existing
 *    `sqlite-text-pk-nullable` ledger entry, which every TEXT-keyed table on both platforms already
 *    carries; no writer on either side ever supplies a null id.
 */

/**
 * The user's own exercise vocabulary. NOOP ships **no** exercise catalogue and no exercise→muscle
 * mapping: the name is whatever the user types, and the muscles are the ones they assigned. A closed
 * catalogue silently mis-attributes everything it fails to recognise.
 */
@Entity(
    tableName = "liftExercise",
    indices = [
        Index(name = "idx_liftExercise_natural", value = ["deviceId", "name"], unique = true),
    ],
)
data class LiftExerciseRow(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    val name: String,
    /** A `LiftMuscle` raw value. A stored-data contract: never rename or remove a token. */
    val primaryMuscle: String? = null,
    /** Comma-separated `LiftMuscle` raw values, same contract. */
    val secondaryMuscles: String? = null,
    val createdAt: Long,
    /** Unix seconds; recency, so the picker can offer what was used most recently. */
    val lastUsedTs: Long? = null,
)

/** A reusable program, e.g. "Upper A". Archived rather than deleted, so history keeps resolving. */
@Entity(
    tableName = "liftProgram",
    indices = [
        Index(name = "idx_liftProgram_device_updatedAt", value = ["deviceId", "updatedAt"]),
    ],
)
data class LiftProgramRow(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    val name: String,
    val note: String? = null,
    val createdAt: Long,
    /** Unix seconds; drives most-recent-first ordering in the hub. */
    val updatedAt: Long,
    @ColumnInfo(defaultValue = "0")
    val archived: Boolean = false,
)

/**
 * One exercise line inside a program: the TARGETS. What actually happened lives in [LiftSetEntity].
 *
 * A line plans a WEIGHT, not only a rep range — `targetWeightKg` — because a program that cannot say
 * how heavy is not a program anyone follows.
 */
@Entity(
    tableName = "liftProgramItem",
    indices = [
        Index(name = "idx_liftProgramItem_device", value = ["deviceId"]),
        Index(name = "idx_liftProgramItem_program_ord", value = ["programId", "ord"]),
    ],
)
data class LiftProgramItemRow(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    val programId: String,
    /** Position within the program, 0-based. */
    val ord: Int,
    val exercise: String,
    val targetSets: Int? = null,
    /** Rep-range low end — the 8 of "8-10". */
    val targetRepsLow: Int? = null,
    val targetRepsHigh: Int? = null,
    /** Target RPE on the user's own 1-10 scale. */
    val targetRpe: Double? = null,
    val targetWeightKg: Double? = null,
    /** Intended rest after each set, seconds. */
    val restSec: Int? = null,
    /** The user's own technique cue, stored and shown back verbatim. */
    val note: String? = null,
)

/**
 * One gym session. Pairs 1:1 with a `workout` row through the natural key
 * `(deviceId, startTs, sport)`, which is why that index is UNIQUE.
 *
 * `sessionRpe` is a NUMBER rather than text appended to the note: Foster's session load is
 * sRPE x duration, so the rating has to be computable or the metric cannot be derived at all.
 */
@Entity(
    tableName = "liftSession",
    indices = [
        Index(name = "idx_liftSession_natural", value = ["deviceId", "startTs", "sport"], unique = true),
    ],
)
data class LiftSessionRow(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    /** Unix seconds; the same instant as the paired `workout.startTs`. */
    val startTs: Long,
    /** Nil while the session is still running. */
    val endTs: Long? = null,
    /** The same token as the paired `workout.sport`. */
    val sport: String,
    /** Nil for a freehand session with no program behind it. */
    val programId: String? = null,
    /** The program's name AS IT WAS, so a later rename never rewrites history. */
    val programName: String? = null,
    val sessionRpe: Double? = null,
    val note: String? = null,
)

/**
 * One set as performed — rows, not a JSON blob, because "what did I lift for this exercise last
 * time" is the read the whole feature exists for, and against a blob it is not answerable by an
 * index.
 *
 * `primaryMuscle` / `secondaryMuscles` are snapshotted AS THEY WERE at log time, so reclassifying an
 * exercise later never silently rewrites what past weeks were counted as.
 *
 * Named `LiftSetEntity` rather than `LiftSetRow` only because `Row` is already this package's name
 * for several unrelated types; the TABLE is `liftSet`, which is what the oracle compares.
 */
@Entity(
    tableName = "liftSet",
    indices = [
        Index(name = "idx_liftSet_device_exercise", value = ["deviceId", "exercise"]),
        Index(name = "idx_liftSet_session_ord", value = ["sessionId", "ord"]),
    ],
)
data class LiftSetEntity(
    @PrimaryKey
    val id: String,
    val deviceId: String,
    val sessionId: String,
    /** Order within the session — COMPLETION order, which with out-of-order work is not plan order. */
    val ord: Int,
    val exercise: String,
    val primaryMuscle: String? = null,
    val secondaryMuscles: String? = null,
    /** 1-based within its exercise. */
    val setIndex: Int,
    /** Kilograms. Display units convert; storage does not. */
    val weightKg: Double? = null,
    val reps: Int? = null,
    /** 1-10 as rated by the user, and never carried from another set. */
    val rpe: Double? = null,
    /** Warm-ups are excluded from volume and from the per-muscle counts. */
    @ColumnInfo(defaultValue = "0")
    val isWarmup: Boolean = false,
    val startTs: Long? = null,
    val endTs: Long? = null,
    /** Rest ACTUALLY taken after this set, measured from the taps rather than planned. */
    val restSec: Int? = null,
    val note: String? = null,
)
