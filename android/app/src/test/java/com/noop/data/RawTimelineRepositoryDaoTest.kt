package com.noop.data

import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** DAO-backed contract tests for the public device-aware repository reads. */
class RawTimelineRepositoryDaoTest {
    private fun rr(source: String, ts: Long, ms: Int) =
        RrInterval(deviceId = source, ts = ts, rrMs = ms)

    private fun device(id: String, status: String, addedAt: Long, brand: String = "WHOOP") =
        PairedDeviceRow(id, brand, "test", null, null, "whoop", "hr", status, addedAt, addedAt)

    private val allWhoops = listOf(
        device("whoop-old", "archived", 1),
        device("my-whoop", "paired", 2),
        device("polar-ignored", "paired", 3, brand = "Polar"),
        device("whoop-new", "active", 4),
    )

    @Test
    fun rrIntervalsUnionQueriesActiveThenCanonicalAndMergesTheirRows() = runBlocking {
        val queried = mutableListOf<String>()
        val active = listOf(rr("whoop-new", 101, 810), rr("whoop-new", 103, 830))
        val canonical = listOf(rr("my-whoop", 100, 800), rr("my-whoop", 101, 810))
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> listOf(
                    device("my-whoop", "paired", 1),
                    device("whoop-new", "active", 2),
                )
                "rrIntervals" -> {
                    val id = args[0] as String
                    queried += id
                    if (id == "whoop-new") active else canonical
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val rows = repo.rrIntervalsUnion("whoop-new", 10, 20, limit = 50)

        assertEquals(listOf("whoop-new", "my-whoop"), queried)
        assertEquals(listOf(100L, 101L, 103L), rows.map { it.ts })
        assertEquals("whoop-new", rows.first { it.ts == 101L }.deviceId)
    }

    @Test
    fun rrIntervalsUnionCanonicalActivePerformsOneLegacyReadUnchanged() = runBlocking {
        val queried = mutableListOf<String>()
        val canonical = listOf(rr("my-whoop", 100, 800), rr("my-whoop", 101, 810))
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> listOf(device("my-whoop", "active", 1))
                "rrIntervals" -> {
                    queried += args[0] as String
                    canonical
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val rows = repo.rrIntervalsUnion("my-whoop", 10, 20, limit = 50)

        assertEquals(listOf("my-whoop"), queried)
        assertSame("single-source legacy result must pass through unchanged", canonical, rows)
    }

    @Test
    fun rawUnionsQueryActiveThenEveryHistoricalWhoopThenCanonical() = runBlocking {
        val queried = mutableListOf<Pair<String, String>>()
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> allWhoops
                "hrSamples" -> { queried += "hr" to (args[0] as String); emptyList<HrSample>() }
                "hrBuckets" -> { queried += "hrBucket" to (args[0] as String); emptyList<HrBucket>() }
                "rrIntervals" -> { queried += "rr" to (args[0] as String); emptyList<RrInterval>() }
                "gravitySamples" -> { queried += "gravity" to (args[0] as String); emptyList<GravitySample>() }
                else -> throw UnsupportedOperationException(method)
            }
        })

        repo.hrSamplesUnion("whoop-new", 10, 20)
        repo.hrBucketsUnion("whoop-new", 10, 20)
        repo.rrIntervalsUnion("whoop-new", 10, 20)
        repo.gravitySamplesUnion("whoop-new", 10, 20)

