import Foundation
import GRDB

// MARK: - v17 store: Lab Book markers
//
// LabMarkerStore.swift — GRDB CRUD over the `labMarker` table (migration v17), the
// source-of-truth for the Health Records "Lab Book" pillar
// (spec 2026-06-19-v5-health-records-design.md §"New").
//
// The book is `labMarker` (one row per dated reading the user entered themselves);
// the daily `metricSeries` projection under source id `lab-book` is HOW the book talks
// to the rest of the app (Compare / Explore / correlation / Coach see it unchanged).
// On every write this store ALSO upserts that daily projection, exactly as the spec
// requires, so the two never drift.
//
// Mirrors the established `MetricSeriesStore` / `DeviceRegistryStore` idiom precisely:
// a plain Codable row struct, raw `Row` fetch + manual decode, idempotent upserts keyed
// by the natural key, all GRDB work via the actor's `syncWrite` / `syncRead` helpers.
//
// NON-CLINICAL: stores ONLY user-entered values + an OPTIONAL user-entered
// `referenceText` (their own report's range, verbatim). No reference-range tables, no
// normality judgement, ever.

/// One stored Lab Book reading. Natural key (deviceId, markerKey, takenAt, source) is
/// enforced by a UNIQUE index so re-importing the same reading is idempotent; `id` is a
/// stable client-generated identifier for edit/delete-by-id and backup round-trips.
public struct LabMarkerRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var markerKey: String
    public var category: String
    /// Pre-derived yyyy-MM-dd day key (the projection key for this reading).
    public var day: String
    /// Precise instant the reading was taken (epoch seconds).
    public var takenAt: Int
    /// Numeric reading. Nil for a qualitative entry whose meaning is in `valueText`.
    public var value: Double?
    public var valueText: String?
    public var unit: String
    public var source: String
    public var note: String?
    /// User-entered reference range, shown back verbatim. NOOP ships none.
    public var referenceText: String?

    public init(
        id: String,
        deviceId: String,
        markerKey: String,
        category: String,
        day: String,
        takenAt: Int,
        value: Double?,
        valueText: String?,
        unit: String,
        source: String,
        note: String?,
        referenceText: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.markerKey = markerKey
        self.category = category
        self.day = day
        self.takenAt = takenAt
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.source = source
        self.note = note
        self.referenceText = referenceText
    }

    /// Decode a GRDB row (raw-Row idiom, matching DeviceRegistryStore.decode).
    static func decode(_ row: Row) -> LabMarkerRow {
        LabMarkerRow(
            id: row["id"],
            deviceId: row["deviceId"],
            markerKey: row["markerKey"],
            category: row["category"],
            day: row["day"],
            takenAt: row["takenAt"],
            value: row["value"],
            valueText: row["valueText"],
            unit: row["unit"],
            source: row["source"],
            note: row["note"],
            referenceText: row["referenceText"]
        )
    }
}

extension WhoopStore {

    /// The constant device-id the daily marker projection is written under, so Compare/
    /// Explore/Coach see markers as a single-source series (spec §"Cross-platform plan").
    public static let labBookSourceId = "lab-book"

    // MARK: - Upsert (idempotent by natural key) + project to metricSeries

    /// Upsert lab-marker rows, then re-project the affected (markerKey, day) cells into
    /// `metricSeries` under `lab-book`. Idempotent: re-upserting the same
    /// (deviceId, markerKey, takenAt, source) updates that reading in place (UNIQUE
    /// index `idx_labMarker_natural`) and the projection reflects the new value.
    ///
    /// The daily projection rule is LATEST-per-day: the reading with the greatest
    /// `takenAt` for a (markerKey, day) wins — byte-identical to
    /// `LabBookProjection.project(.latest)`. Only NUMERIC readings project (a
    /// REAL-only `metricSeries` cell can't carry `valueText`).
    ///
    /// Returns the number of marker rows written/updated.
    @discardableResult
    public func upsertLabMarkers(_ rows: [LabMarkerRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var written = 0
            // Track which (deviceId, markerKey, day) cells need re-projecting.
            var touched: Set<DayCell> = []
            for r in rows {
                // Upsert keyed on the natural index, NOT on the `id` PK: a re-import of the
                // "same reading" (same deviceId+markerKey+takenAt+source) must update, not
                // duplicate, even if the caller minted a fresh id.
                try db.execute(sql: """
                    INSERT INTO labMarker
                        (id, deviceId, markerKey, category, day, takenAt,
                         value, valueText, unit, source, note, referenceText)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE SET
                        category = excluded.category,
                        day = excluded.day,
                        value = excluded.value,
                        valueText = excluded.valueText,
                        unit = excluded.unit,
                        note = excluded.note,
                        referenceText = excluded.referenceText
                    """, arguments: [
                        r.id, r.deviceId, r.markerKey, r.category, r.day, r.takenAt,
                        r.value, r.valueText, r.unit, r.source, r.note, r.referenceText,
                    ])
                written += db.changesCount
                touched.insert(DayCell(deviceId: r.deviceId, markerKey: r.markerKey, day: r.day))
            }
            try reprojectCells(db, cells: touched)
            return written
        }
    }

