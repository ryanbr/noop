package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Kotlin twin of `SleepMergeAcrossGapTests`.
 *
 * `mergePeriods` absorbed a short run into its neighbour whatever the time between them. When
 * `buildRuns` had closed a run on a data gap, that moved the neighbour's edge across the whole gap. On a
 * real WHOOP 5.0 night, a few minutes of evening stillness before a charging gap of several hours were
 * folded into the night after it, the merged run was more than half HR gap, and the off-wrist backstop
 * dropped the night, including the hours that were worn.
 */
class SleepMergeAcrossGapTest {

    private fun key(p: SleepStager.Period) = "${p.stage.first()}${p.start}-${p.end}"

    /**
     * Byte-identical with Swift over a spread of generated cases. The expected lines are the stdout of the
     * Swift `mergePeriods`, compiled standalone with the same generator, pasted verbatim.
     */
    @Test
    fun mergePeriodsMatchesTheSwiftOracle() {
        var seed = 12345u
        fun next(n: Int): Int {
            seed = seed * 1103515245u + 12345u
            return ((seed shr 16) % n.toUInt()).toInt()
        }
        val lens = listOf(300, 600, 840, 899, 900, 1800, 3600, 18000)
        val gaps = listOf(1, 60, 1200, 1201, 3600, 18000)
        val got = (0 until 60).map {
            var t = 0L
            val ps = ArrayList<SleepStager.Period>()
            repeat(2 + next(5)) {
                val len = lens[next(lens.size)]
                val stage = if (next(2) == 0) "sleep" else "active"
                ps.add(SleepStager.Period(stage = stage, start = t, end = t + len))
                t += len + gaps[next(gaps.size)]
            }
            SleepStager.mergePeriods(ps).joinToString(",") { key(it) }
        }
        assertEquals(swiftOracle, got)
    }

    private val swiftOracle = listOf(
        "a0-900,a901-18901,s20102-20942",
        "s0-899,s2100-2999,a4200-5100,a6300-24300",
        "s0-1800,a1801-2701,s6301-7200",
        "s0-840,s18840-37200",
        "s0-600,a1801-2101",
        "a0-600,s1801-19801,s23401-24241,a25442-26342",
        "a0-1740,a5340-6240,s6241-9841",
        "a0-2940,a4141-7741",
        "a0-3600,s4800-5700",
        "a0-3901,a7501-8401,s9601-15001",
        "s0-3600,a7200-10800",
        "s0-3600,a4801-8401,s12001-12301",
        "s0-3839,a7439-25439,s29039-48539",
        "a0-1800,a1801-5401,s6601-8401,a9602-10202",
        "a0-1800,a5400-7200,s8400-14040",
        "s0-900,a960-5220,s8820-10321",
        "a0-900,s2101-3901",
        "a0-18000,a19201-20101,a20102-21002,a39002-42602,s46202-49142",
        "s0-2759,a20759-21658",
        "a0-18000,a18001-18901,s36901-38701,a38761-40561",
        "s0-18900",
        "a0-7800,a11400-12300,a12360-30360",
        "s0-18000,a18060-18960,s22560-23460",
        "s0-3600,a7200-8100,s9301-9901,a13501-17101,s17102-18302",
        "a0-19800,s37800-38640,a42240-44040,s62040-62640,s80640-84240",
        "a0-901",
        "s0-5282",
        "s0-3600,a3601-4501,s4502-22502",
        "s0-3600,a7200-9000,s10200-13800",
        "s0-1201",
        "s0-2880,a4080-22080,a23281-31020",
        "s0-2399,s20399-22199",
        "a0-601,a4201-23160,s26760-28560",
        "s0-3600,s21600-21900,a23101-41702,s59702-61502",
        "s0-1500,s5100-8940,a10141-10441",
        "a0-1799",
        "s0-3600,s7200-9000,s27000-45000,a46201-46801,a48002-48901",
        "a0-2401,s6001-6901,a8101-9001,s9002-10802",
        "a0-1800,s19800-37800,a37801-39001,s40202-58202",
        "s0-4259,a4260-6360",
        "s0-900,a2101-5701,s5761-7561,s8762-12362,a13563-17764",
        "a0-2160",
        "s0-1800,a1801-3660",
        "a0-20040,s23640-41640,a41641-44521,s62521-63121",
        "s0-900,s18900-19799,s23399-23999",
        "s0-3600,a3660-5400,a23400-42359",
        "s0-18000,a18060-19860,a19920-21720,a22920-23820,a25021-26821",
        "s0-900,s901-1801,a3001-26762",
        "a0-18000,a21600-22440,s40440-40740,s41941-59941",
        "a0-3899,s7499-12899",
        "a0-600,s18600-19500",
        "s0-900,s901-2701,s6301-8101,a26101-27959,a45959-47759",
        "s0-3600,a3601-4501",
        "a0-2101,a20101-24361,s42361-44161",
        "s0-5400",
        "a0-840,a18840-22440,a40440-58440,a62040-65640,a83640-84480,s85681-86581",
        "s0-2999",
        "a0-900,s960-1860,s19860-23460",
        "a0-1800,s3001-4860",
        "a0-900,a2100-3900,a5101-8760",
    )

    private val dev = "test"
    private val refMidnight = 1_749_513_600L                    // 2025-06-10 00:00:00 UTC
    private fun at(min: Int) = refMidnight + min * 60L

    private fun still(fromMin: Int, toMin: Int) =
        (at(fromMin) until at(toMin) step 60).map {
            GravitySample(deviceId = dev, ts = it, x = 0.0, y = 0.0, z = 1.0)
        }

    private fun moving(fromMin: Int, toMin: Int) =
        (at(fromMin) until at(toMin) step 60).mapIndexed { i, t ->
            if (i % 2 == 0) GravitySample(deviceId = dev, ts = t, x = 1.0, y = 0.0, z = 0.0)
            else GravitySample(deviceId = dev, ts = t, x = 0.0, y = 1.0, z = 0.0)
        }

    private fun hr1Hz(fromMin: Int, toMin: Int, bpm: Int) =
        (at(fromMin) until at(toMin)).map { HrSample(deviceId = dev, ts = it, bpm = bpm) }

    /**
     * The field shape: an active evening, a few still minutes, then no data at all for seven hours (the
     * strap on its charger), then a worn five-hour night. Before the fix the still minutes were folded
     * into the night, the run was mostly HR gap, and the off-wrist backstop dropped it.
     */
    @Test
    fun aNightAfterAChargingGapIsKept() {
        val evening = -7 * 60
        val grav = moving(evening, evening + 30) + still(evening + 30, evening + 38) +
            still(60, 360) + moving(360, 390)
        val hr = hr1Hz(evening, evening + 30, 90) + hr1Hz(evening + 30, evening + 38, 60) +
            hr1Hz(60, 360, 52) + hr1Hz(360, 390, 90)

        val lines = ArrayList<String>()
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav, traceSink = { lines.add(it) })

        assertEquals("the worn night must be kept.\n" + lines.joinToString("\n"), 1, sessions.size)
        assertEquals("the night starts after the gap, not before it", at(60), sessions.first().start)
        assertFalse("the off-wrist backstop must not see a run that spans the gap",
            lines.any { it.contains("gate=offWrist") })
    }
}