        val expected = listOf("whoop-new", "whoop-old", "my-whoop")
        assertEquals(expected, queried.filter { it.first == "hr" }.map { it.second })
        assertEquals(expected, queried.filter { it.first == "hrBucket" }.map { it.second })
        assertEquals(expected, queried.filter { it.first == "rr" }.map { it.second })
        assertEquals(expected, queried.filter { it.first == "gravity" }.map { it.second })
    }

    @Test
    fun rawResolverKeepsActiveNonWhoopButExcludesUnrelatedNonWhoopRegistryRows() = runBlocking {
        val queried = mutableListOf<String>()
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> listOf(
                    device("whoop-old", "archived", 1),
                    device("polar-other", "paired", 2, brand = "Polar"),
                    device("polar-active", "active", 3, brand = "Polar"),
                    device("my-whoop", "paired", 4),
                )
                "hrSamples" -> { queried += args[0] as String; emptyList<HrSample>() }
                else -> throw UnsupportedOperationException(method)
            }
        })

        repo.hrSamplesUnion("polar-active", 10, 20)

        assertEquals(listOf("polar-active", "whoop-old", "my-whoop"), queried)
        assertEquals(
            listOf("polar-active", "whoop-old", "my-whoop"),
            WhoopRepository.rawWhoopSourceIdsFor(
                activeDeviceId = "polar-active",
                registeredWhoopIds = listOf("whoop-old", "my-whoop"),
            ),
        )
    }

    @Test
    fun sessionMotionFallbackIncludesArchivedWhoopButNotOtherBrands() = runBlocking {
        val queried = mutableListOf<String>()
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> allWhoops
                "sessionMotionJson" -> {
                    val id = args[0] as String
                    queried += id
                    if (id == "whoop-old-noop") "[3,4]" else null
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val result = repo.sessionMotions(
            "whoop-new",
            listOf(SleepSession(deviceId = "unknown-owner", startTs = 1_000, endTs = 2_000)),
        )

        assertEquals(listOf("unknown-owner-noop", "whoop-new-noop", "whoop-old-noop"), queried)
        assertEquals(listOf(3.0, 4.0), result[1_000L])
    }

    @Test
    fun sleepUnionsIncludeArchivedRawAndComputedNights() = runBlocking {
        val queried = mutableListOf<String>()
        val rows = mapOf(
            "whoop-new" to listOf(SleepSession("whoop-new", 3_000, 4_000)),
            "whoop-old" to listOf(SleepSession("whoop-old", 1_000, 2_000)),
            "whoop-new-noop" to listOf(SleepSession("whoop-new-noop", 7_000, 8_000)),
            "whoop-old-noop" to listOf(SleepSession("whoop-old-noop", 5_000, 6_000)),
        )
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> allWhoops
                "sleepSessions" -> {
                    val id = args[0] as String
                    queried += id
                    rows[id].orEmpty()
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val raw = repo.sleepSessionsUnion("whoop-new", 0, 10_000)
        val computed = repo.computedSleepSessionsUnion("whoop-new", 0, 10_000)

        assertEquals(
            listOf("whoop-new", "whoop-old", "my-whoop", "whoop-new-noop", "whoop-old-noop", "my-whoop-noop"),
            queried,
        )
        assertEquals(listOf("whoop-new", "whoop-old"), raw.map { it.deviceId })
        assertEquals(listOf("whoop-new-noop", "whoop-old-noop"), computed.map { it.deviceId })
    }

    @Test
    fun habitualMidsleepLearnsAcrossActiveAndArchivedStrapHistory() = runBlocking {
        val queried = mutableListOf<String>()
        val now = System.currentTimeMillis() / 1_000L
        fun nights(id: String, dayOffset: IntRange) = dayOffset.map { day ->
            val start = now - day * 86_400L
            SleepSession(id, start, start + 8 * 3_600L)
        }
        val rows = mapOf(
            "whoop-new" to nights("whoop-new", 1..7),
            "whoop-old-noop" to nights("whoop-old-noop", 8..14),
        )
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> allWhoops
                "sleepSessions" -> {
                    val id = args[0] as String
                    queried += id
                    rows[id].orEmpty()
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val habitual = repo.habitualMidsleepSec("whoop-new", days = 30)

        assertEquals(
            listOf("whoop-new", "whoop-old", "my-whoop", "whoop-new-noop", "whoop-old-noop", "my-whoop-noop"),
            queried,
        )
        org.junit.Assert.assertNotNull(habitual)
    }

    @Test
    fun sessionMotionsPrefersOldSessionOwnerOverSameStartFallbacks() = runBlocking {
        val queried = mutableListOf<Pair<String, Long>>()
        val start = 1_000L
        val values = mapOf(
            "whoop-old-noop" to "[1,2]",
            "whoop-new-noop" to "[8,8]",
            "my-whoop-noop" to "[9,9]",
        )
        val repo = WhoopRepository(proxyDao { method, args ->
            when (method) {
                "pairedDevices" -> allWhoops
                "sessionMotionJson" -> {
                    val id = args[0] as String
                    queried += id to (args[1] as Long)
                    values[id]
                }
                else -> throw UnsupportedOperationException(method)
            }
        })

        val result = repo.sessionMotions(
            activeStrapId = "whoop-new",
            sessions = listOf(SleepSession(deviceId = "whoop-old", startTs = start, endTs = start + 3600)),
        )

        assertEquals(listOf("whoop-old-noop" to start), queried)
        assertEquals(listOf(1.0, 2.0), result[start])
    }

    private fun proxyDao(call: (String, Array<out Any?>) -> Any?): WhoopDao =
        Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            // These fixtures predate transport labels and exercise the legacy alias-union contract.
            when (method.name) {
                "pairedDevice", "activeDeviceId" -> null
                "hasWhoop5RrSource" -> false
                else -> call(method.name, args ?: emptyArray())
            }
        } as WhoopDao
}
