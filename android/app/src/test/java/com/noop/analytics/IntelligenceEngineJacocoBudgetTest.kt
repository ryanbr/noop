package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import org.jacoco.core.instr.Instrumenter
import org.jacoco.core.runtime.OfflineInstrumentationAccessGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Regression guard for the JaCoCo method-size failure tracked by bhelm/noop#102. */
class IntelligenceEngineJacocoBudgetTest {
    @Test
    fun offlineInstrumentedMethodsKeepSafeCodeMargins() {
        val resource = "/com/noop/analytics/IntelligenceEngine.class"
        val original = IntelligenceEngine::class.java.getResourceAsStream(resource)?.use { it.readBytes() }
        assertNotNull("Missing compiled, uninstrumented class resource $resource", original)

        // Do not catch this: any JaCoCo instrumentation exception is the regression this test guards.
        val instrumented = Instrumenter(OfflineInstrumentationAccessGenerator()).instrument(
            original!!,
            "com/noop/analytics/IntelligenceEngine",
        )
        val lengths = methodCodeLengths(instrumented)

        // RATCHET, not a ceiling. Lower this whenever an extraction frees space; never raise it to fit a
        // change. It was 61,535 while the method measured 61,518 — SEVENTEEN bytes — so the guard had
        // stopped guarding and simply blocked everything, at test time, with no hint that the method had
        // been full since before whoever hit it arrived. Lifting the skin/SpO2/wrist-off reads out brought
        // it to 54,087, and this number banks that rather than leaving 7,400 bytes to be spent silently
        // the same way.
        //
        // The margin is deliberate and roughly 1.9 K: enough for an ordinary change (the pass-1 sliding
        // read windows need about 825), small enough that a large regression fails here rather than at the
        // JVM's 64 KB wall. If a change genuinely needs more, extract — this file already shows the shape
        // twice over.
        assertExactMethodBudget(lengths, "analyzeRecentOnCpu", 56_000)
        // Untouched: 6,415 against 12,000. Slack, but it has not been creeping, and ratcheting a method
        // nobody is pressing against would be tightening for its own sake.
        assertExactMethodBudget(lengths, "persistFitnessVitalityAndSteps", 12_000)
    }

