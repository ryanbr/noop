import Foundation

// MARK: - Hevy workout parser (DRAFT — see the caveat below)
//
// Hevy is a strength-training logger. Its API returns a page of workouts, each a titled window with
// exercises and sets. NOOP's `workout` table wants startTs, endTs, sport, source, durationS,
// energyKcal, avgHr, maxHr, strain, distanceM — and Hevy carries NONE of the physiology. It has no
// heart rate, no calories, no distance.
//
// That is the whole design, not a shortfall: HEVY SUPPLIES THE WINDOW AND THE LABEL, THE STRAP
// SUPPLIES THE PHYSIOLOGY. A lifting session already sits inside NOOP's HR record as an unlabelled
// stretch of elevated heart rate; what NOOP cannot know is that it was "Push Day" and which lifts it
// held. So a parsed Hevy workout is imported with its times and title and NOTHING invented, and the
// existing workout HR-fill path attaches avg/max HR and strain from the strap's own samples.
//
// Deliberately NOT importing set-level detail (weight, reps, RPE). NOOP has nowhere to put it, no
// screen that would show it, and no analytic that consumes it — importing it would be storing data
// to no end. The exercise TITLES are kept, because they are what makes the window recognisable.
//
// CAVEAT, and the reason this is a draft: the payload shape below is written from Hevy's documented
// v1 response (`workouts[]` with `start_time` / `end_time` / `exercises[].title`). It has NOT been
// checked against a live response. Field names and the envelope must be verified before this leaves
// draft — the parser is tolerant, so a wrong name yields nothing rather than a wrong number, but
// "yields nothing" is not a shipping state either.
//
// This file is PARSING ONLY. There is no client and nothing here makes a request, so the draft
// cannot reach the network by accident. The transport question (an API key, where it is stored, and
// whether an offline-first app should hold one at all) is deliberately left for the PR discussion —
// the Oura lane answers it one way, behind a compile-time gate with untracked secrets.

/// One workout as Hevy describes it: a titled window with the exercises it held.
public struct HevyWorkout: Sendable, Equatable {
    /// Hevy's own workout id, kept so a re-import can recognise the same session.
    public let id: String
    /// The user's title for the session, e.g. "Push Day". This is the thing NOOP cannot derive.
    public let title: String
    /// The user's free-text note, when they wrote one.
    public let notes: String?
    public let start: Date
    public let end: Date
    /// Exercise titles in the order Hevy listed them. Titles only — see the header on set detail.
    public let exerciseTitles: [String]
    /// How many sets the session held in total, across every exercise. A single honest scalar for
    /// "how much work was logged", where the per-set detail has nowhere to live.
    public let setCount: Int

    public init(id: String, title: String, notes: String?, start: Date, end: Date,
                exerciseTitles: [String], setCount: Int) {
        self.id = id
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.exerciseTitles = exerciseTitles
        self.setCount = setCount
    }

    /// Seconds between the two stamps, or nil when the window is degenerate.
    public var durationS: Double? {
        let d = end.timeIntervalSince(start)
        return d > 0 ? d : nil
    }
}

public enum HevyParser {

    /// The `source` string a Hevy-imported workout carries, so provenance survives into the row and
    /// a later re-import can tell its own rows from a strap's.
    public static let source = "hevy"

    /// The sport label. Hevy is a strength logger, so every session is strength training — there is
    /// no per-workout sport in the payload to read, and guessing one from the title would invent a
    /// classification the user never made.
    public static let sport = "Strength"

    /// Parse a Hevy workouts page.
    ///
    /// Tolerant in the same way the Garmin export lane is: a workout missing an id, a title or either
    /// timestamp is SKIPPED rather than defaulted, because a workout with an invented window would be
    /// attached to the wrong stretch of heart rate. A malformed page yields an empty array, never a
    /// throw — this runs over data from someone else's server.
    public static func parse(_ data: Data) -> [HevyWorkout] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // Accept either the documented envelope or a bare array, so a saved response pasted from a
        // browser parses the same as a client's page.
        let raw: [Any]
        if let obj = root as? [String: Any], let list = obj["workouts"] as? [Any] {
            raw = list
        } else if let list = root as? [Any] {
            raw = list
        } else {
            return []
        }

        return raw.compactMap { element in
            guard let w = element as? [String: Any],
                  let id = string(w["id"]),
                  let start = date(w["start_time"]),
                  let end = date(w["end_time"]) else { return nil }
            let exercises = (w["exercises"] as? [Any]) ?? []
            var titles: [String] = []
            var sets = 0
            for e in exercises {
                guard let ex = e as? [String: Any] else { continue }
                if let t = string(ex["title"]) { titles.append(t) }
                sets += ((ex["sets"] as? [Any])?.count ?? 0)
            }
            return HevyWorkout(
                id: id,
                title: string(w["title"]) ?? "",
                notes: string(w["description"]),
                start: start,
                end: end,
                exerciseTitles: titles,
                setCount: sets
            )
        }
    }

    /// The note NOOP stores on the row: the exercises, comma separated, after the user's own note.
    ///
    /// This is what makes the window recognisable months later, and it is the only place the exercise
    /// titles go — there is no lifting screen to build them into.
    public static func noteLine(_ w: HevyWorkout) -> String? {
        let lifts = w.exerciseTitles.joined(separator: ", ")
        let parts = [w.notes?.trimmingCharacters(in: .whitespacesAndNewlines), lifts.isEmpty ? nil : lifts]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    // MARK: - tolerant readers

    private static func string(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// ISO-8601, with and without fractional seconds — Hevy has been seen emitting both, and a
    /// formatter that handles only one silently drops half the page.
    private static func date(_ any: Any?) -> Date? {
        guard let s = string(any) else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
