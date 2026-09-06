package com.noop.testcentre

import org.json.JSONObject

/**
 * Twin of the Swift TestBundleMeta (spec section 5.1): meta.json schema v1, the machine-readable tie
 * between a strap log and the test profile that produced it. Same snake_case wire keys, same build and
 * storage blocks, redaction stamped v2. We emit keys in sorted order by hand so the bytes line up with
 * the Swift JSONEncoder sortedKeys output, which the parity test asserts.
 */
data class TestBundleMeta(
    val schema: Int,
    val appVersion: String,
    val platform: String,
    val osVersion: String,
    val strapModel: String?,
    val source: List<String>,
    val testProfile: String,
    val profileStartedAt: String?,
    val questionnaire: Map<String, String>,
    val build: Build,
    val storage: Storage,
    val redaction: String,
    val truncated: Boolean,
    val captureCheck: CaptureCheck,
) {
    data class Build(val channel: String, val signed: Boolean)
    data class Storage(
        val dbBytes: Int,
        val rows: Map<String, Int>,
        val rawCaptureBytes: Int,
        /** #1911: estimated payload bytes per table, keyed as [rows] is. Swift twin: `Storage.rowBytes`. */
        val rowBytes: Map<String, Int> = emptyMap(),
    )

    /** The report-completeness tie (twin of the Swift CaptureCheck): per-domain killer-trace presence
     *  ({domainId -> "present"|"MISSING"}) plus the overall `complete` flag, so a maintainer can tell at
     *  a glance whether the report actually carries each active mode's diagnostic. */
    data class CaptureCheck(val traces: Map<String, String>, val complete: Boolean)

    /** Pretty, sorted JSON. We do NOT rely on JSONObject key ordering (the org.json on the unit-test
     *  classpath is HashMap-backed and does not preserve insertion order), so we emit keys in explicit
     *  alphabetical order ourselves, matching the Swift JSONEncoder .sortedKeys output the parity test
     *  asserts. Only JSONObject.quote (a pure static escaper) is used, so this is backend-independent. */
    fun encoded(): String {
        val root = mapOf<String, Any?>(
            "app_version" to appVersion,
            "build" to mapOf("channel" to build.channel, "signed" to build.signed),
            "capture_check" to mapOf(
                "complete" to captureCheck.complete,
                "traces" to captureCheck.traces),
            "os_version" to osVersion,
            "platform" to platform,
            "profile_started_at" to profileStartedAt,
            "questionnaire" to questionnaire,
            "redaction" to redaction,
            "schema" to schema,
            "source" to source,
            "storage" to mapOf(
                "db_bytes" to storage.dbBytes,
                "raw_capture_bytes" to storage.rawCaptureBytes,
                "rows" to storage.rows,
                // #1911: bytes beside the counts, so this block matches the Apple bundle's. Rows alone
                // cannot say which table holds a large store - ppgWaveformSample's rows carry a BLOB.
                "row_bytes" to storage.rowBytes),
            "strap_model" to strapModel,
            "test_profile" to testProfile,
            "truncated" to truncated)
        return emit(root, 0)
    }

    private fun emit(value: Any?, indent: Int): String {
        val pad = "  ".repeat(indent)
        val padIn = "  ".repeat(indent + 1)
        return when (value) {
            null -> "null"
            is String -> JSONObject.quote(value)
            is Boolean, is Int, is Long, is Double -> value.toString()
            is Map<*, *> -> {
                val entries = value.entries.associate { it.key.toString() to it.value }
                if (entries.isEmpty()) "{}"
                else entries.keys.sorted().joinToString(",\n", "{\n", "\n$pad}") { k ->
                    "$padIn${JSONObject.quote(k)} : ${emit(entries[k], indent + 1)}"
                }
            }
            is List<*> ->
                if (value.isEmpty()) "[]"
                else value.joinToString(",\n", "[\n", "\n$pad]") { "$padIn${emit(it, indent + 1)}" }
            else -> JSONObject.quote(value.toString())
        }
    }
}
