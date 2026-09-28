package com.noop.oura

/**
 * Pure, deterministic encoder for ONE line of the Oura activity (0x50 MET) research corpus — the Kotlin
 * twin of Swift `OuraActivityDumpLine`. Byte-identical output (fixed key order; `met` via Kotlin's
 * shortest round-trip [Double.toString], which matches Swift's `String(_:)` across the MET value range),
 * so the two platforms' JSONL corpora are interchangeable.
 *
 * WHY a sidecar and not a stream/table: the 0x50 activity/MET decode is Tier-B (a plausible third-party
 * formula, day-scale validated but not per-minute exact — OURA_PROTOCOL.md s6.13). The honest-data invariant forbids Tier-B
 * ever minting a durable scoring row, so it must never touch the datastore. This corpus is a separate,
 * clearly-labelled diagnostic file the app appends to purely so the raw MET series can be accumulated for
 * offline investigation. It never feeds scoring and is safe to delete.
 *
 * FORMAT: newline-delimited JSON (JSONL) — one record per line, append-only. The line is hand-built in a
 * FIXED key order so it is stable and testable byte-for-byte.
 */
object OuraActivityDumpLine {
    /** Bump when the record shape changes so a downstream reader can branch on `schema`. */
    const val SCHEMA = 1

    /**
     * One JSONL record (NO trailing newline — the writer adds it). `deviceId` is a controlled registry id
     * (e.g. `oura-<uuid>`) and `iso` is app-generated, so neither needs JSON string-escaping here.
     *   - ringTs:       the record's raw ring-clock timestamp (the dedup key: strictly increases per record).
     *   - utc:          the anchored wall-clock (unix seconds) for the record envelope.
     *   - iso:          human-readable UTC of `utc` (convenience for eyeballing).
     *   - state:        the raw 0x50 state byte (semantics unconfirmed — captured verbatim for study).
     *   - secPerSample: the ASSUMED per-sample cadence (60 s); downstream can recompute from `utc` deltas.
     *   - met:          the decoded per-sample MET series (Tier-B formula output, verbatim).
     */
    fun encode(
        deviceId: String,
        ringTs: Long,
        utc: Long,
        iso: String,
        state: Int,
        secPerSample: Int,
        met: List<Double>,
    ): String {
        val metStr = met.joinToString(",") { it.toString() }
        return "{\"schema\":$SCHEMA,\"deviceId\":\"$deviceId\",\"ringTs\":$ringTs," +
            "\"utc\":$utc,\"iso\":\"$iso\",\"state\":$state," +
            "\"secPerSample\":$secPerSample,\"met\":[$metStr]}"
    }
}
