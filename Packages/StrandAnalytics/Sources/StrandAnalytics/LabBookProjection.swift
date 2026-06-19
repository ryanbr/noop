import Foundation

// MARK: - Lab Book projection (pure)
//
// LabBookProjection.swift — the pure, DB-free, deterministic logic that turns a set
// of Lab Book readings into the daily `(day, key, value)` form the rest of the app
// already understands, plus the windowed-aggregate pairing used before
// `CorrelationEngine.pearson`.
//
// Per the Health Records design spec (2026-06-19-v5-health-records-design.md,
// §"On-device algorithm" and §"New"):
//   - There is NO new statistics here. A marker is just another `(day, value)` series.
//     Day-alignment + Pearson are reused byte-for-byte from `CorrelationEngine`.
//   - SPARSE-MARKER handling is the real design problem: bloods are months apart, so
//     naive day-alignment yields too few overlapping points. So a reading on day D is
//     paired with the MEAN of a wearable series over a trailing window UP TO AND
//     INCLUDING D (default 14 days) — a disclosed trailing-exposure-window choice, the
//     same idea as a moving-average feature, kept fully deterministic and on-device.
//   - HONESTY about n: callers gate the conclusion sentence on a reading-count floor
//     (default 4); this engine just reports the exact pairs and their n.
//
// This engine is timezone-free by construction: it operates on pre-derived
// `yyyy-MM-dd` day strings (the store derives the day from a reading's `takenAt`),
// exactly like `CorrelationEngine`. That keeps the Swift engine and its Kotlin twin
// byte-identical with no Calendar/ZoneId divergence.
//
// NON-CLINICAL (spec §"Non-clinical"): this folds and lines up the user's own numbers.
// It never judges a value normal/abnormal and ships no thresholds.

/// One reading reduced to exactly what the projection needs: a numeric value on a
/// pre-derived day, with the precise `takenAt` epoch seconds kept only to break
/// ties when several readings of the same marker land on the same day.
///
/// Non-numeric (`valueText`-only) readings are simply not represented here — the
/// caller omits them, since a `REAL`-only daily series can't carry them.
public struct LabReading: Equatable, Sendable {
    /// Marker identifier (e.g. `"ldl"`, `"bp_systolic"`).
    public let markerKey: String
    /// Pre-derived `yyyy-MM-dd` day key (the store derived this from `takenAt`).
    public let day: String
    /// Numeric reading.
    public let value: Double
    /// The reading's instant (epoch seconds). Used ONLY to order same-day readings
    /// so "latest-per-day" is deterministic; never re-derives the day.
    public let takenAtEpoch: Double

    public init(markerKey: String, day: String, value: Double, takenAtEpoch: Double) {
        self.markerKey = markerKey
        self.day = day
        self.value = value
        self.takenAtEpoch = takenAtEpoch
    }
}

/// A projected daily point for one marker: the value that represents marker `key`
/// on `day` after folding multiple same-day readings. This is what gets upserted
/// into `metricSeries` under the `lab-book` source id.
public struct ProjectedPoint: Equatable, Sendable {
    public let markerKey: String
    public let day: String
    public let value: Double

    public init(markerKey: String, day: String, value: Double) {
        self.markerKey = markerKey
        self.day = day
        self.value = value
    }
}

/// How to collapse several readings of the same marker on the same day into one
/// daily value.
public enum DailyFold: Sendable {
    /// The reading with the latest `takenAt` wins (ties broken by input order).
    case latest
    /// The arithmetic mean of the day's readings.
    case mean
}

/// One windowed-aggregate pair: a marker reading on `day` lined up against the mean
/// of a wearable series over the trailing window up to and including `day`.
public struct WindowedPair: Equatable, Sendable {
    /// The marker reading's day (`yyyy-MM-dd`).
    public let day: String
    /// The marker's projected daily value on `day` (the x of the pair).
    public let markerValue: Double
    /// The trailing-window mean of the wearable series (the y of the pair).
    public let wearableMean: Double
    /// How many wearable points fell inside the window (transparency; 0-coverage
    /// days are never emitted, so this is always ≥ 1 for an emitted pair).
    public let wearableN: Int

    public init(day: String, markerValue: Double, wearableMean: Double, wearableN: Int) {
        self.day = day
        self.markerValue = markerValue
        self.wearableMean = wearableMean
        self.wearableN = wearableN
    }
}

public enum LabBookProjection {

    /// The constant device-id every projected marker day is written under, so a
    /// future cross-device file sync would line up and the per-source resolver treats
    /// markers as single-source (spec §"Cross-platform plan").
    public static let sourceId = "lab-book"

    /// The two keys a blood-pressure pair is stored as (spec §"Blood pressure
    /// modelling": two keys for clean correlation, not one composite).
    public static let bpSystolicKey = "bp_systolic"
    public static let bpDiastolicKey = "bp_diastolic"

