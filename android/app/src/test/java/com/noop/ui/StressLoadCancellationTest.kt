package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StressLoadCancellationTest {
    @Test fun successfulReadAndTwoPhaseOrderStayIntact() = runTest {
        val phases = mutableListOf<Int>()
        StressLoadCancellation.read { 21 }?.let { phases += it }
        StressLoadCancellation.read { 34 }?.let { phases += it }
        assertEquals(listOf(21, 34), phases)
    }

    @Test fun successfulAbsentValueIsNotCancellation() = runTest {
        var reads = 0
        assertNull(StressLoadCancellation.read<Int?> { reads += 1; null })
        assertEquals(1, reads)
    }

    @Test fun alreadyCancelledLoadDoesNotStartARead() = runTest {
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        var reads = 0
        val old = launch {
            withContext(NonCancellable) { entered.complete(Unit); released.await() }
            StressLoadCancellation.read { reads += 1; 7 }
        }
        entered.await()
        old.cancel()
        released.complete(Unit)
        old.join()
        assertEquals(0, reads)
    }

    @Test fun lateCancelledReadCannotReplaceFreshState() = runTest {
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()
        val old = launch {
            StressLoadCancellation.read {
                withContext(NonCancellable) { entered.complete(Unit); released.await() }
                "old"
            }?.let { published += it }
        }
        entered.await()
        old.cancel()
        StressLoadCancellation.read { "fresh" }?.let { published += it }
        released.complete(Unit)
        old.join()
        assertEquals(listOf("fresh"), published)
    }

    @Test fun cancelledReadDoesNotStartTheNextPhase() = runTest {
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        var advancedReads = 0
        val published = mutableListOf<Int>()
        val old = launch {
            val core = StressLoadCancellation.read {
                withContext(NonCancellable) { entered.complete(Unit); released.await() }
                1
            } ?: return@launch
            published += core
            StressLoadCancellation.read { advancedReads += 1; 2 }?.let { published += it }
        }
        entered.await()
        old.cancel()
        released.complete(Unit)
        old.join()
        assertEquals(emptyList<Int>(), published)
        assertEquals(0, advancedReads)
    }

    @Test fun lateAdvancedReadCannotRestoreOldLenses() = runTest {
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()
        val old = launch {
            val core = StressLoadCancellation.read { "old-core" } ?: return@launch
            published += core
            StressLoadCancellation.read {
                withContext(NonCancellable) { entered.complete(Unit); released.await() }
                "old-lenses"
            }?.let { published += it }
        }
        entered.await()
        old.cancel()
        StressLoadCancellation.read { "fresh-core" }?.let { published += it }
        released.complete(Unit)
        old.join()
        assertEquals(listOf("old-core", "fresh-core"), published)
    }

    @Test fun ordinaryReadFailureStillUsesAbsentFallback() = runTest {
        var reads = 0
        val value = StressLoadCancellation.read<Int> { reads += 1; throw IllegalStateException("fixture") }
        assertNull(value)
        assertEquals(1, reads)
    }

    @Test fun cancellationIsNeverAFailedReadFallback() = runTest {
        var fallbackPublished = false
        var cancellationRethrown = false
        try {
            val value = StressLoadCancellation.read<Int> { throw CancellationException("fixture") }
            fallbackPublished = value == null
        } catch (_: CancellationException) {
            cancellationRethrown = true
        }
        assertTrue(cancellationRethrown)
        assertEquals(false, fallbackPublished)
    }
}
