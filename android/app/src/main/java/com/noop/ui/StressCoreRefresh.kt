package com.noop.ui

import kotlinx.coroutines.CancellationException

/** Memoises successful core reads; failed reads remain eligible on the next refresh tick. */
internal class StressCoreRefresh<T : Any> {
    private var lastHrFingerprint: Pair<Int, Long>? = null

    suspend fun loadIfChanged(fingerprint: Pair<Int, Long>?, load: suspend () -> T): T? {
        if (fingerprint != null && fingerprint == lastHrFingerprint) return null
        val core = try {
            load()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        }
        lastHrFingerprint = fingerprint
        return core
    }
}
