package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class StressCoreRefreshTest {
    @Test
    fun failedFirstReadRetriesUnchangedDataAndThenMemoisesSuccess() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val fingerprint = 100 to 500L
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
        val first = 100 to 500L
        val next = 101 to 510L
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
        val emptyFingerprint = 0 to 0L
        assertEquals(emptyList<Int>(), refresh.loadIfChanged(emptyFingerprint) { emptyList() })
        assertNull(refresh.loadIfChanged(emptyFingerprint) { error("must skip successful empty read") })
    }

    @Test
    fun lifecycleCancellationPropagatesAndDoesNotConsumeFingerprint() = runBlocking {
        val refresh = StressCoreRefresh<String>()
        val fingerprint = 100 to 500L
        val cancellation = CancellationException("screen stopped")
        try {
            refresh.loadIfChanged(fingerprint) { throw cancellation }
            fail("cancellation must propagate")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
        assertEquals("resumed", refresh.loadIfChanged(fingerprint) { "resumed" })
    }
}
