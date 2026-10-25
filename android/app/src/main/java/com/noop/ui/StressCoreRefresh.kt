package com.noop.ui

/** Memoises successful union reads; failed reads remain eligible on the next refresh tick. */
internal class StressCoreRefresh<T : Any> {
    private var lastHrFingerprint: String? = null

    suspend fun loadIfChanged(fingerprint: String?, load: suspend () -> T): T? {
        if (fingerprint != null && fingerprint == lastHrFingerprint) return null
        val core = StressLoadCancellation.read(load) ?: return null
        lastHrFingerprint = fingerprint
        return core
    }
}
