package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class StressCoreRefreshTest {
    @Test
    fun failedFirstReadRetriesUnchangedDataAndThenMemoisesSuccess() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val fingerprint = "whoop-active=100:500,my-whoop=0:0"
        var attempts = 0
        suspend fun load(): String {
            attempts++
            if (attempts == 1) error("temporary read failure")
            return "timeline"
        }
        assertNull(refresh.loadIfChanged(fingerprint, ::load))
        assertEquals("timeline", refresh.loadIfChanged(fingerprint, ::load))
        assertNull(refresh.loadIfChanged(fingerprint, ::load))
        assertEquals(2, attempts)
    }

    @Test
    fun failedRefreshRetainsDisplayedCoreAndRetriesNewFingerprint() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val first = "whoop-active=100:500,my-whoop=0:0"
        val next = "whoop-active=101:510,my-whoop=0:0"
        var displayed = "loading"
        refresh.loadIfChanged(first) { "previous" }?.let { displayed = it }
        refresh.loadIfChanged(next) { error("temporary failure") }?.let { displayed = it }
        assertEquals("previous", displayed)
        refresh.loadIfChanged(next) { "updated" }?.let { displayed = it }
        assertEquals("updated", displayed)
    }

    @Test
    fun unknownFingerprintAlwaysReadsAndSuccessfulEmptyCoreIsMemoised() = runBlocking {
        val refresh = StressCoreRefresh<List<Int>>()
        assertEquals(emptyList<Int>(), refresh.loadIfChanged(null) { emptyList() })
        assertEquals(listOf(1), refresh.loadIfChanged(null) { listOf(1) })
        val emptyFingerprint = "whoop-active=0:0,my-whoop=0:0"
        assertEquals(emptyList<Int>(), refresh.loadIfChanged(emptyFingerprint) { emptyList() })
        assertNull(refresh.loadIfChanged(emptyFingerprint) { error("must skip successful empty read") })
    }

    @Test
    fun lifecycleCancellationPropagatesAndDoesNotConsumeFingerprint() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val fingerprint = "whoop-active=100:500,my-whoop=0:0"
        val cancellation = CancellationException("screen stopped")
        try {
            refresh.loadIfChanged(fingerprint) { throw cancellation }
            fail("cancellation must propagate")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
        assertEquals("resumed", refresh.loadIfChanged(fingerprint) { "resumed" })
    }

    @Test
    fun aliasBackfillChangesTheUnionFingerprintAndRetriesWithoutChangingActiveHr() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val before = "whoop-active=100:500,whoop-archived=1:400,my-whoop=0:0"
        val after = "whoop-active=100:500,whoop-archived=2:400,my-whoop=0:0"
        assertEquals("previous", refresh.loadIfChanged(before) { "previous" })
        assertNull(refresh.loadIfChanged(after) { error("temporary read failure") })
        assertEquals("backfilled", refresh.loadIfChanged(after) { "backfilled" })
        assertNull(refresh.loadIfChanged(after) { error("must skip successful union read") })
    }

    @Test
    fun lateCancelledCoreCannotPublishOrConsumeTheUnionFingerprint() = runTest {
        val refresh = StressCoreRefresh<String>()
        val fingerprint = "whoop-active=100:500,my-whoop=0:0"
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()
        val old = launch {
            refresh.loadIfChanged(fingerprint) {
                withContext(NonCancellable) { entered.complete(Unit); released.await() }
                "stale"
            }?.let { published += it }
        }
        entered.await()
        old.cancel()
        released.complete(Unit)
        old.join()
        assertEquals(emptyList<String>(), published)
        assertEquals("resumed", refresh.loadIfChanged(fingerprint) { "resumed" })
    }
}
