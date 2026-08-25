import Foundation
import WhoopStore

/// The metric columns the coverage line reports, in the order it reports them.
///
/// This order is part of the emitted string, so it is a cross-platform contract: the Kotlin twin
/// (`com.noop.ingest.IMPORT_COLUMN_LABELS`) lists the same labels in the same order, and both are pinned
/// by a test. Adding a column means adding it to both, in the same position.
///
/// Scoped to the seven daily PHYSIOLOGICAL metrics — the ones a vitals card reads, and so the ones behind
/// "why is this card empty". Sleep-duration columns belong to their own stage and are not folded in here,
/// where they would dilute the signal the line exists to carry.
public let importColumnLabels = ["recovery", "rhr", "hrv", "skin_temp", "spo2", "strain", "resp"]

/// Count, per metric column, how many of these MAPPED daily rows carried a usable value.
///
/// Counted on the mapped `DailyMetric` rows, not on the raw parsed CSV rows, and that distinction is the
/// whole reason this takes the type it does: the WHOOP mapping drops any cycle without a usable day, so
/// the two populations differ, and counting them on different sides of that guard would make the twin
/// lines disagree on a real export. `DailyMetric`'s field names are identical on both platforms, so the
/// two implementations read the same.
///
/// A count of zero means the export never carried that column — or carried it under a header the aliases
/// do not match — which is the commonest cause of a card that stays empty after an import the user
/// watched succeed. Known before any store write, so it carries none of the ambiguity that keeps
/// `rowsOut` honest-but-unverified on Android.
///
/// `filter{}.count` rather than `count(where:)`: the packages declare swift-tools-version 5.9, and this
/// path has no local compile on Linux, so the form that has always existed is the right one to pick.
///
/// Kotlin twin: `com.noop.ingest.importColumnCoverage`.
public func importColumnCoverage(_ rows: [DailyMetric]) -> [(String, Int)] {
    [
        ("recovery", rows.filter { $0.recovery != nil }.count),
        ("rhr", rows.filter { $0.restingHr != nil }.count),
        ("hrv", rows.filter { $0.avgHrv != nil }.count),
        ("skin_temp", rows.filter { $0.skinTempDevC != nil }.count),
        ("spo2", rows.filter { $0.spo2Pct != nil }.count),
        ("strain", rows.filter { $0.strain != nil }.count),
        ("resp", rows.filter { $0.respRateBpm != nil }.count),
    ]
}
