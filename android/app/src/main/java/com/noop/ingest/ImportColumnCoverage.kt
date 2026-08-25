package com.noop.ingest

import com.noop.data.DailyMetric

/**
 * The metric columns the coverage line reports, in the order it reports them.
 *
 * This order is part of the emitted string, so it is a cross-platform contract: the Swift twin
 * (`StrandImport.importColumnLabels`) lists the same labels in the same order, and both are pinned by a
 * test. Adding a column means adding it to both, in the same position.
 *
 * Scoped to the seven daily PHYSIOLOGICAL metrics — the ones a vitals card reads, and so the ones behind
 * "why is this card empty". Sleep-duration columns belong to their own stage and are not folded in here,
 * where they would dilute the signal the line exists to carry.
 */
internal val IMPORT_COLUMN_LABELS =
    listOf("recovery", "rhr", "hrv", "skin_temp", "spo2", "strain", "resp")

/**
 * Count, per metric column, how many of these parsed rows carried a usable value.
 *
 * Counted on the PARSED rows rather than inside the parse loop: the rows already hold the answer, so this
 * needs no change to the parsers and cannot drift from what they actually produced. A count of zero means
 * the export never carried that column — or carried it under a header the aliases do not match — which is
 * the commonest cause of a card that stays empty after an import the user watched succeed.
 *
 * Swift twin: `StrandImport.importColumnCoverage`.
 */
internal fun importColumnCoverage(rows: List<DailyMetric>): List<Pair<String, Int>> = listOf(
    "recovery" to rows.count { it.recovery != null },
    "rhr" to rows.count { it.restingHr != null },
    "hrv" to rows.count { it.avgHrv != null },
    "skin_temp" to rows.count { it.skinTempDevC != null },
    "spo2" to rows.count { it.spo2Pct != null },
    "strain" to rows.count { it.strain != null },
    "resp" to rows.count { it.respRateBpm != null },
)