    @Test
    fun extractedBlockRemainsSerialAndAtTheRequiredCallSite() {
        val sourcePath = locateIntelligenceEngineSource()
        val source = String(Files.readAllBytes(sourcePath), StandardCharsets.UTF_8)
        val code = maskCommentsAndLiterals(source)
        val helperName = "persistFitnessVitalityAndSteps"

        val declaration = Regex("""private\s+suspend\s+fun\s+($helperName)\s*\(""")
            .findAll(code)
            .toList()
        assertEquals("Expected exactly one private suspend $helperName helper in $sourcePath", 1, declaration.size)

        val nameOffsetInDeclaration = declaration.single().groups[1]!!.range.first
        val nameUses = Regex("""\b$helperName\s*\(""").findAll(code).map { it.range.first }.toList()
        val calls = nameUses.filter { it != nameOffsetInDeclaration }
        assertEquals("Expected exactly one call to $helperName", 1, calls.size)

        val replace = requireExactlyOne(code, Regex("""\brepo\s*\.\s*replaceComputedScoreWindow\s*\("""))
        val dismissed = requireExactlyOne(code, Regex("""\bDismissedSleepGuard\s*\.\s*keeping\s*\("""))
        assertTrue("$helperName must run after replaceComputedScoreWindow", calls.single() > replace)
        assertTrue("$helperName must run before DismissedSleepGuard.keeping", calls.single() < dismissed)

        val bodyOpen = code.indexOf('{', declaration.single().range.last + 1)
        assertTrue("Missing body for $helperName", bodyOpen >= 0)
        val bodyClose = matchingBrace(code, bodyOpen)
        val helperCode = code.substring(bodyOpen, bodyClose + 1)
        val helperRaw = source.substring(bodyOpen, bodyClose + 1)

        val orderedOperations = listOf(
            "fitnessAgeRows" to Regex("""\bfitnessAgeRows\s*\("""),
            "fitness diagnostic" to Regex("""\bdiag\s*\("""),
            "Fitness upsert" to Regex(
                """\brepo\s*\.\s*upsertMetricSeriesWithProvenance\s*\(\s*rows\s*=\s*faPts\b""",
            ),
            "Vitality compute" to Regex("""\bVitalityEngine\s*\.\s*compute\s*\("""),
            "Vitality upsert" to Regex("""\brepo\s*\.\s*upsertMetricSeries\s*\(\s*listOf\s*\("""),
            "Apple Health read" to Regex("""\brepo\s*\.\s*appleDaily\s*\(\s*WhoopRepository\s*\.\s*APPLE_HEALTH_SOURCE\b"""),
            "Health Connect read" to Regex("""\brepo\s*\.\s*appleDaily\s*\(\s*WhoopRepository\s*\.\s*HEALTH_CONNECT_SOURCE\b"""),
            "gravity samples" to Regex("""\brepo\s*\.\s*gravitySamples\s*\("""),
            "calibration" to Regex("""\bStepsEstimateEngine\s*\.\s*calibrate\s*\("""),
            "step upsert" to Regex("""\brepo\s*\.\s*upsertMetricSeries\s*\(\s*estRows\s*\)"""),
            "calibration persistence" to Regex("""\bpersistStepsCalibration\s*\("""),
            "calibration trace" to Regex("""\bStepsEstimateEngineTrace\s*\.\s*calibrationTrace\s*\("""),
        )
        var previous = -1
        for ((label, pattern) in orderedOperations) {
            val positions = pattern.findAll(helperCode).map { it.range.first }.toList()
            assertEquals("Expected exactly one $label operation in $helperName", 1, positions.size)
            assertTrue("$label moved out of the required serial order", positions.single() > previous)
            previous = positions.single()
        }
        // Find the call token in literal/comment-masked code first, so commented-out code or a string
        // containing `stepsTraceSink("stepsEst day=...`) cannot satisfy the guard. Then inspect only the
        // corresponding raw first argument, whose literal contents were deliberately masked above.
        val stepsEstimateTraces = Regex("""\bstepsTraceSink\s*\(""")
            .findAll(helperCode)
            .map { it.range.first to helperRaw.substring(it.range.last + 1) }
            .filter { (_, rawArguments) -> Regex("""^\s*"stepsEst day=""").containsMatchIn(rawArguments) }
            .map { (position, _) -> position }
            .toList()
        assertEquals("Expected exactly one stepsEst trace", 1, stepsEstimateTraces.size)
        assertTrue("stepsEst trace must remain after calibrationTrace", stepsEstimateTraces.single() > previous)

        val forbidden = listOf("withContext", "async", "launch", "coroutineScope", "supervisorScope")
        for (name in forbidden) {
            assertTrue(
                "$helperName must remain serial: forbidden $name call found",
                !Regex("""\b$name\s*\(""").containsMatchIn(helperCode),
            )
        }
        assertTrue(
            "$helperName must not catch and suppress persistence failures",
            !Regex("""\bcatch\s*\(""").containsMatchIn(helperCode),
        )
    }

    @Test
    fun extractedBlockRetainsRuntimeReadCallbackTraceAndFailureOrder() {
        val events = arrayListOf<String>()
        val repo = recordingRepository(events)

        invokeExtractedBlock(
            repo = repo,
            diag = { events.add("diag") },
            persistCalibration = { events.add("calibration") },
            trace = { events.add("trace") },
        )

        assertEquals("diag", events.first())
        assertEquals("apple:apple-health", events[1])
        assertEquals("apple:health-connect", events[2])
        assertEquals(60, events.count { it == "gravity" })
        assertEquals("calibration", events[63])
        assertTrue("calibration trace must follow persistence callback", events.drop(64).all { it == "trace" })
        assertTrue("manual calibration must emit a trace", events.size > 64)

        val sentinel = IllegalStateException("apple read failed")
        val failureEvents = arrayListOf<String>()
        val failingRepo = recordingRepository(failureEvents, appleFailure = sentinel)
        try {
            invokeExtractedBlock(
                repo = failingRepo,
                diag = { failureEvents.add("diag") },
                persistCalibration = { failureEvents.add("calibration") },
                trace = { failureEvents.add("trace") },
            )
            fail("Repository failure must propagate out of the extracted suspend helper")
        } catch (failure: InvocationTargetException) {
            assertSame(sentinel, failure.cause)
        }
        assertEquals(listOf("diag", "apple:apple-health"), failureEvents)
    }

