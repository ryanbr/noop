package com.noop.data

/** A bounded derived-score update that preserves sleep records and other stored day fields. */
data class SleepRecoveryUpdate(val day: String, val recovery: Double?, val skinTempDevC: Double?, val sourceId: String? = null) {
    /** Swift twin: `SleepRecoveryUpdate.changes`. */
    fun changes(row: DailyMetric): Boolean = day == row.day &&
        (recovery != row.recovery || skinTempDevC != row.skinTempDevC)
}
