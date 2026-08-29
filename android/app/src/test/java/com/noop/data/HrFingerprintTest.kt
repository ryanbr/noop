package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #836 — [WhoopRepository.hrFingerprint] is the cheap whole-history raw-HR change-detector the 15-min idle
 * rescore gates on: `"count:maxTs"`. Stubbed through a Proxy [WhoopDao] (no Room), answering only the two
 * aggregate queries the fingerprint reads. Mirrors the Swift WhoopStore.hrFingerprint semantics.
 */
class HrFingerprintTest {

    private fun repo(count: Int, maxTs: Long): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "countHr" -> count
                "maxHrTs" -> maxTs
                else -> throw UnsupportedOperationException("hrFingerprint must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    @Test fun combinesCountAndMaxTs() = runBlocking {
        assertEquals("42:1700", repo(count = 42, maxTs = 1700L).hrFingerprint())
    }

    // An empty store is a stable, non-null "0:0" (COALESCE), so a first run still differs from the unset
    // (null) watermark and scores; two empty reads match, so a genuinely empty store doesn't churn.
    @Test fun emptyStoreIsZeroZero() = runBlocking {
        assertEquals("0:0", repo(count = 0, maxTs = 0L).hrFingerprint())
    }

    // A new sample (count up, later maxTs) moves the fingerprint, so the idle tick rescores.
    @Test fun newSampleMovesTheFingerprint() = runBlocking {
        val before = repo(count = 10, maxTs = 1000L).hrFingerprint()
        val after = repo(count = 11, maxTs = 1060L).hrFingerprint()
        assertEquals("10:1000", before)
        assertEquals("11:1060", after)
    }

    @Test fun analysisFingerprintUsesTheCompleteDaoAggregate() = runBlocking {
        val expected = "v2|h10:1000|p0|r2|x0|g1|s0|e0|o0|t0|z0"
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "analysisFingerprint" -> expected
                else -> throw UnsupportedOperationException("analysisFingerprint must not call ${method.name}")
            }
        } as WhoopDao
        assertEquals(expected, WhoopRepository(dao).analysisFingerprint())
    }
}
