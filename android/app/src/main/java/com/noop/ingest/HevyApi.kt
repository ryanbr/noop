package com.noop.ingest

import org.json.JSONArray
import org.json.JSONObject
import java.time.ZoneId

/**
 * Parsers for the Hevy Web API endpoints beyond `GET /v1/workouts`, which [LiftingImporter] already
 * folds into Strength sessions.
 *
 * Kotlin mirror of the macOS/iOS source of truth
 *   Packages/StrandImport/Sources/StrandImport/HevyAPI.swift
 *
 * Verified against Hevy's published OpenAPI spec (api.hevyapp.com/docs). Every endpoint takes the
 * user's own `api-key` header, and the paginated ones take `page` / `pageSize` - note the defaults
 * are SMALL (5, or 10 for body measurements), so a caller that reads one page has almost certainly
 * not read the account.
 *
 * Parsing only, deliberately: there is no client, and the transport question (whether an
 * offline-first app should hold an API key at all) is unanswered. These are pure so the shape can be
 * pinned by tests now and the decision taken later. Tolerant throughout, because this runs over
 * another server's data: a malformed element is skipped and counted, never fatal.
 */
object HevyApi {

    /**
     * Hevy's published muscle-group vocabulary, attached to an exercise TEMPLATE rather than to a
     * logged set.
     *
     * This matters more than it looks: an exercise carries `exercise_template_id`, so this is
     * authoritative attribution for the exercise a set was performed on, from the people who own the
     * catalogue. Anything NOOP derives by matching exercise TITLES is guessing at data published
     * here.
     *
     * An unrecognised value parses to null rather than to [OTHER], because Hevy defines `other` as a
     * real category and folding a newly-added group into it would silently mislabel it.
     */
    enum class MuscleGroup(val wire: String) {
        ABDOMINALS("abdominals"),
        SHOULDERS("shoulders"),
        BICEPS("biceps"),
        TRICEPS("triceps"),
        FOREARMS("forearms"),
        QUADRICEPS("quadriceps"),
        HAMSTRINGS("hamstrings"),
        CALVES("calves"),
        GLUTES("glutes"),
        ABDUCTORS("abductors"),
        ADDUCTORS("adductors"),
        LATS("lats"),
        UPPER_BACK("upper_back"),
        TRAPS("traps"),
        LOWER_BACK("lower_back"),
        CHEST("chest"),
        CARDIO("cardio"),
        NECK("neck"),
        FULL_BODY("full_body"),
        OTHER("other"),
        ;

        companion object {
            private val byWire = entries.associateBy { it.wire }

            /** Resolve a wire value, or null when Hevy has added a group this build does not know. */
            fun from(raw: String?): MuscleGroup? = raw?.lowercase()?.let { byWire[it] }
        }
    }

    /**
     * One page of a paginated Hevy response. [pageCount] is the total number of pages, so a caller
     * keeps going while [hasMore].
     */
    data class Page<T>(
        val items: List<T>,
        val page: Int,
        val pageCount: Int,
        /**
         * Elements that were present but unusable. Non-zero means the response was understood and
         * something in it was not, which is different from an empty page.
         */
        val skipped: Int,
    ) {
        val hasMore: Boolean get() = page < pageCount
    }

    /**
     * An entry in Hevy's exercise catalogue. [equipment] and [type] stay raw strings: nothing in
     * NOOP consumes them yet, and an enum would only add a drift risk when Hevy adds a value.
     */
    data class ExerciseTemplate(
        val id: String,
        val title: String,
        val type: String?,
        val primaryMuscleGroup: MuscleGroup?,
        val secondaryMuscleGroups: List<MuscleGroup>,
        val equipment: String?,
        val isCustom: Boolean,
    )

    /**
     * A body-composition entry.
     *
     * The date is kept as Hevy writes it (a bare `yyyy-MM-dd`, no time and no zone) rather than
     * resolved to an instant here. Choosing a moment inside that day is a real decision with a real
     * failure mode - NOOP already re-buckets nights when an offset changes - and it belongs to
     * whatever stores the sample, not to the parser.
     *
     * Hevy also returns fourteen circumference fields (neck, chest, each bicep, each thigh, and so
     * on). They are deliberately not modelled: nothing in NOOP consumes them, and an unused field is
     * a schema commitment with no payer.
     */
    data class BodyMeasurement(
        val date: String,
        val weightKg: Double?,
        val fatPercent: Double?,
        val leanMassKg: Double?,
    ) {
        /**
         * True when the entry carries none of the three figures NOOP could use, which is the case
         * for an entry that only recorded circumferences.
         */
        val isEmpty: Boolean get() = weightKg == null && fatPercent == null && leanMassKg == null
    }