    private fun recordingRepository(
        events: MutableList<String>,
        appleFailure: RuntimeException? = null,
    ): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, arguments ->
            when (method.name) {
                "appleDaily" -> {
                    events.add("apple:${arguments!![0]}")
                    if (appleFailure != null) throw appleFailure
                    emptyList<Any>()
                }
                "gravitySamples" -> {
                    events.add("gravity")
                    emptyList<Any>()
                }
                else -> throw UnsupportedOperationException("Extracted block must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun invokeExtractedBlock(
        repo: WhoopRepository,
        diag: (String) -> Unit,
        persistCalibration: (StepsEstimateEngine.Calibration) -> Unit,
        trace: (String) -> Unit,
    ) {
        val method = IntelligenceEngine::class.java.declaredMethods.single {
            it.name == "persistFitnessVitalityAndSteps"
        }
        method.isAccessible = true
        val continuation = object : Continuation<Unit> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(result: Result<Unit>) = result.getOrThrow()
        }
        val result = method.invoke(
            IntelligenceEngine,
            repo,
            emptyList<DailyMetric>(),
            emptyList<DailyMetric>(),
            UserProfile(),
            "strap-noop",
            "1970-01-01",
            diag,
            0L,
            0L,
            null,
            listOf("strap" to 0),
            "strap",
            1.5,
            persistCalibration,
            trace,
            continuation,
        )
        assertEquals(Unit, result)
    }

    private fun assertExactMethodBudget(lengths: Map<String, List<Int>>, name: String, budget: Int) {
        val matches = lengths[name]
        assertNotNull("Instrumented class has no method named $name", matches)
        assertEquals("Expected one exact JVM method named $name", 1, matches!!.size)
        println("$name instrumented Code length=${matches.single()} budget=$budget margin=${65_535 - matches.single()}")
        assertTrue(
            "$name instrumented Code length ${matches.single()} exceeds the $budget-byte budget",
            matches.single() <= budget,
        )
    }

