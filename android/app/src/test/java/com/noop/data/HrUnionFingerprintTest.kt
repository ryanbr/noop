package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #2566 — [WhoopRepository.hrUnionFingerprint] is the SINGLE index-only witness of whether a window's
 * heart rate changed, shared by the cycle load cache and the daytime stress lens memo. Until #2566 there
 * were two of these computing the same facts in different encodings, and nothing stopped them drifting.
 *
 * The property that matters is #908: a strap re-added through the device manager banks its live raw under
 * a FRESH id, so a fingerprint keyed on the active id alone would serve a stale cached result after a
 * backfill landed rows under the alias. These pin that the witness walks the same id set
 * [WhoopRepository.hrSamplesUnion] reads, and that it does so with index aggregates only.
 *
 * Stubbed through a Proxy [WhoopDao] (no Room), answering per-id so a change under ONE id is visible.
 */
class HrUnionFingerprintTest {

    private fun row(id: String) = PairedDeviceRow(
        id = id, brand = "WHOOP", model = "4.0", nickname = null,
        sourceKind = "strap", capabilities = "hr", status = "active",
        addedAt = 0L, lastSeenAt = 0L,
    )

    /** [counts] and [maxTs] are keyed by deviceId, so each union id answers independently. */
    private fun repo(
        registered: List<String>,
        counts: Map<String, Int>,
        maxTs: Map<String, Long>,
        seen: MutableList<String>? = null,
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
                    counts[id] ?: 0
                }
                "maxHrTsInWindow" -> {
                    val id = args[0] as String
                    seen?.add("maxTs:$id")
                    maxTs[id] ?: 0L
                }
                // Any row fetch here would defeat the point: this is the cheap witness that AVOIDS one.
                else -> throw UnsupportedOperationException("hrUnionFingerprint must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    // The union is (active, other registered WHOOPs, canonical "my-whoop"), so a single-strap install
    // still reads two ids and a re-added strap reads three.
    @Test fun walksEveryUnionIdNotJustTheActive() = runBlocking {
        val seen = mutableListOf<String>()
        val fp = repo(
            registered = listOf("whoop-alias"),
            counts = mapOf("whoop-active" to 3, "whoop-alias" to 7, "my-whoop" to 11),
            maxTs = mapOf("whoop-active" to 300L, "whoop-alias" to 700L, "my-whoop" to 1100L),
            seen = seen,
        ).hrUnionFingerprint("whoop-active", 0L, 9_999L)

        assertEquals("whoop-active=3:300,whoop-alias=7:700,my-whoop=11:1100", fp)
        // Exactly one COUNT and one MAX per id, never a repeat and never a fourth id.
        assertEquals(
            listOf(
                "count:whoop-active", "maxTs:whoop-active",
                "count:whoop-alias", "maxTs:whoop-alias",
                "count:my-whoop", "maxTs:my-whoop",
            ),
            seen,
        )
    }

    // #908, the reason this is a union at all: rows landing under the ALIAS id must move the witness,
    // although the active id is untouched. A fingerprint keyed on the active id alone stays equal here
    // and serves a stale cached score.
    @Test fun movesWhenARowLandsUnderAnAliasIdOnly() = runBlocking {
        val before = repo(
            registered = listOf("whoop-alias"),
            counts = mapOf("whoop-active" to 5, "whoop-alias" to 0, "my-whoop" to 0),
            maxTs = mapOf("whoop-active" to 500L, "whoop-alias" to 0L, "my-whoop" to 0L),
        ).hrUnionFingerprint("whoop-active", 0L, 9_999L)

        val after = repo(
            registered = listOf("whoop-alias"),
            counts = mapOf("whoop-active" to 5, "whoop-alias" to 1, "my-whoop" to 0),
            maxTs = mapOf("whoop-active" to 500L, "whoop-alias" to 900L, "my-whoop" to 0L),
        ).hrUnionFingerprint("whoop-active", 0L, 9_999L)

        assertNotEquals(before, after)
    }

    // The canonical import id is in the union too, so a backfill under "my-whoop" moves it as well.
    @Test fun movesWhenARowLandsUnderTheCanonicalIdOnly() = runBlocking {
        val before = repo(
            registered = emptyList(),
            counts = mapOf("whoop-active" to 5, "my-whoop" to 0),
            maxTs = mapOf("whoop-active" to 500L, "my-whoop" to 0L),
        ).hrUnionFingerprint("whoop-active", 0L, 9_999L)

        val after = repo(
            registered = emptyList(),
            counts = mapOf("whoop-active" to 5, "my-whoop" to 2),
            maxTs = mapOf("whoop-active" to 500L, "my-whoop" to 800L),
        ).hrUnionFingerprint("whoop-active", 0L, 9_999L)

        assertEquals("whoop-active=5:500,my-whoop=0:0", before)
        assertNotEquals(before, after)
    }

    // Unchanged inputs must produce the SAME string, or every caller re-folds on every pass and the
    // memo is worse than no memo at all.
    @Test fun stableWhenNothingChanged() = runBlocking {
        fun fp() = runBlocking {
            repo(
                registered = listOf("whoop-alias"),
                counts = mapOf("whoop-active" to 4, "whoop-alias" to 6, "my-whoop" to 8),
                maxTs = mapOf("whoop-active" to 400L, "whoop-alias" to 600L, "my-whoop" to 800L),
            ).hrUnionFingerprint("whoop-active", 0L, 9_999L)
        }
        assertEquals(fp(), fp())
    }

    // An empty window is a stable non-null value per id, so a first run still differs from an unset
    // watermark while two empty reads match and nothing churns.
    @Test fun emptyWindowIsStableZeroes() = runBlocking {
        assertEquals(
            "whoop-active=0:0,my-whoop=0:0",
            repo(registered = emptyList(), counts = emptyMap(), maxTs = emptyMap())
                .hrUnionFingerprint("whoop-active", 0L, 9_999L),
        )
    }

    // The active id is never duplicated when it is also the canonical id (single-strap install that
    // never re-paired), so the witness stays one entry rather than comparing "my-whoop" against itself.
    @Test fun canonicalActiveIsNotDuplicated() = runBlocking {
        assertEquals(
            "my-whoop=9:900",
            repo(
                registered = emptyList(),
                counts = mapOf("my-whoop" to 9),
                maxTs = mapOf("my-whoop" to 900L),
            ).hrUnionFingerprint("my-whoop", 0L, 9_999L),
        )
    }
}
