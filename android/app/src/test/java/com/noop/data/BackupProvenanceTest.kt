package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #1410 build-provenance JSON. The expected strings are byte-identical to what Swift's
 * `JSONSerialization(.sortedKeys)` emits for the same inputs (see `BackupProvenanceTests.swift`) —
 * keys alphabetical, compact, numbers unquoted — so an analyst reads one shape across platforms.
 */
class BackupProvenanceTest {

    @Test fun manifest_json_is_sorted_and_parity_with_swift() {
        assertEquals(
            """{"appBuild":"221","appVersion":"10.1.1","exportedAt":1723900000000,"platform":"android","schemaVersion":30}""",
            BackupManifest.json(
                appVersion = "10.1.1", appBuild = "221", platform = "android",
                schemaVersion = 30, exportedAtMs = 1_723_900_000_000L,
            ),
        )
    }

    @Test fun versionEvent_payload_is_sorted() {
        assertEquals(
            """{"from":"10.1.0","schemaVersion":30,"to":"10.1.1"}""",
            AppVersionEvent.payloadJson(from = "10.1.0", to = "10.1.1", schemaVersion = 30),
        )
    }

    @Test fun shouldRecord_only_on_a_real_transition() {
        assertFalse("first launch — no prior", AppVersionEvent.shouldRecord(lastSeen = null, current = "10.1.1"))
        assertFalse("blank prior", AppVersionEvent.shouldRecord(lastSeen = "", current = "10.1.1"))
        assertFalse("unchanged", AppVersionEvent.shouldRecord(lastSeen = "10.1.1", current = "10.1.1"))
        assertTrue("transition", AppVersionEvent.shouldRecord(lastSeen = "10.1.0", current = "10.1.1"))
    }
}
