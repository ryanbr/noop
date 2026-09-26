package com.noop.data

/** Daily weight in canonical kilograms, with provenance retained across database backups. */
data class WeightEntry(val day: String, val kilograms: Double, val source: String) {
    val isManual: Boolean get() = source == WeightHistory.MANUAL_SOURCE
}

/** Swift WhoopStore.WeightHistory twin. Profile scalars are never fabricated into dated history. */
object WeightHistory {
    const val MANUAL_SOURCE = "noop-weight"
    const val KEY = "weight"
    val sources = listOf(MANUAL_SOURCE, "apple-health", "health-connect")

    fun validKilograms(value: Double): Boolean = value.isFinite() && value > 0 && value <= 1000

    /** Strict Gregorian YYYY-MM-DD, independent of the device locale and timezone. */
    fun validDay(day: String): Boolean {
        if (day.length != 10 || day[4] != '-' || day[7] != '-' ||
            day.indices.any { it != 4 && it != 7 && day[it] !in '0'..'9' }) return false
        val year = day.substring(0, 4).toInt()
        val month = day.substring(5, 7).toInt()
        val date = day.substring(8, 10).toInt()
        if (year < 1 || month !in 1..12) return false
        val leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        val lengths = listOf(31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        return date in 1..lengths[month - 1]
    }

    /** Manual > Apple Health > Health Connect per day; losing rows remain in storage. */
    fun resolve(entries: List<WeightEntry>, through: String): List<WeightEntry> {
        val byDay = mutableMapOf<String, WeightEntry>()
        for (source in sources.reversed()) {
            for (entry in entries) {
                if (entry.source == source && entry.day <= through &&
                    validDay(entry.day) && validKilograms(entry.kilograms)) byDay[entry.day] = entry
            }
        }
        return byDay.values.sortedBy { it.day }
    }
}
