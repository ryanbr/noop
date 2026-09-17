package com.noop.analytics

import com.noop.analytics.Calories.MetSample
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

/**
 * Byte-identity oracle for [Calories.estimateDayEnergyFromMet] against its Swift twin
 * `Calories.estimateDayEnergyFromMET` (#2242).
 *
 * [EXPECTED] is the VERBATIM stdout of the Swift twin compiled standalone (`swiftc -O twin.swift
 * main.swift`, the real `Calories` enum extracted from `WorkoutDetector.swift`) over the case spread
 * rebuilt below, one `%.6f` line per case and profile (80 lines: 17 shapes + the three 2026-09-17 overlap shapes, × 4 profiles). The CLAUDE.md parity rule: verify by oracle, not
 * by reading the two implementations side by side. Regenerate the literal from Swift whenever the
 * estimator changes on either side — never hand-edit a number here.
 *
 * `day0` is 2026-08-15 00:00 Europe/Paris (1755208800 UTC); `day1` is the next midnight.
 */
class MetCaloriesOracleTest {

    private val day0 = 1_755_208_800L
    private val day1 = day0 + 86_400L

    private val profiles: List<Pair<String, UserProfile>> = listOf(
        "default" to UserProfile(),
        "male-82-181-45" to UserProfile(weightKg = 82.0, heightCm = 181.0, age = 45.0, sex = "male"),
        "female-60-165-30" to UserProfile(weightKg = 60.0, heightCm = 165.0, age = 30.0, sex = "female"),
        "zeroed-profile" to UserProfile(weightKg = 0.0, heightCm = 0.0, age = 0.0, sex = "male"),
    )

    private fun line(name: String, samples: List<MetSample>, p: UserProfile, s: Long = day0, e: Long = day1): String {
        val r = Calories.estimateDayEnergyFromMet(samples, p, s, e)
        return String.format(
            Locale.ROOT, "%s|%.6f|%.6f|%.6f|%.6f|%.6f",
            name, r.restingKcal, r.activeKcal, r.observedSeconds, r.coverageFraction, r.totalKcal,
        )
    }

    private fun fullDay(met: Double): MutableList<MetSample> =
        (0 until 1440).map { MetSample(day0 + it * 60L, met) }.toMutableList()

