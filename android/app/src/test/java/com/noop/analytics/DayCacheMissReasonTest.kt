package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2073: the day-cache reuse line reported only HOW MANY nights were reused, never why the rest missed.
 *
 * A field log showed `reused=0/21` on 13 of 17 passes, each costing about 50 seconds of prep and 1.75M
 * row reads, every 15 minutes on battery. A healthy pass reuses all but today, whose heart rate is still
 * growing, so a total miss means something shared by every key moved. Those are different bugs and the
 * count could not tell them apart.
 *
 * Keys are `owner|hrCount:hrMaxTs:anchor:detail|streams`.
 */
class DayCacheMissReasonTest {
    private fun key(owner: String, hr: String, streams: String) = "$owner|$hr|$streams"

    @Test
    fun `an identical key is not a miss`() {
        val k = key("my-whoop", "100:200:nil:s", "a|rrAlias5=true")
        assertEquals("none", AnalyzeRecentDayCache.missReason(k, k))
    }

    @Test
    fun `today's growing heart rate is named as the hr segment`() {
        // The healthy case: only today misses, and it misses for the right reason.
        assertEquals(
            "hr",
            AnalyzeRecentDayCache.missReason(
                key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
                key("my-whoop", "140:260:nil:s", "a|rrAlias5=true"),
            ),
        )
    }

    @Test
    fun `a moved owner is named, because it invalidates every day at once`() {
        assertEquals(
            "owner",
            AnalyzeRecentDayCache.missReason(
                key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
                key("whoop-5A0", "100:200:nil:s", "a|rrAlias5=true"),
            ),
        )
    }

    /**
     * The one input computed ONCE per pass and folded into all 21 keys, so a single flip is a total miss.
     * Separated from the rest of `streams` precisely so a log can say whether that is what happened.
     */
    @Test
    fun `the pass-global rr alias is called out separately from the stream fingerprint`() {
        assertEquals(
            "rrAlias5",
            AnalyzeRecentDayCache.missReason(
                key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
                key("my-whoop", "100:200:nil:s", "a|rrAlias5=false"),
            ),
        )
        // A stream fingerprint that moved while the alias held is the OTHER answer, and means per-day data.
        assertEquals(
            "streams",
            AnalyzeRecentDayCache.missReason(
                key("my-whoop", "100:200:nil:s", "a|rrAlias5=true"),
                key("my-whoop", "100:200:nil:s", "b|rrAlias5=true"),
            ),
        )
    }

    /**
     * The causes that do NOT come from comparing two keys, and the reason the tally reports them at all.
     * A cache dropped wholesale, or a night that was never cached, leaves nothing to compare, so without
     * their own tokens a total miss would print `reused=0/21` with no cause, which is the exact silence
     * this diagnostic exists to remove.
     */
    @Test
    fun `the causes with no key to compare still have names`() {
        // Both are produced by the engine rather than by missReason, so this pins the vocabulary the
        // reader will see rather than the function's branches.
        // `configDropped` carries the field that moved, e.g. `configDropped(hrvBaseline)`, so the bare
        // token is a prefix rather than the whole key. See [DayCacheConfigFieldTest].
        val tokens = setOf("none", "shape", "owner", "hr", "rrAlias5", "streams", "absent",
                           "configDropped(<field>)")
        assertTrue(tokens.contains("absent"))
        assertTrue(tokens.any { it.startsWith("configDropped") })
    }

    @Test
    fun `a key that is not the expected shape says so rather than guessing`() {
        assertEquals("shape", AnalyzeRecentDayCache.missReason("nopipes", "alsonone"))
    }
}
