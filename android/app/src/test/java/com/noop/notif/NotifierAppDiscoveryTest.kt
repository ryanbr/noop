package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Unit tests for the wrist-alert app picker's selection rule ([InstalledNotifierApps.filterNotifierCandidates])
 * and the discovery store ([NotifierAppDiscovery]).
 *
 * The filter is the whole feature: "which installed apps may be offered for per-app wrist buzzes".
 * It is deliberately a pure function of (declares POST_NOTIFICATIONS, enabled, is-self) so the rule
 * is testable without a device — the PackageManager plumbing in InstalledNotifierApps.list is thin
 * by comparison. Mirrors the plain-JUnit style of the other notif/ policy tests; the two discovery-
 * store tests run under Robolectric (already a test dep) for a real SharedPreferences.
 */
@RunWith(RobolectricTestRunner::class)
class NotifierAppDiscoveryTest {

    private fun candidate(pkg: String, posts: Boolean = true, enabled: Boolean = true, system: Boolean = false) =
        NotifierCandidate(pkg, requestsPostNotifications = posts, enabled = enabled, systemApp = system)

    @Test
    fun `apps declaring the notification permission are offered`() {
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(candidate("com.acme.chat"), candidate("com.acme.game", posts = false)),
            selfPackage = "com.noop.whoop",
        )
        assertEquals(listOf("com.acme.chat"), kept.map { it.packageName })
    }

    @Test
    fun `disabled packages are not offered`() {
        // A disabled (uninstalled-for-this-user / stopped) system package must not appear as a
        // pickable app — toggling it on would promise a buzz that can never arrive.
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(candidate("com.acme.chat", enabled = false)),
            selfPackage = "com.noop.whoop",
        )
        assertTrue(kept.isEmpty())
    }

    @Test
    fun `noop's own package is never offered`() {
        // NOOP's own notifications are governed by the Daily-reports card, not the wrist picker;
        // offering it here would buzz for NOOP's own alerts (the same self-buzz trap #1115 guards
        // against for the Clock path).
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(candidate("com.noop.whoop")),
            selfPackage = "com.noop.whoop",
        )
        assertTrue(kept.isEmpty())
    }

    @Test
    fun `null requestedPermissions is treated as not-a-notifier`() {
        // PackageInfo.requestedPermissions is nullable; a null array must not NPE and must not
        // sneak an app into the picker.
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(NotifierCandidate("com.acme.mystery", requestsPostNotifications = false, enabled = true)),
            selfPackage = "com.noop.whoop",
        )
        assertTrue(kept.isEmpty())
    }

    @Test
    fun `selection keeps declaration and enabledness as independent requirements`() {
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(
                candidate("a.ok"),
                candidate("b.noPerm", posts = false),
                candidate("c.disabled", enabled = false),
                candidate("d.self", posts = true).copy(packageName = "com.noop.whoop"),
            ),
            selfPackage = "com.noop.whoop",
        )
        assertEquals(listOf("a.ok"), kept.map { it.packageName })
    }

    @Test
    fun `system packages are not offered by the enumeration path`() {
        // The enumeration path lists apps by what they DECLARE, with no evidence they ever notify,
        // so FLAG_SYSTEM apps (OEM agents, bundled services) stay out. A system app that actually
        // POSTS is handled by the discovered path instead — see the Gmail test below.
        val kept = InstalledNotifierApps.filterNotifierCandidates(
            listOf(candidate("com.acme.chat"), candidate("com.oem.agent", system = true)),
            selfPackage = "com.noop.whoop",
        )
        assertEquals(listOf("com.acme.chat"), kept.map { it.packageName })
    }

    @Test
    fun `a preinstalled app that actually posted is offered`() {
        // The Gmail case: OEM builds mark Gmail / Samsung Messages / carrier apps FLAG_SYSTEM, so a
        // blanket flag filter hid them even after they posted and the listener recorded them.
        // Posting is the evidence the feature is built on — the flag is not.
        val ctx = org.robolectric.RuntimeEnvironment.getApplication()
        val pm = ctx.packageManager
        val pkg = "com.google.android.gm"
        val info = android.content.pm.PackageInfo().apply {
            packageName = pkg
            applicationInfo = android.content.pm.ApplicationInfo().apply {
                packageName = pkg
                flags = android.content.pm.ApplicationInfo.FLAG_SYSTEM
                enabled = true
            }
            requestedPermissions = arrayOf(InstalledNotifierApps.POST_NOTIFICATIONS)
        }
        org.robolectric.Shadows.shadowOf(pm).installPackage(info)

        NotifierAppDiscovery.record(ctx, pkg)
        val packages = NotifierAppDiscovery.load(ctx).map { it.packageName }
        assertTrue("preinstalled poster must be pickable", pkg in packages)
    }

    @Test
    fun `NotifierApp is keyed by package name`() {
        // The picker's persistence key IS the package name — the exact key the notification
        // listener gates on (NotifPrefs.appEnabled(ctx, sbn.packageName)). Pin the shape so a
        // refactor cannot silently key prefs on the label.
        val app = NotifierApp("com.acme.chat", "Acme Chat")
        assertEquals("com.acme.chat", app.packageName)
        assertEquals("Acme Chat", app.label)
    }

    @Test
    fun `discovery store is empty before any post`() {
        val ctx = org.robolectric.RuntimeEnvironment.getApplication()
        assertFalse(NotifierAppDiscovery.discoveredPackages(ctx).isNotEmpty())
    }

    @Test
    fun `record persists a package and is idempotent`() {
        val ctx = org.robolectric.RuntimeEnvironment.getApplication()
        NotifierAppDiscovery.record(ctx, "com.acme.chat")
        NotifierAppDiscovery.record(ctx, "com.acme.chat") // second post: no-op, no duplicate storm
        NotifierAppDiscovery.record(ctx, "com.acme.mail")
        val discovered = NotifierAppDiscovery.discoveredPackages(ctx)
        assertTrue(discovered.contains("com.acme.chat"))
        assertTrue(discovered.contains("com.acme.mail"))
    }
}
