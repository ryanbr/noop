import Foundation

/// Parsers for the Hevy Web API endpoints beyond `GET /v1/workouts`, which `LiftingImporter` already
/// folds into Strength sessions.
///
/// Verified against Hevy's published OpenAPI spec (api.hevyapp.com/docs). Every endpoint takes the
/// user's own `api-key` header, and the paginated ones take `page` / `pageSize` — note the defaults
/// are SMALL (5, or 10 for body measurements), so a caller that reads one page has almost certainly
/// not read the account.
///
/// Parsing only, deliberately: there is no client, and the transport question (whether an
/// offline-first app should hold an API key at all) is unanswered. These are pure so the shape can be
/// pinned by tests now and the decision taken later. Tolerant throughout, because this runs over
/// another server's data: a malformed element is skipped and counted, never fatal.
public enum HevyAPI {

    // MARK: - Muscle groups

    /// Hevy's published muscle-group vocabulary, attached to an exercise TEMPLATE rather than to a
    /// logged set.
    ///
    /// This matters more than it looks: an exercise carries `exercise_template_id`, so this is
    /// authoritative attribution for the exercise a set was performed on, from the people who own the
    /// catalogue. Anything NOOP derives by matching exercise TITLES is guessing at data that is
    /// published here.
    ///
    /// An unrecognised value parses to nil rather than to `.other`, because Hevy defines `other` as a
    /// real category and folding a newly-added group into it would silently mislabel it.
    public enum MuscleGroup: String, Sendable, CaseIterable {
        case abdominals
        case shoulders
        case biceps
        case triceps
        case forearms
        case quadriceps
        case hamstrings
        case calves
        case glutes
        case abductors
        case adductors
        case lats
        case upperBack = "upper_back"
        case traps
        case lowerBack = "lower_back"
        case chest
        case cardio
        case neck
        case fullBody = "full_body"
        case other
    }

    // MARK: - Models

    /// One page of a paginated Hevy response. `pageCount` is the total number of pages, so a caller
    /// keeps going while `page < pageCount`.
    public struct Page<Element: Sendable>: Sendable {
        public let items: [Element]
        public let page: Int
        public let pageCount: Int
        /// Elements that were present but unusable. Non-zero means the response was understood and
        /// something in it was not, which is different from an empty page.
        public let skipped: Int

        public var hasMore: Bool { page < pageCount }
    }

    /// An entry in Hevy's exercise catalogue. `equipment` and `type` stay raw strings: nothing in
    /// NOOP consumes them yet, and an enum would only add a drift risk when Hevy adds a value.
    public struct ExerciseTemplate: Sendable, Equatable {
        public let id: String
        public let title: String
        public let type: String?
        public let primaryMuscleGroup: MuscleGroup?
        public let secondaryMuscleGroups: [MuscleGroup]
        public let equipment: String?
        public let isCustom: Bool
    }

    /// A body-composition entry.
    ///
    /// The date is kept as Hevy writes it (a bare `yyyy-MM-dd`, no time and no zone) rather than
    /// resolved to an instant here. Choosing a moment inside that day is a real decision with a real
    /// failure mode -- NOOP already re-buckets nights when an offset changes -- and it belongs to
    /// whatever stores the sample, not to the parser.
    ///
    /// Hevy also returns fourteen circumference fields (neck, chest, each bicep, each thigh, and so
    /// on). They are deliberately not modelled: nothing in NOOP consumes them, and an unused field is
    /// a schema commitment with no payer.
    public struct BodyMeasurement: Sendable, Equatable {
        public let date: String
        public let weightKg: Double?
        public let fatPercent: Double?
        public let leanMassKg: Double?

        /// True when the entry carries none of the three figures NOOP could use, which is the case
        /// for an entry that only recorded circumferences.
        public var isEmpty: Bool { weightKg == nil && fatPercent == nil && leanMassKg == nil }
    }