    private fun spread(): List<String> {
        val out = mutableListOf<String>()
        for ((pn, p) in profiles) {
            out += line("$pn/empty", emptyList(), p)
            out += line("$pn/rest-0.9-all-day", fullDay(0.9), p)
            // One 30-min 4.0-MET bout on the rest floor, rest of the day at 0.9.
            val bout = fullDay(0.9)
            for (i in 600 until 630) bout[i] = MetSample(day0 + i * 60L, 4.0)
            out += line("$pn/one-30min-4.0-bout", bout, p)
            // Threshold edge: 1.4 is rest, 1.5 is active (one minute each), rest of day absent.
            out += line("$pn/threshold-1.4-1.5", listOf(MetSample(day0, 1.4), MetSample(day0 + 60, 1.5)), p)
            // Two-slope decoder boundary: 12.7 (byte 0x7f) then 12.8 (byte 0x80).
            out += line("$pn/two-slope-12.7-12.8", listOf(MetSample(day0, 12.7), MetSample(day0 + 60, 12.8)), p)
            // 60 % coverage: the first 864 minutes only, a 2.5-MET walk from minute 400..460.
            var sixty: List<MetSample> = (0 until 864).map { MetSample(day0 + it * 60L, if (it >= 400 && it < 460) 2.5 else 1.0) }
            out += line("$pn/coverage-60pct", sixty, p)
            // 40 % coverage — below the gate; the estimator still reports it, the caller decides.
            sixty = sixty.take(576)
            out += line("$pn/coverage-40pct", sixty, p)
            // secPerSample 120: 720 samples of 2 min at 1.0, one 3.0-MET sample.
            val twoMin = (0 until 720).map { MetSample(day0 + it * 120L, 1.0, 120) }.toMutableList()
            twoMin[300] = MetSample(day0 + 300 * 120L, 3.0, 120)
            out += line("$pn/secPerSample-120", twoMin, p)
            // Duplicate ts: the lower MET wins, and the minute is covered once.
            out += line("$pn/dup-ts-lower-wins", listOf(MetSample(day0, 5.0), MetSample(day0, 2.0), MetSample(day0 + 60, 0.9)), p)
            // Out-of-window samples are ignored; dayEnd exclusive.
            out += line(
                "$pn/window-edges",
                listOf(MetSample(day0 - 60, 9.0), MetSample(day0, 2.0), MetSample(day1 - 60, 2.0), MetSample(day1, 9.0)), p,
            )
            // Today, partial: dayEnd = midnight + 6 h, 6 h of 1.2 MET plus 20 min at 6.0 → coverage 1.0 of the elapsed window.
            var partial: List<MetSample> = (0 until 360).map { MetSample(day0 + it * 60L, if (it >= 200 && it < 220) 6.0 else 1.2) }
            out += line("$pn/today-partial-6h", partial, p, day0, day0 + 6 * 3600L)
            partial = partial.take(180)
            out += line("$pn/today-partial-6h-half-covered", partial, p, day0, day0 + 6 * 3600L)
            // Coverage over-run: 1500 one-minute samples inside a 24 h day clamp to the span.
            out += line("$pn/overrun-clamps", (0 until 1500).map { MetSample(day0 + it * 60L, 1.0) }, p, day0, day0 + 1500 * 60L - 3600L)
            // DST day: 23 h span (Europe/Paris 2026-03-29), full coverage.
            out += line("$pn/dst-23h", (0 until 1380).map { MetSample(day0 + it * 60L, if (it % 7 == 0) 2.2 else 0.95) }, p, day0, day0 + 82_800L)
            // Zero and negative secPerSample rows are dropped; zero-length day.
            out += line(
                "$pn/bad-epoch-dropped",
                listOf(MetSample(day0, 4.0, 0), MetSample(day0 + 60, 4.0, -60), MetSample(day0 + 120, 4.0)), p,
            )
            out += line("$pn/zero-length-day", fullDay(2.0), p, day0, day0)
            // A realistic day: rest 0.9 at night, 1.1 daytime, three walks 3.4 and a 45-min 7.5 run.
            val real = fullDay(0.9)
            for (i in 420 until 1380) real[i] = MetSample(day0 + i * 60L, 1.1)
            for ((a, b) in listOf(480 to 505, 760 to 790, 1100 to 1140)) for (i in a until b) real[i] = MetSample(day0 + i * 60L, 3.4)
            for (i in 1080 until 1125) real[i] = MetSample(day0 + i * 60L, 7.5)
            real.subList(300, 360).clear()   // a one-hour ring-side hole
            out += line("$pn/realistic-day", real, p)
            // 2026-09-17: a re-served minute lands 3–4 s off its first copy under a fresh session anchor; the twin is dropped.
            out += line(
                "$pn/overlap-3s-twins",
                listOf(MetSample(day0, 4.0), MetSample(day0 + 3, 4.0), MetSample(day0 + 60, 0.9), MetSample(day0 + 64, 9.0), MetSample(day0 + 120, 4.0)), p,
            )
            // Overlap is judged against the interval just counted: a 57-s-late twin of minute 0 loses; minute 2 is kept.
            out += line("$pn/overlap-57s-twin", listOf(MetSample(day0, 1.0), MetSample(day0 + 57, 5.0), MetSample(day0 + 120, 1.0)), p)
            // The phone's shape: a full day where every 7th minute also arrived 4 s late from a second session.
            val twins = fullDay(1.1)
            for (i in 0 until 1440 step 7) twins += MetSample(day0 + i * 60L + 4, 3.0)
            out += line("$pn/overlap-phone-day", twins, p)
        }
        return out
    }

    @Test
    fun matchesSwiftTwinByteForByte() {
        val actual = spread()
        assertEquals(EXPECTED.size, actual.size)
        for (i in EXPECTED.indices) assertEquals("case ${i + 1}", EXPECTED[i], actual[i])
    }