    /**
     * Whose account a key belongs to. Worth a call before an import, so a wrong key fails with
     * "that key isn't yours" rather than with an empty history.
     */
    data class UserInfo(val id: String, val name: String?, val url: String?)

    /**
     * A change to the account since a given moment: either a workout in its current form, or the id
     * of one that is gone.
     *
     * This is the endpoint that would make an API import worth having over the CSV export, because
     * it is the only one that reports DELETIONS. It is also the one that exposes what NOOP does not
     * yet store: a workout row is keyed by (deviceId, startTs), and neither event can be applied
     * through that key. A delete names a Hevy id NOOP never kept, and an edit that moved the start
     * time would land as a second session rather than replacing the first. Persisting Hevy's id
     * alongside the row is the missing piece, and it is a schema change on both platforms.
     */
    sealed interface WorkoutEvent {
        /** The Hevy workout id an event refers to, which is the key NOOP would have to have stored. */
        val workoutId: String

        data class Updated(override val workoutId: String, val session: LiftingImporter.Session) : WorkoutEvent
        data class Deleted(override val workoutId: String, val deletedAtTs: Long?) : WorkoutEvent
    }

    // MARK: - GET /v1/workouts/events

    /**
     * Parse a workout-events page (`since` defaults to the epoch, so an unqualified call replays the
     * whole account).
     *
     * An `updated` event carries the same workout shape a page does and is folded by the same code
     * path, so an edit cannot arrive with different arithmetic from the workout it edits. An update
     * whose sets all fold away - every set deleted, or every set turned into a warm-up - yields no
     * session and is counted as skipped; it is NOT a deletion, and treating it as one would drop a
     * workout the user still has.
     */
    fun parseWorkoutEvents(data: ByteArray, zone: ZoneId = ZoneId.systemDefault()): Page<WorkoutEvent> =
        parsePage(data, "events") { dict ->
            when (dict.optString("type").lowercase()) {
                "updated" -> {
                    val w = dict.optJSONObject("workout")
                    val id = w?.optString("id")?.ifEmpty { null }
                    val session = w?.let { LiftingImporter.hevyAccumulator(it, zone) }?.toSession()
                    if (id != null && session != null) WorkoutEvent.Updated(id, session) else null
                }
                "deleted" -> dict.optString("id").ifEmpty { null }?.let { id ->
                    WorkoutEvent.Deleted(
                        id,
                        dict.optString("deleted_at").ifEmpty { null }
                            ?.let { LiftingImporter.parseEpochSeconds(it, zone) },
                    )
                }
                else -> null
            }
        }

    // MARK: - GET /v1/exercise_templates

    /**
     * Parse an exercise-template page. A template with no id or no title is unusable as a join
     * target, so it is skipped rather than stored half-formed.
     */
    fun parseExerciseTemplates(data: ByteArray): Page<ExerciseTemplate> =
        parsePage(data, "exercise_templates") { dict ->
            val id = dict.optString("id").ifEmpty { null }
            val title = dict.optString("title").ifEmpty { null }
            if (id == null || title == null) return@parsePage null
            val secondaryRaw = dict.optJSONArray("secondary_muscle_groups") ?: JSONArray()
            val secondary = (0 until secondaryRaw.length())
                .mapNotNull { MuscleGroup.from(secondaryRaw.optString(it).ifEmpty { null }) }
            ExerciseTemplate(
                id = id,
                title = title,
                type = dict.optString("type").ifEmpty { null },
                primaryMuscleGroup = MuscleGroup.from(dict.optString("primary_muscle_group").ifEmpty { null }),
                secondaryMuscleGroups = secondary,
                equipment = dict.optString("equipment").ifEmpty { null },
                isCustom = dict.optBoolean("is_custom", false),
            )
        }

