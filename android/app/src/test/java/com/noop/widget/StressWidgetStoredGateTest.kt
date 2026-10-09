package com.noop.widget

import com.noop.data.PairedDeviceRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.io.File
import java.lang.reflect.Proxy
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2710 — every gate standing in front of a UNION stress read must itself be a union witness.
 *
 * The producer's memo was only the first of three. The worker's gate is the one that bites hardest:
 * it compares a PERSISTED value and returns before [StressWidgetProducer.todayCurve] is reached at
 * all, so keyed on the active strap alone it skipped the scoring pass outright after a backfill landed
 * today's rows under an alias id (#908, a strap re-added through the device manager). The widget then
 * held a curve that nothing would correct until the active strap's own count moved.
 *
 * Stubbed through a Proxy [WhoopDao] (no Room), answering per-id so a change under ONE id is visible,
 * and refusing every row fetch: this gate exists to AVOID one.
 */
class StressWidgetStoredGateTest {

    // 2023-11-14T22:13:20Z. In UTC the local stress day is 19675 and its window starts at 1699920000,
    // so the gate's expected arguments are arithmetic rather than a second call to the window helper.
    private val nowMs = 1_700_000_000_000L
    private val utc = ZoneId.of("UTC")

    private fun row(id: String) = PairedDeviceRow(
        id = id, brand = "WHOOP", model = "4.0", nickname = null,
        sourceKind = "strap", capabilities = "hr", status = "active",
        addedAt = 0L, lastSeenAt = 0L,
    )

    private fun repo(
        registered: List<String>,
        counts: Map<String, Int>,
        maxTs: Map<String, Long>,
        seen: MutableList<String>? = null,
        windows: MutableList<Pair<Long, Long>>? = null,
    ): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "pairedDevices" -> registered.map(::row)
                "countHrInWindow" -> {
                    val id = args[0] as String
                    seen?.add("count:$id")
                    windows?.add((args[1] as Long) to (args[2] as Long))
                    counts[id] ?: 0
                }
                "maxHrTsInWindow" -> {
                    val id = args[0] as String
                    seen?.add("maxTs:$id")
                    maxTs[id] ?: 0L
                }
                else -> throw UnsupportedOperationException("the stored gate must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    @Test fun walksEveryUnionIdOverTodaySoFarWithIndexAggregatesOnly() = runBlocking {
        val seen = mutableListOf<String>()
        val windows = mutableListOf<Pair<Long, Long>>()
        val fp = StressWidgetRefresh.storedFingerprint(
            repo(
                registered = listOf("whoop-alias"),
                counts = mapOf("whoop-active" to 3, "whoop-alias" to 7, "my-whoop" to 11),
                maxTs = mapOf("whoop-active" to 300L, "whoop-alias" to 700L, "my-whoop" to 1100L),
                seen = seen,
                windows = windows,
            ),
            deviceId = "whoop-active", nowMs = nowMs, zone = utc,
        )

        assertEquals(
            "whoop-active=3:300,whoop-alias=7:700,my-whoop=11:1100|day=19675",
            fp,
        )
        assertEquals(
            listOf(
                "count:whoop-active", "maxTs:whoop-active",
                "count:whoop-alias", "maxTs:whoop-alias",
                "count:my-whoop", "maxTs:my-whoop",
            ),
            seen,
        )
        // Day start to NOW, not to the day's end: the gate asks what has landed so far, which is the
        // same span StressWidgetProducer scores.
        assertEquals(List(3) { 1_699_920_000L to 1_700_000_000L }, windows)
    }

    // THE #2710 CASE. The active strap is idle and unchanged; the day's rows arrive under the alias.
    @Test fun aliasBackfillMovesTheStoredFingerprint() = runBlocking {
        val before = StressWidgetRefresh.storedFingerprint(
            repo(
                registered = listOf("whoop-alias"),
                counts = mapOf("whoop-active" to 3, "whoop-alias" to 0, "my-whoop" to 0),
                maxTs = mapOf("whoop-active" to 300L),
            ),
            deviceId = "whoop-active", nowMs = nowMs, zone = utc,
        )
        val after = StressWidgetRefresh.storedFingerprint(
            repo(
                registered = listOf("whoop-alias"),
                counts = mapOf("whoop-active" to 3, "whoop-alias" to 412, "my-whoop" to 0),
                maxTs = mapOf("whoop-active" to 300L, "whoop-alias" to 1_699_999_000L),
            ),
            deviceId = "whoop-active", nowMs = nowMs, zone = utc,
        )

        assertNotEquals(before, after)
    }

    // A witness that happened to match across midnight would otherwise hold yesterday's line as today's.
    @Test fun theLocalDayIsPartOfTheStoredIdentity() {
        fun at(ms: Long) = runBlocking {
            StressWidgetRefresh.storedFingerprint(
                repo(
                    registered = emptyList(),
                    counts = mapOf("whoop-active" to 5, "my-whoop" to 0),
                    maxTs = mapOf("whoop-active" to 500L),
                ),
                deviceId = "whoop-active", nowMs = ms, zone = utc,
            )
        }

        assertNotEquals(at(nowMs), at(nowMs + 86_400_000L))
        assertEquals(at(nowMs), at(nowMs))
    }

    /**
     * Source tripwires for the two gates that cannot be reached from a JVM test: the worker's is behind
     * a Context and a NoopApplication, the screen's is inside a Compose LaunchedEffect. Both compile
     * perfectly well with the narrow witness, which is how they came to disagree with the read.
     */
    @Test fun everyStressGateUsesTheUnionWitness() {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val root = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
            .firstOrNull { File(it, "Strand/Data/StressDayCurve.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
        fun source(path: String) = File(root, path).readText()

        val screen = source("android/app/src/main/java/com/noop/ui/StressScreen.kt")
        val worker = source("android/app/src/main/java/com/noop/widget/StressWidgetRefresh.kt")

        assertTrue(
            "the screen's periodic re-read gate must use the union witness",
            screen.contains("vm.repo.hrUnionFingerprint(vm.activeStrapId, window.fromEpochSecond, nowSeconds)"),
        )
        assertTrue(
            "the worker's stored gate must route through storedFingerprint",
            worker.contains("StressWidgetRefresh.storedFingerprint("),
        )
        for (path in listOf(
            "android/app/src/main/java/com/noop/ui/StressScreen.kt",
            "android/app/src/main/java/com/noop/widget/StressWidgetRefresh.kt",
        )) {
            assertFalse(
                "$path guards a union read, so it must not gate on hrFingerprintWindow",
                source(path).contains("hrFingerprintWindow("),
            )
        }

        // The Apple producer is the documented twin of StressWidgetProducer and guards the same union
        // reads. Its witness used to be a union SUM, one count and one max across the ids, which holds
        // steady when the window's composition changes without its totals changing. Asserted from here
        // because this is the suite that runs on every push; the Swift side has no JVM reach of its own.
        val appleProducer = source("Strand/Data/StressDayCurve.swift")
        assertTrue(
            "the Apple producer must gate on the per-id union witness",
            appleProducer.contains("await repo.hrFingerprintUnion(from: from, to: to)"),
        )
        assertFalse(
            "the superseded summed witness must not come back",
            source("Strand/Data/Repository.swift").contains("func hrFingerprint(from:"),
        )
    }
}