    /** The Swift twin's stdout, verbatim. */
    private val EXPECTED = listOf(
        "default/empty|0.000000|0.000000|0.000000|0.000000|0.000000",
        "default/rest-0.9-all-day|1581.657500|0.000000|86400.000000|1.000000|1581.657500",
        "default/one-30min-4.0-bout|1581.657500|91.875000|86400.000000|1.000000|1673.532500",
        "default/threshold-1.4-1.5|2.196747|0.000000|120.000000|0.001389|2.196747",
        "default/two-slope-12.7-12.8|2.196747|27.562500|120.000000|0.001389|29.759247",
        "default/coverage-60pct|948.994500|73.500000|51840.000000|0.600000|1022.494500",
        "default/coverage-40pct|632.663000|73.500000|34560.000000|0.400000|706.163000",
        "default/secPerSample-120|1581.657500|3.675000|86400.000000|1.000000|1585.332500",
        "default/dup-ts-lower-wins|2.196747|0.612500|120.000000|0.001389|2.809247",
        "default/window-edges|2.196747|1.225000|120.000000|0.001389|3.421747",
        "default/today-partial-6h|395.414375|110.250000|21600.000000|1.000000|505.664375",
        "default/today-partial-6h-half-covered|197.707188|0.000000|10800.000000|0.500000|197.707188",
        "default/overrun-clamps|1581.657500|0.000000|86400.000000|1.000000|1581.657500",
        "default/dst-23h|1515.755104|169.785000|82800.000000|1.000000|1685.540104",
        "default/bad-epoch-dropped|1.098373|3.062500|60.000000|0.000694|4.160873",
        "default/zero-length-day|0.000000|0.000000|0.000000|0.000000|0.000000",
        "default/realistic-day|1515.755104|493.675000|82800.000000|0.958333|2009.430104",
        "default/overlap-3s-twins|3.295120|6.125000|180.000000|0.002083|9.420120",
        "default/overlap-57s-twin|2.196747|0.000000|120.000000|0.001389|2.196747",
        "default/overlap-phone-day|1581.657500|0.000000|86400.000000|1.000000|1581.657500",
        "male-82-181-45/empty|0.000000|0.000000|0.000000|0.000000|0.000000",
        "male-82-181-45/rest-0.9-all-day|1800.070000|0.000000|86400.000000|1.000000|1800.070000",
        "male-82-181-45/one-30min-4.0-bout|1800.070000|107.625000|86400.000000|1.000000|1907.695000",
        "male-82-181-45/threshold-1.4-1.5|2.500097|0.000000|120.000000|0.001389|2.500097",
        "male-82-181-45/two-slope-12.7-12.8|2.500097|32.287500|120.000000|0.001389|34.787597",
        "male-82-181-45/coverage-60pct|1080.042000|86.100000|51840.000000|0.600000|1166.142000",
        "male-82-181-45/coverage-40pct|720.028000|86.100000|34560.000000|0.400000|806.128000",
        "male-82-181-45/secPerSample-120|1800.070000|4.305000|86400.000000|1.000000|1804.375000",
        "male-82-181-45/dup-ts-lower-wins|2.500097|0.717500|120.000000|0.001389|3.217597",
        "male-82-181-45/window-edges|2.500097|1.435000|120.000000|0.001389|3.935097",
        "male-82-181-45/today-partial-6h|450.017500|129.150000|21600.000000|1.000000|579.167500",
        "male-82-181-45/today-partial-6h-half-covered|225.008750|0.000000|10800.000000|0.500000|225.008750",
        "male-82-181-45/overrun-clamps|1800.070000|0.000000|86400.000000|1.000000|1800.070000",
        "male-82-181-45/dst-23h|1725.067083|198.891000|82800.000000|1.000000|1923.958083",
        "male-82-181-45/bad-epoch-dropped|1.250049|3.587500|60.000000|0.000694|4.837549",
        "male-82-181-45/zero-length-day|0.000000|0.000000|0.000000|0.000000|0.000000",
        "male-82-181-45/realistic-day|1725.067083|578.305000|82800.000000|0.958333|2303.372083",
        "male-82-181-45/overlap-3s-twins|3.750146|7.175000|180.000000|0.002083|10.925146",
        "male-82-181-45/overlap-57s-twin|2.500097|0.000000|120.000000|0.001389|2.500097",
        "male-82-181-45/overlap-phone-day|1800.070000|0.000000|86400.000000|1.000000|1800.070000",
        "female-60-165-30/empty|0.000000|0.000000|0.000000|0.000000|0.000000",
        "female-60-165-30/rest-0.9-all-day|1383.683000|0.000000|86400.000000|1.000000|1383.683000",
        "female-60-165-30/one-30min-4.0-bout|1383.683000|78.750000|86400.000000|1.000000|1462.433000",
        "female-60-165-30/threshold-1.4-1.5|1.921782|0.000000|120.000000|0.001389|1.921782",
        "female-60-165-30/two-slope-12.7-12.8|1.921782|23.625000|120.000000|0.001389|25.546782",
        "female-60-165-30/coverage-60pct|830.209800|63.000000|51840.000000|0.600000|893.209800",
        "female-60-165-30/coverage-40pct|553.473200|63.000000|34560.000000|0.400000|616.473200",
        "female-60-165-30/secPerSample-120|1383.683000|3.150000|86400.000000|1.000000|1386.833000",
        "female-60-165-30/dup-ts-lower-wins|1.921782|0.525000|120.000000|0.001389|2.446782",
        "female-60-165-30/window-edges|1.921782|1.050000|120.000000|0.001389|2.971782",
        "female-60-165-30/today-partial-6h|345.920750|94.500000|21600.000000|1.000000|440.420750",
        "female-60-165-30/today-partial-6h-half-covered|172.960375|0.000000|10800.000000|0.500000|172.960375",
        "female-60-165-30/overrun-clamps|1383.683000|0.000000|86400.000000|1.000000|1383.683000",
        "female-60-165-30/dst-23h|1326.029542|145.530000|82800.000000|1.000000|1471.559542",
        "female-60-165-30/bad-epoch-dropped|0.960891|2.625000|60.000000|0.000694|3.585891",
        "female-60-165-30/zero-length-day|0.000000|0.000000|0.000000|0.000000|0.000000",
        "female-60-165-30/realistic-day|1326.029542|423.150000|82800.000000|0.958333|1749.179542",
        "female-60-165-30/overlap-3s-twins|2.882673|5.250000|180.000000|0.002083|8.132673",
        "female-60-165-30/overlap-57s-twin|1.921782|0.000000|120.000000|0.001389|1.921782",
        "female-60-165-30/overlap-phone-day|1383.683000|0.000000|86400.000000|1.000000|1383.683000",
        "zeroed-profile/empty|0.000000|0.000000|0.000000|0.000000|0.000000",
        "zeroed-profile/rest-0.9-all-day|1671.672000|0.000000|86400.000000|1.000000|1671.672000",
        "zeroed-profile/one-30min-4.0-bout|1671.672000|91.875000|86400.000000|1.000000|1763.547000",
        "zeroed-profile/threshold-1.4-1.5|2.321767|0.000000|120.000000|0.001389|2.321767",
        "zeroed-profile/two-slope-12.7-12.8|2.321767|27.562500|120.000000|0.001389|29.884267",
        "zeroed-profile/coverage-60pct|1003.003200|73.500000|51840.000000|0.600000|1076.503200",
        "zeroed-profile/coverage-40pct|668.668800|73.500000|34560.000000|0.400000|742.168800",
        "zeroed-profile/secPerSample-120|1671.672000|3.675000|86400.000000|1.000000|1675.347000",
        "zeroed-profile/dup-ts-lower-wins|2.321767|0.612500|120.000000|0.001389|2.934267",
        "zeroed-profile/window-edges|2.321767|1.225000|120.000000|0.001389|3.546767",
        "zeroed-profile/today-partial-6h|417.918000|110.250000|21600.000000|1.000000|528.168000",
        "zeroed-profile/today-partial-6h-half-covered|208.959000|0.000000|10800.000000|0.500000|208.959000",
        "zeroed-profile/overrun-clamps|1671.672000|0.000000|86400.000000|1.000000|1671.672000",
        "zeroed-profile/dst-23h|1602.019000|169.785000|82800.000000|1.000000|1771.804000",
        "zeroed-profile/bad-epoch-dropped|1.160883|3.062500|60.000000|0.000694|4.223383",
        "zeroed-profile/zero-length-day|0.000000|0.000000|0.000000|0.000000|0.000000",
        "zeroed-profile/realistic-day|1602.019000|493.675000|82800.000000|0.958333|2095.694000",
        "zeroed-profile/overlap-3s-twins|3.482650|6.125000|180.000000|0.002083|9.607650",
        "zeroed-profile/overlap-57s-twin|2.321767|0.000000|120.000000|0.001389|2.321767",
        "zeroed-profile/overlap-phone-day|1671.672000|0.000000|86400.000000|1.000000|1671.672000",
    )
}