    // MARK: - GET /v1/body_measurements

    /**
     * Parse a body-measurement page. An entry with no date cannot be filed, and one carrying only
     * circumferences has nothing NOOP can store, so both are skipped and counted.
     */
    fun parseBodyMeasurements(data: ByteArray): Page<BodyMeasurement> =
        parsePage(data, "body_measurements") { dict ->
            val date = dict.optString("date").trim().ifEmpty { null } ?: return@parsePage null
            val entry = BodyMeasurement(
                date = date,
                weightKg = positive(dict.opt("weight_kg")),
                fatPercent = LiftingImporter.jsonDouble(dict.opt("fat_percent")),
                leanMassKg = positive(dict.opt("lean_mass_kg")),
            )
            if (entry.isEmpty) null else entry
        }

    // MARK: - GET /v1/workouts/count and /v1/user/info

    /**
     * Parse `{ "workout_count": 42 }`. A cheap way to ask whether anything has changed before paging
     * the whole history at a default page size of five.
     */
    fun parseWorkoutCount(data: ByteArray): Int? {
        val root = obj(data) ?: return null
        val n = LiftingImporter.jsonDouble(root.opt("workout_count")) ?: return null
        return if (n >= 0 && n < 1e9) n.toInt() else null
    }

    /** Parse `{ "data": { "id": …, "name": …, "url": … } }`. */
    fun parseUserInfo(data: ByteArray): UserInfo? {
        val root = obj(data) ?: return null
        // The payload nests under `data`; tolerate a bare object too, since a caller that has already
        // unwrapped one should not get a silent null.
        val dict = root.optJSONObject("data") ?: root
        val id = dict.optString("id").ifEmpty { null } ?: return null
        return UserInfo(id, dict.optString("name").ifEmpty { null }, dict.optString("url").ifEmpty { null })
    }

    // MARK: - Shared

    /**
     * The `page` / `page_count` pair off any paginated Hevy body, for a caller that wants to know how
     * far it has to go before it has parsed the elements.
     */
    fun parsePagination(data: ByteArray): Pair<Int, Int>? {
        val root = obj(data) ?: return null
        return pageNumber(root.opt("page"), 1) to pageNumber(root.opt("page_count"), 1)
    }

    private fun text(data: ByteArray): String =
        Bom.stripString(String(Bom.stripUtf8(data), Charsets.UTF_8)).trim()

    private fun obj(data: ByteArray): JSONObject? =
        runCatching { JSONObject(text(data)) }.getOrNull()

    /**
     * Fold a `{ page, page_count, <key>: [...] }` envelope. A bare array is accepted as well, so a
     * caller that already unwrapped a page is not forced back into the envelope.
     */
    private fun <T> parsePage(data: ByteArray, key: String, element: (JSONObject) -> T?): Page<T> {
        val body = text(data)
        var page = 1
        var pageCount = 1
        val raw: JSONArray = if (body.startsWith("[")) {
            runCatching { JSONArray(body) }.getOrNull() ?: JSONArray()
        } else {
            val root = runCatching { JSONObject(body) }.getOrNull()
            page = pageNumber(root?.opt("page"), 1)
            pageCount = pageNumber(root?.opt("page_count"), 1)
            root?.optJSONArray(key) ?: JSONArray()
        }

        val items = ArrayList<T>(raw.length())
        var skipped = 0
        for (i in 0 until raw.length()) {
            val dict = raw.optJSONObject(i)
            val parsed = dict?.let { element(it) }
            if (parsed == null) skipped++ else items.add(parsed)
        }
        return Page(items, page, pageCount, skipped)
    }

    /**
     * A page number, bounded. Hevy sends integers, but this runs over another server's data and the
     * value ends up in a loop condition.
     */
    private fun pageNumber(any: Any?, fallback: Int): Int {
        val d = LiftingImporter.jsonDouble(any) ?: return fallback
        return if (d >= 1 && d < 1e7) d.toInt() else fallback
    }

    /**
     * A measurement that must be positive to mean anything. A zero body weight is a cleared field,
     * not a reading, and storing it would drag an average down.
     */
    private fun positive(any: Any?): Double? = LiftingImporter.jsonDouble(any)?.takeIf { it > 0 }
}
