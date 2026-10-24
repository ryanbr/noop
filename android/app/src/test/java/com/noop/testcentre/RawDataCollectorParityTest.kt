package com.noop.testcentre

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Android half of the shared feature-level raw-data collector parity guard. */
class RawDataCollectorParityTest {
    private val oracleBytes: ByteArray
        get() = requireNotNull(javaClass.classLoader!!.getResourceAsStream("raw_data_collector_parity.json"))
            .use { it.readBytes() }

    private fun repoRoot(): File {
        var cursor = File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            if (File(cursor, "android/app/src/main").isDirectory) return cursor
            cursor = cursor.parentFile ?: cursor
        }
        error("repository root not found from ${System.getProperty("user.dir")}")
    }

    @Test fun androidSurfaceStillImplementsEveryDeclaredCapability() {
        val root = repoRoot()
        val source = listOf(
            "android/app/src/main/java/com/noop/testcentre/GroundTruthCollector.kt",
            "android/app/src/main/java/com/noop/testcentre/ImuSessionFileStore.kt",
            "android/app/src/main/java/com/noop/testcentre/ImuSessionFileStore.kt",
            "android/app/src/main/java/com/noop/data/WhoopDatabase.kt",
            "android/app/src/main/java/com/noop/data/Entities.kt",
            "android/app/src/main/java/com/noop/data/WhoopRepository.kt",
            "android/app/src/main/java/com/noop/ui/GroundTruthCollectorScreen.kt",
            "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt",
            "android/app/src/main/res/values/strings.xml",
        ).joinToString("\n") { File(root, it).readText() }
        val capabilities = JSONObject(oracleBytes.toString(Charsets.UTF_8)).getJSONObject("capabilities")
        for (name in capabilities.keys()) {
            val markers = capabilities.getJSONObject(name).getJSONArray("kotlin")
            for (index in 0 until markers.length()) {
                val marker = markers.getString(index)
                assertTrue("Android collector lost $name marker: $marker", source.contains(marker))
            }
        }
    }

    @Test fun androidAndAppleOracleCopiesAreByteIdentical() {
        val apple = File(repoRoot(), "StrandTests/Resources/raw_data_collector_parity.json")
        assertEquals(oracleBytes.toList(), apple.readBytes().toList())
    }

    /**
     * The raw-IMU fail-safe must not act on a live MG ECG record (#2846). Type 43 is `REALTIME_RAW_DATA`,
     * which an ECG capture also arrives under, so without the exemption a capture draws a
     * `STOP_RAW_DATA` + `TOGGLE_IMU_MODE` pair every 30 s for as long as generation runs.
     *
     * Asserted as source rather than behaviour because `stopUnexpectedRealtimeImu` is private and
     * reaching it needs a live GATT. What the clause DECIDES is covered where it can be run:
     * `Whoop5EcgTest` pins `r17FromFrame` accepting a well-formed R17 record and rejecting the wrong
     * revision, the wrong type, a bad CRC and the IMU stream type. Apple twin:
     * `testAppleExemptsALiveEcgRecordFromTheImuFailSafe`.
     *
     * Scoped to the function's own text rather than to the file, because a whole-file `contains` is not
     * the assertion this test's name makes: it passes while the clause sits in any of ten thousand other
     * lines, including a comment, which is exactly how a guard gets moved out from under its own pin.
     * The window is the signature to the fail-safe's log line, so it cannot be satisfied from outside.
     */
    @Test fun androidExemptsALiveEcgRecordFromTheImuFailSafe() {
        val source = File(repoRoot(), "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt").readText()
        val signature = source.indexOf("private fun stopUnexpectedRealtimeImu")
        assertTrue("stopUnexpectedRealtimeImu not found", signature >= 0)
        val logLine = source.indexOf("log(\"Raw IMU fail-safe:", signature)
        assertTrue("the fail-safe's log line not found after its signature", logLine > signature)
        val body = source.substring(signature, logLine)
        assertTrue(
            "the fail-safe must still key on the realtime types the exemption narrows",
            body.contains("if (type != 43 && type != 51) return"),
        )
        assertTrue(
            "the ECG exemption must sit INSIDE stopUnexpectedRealtimeImu, not merely in the file",
            body.contains("if (Whoop5Ecg.r17FromFrame(frame) != null) return"),
        )
    }
}