    /// Default trailing window (days, inclusive of the reading day) for pairing a
    /// sparse marker against a continuously-measured wearable series.
    public static let defaultWindowDays = 14

    // MARK: - Daily projection

    /// Fold readings into one daily point per (markerKey, day).
    ///
    /// For each marker and day, multiple readings are collapsed by `fold`
    /// (`.latest` = most recent `takenAt` wins; `.mean` = arithmetic mean). Output is
    /// sorted by markerKey then day ascending so it is deterministic across platforms.
    public static func project(_ readings: [LabReading], fold: DailyFold = .latest) -> [ProjectedPoint] {
        // Group by (markerKey, day) → list of readings in that cell.
        var cells: [String: [LabReading]] = [:]
        var order: [String] = []
        for r in readings {
            let cellKey = r.markerKey + "\u{1}" + r.day
            if cells[cellKey] == nil { order.append(cellKey) }
            cells[cellKey, default: []].append(r)
        }

        var out: [ProjectedPoint] = []
        out.reserveCapacity(order.count)
        for cellKey in order {
            guard let group = cells[cellKey], !group.isEmpty else { continue }
            let value: Double
            switch fold {
            case .latest:
                // Most recent takenAt wins; a tie keeps the last in input order
                // (`>` makes the later-encountered equal element NOT replace, so the
                // last one written is the running best — deterministic either way as
                // the store dedupes by natural key).
                var best = group[0]
                for r in group.dropFirst() where r.takenAtEpoch >= best.takenAtEpoch {
                    best = r
                }
                value = best.value
            case .mean:
                var sum = 0.0
                for r in group { sum += r.value }
                value = sum / Double(group.count)
            }
            out.append(ProjectedPoint(markerKey: group[0].markerKey, day: group[0].day, value: value))
        }

        // Deterministic order: markerKey asc, then day asc.
        out.sort { $0.markerKey != $1.markerKey ? $0.markerKey < $1.markerKey : $0.day < $1.day }
        return out
    }

    // MARK: - Windowed-aggregate pairing

    /// Pair each marker reading with the trailing-window mean of a wearable series.
    ///
    /// For a marker projected to `[(day, value)]` (one numeric value per day — pass the
    /// `.project` output filtered to one markerKey, or any `(day,value)` series) and a
    /// daily `wearable` series `[(day, value)]`, each marker day `D` is paired with the
    /// mean of all wearable values whose day is within the trailing `windowDays`
    /// (inclusive of D): `D - (windowDays - 1) ... D`.
    ///
    /// Days where NO wearable point falls inside the window are DROPPED (spec: "days
    /// with no wearable coverage are dropped"). The result is sorted by day ascending.
    /// Window is clamped to ≥ 1. The day arithmetic reuses the same UTC-calendar
    /// `shiftDay` used by `CorrelationEngine.lagged`, so the boundary is computed the
    /// same way everywhere.
    public static func pairMarkerToWearable(
        marker: [(day: String, value: Double)],
        wearable: [(day: String, value: Double)],
        windowDays: Int = defaultWindowDays
    ) -> [WindowedPair] {
        let width = max(1, windowDays)

        // Last-write-wins per day for both series (matches CorrelationEngine.alignByDay).
        var markerByDay: [String: Double] = [:]
        for row in marker { markerByDay[row.day] = row.value }
        var wearableByDay: [String: Double] = [:]
        for row in wearable { wearableByDay[row.day] = row.value }

        var pairs: [WindowedPair] = []
        for day in markerByDay.keys.sorted() {
            guard let mv = markerByDay[day] else { continue }
            // Walk the trailing window [D-(width-1) ... D] inclusive, summing wearable
            // coverage. Deterministic: a fixed UTC calendar, integer day offsets.
            var sum = 0.0
            var n = 0
            for back in 0..<width {
                guard let wDay = CorrelationEngine.shiftDay(day, by: -back) else { continue }
                if let wv = wearableByDay[wDay] {
                    sum += wv
                    n += 1
                }
            }
            guard n > 0 else { continue } // no coverage → drop the reading
            pairs.append(WindowedPair(day: day, markerValue: mv, wearableMean: sum / Double(n), wearableN: n))
        }
        return pairs
    }

    /// Convenience: reduce windowed pairs to the `(x, y)` tuples `CorrelationEngine.pearson`
    /// consumes (x = marker value, y = wearable trailing-window mean), ordered by day.
    /// The caller passes the result straight into `CorrelationEngine.pearson`; this
    /// engine adds no statistics of its own.
    public static func correlationInput(_ pairs: [WindowedPair]) -> [(Double, Double)] {
        pairs.map { ($0.markerValue, $0.wearableMean) }
    }
}