    // MARK: - Reads

    /// All readings in a category, oldest first (by takenAt). Served by
    /// `idx_labMarker_device_category` + the takenAt index.
    public func labMarkers(deviceId: String, category: String) async throws -> [LabMarkerRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM labMarker
                WHERE deviceId = ? AND category = ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId, category]).map(LabMarkerRow.decode)
        }
    }

    /// Full reading history for one marker, oldest first (by takenAt). Served
    /// index-only by `idx_labMarker_device_marker_takenAt`.
    public func labMarkers(deviceId: String, markerKey: String) async throws -> [LabMarkerRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM labMarker
                WHERE deviceId = ? AND markerKey = ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId, markerKey]).map(LabMarkerRow.decode)
        }
    }

    /// Distinct marker keys present for a device, sorted ascending.
    public func markerKeysPresent(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT markerKey FROM labMarker
                WHERE deviceId = ?
                ORDER BY markerKey ASC
                """, arguments: [deviceId])
        }
    }

    // MARK: - Delete (removes the row AND its now-orphaned projected day)

    /// Delete one reading by `id`. If that was the last numeric reading for its
    /// (markerKey, day) cell, the projected `metricSeries` day is removed too; otherwise
    /// the projection is recomputed from the remaining same-day readings. Returns true if
    /// a row was deleted.
    @discardableResult
    public func deleteLabMarker(id: String) async throws -> Bool {
        try syncWrite { db in
            // Capture the cell so we can re-project after the delete.
            guard let row = try Row.fetchOne(db, sql:
                "SELECT * FROM labMarker WHERE id = ?", arguments: [id]).map(LabMarkerRow.decode) else {
                return false
            }
            try db.execute(sql: "DELETE FROM labMarker WHERE id = ?", arguments: [id])
            try reprojectCells(db, cells: [DayCell(deviceId: row.deviceId, markerKey: row.markerKey, day: row.day)])
            return true
        }
    }

    // MARK: - Projection helpers (private)

    /// Identifies one daily projection cell.
    private struct DayCell: Hashable {
        let deviceId: String
        let markerKey: String
        let day: String
    }

    /// Recompute the `metricSeries` projection (under `lab-book`) for each touched cell
    /// from the CURRENT `labMarker` rows. Latest-numeric-per-day wins; if no numeric
    /// reading remains for a cell, its projected day is deleted (so a removed/last
    /// reading never leaves a stale projected value behind).
    private func reprojectCells(_ db: Database, cells: Set<DayCell>) throws {
        for cell in cells {
            // Latest NUMERIC reading for this (markerKey, day): greatest takenAt with a
            // non-null value. Matches LabBookProjection.project(.latest) on numeric rows.
            let latest = try Double.fetchOne(db, sql: """
                SELECT value FROM labMarker
                WHERE deviceId = ? AND markerKey = ? AND day = ? AND value IS NOT NULL
                ORDER BY takenAt DESC
                LIMIT 1
                """, arguments: [cell.deviceId, cell.markerKey, cell.day])

            if let v = latest {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [WhoopStore.labBookSourceId, cell.day, cell.markerKey, v])
            } else {
                // No numeric reading remains for this cell → drop the projected day.
                try db.execute(sql: """
                    DELETE FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """, arguments: [WhoopStore.labBookSourceId, cell.day, cell.markerKey])
            }
        }
    }
}