    /// Whose account a key belongs to. Worth a call before an import, so a wrong key fails with
    /// "that key isn't yours" rather than with an empty history.
    public struct UserInfo: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let url: String?
    }

    /// A change to the account since a given moment: either a workout in its current form, or the id
    /// of one that is gone.
    ///
    /// This is the endpoint that would make an API import worth having over the CSV export, because
    /// it is the only one that reports DELETIONS. It is also the one that exposes what NOOP does not
    /// yet store: a workout row is keyed by `(deviceId, startTs)`, and neither event can be applied
    /// through that key. A delete names a Hevy id NOOP never kept, and an edit that moved the start
    /// time would land as a second session rather than replacing the first. Persisting Hevy's id
    /// alongside the row is the missing piece, and it is a schema change on both platforms.
    public enum WorkoutEvent: Sendable {
        case updated(id: String, session: LiftingSession)
        case deleted(id: String, deletedAt: Date?)

        /// The Hevy workout id an event refers to, which is the key NOOP would have to have stored.
        public var workoutID: String {
            switch self {
            case let .updated(id, _): return id
            case let .deleted(id, _): return id
            }
        }
    }

    // MARK: - GET /v1/workouts/events

    /// Parse a workout-events page (`since` defaults to the epoch, so an unqualified call replays the
    /// whole account).
    ///
    /// An `updated` event carries the same `Workout` shape a page does and is folded by the same code
    /// path, so an edit cannot arrive with different arithmetic from the workout it edits. An update
    /// whose sets all fold away -- every set deleted, or every set turned into a warm-up -- yields no
    /// session and is counted as skipped; it is NOT a deletion, and treating it as one would drop a
    /// workout the user still has.
    public static func parseWorkoutEvents(data: Data, zone: TimeZone = .current) -> Page<WorkoutEvent> {
        // The closure is annotated because `Element` is inferred FROM it: leading-dot `.updated`
        // has nothing to resolve against until the return type is spelled out.
        parsePage(data, key: "events") { (dict: [String: Any]) -> WorkoutEvent? in
            switch (dict["type"] as? String)?.lowercased() {
            case "updated":
                guard let w = dict["workout"] as? [String: Any],
                      let id = w["id"] as? String, !id.isEmpty,
                      let acc = LiftingImporter.hevyAccumulator(from: w, zone: zone),
                      let session = acc.session else { return nil }
                return .updated(id: id, session: session)
            case "deleted":
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                return .deleted(id: id,
                                deletedAt: (dict["deleted_at"] as? String)
                                    .flatMap { LiftingImporter.parseDate($0, zone: zone) })
            default:
                return nil
            }
        }
    }

    // MARK: - GET /v1/exercise_templates

    /// Parse an exercise-template page. A template with no id or no title is unusable as a join
    /// target, so it is skipped rather than stored half-formed.
    public static func parseExerciseTemplates(data: Data) -> Page<ExerciseTemplate> {
        parsePage(data, key: "exercise_templates") { dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let title = dict["title"] as? String, !title.isEmpty else { return nil }
            let secondary = ((dict["secondary_muscle_groups"] as? [Any]) ?? [])
                .compactMap { $0 as? String }
                .compactMap { MuscleGroup(rawValue: $0.lowercased()) }
            return ExerciseTemplate(
                id: id,
                title: title,
                type: dict["type"] as? String,
                primaryMuscleGroup: (dict["primary_muscle_group"] as? String)
                    .flatMap { MuscleGroup(rawValue: $0.lowercased()) },
                secondaryMuscleGroups: secondary,
                equipment: dict["equipment"] as? String,
                isCustom: (dict["is_custom"] as? Bool) ?? false
            )
        }
    }

    // MARK: - GET /v1/body_measurements

    /// Parse a body-measurement page. An entry with no date cannot be filed, and one carrying only
    /// circumferences has nothing NOOP can store, so both are skipped and counted.
    public static func parseBodyMeasurements(data: Data) -> Page<BodyMeasurement> {
        parsePage(data, key: "body_measurements") { dict in
            guard let date = (dict["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !date.isEmpty else { return nil }
            let entry = BodyMeasurement(
                date: date,
                weightKg: positive(dict["weight_kg"]),
                fatPercent: LiftingImporter.jsonDouble(dict["fat_percent"]),
                leanMassKg: positive(dict["lean_mass_kg"])
            )
            return entry.isEmpty ? nil : entry
        }
    }

    // MARK: - GET /v1/workouts/count and /v1/user/info

    /// Parse `{ "workout_count": 42 }`. A cheap way to ask whether anything has changed before
    /// paging the whole history at a default page size of five.
    public static func parseWorkoutCount(data: Data) -> Int? {
        guard let root = object(data), let n = LiftingImporter.jsonDouble(root["workout_count"]),
              n >= 0, n < 1e9 else { return nil }
        return Int(n)
    }

    /// Parse `{ "data": { "id": …, "name": …, "url": … } }`.
    public static func parseUserInfo(data: Data) -> UserInfo? {
        guard let root = object(data) else { return nil }
        // The payload nests under `data`; tolerate a bare object too, since a caller that has already
        // unwrapped one should not get a silent nil.
        let dict = (root["data"] as? [String: Any]) ?? root
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return UserInfo(id: id, name: dict["name"] as? String, url: dict["url"] as? String)
    }

    // MARK: - Shared

    /// The `page` / `page_count` pair off any paginated Hevy body, for a caller that wants to know
    /// how far it has to go before it has parsed the elements.
    public static func parsePagination(data: Data) -> (page: Int, pageCount: Int)? {
        guard let root = object(data) else { return nil }
        return (pageNumber(root["page"], fallback: 1), pageNumber(root["page_count"], fallback: 1))
    }

    private static func object(_ data: Data) -> [String: Any]? {
        // JSONSerialization rejects a leading UTF-8 BOM, so strip it (the shared CSV helper).
        try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data)) as? [String: Any]
    }

    /// Fold a `{ page, page_count, <key>: [...] }` envelope. A bare array is accepted as well, so a
    /// caller that already unwrapped a page is not forced back into the envelope.
    private static func parsePage<Element>(
        _ data: Data,
        key: String,
        element: ([String: Any]) -> Element?
    ) -> Page<Element> {
        let root = try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data))
        let raw: [Any]
        var page = 1
        var pageCount = 1
        if let dict = root as? [String: Any] {
            raw = (dict[key] as? [Any]) ?? []
            page = pageNumber(dict["page"], fallback: 1)
            pageCount = pageNumber(dict["page_count"], fallback: 1)
        } else if let list = root as? [Any] {
            raw = list
        } else {
            raw = []
        }

        var items: [Element] = []
        var skipped = 0
        for entry in raw {
            guard let dict = entry as? [String: Any], let parsed = element(dict) else {
                skipped += 1
                continue
            }
            items.append(parsed)
        }
        return Page(items: items, page: page, pageCount: pageCount, skipped: skipped)
    }

    /// A page number, bounded. Hevy sends integers, but this runs over another server's data and the
    /// value ends up in a loop condition.
    private static func pageNumber(_ any: Any?, fallback: Int) -> Int {
        guard let d = LiftingImporter.jsonDouble(any), d >= 1, d < 1e7 else { return fallback }
        return Int(d)
    }

    /// A measurement that must be positive to mean anything. A zero body weight is a cleared field,
    /// not a reading, and storing it would drag an average down.
    private static func positive(_ any: Any?) -> Double? {
        guard let d = LiftingImporter.jsonDouble(any), d > 0 else { return nil }
        return d
    }
}
