package com.noop

import java.util.TimeZone

/** The zones the day-shift tests run in: both sides of UTC out to the date-line extremes, since a day key
 *  at UTC midnight is the evening before to the west and the same day to the east. */
val DAY_SHIFT_ZONES = listOf("Pacific/Honolulu", "America/New_York", "UTC", "Asia/Tokyo", "Pacific/Kiritimati")

/** Runs [body] with the JVM default zone (what `ZoneId.systemDefault()` and a zoneless `SimpleDateFormat`
 *  read) pinned to [zone], then restores it. Pinned in-process because a test that only fails west of UTC
 *  passes on a UTC runner. */
fun <T> inTimeZone(zone: String, body: () -> T): T {
    val saved = TimeZone.getDefault()
    TimeZone.setDefault(TimeZone.getTimeZone(zone))
    try {
        return body()
    } finally {
        TimeZone.setDefault(saved)
    }
}

/** [inTimeZone] once per zone in [zones], handing [body] the zone's id for assertion messages. */
fun inEachTimeZone(zones: List<String> = DAY_SHIFT_ZONES, body: (String) -> Unit) {
    for (zone in zones) inTimeZone(zone) { body(zone) }
}
