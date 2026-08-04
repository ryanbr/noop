package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #984 — what a tap on an inbox row opens.
 *
 * The bug: the What's New row was posted with NO `deepLink` while its own message read "tap to read
 * what's new", and the tap handler bailed out on a null link. So every release since the inbox shipped
 * posted an entry that could not be opened — the tap only marked it read, which moved it from "New"
 * down into "Earlier" on a sheet that could not scroll, and it looked deleted.
 *
 * [UpdateStore.deepLinkTarget] is the rule, pulled out of the Compose row so it can be pinned here.
 * The store's own persistence is SharedPreferences + org.json and is not reachable from a plain JVM
 * test (the same constraint `NapStoreTest` documents), so this is the half of the fix that CAN be
 * tested — the seeding itself is covered by the Android build, not by a unit test.
 */
class UpdateDeepLinkTest {

    private fun item(kind: UpdateKind, deepLink: String? = null) =
        UpdateItem(kind = kind, title = "t", message = "m", deepLink = deepLink)

    /** The regression itself: a What's New row opens the changelog even with no link of its own. */
    @Test
    fun whatsNewResolvesToTheChangelogWithoutAnExplicitLink() {
        assertEquals(UpdateStore.WHATS_NEW_DEEP_LINK,
            UpdateStore.deepLinkTarget(item(UpdateKind.WHATS_NEW)))
    }

    /**
     * The fallback is what rescues rows ALREADY sitting in someone's inbox. Those were posted before
     * the fix with `deepLink = null`, and without this they would stay inert until a later release
     * replaced them — which is exactly the state the bug was reported from.
     */
    @Test
    fun aWhatsNewRowPostedBeforeTheFixStillOpens() {
        val legacyRow = UpdateItem(kind = UpdateKind.WHATS_NEW, title = "NOOP 9.2.3", message = "m")
        assertNull("precondition: the old row carries no link", legacyRow.deepLink)
        assertEquals(UpdateStore.WHATS_NEW_DEEP_LINK, UpdateStore.deepLinkTarget(legacyRow))
    }

    /** An explicit link always wins, so the fallback can never hijack a row that names its own target. */
    @Test
    fun anExplicitLinkIsNotOverriddenByTheFallback() {
        assertEquals("trends",
            UpdateStore.deepLinkTarget(item(UpdateKind.WHATS_NEW, deepLink = "trends")))
    }

    /** Purely informational kinds stay inert — the fallback is scoped to What's New, not to everything. */
    @Test
    fun otherKindsWithoutALinkStayInformational() {
        assertNull(UpdateStore.deepLinkTarget(item(UpdateKind.STRAP_ALERT)))
        assertNull(UpdateStore.deepLinkTarget(item(UpdateKind.DISMISSED_CARD)))
        assertNull(UpdateStore.deepLinkTarget(item(UpdateKind.READING)))
    }

    /** Those kinds still route when they DO carry a link (the "reading" rows point at Trends). */
    @Test
    fun otherKindsStillRouteWhenTheyCarryALink() {
        assertEquals("trends", UpdateStore.deepLinkTarget(item(UpdateKind.READING, deepLink = "trends")))
    }

    /**
     * The key is a contract with `AppRoot`'s `onDeepLink`, which ignores any key it does not recognise —
     * a silent no-op, i.e. the exact failure mode this issue was. Pinned so a rename cannot reintroduce
     * it quietly on one side.
     */
    @Test
    fun theChangelogKeyIsStable() {
        assertEquals("whatsNew", UpdateStore.WHATS_NEW_DEEP_LINK)
    }
}