    private fun locateIntelligenceEngineSource(): Path {
        val suffixes = listOf(
            Path.of("app/src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
            Path.of("src/main/java/com/noop/analytics/IntelligenceEngine.kt"),
        )
        val matches = LinkedHashSet<Path>()
        var directory: Path? = Path.of(System.getProperty("user.dir")).toAbsolutePath().normalize()
        while (directory != null) {
            for (suffix in suffixes) {
                val candidate = directory.resolve(suffix).normalize()
                if (Files.isRegularFile(candidate)) matches.add(candidate.toRealPath())
            }
            directory = directory.parent
        }
        assertEquals(
            "Could not locate IntelligenceEngine.kt fail-closed from user.dir=${System.getProperty("user.dir")}: $matches",
            1,
            matches.size,
        )
        return matches.single()
    }

    private fun requireExactlyOne(text: String, pattern: Regex): Int {
        val matches = pattern.findAll(text).toList()
        assertEquals("Expected exactly one source match for ${pattern.pattern}", 1, matches.size)
        return matches.single().range.first
    }

    /** Masks comments, chars, and strings with spaces while preserving offsets and line endings. */
    private fun maskCommentsAndLiterals(source: String): String {
        val out = source.toCharArray()
        var i = 0
        var blockDepth = 0
        while (i < source.length) {
            if (blockDepth > 0) {
                when {
                    source.startsWith("/*", i) -> {
                        blank(out, i, 2)
                        blockDepth++
                        i += 2
                    }
                    source.startsWith("*/", i) -> {
                        blank(out, i, 2)
                        blockDepth--
                        i += 2
                    }
                    else -> {
                        blank(out, i, 1)
                        i++
                    }
                }
                continue
            }
            when {
                source.startsWith("//", i) -> {
                    while (i < source.length && source[i] != '\n' && source[i] != '\r') {
                        out[i++] = ' '
                    }
                }
                source.startsWith("/*", i) -> {
                    blank(out, i, 2)
                    blockDepth = 1
                    i += 2
                }
                source.startsWith("\"\"\"", i) -> {
                    blank(out, i, 3)
                    i += 3
                    while (i < source.length && !source.startsWith("\"\"\"", i)) {
                        blank(out, i, 1)
                        i++
                    }
                    check(i < source.length) { "Unterminated triple-quoted string in IntelligenceEngine.kt" }
                    blank(out, i, 3)
                    i += 3
                }
                source[i] == '"' || source[i] == '\'' -> {
                    val quote = source[i]
                    out[i++] = ' '
                    var escaped = false
                    var closed = false
                    while (i < source.length) {
                        val char = source[i]
                        if (char == '\n' || char == '\r') break
                        out[i++] = ' '
                        if (!escaped && char == quote) {
                            closed = true
                            break
                        }
                        escaped = !escaped && char == '\\'
                    }
                    check(closed) { "Unterminated quoted literal in IntelligenceEngine.kt" }
                }
                else -> i++
            }
        }
        check(blockDepth == 0) { "Unterminated block comment in IntelligenceEngine.kt" }
        return String(out)
    }

    private fun blank(chars: CharArray, start: Int, count: Int) {
        for (offset in 0 until count) {
            val index = start + offset
            if (index < chars.size && chars[index] != '\n' && chars[index] != '\r') chars[index] = ' '
        }
    }

    private fun matchingBrace(code: String, opening: Int): Int {
        var depth = 0
        for (i in opening until code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return i
                }
            }
        }
        error("Unclosed helper body in IntelligenceEngine.kt")
    }

    /** Minimal strict classfile parser; reports each method's exact Code attribute code_length. */
    private fun methodCodeLengths(bytes: ByteArray): Map<String, List<Int>> {
        val input = ClassReader(bytes)
        check(input.u4() == 0xCAFEBABEL) { "Not a JVM class file" }
        input.skip(4) // minor_version, major_version
        val constantPool = arrayOfNulls<String>(input.u2())
        var index = 1
        while (index < constantPool.size) {
            when (val tag = input.u1()) {
                1 -> constantPool[index] = String(input.bytes(input.u2()), StandardCharsets.UTF_8)
                3, 4 -> input.skip(4)
                5, 6 -> {
                    input.skip(8)
                    index++
                }
                7, 8, 16, 19, 20 -> input.skip(2)
                9, 10, 11, 12, 17, 18 -> input.skip(4)
                15 -> input.skip(3)
                else -> error("Unsupported constant-pool tag $tag at index $index")
            }
            index++
        }
        input.skip(6) // access_flags, this_class, super_class
        repeat(input.u2()) { input.skip(2) }
        repeat(input.u2()) { skipMember(input) } // fields

        val result = linkedMapOf<String, MutableList<Int>>()
        repeat(input.u2()) {
            input.skip(2) // access_flags
            val name = constantPool[input.u2()] ?: error("Method name is not a UTF-8 constant")
            input.skip(2) // descriptor_index
            repeat(input.u2()) {
                val attributeName = constantPool[input.u2()] ?: error("Attribute name is not UTF-8")
                val attributeLength = input.u4Int()
                if (attributeName == "Code") {
                    val attributeEnd = input.position + attributeLength
                    input.skip(4) // max_stack, max_locals
                    val codeLength = input.u4Int()
                    check(codeLength <= 65_535) { "Invalid JVM Code length $codeLength for $name" }
                    result.getOrPut(name) { arrayListOf() }.add(codeLength)
                    input.position = attributeEnd
                } else {
                    input.skip(attributeLength)
                }
            }
        }
        return result
    }

    private fun skipMember(input: ClassReader) {
        input.skip(6) // access_flags, name_index, descriptor_index
        repeat(input.u2()) {
            input.skip(2)
            input.skip(input.u4Int())
        }
    }

    private class ClassReader(private val bytes: ByteArray) {
        var position: Int = 0
            set(value) {
                check(value in field..bytes.size) { "Invalid classfile seek from $field to $value" }
                field = value
            }

        fun u1(): Int {
            requireAvailable(1)
            return bytes[position++].toInt() and 0xff
        }

        fun u2(): Int = (u1() shl 8) or u1()

        fun u4(): Long = (u1().toLong() shl 24) or
            (u1().toLong() shl 16) or
            (u1().toLong() shl 8) or
            u1().toLong()

        fun u4Int(): Int {
            val value = u4()
            check(value <= Int.MAX_VALUE) { "Classfile length $value exceeds parser capacity" }
            return value.toInt()
        }

        fun bytes(count: Int): ByteArray {
            requireAvailable(count)
            return bytes.copyOfRange(position, position + count).also { position += count }
        }

        fun skip(count: Int) {
            check(count >= 0) { "Negative classfile skip $count" }
            requireAvailable(count)
            position += count
        }

        private fun requireAvailable(count: Int) {
            check(position + count <= bytes.size) {
                "Truncated classfile at offset $position (need $count, size ${bytes.size})"
            }
        }
    }
}
