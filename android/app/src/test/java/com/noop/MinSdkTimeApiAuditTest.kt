package com.noop

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source guard for #2789: `LocalDate.ofInstant` and `LocalTime.ofInstant` are Java 9 additions that
 * Android only ships from API 34. minSdk is 26 with no core-library desugaring, so on Android 8–13
 * the call throws `NoSuchMethodError`: a crash in the Health Connect import, and a silently dropped
 * readout wherever a `runCatching` swallowed it.
 *
 * No behaviour test can see this, because the JVM these tests run on has the method. Android lint's
 * `NewApi` check would, but CI does not run lint. `instant.atZone(zone).toLocalDate()` is the same
 * conversion and exists on every API level.
 */
class MinSdkTimeApiAuditTest {

    private val java9OfInstant = Regex("""\b(LocalDate|LocalTime)\.ofInstant\s*\(""")

    private fun mainSourceDir(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val found = listOf(
            File(userDir, "src/main/java/com/noop"),
            File(userDir, "app/src/main/java/com/noop"),
            File(userDir, "android/app/src/main/java/com/noop"),
        ).firstOrNull { it.isDirectory }
        assertNotNull("com/noop not found from user.dir=$userDir; a source guard must fail closed", found)
        return found!!
    }

    @Test fun mainSourcesNeverCallTheApi34OfInstantFactories() {
        val sources = mainSourceDir().walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("only ${sources.size} Kotlin files found; the guard is scanning the wrong tree", sources.size > 100)
        val hits = sources.flatMap { file ->
            file.readLines().mapIndexedNotNull { index, line ->
                val code = line.trim()
                val isComment = code.startsWith("//") || code.startsWith("*") || code.startsWith("/*")
                if (!isComment && java9OfInstant.containsMatchIn(code)) "${file.name}:${index + 1}" else null
            }
        }
        assertTrue("API 34 ofInstant on minSdk 26 (use atZone(..).toLocalDate()): $hits", hits.isEmpty())
    }
}
