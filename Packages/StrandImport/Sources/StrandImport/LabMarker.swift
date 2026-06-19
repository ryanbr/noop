import Foundation

// MARK: - Lab Book marker model
//
// LabMarker.swift — the value type for ONE stored Lab Book reading, the richer
// source-of-truth row behind the daily `metricSeries` projection.
//
// Per the Health Records design spec (2026-06-19-v5-health-records-design.md, §"New"):
// a single calendar day can hold several readings; each reading carries a precise
// `takenAt` instant and a `unit`; and free-text notes / qualitative ("valueText")
// results don't fit a REAL-only `metricSeries` cell — so the book is its own table
// (`labMarker`, WhoopStore v17) and the projection is how that book talks to the
// rest of the app.
//
// NON-CLINICAL (spec §"Non-clinical / legal framing"): this type holds ONLY values
// the user entered themselves. `referenceText` is the user's own report text shown
// back verbatim — NOOP never ships a reference range and never asserts normality.
// Nothing here tests, reads, or interprets a result.
//
// Pure value type, DB-free and I/O-free (mirrors `ImportModels` style) so it can be
// constructed and folded in unit tests with no database.

/// The category a marker belongs to. Drives grouping in the Lab Book screen.
/// Deliberately broad and non-diagnostic — these are organisational buckets for a
/// personal logbook, not clinical panels.
public enum LabMarkerCategory: String, Sendable, Codable, Equatable, CaseIterable {
    case bloodPanel
    case bloodPressure
    case bodyMeasurement
    case imaging
    case appointmentNote
    case other
}

/// One dated reading of a marker the user keeps in their Lab Book.
///
/// `value` is the numeric reading (nil for a purely qualitative entry whose meaning
/// lives in `valueText`). `takenAt` is the precise instant the reading was taken
/// (a day can hold more than one), and the daily projection derives its `yyyy-MM-dd`
/// day key from it. `source` is the provenance id (manual entry, a CSV import, …);
/// the projection device-id is the constant `"lab-book"` regardless of `source`.
public struct LabMarker: Sendable, Equatable, Codable {
    /// Catalog/custom marker identifier, e.g. `"ldl"`, `"bp_systolic"`, `"ferritin"`.
    public var markerKey: String
    /// Organisational category for grouping.
    public var category: LabMarkerCategory
    /// Numeric reading. `nil` for a qualitative entry (see `valueText`).
    public var value: Double?
    /// Raw textual reading for non-numeric / qualitative results (e.g. "negative",
    /// "trace"). Always populated when `value` is nil; may also annotate a numeric one.
    public var valueText: String?
    /// Unit string as the user entered it (e.g. `"mmol/L"`, `"mg/dL"`, `"mmHg"`).
    public var unit: String
    /// The instant the reading was taken (not merely a day — a day can hold several).
    public var takenAt: Date
    /// Provenance id of this reading (`"manual"`, a CSV file tag, …).
    public var source: String
    /// Optional user-entered free-text note for this reading.
    public var note: String?
    /// Optional reference range, shown back VERBATIM as the user typed it from their
    /// own report. NOOP never computes or ships a range (spec §"Non-clinical").
    public var referenceText: String?

    public init(
        markerKey: String,
        category: LabMarkerCategory,
        value: Double?,
        valueText: String?,
        unit: String,
        takenAt: Date,
        source: String,
        note: String?,
        referenceText: String?
    ) {
        self.markerKey = markerKey
        self.category = category
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.takenAt = takenAt
        self.source = source
        self.note = note
        self.referenceText = referenceText
    }
}
