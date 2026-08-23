package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Pins the Android More-page navigation contract. More is a real NavHost destination, so each row must
 * push its destination onto the current stack. Treating a row like a bottom-tab switch pops More back to
 * Today before opening the destination, which makes Android Back skip More entirely.
 *
 * This source audit is deliberately paired with the existing navigation wiring: it proves every generated
 * [MoreRow] still flows through the shared push callback while the actual bottom bar retains the separate
 * top-level state-save/restore policy. It follows the source-locating pattern used by
 * [ResolvedSeriesCallSiteAuditTest].
 */
class MoreNavigationContractTest {

    /** Locate AppRoot.kt from Gradle, IDE, or repository-root test working directories. */
    private fun appRootSource(): File? {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/AppRoot.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/AppRoot.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/AppRoot.kt"),
        ).firstOrNull { it.isFile }
    }

    @Test
    fun moreRowsPushWhileBottomTabsRemainTopLevel() {
        val sourceFile = appRootSource()
        assumeTrue("AppRoot.kt not reachable from ${System.getProperty("user.dir")}", sourceFile != null)
        val source = sourceFile!!.readText().replace(Regex("\\s+"), " ")

        assertTrue(
            "More destinations must be pushed so Back returns to More",
            source.contains("MoreScreen(onNavigate = { nav.navigate(it) })"),
        )
        assertFalse(
            "More destinations must not clear the stack through navigateTopLevel",
            source.contains("MoreScreen(onNavigate = { nav.navigateTopLevel(it) })"),
        )
        assertTrue(
            "Every generated More row must keep using the shared navigation callback",
            source.contains("MoreRow(dest = dest, onClick = { onNavigate(dest.route) })"),
        )
        assertTrue(
            "Bottom-tab selections must retain top-level state save/restore",
            source.contains("if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)"),
        )
    }
}
