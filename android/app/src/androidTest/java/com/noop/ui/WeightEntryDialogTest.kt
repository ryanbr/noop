package com.noop.ui

import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.data.MetricSeriesRow
import com.noop.data.WeightHistoryStore
import java.time.LocalDate
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.R
import com.noop.data.WeightEntry
import com.noop.data.WeightHistory
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Isolated form tests: synthetic values only, no strap or application database needed. */
@RunWith(AndroidJUnit4::class)
class WeightEntryDialogTest {
    @get:Rule val compose = createComposeRule()

    private fun show(system: UnitSystem = UnitSystem.METRIC, entry: WeightEntry? = null,
                     busy: Boolean = false, onSave: (String, Double) -> Unit = { _, _ -> }) {
        compose.setContent {
            NoopTheme {
                WeightEntryDialog(entry, system, busy, null, onDismiss = {}, onSave = onSave)
            }
        }
    }
    private fun save() = compose.onNodeWithText(uiString(R.string.ground_truth_save))
    private fun input() = compose.onNode(hasSetTextAction())

    @Test fun acceptsDecimalCommaAndStoresKilograms() {
        var saved: Double? = null
        show(onSave = { _, kg -> saved = kg })
        input().performTextInput("85,5")
        save().assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(85.5, saved!!, 0.0) }
    }

    @Test fun poundsAreConvertedOnceOnSave() {
        var saved: Double? = null
        show(system = UnitSystem.IMPERIAL, onSave = { _, kg -> saved = kg })
        input().performTextInput("187.3927")
        save().performClick()
        compose.runOnIdle { assertEquals(85.0, saved!!, 1e-10) }
    }

    @Test fun invalidInputCannotBeSaved() {
        show()
        save().assertIsNotEnabled()
        for (value in listOf("0", "-1", "NaN", "1001", "85,5.2")) {
            input().performTextReplacement(value)
            save().assertIsNotEnabled()
        }
        input().performTextReplacement("85.5")
        save().assertIsEnabled()
    }

    @Test fun unchangedImperialEditKeepsOriginalPrecisionAndDate() {
        val original = WeightEntry("2026-09-20", 85.123456789, WeightHistory.MANUAL_SOURCE)
        var saved: Pair<String, Double>? = null
        show(UnitSystem.IMPERIAL, original, onSave = { day, kg -> saved = day to kg })
        save().performClick()
        compose.runOnIdle { assertEquals(original.day to original.kilograms, saved) }
    }

    @Test fun historyRendersAndDeletingManualRevealsImport() {
        val rows = ConcurrentHashMap<Triple<String, String, String>, MetricSeriesRow>()
        val today = LocalDate.now().toString()
        fun put(row: MetricSeriesRow) { rows[Triple(row.deviceId, row.day, row.key)] = row }
        for (i in 0..12) {
            val day = LocalDate.now().minusDays((12 - i).toLong() * 3).toString()
            put(MetricSeriesRow("health-connect", day, "weight", 86.0 - i * 0.15))
        }
        put(MetricSeriesRow(WeightHistory.MANUAL_SOURCE, today, "weight", 84.0))
        val store = WeightHistoryStore(
            { entries -> entries.forEach(::put) },
            { source, key, from, to -> rows.values.filter { it.deviceId == source && it.key == key && it.day in from..to } },
            { source, day, key -> rows.remove(Triple(source, day, key)); Unit },
        )
        compose.setContent { NoopTheme { WeightHistoryContent(store) } }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(uiString(R.string.weight_manual)).fetchSemanticsNodes().isNotEmpty()
        }
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)!!
        File(directory, "weight-history.png").outputStream().use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        compose.onNodeWithContentDescription(uiString(R.string.workout_action_delete)).performClick()
        compose.onNodeWithText(uiString(R.string.workout_action_delete)).performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(uiString(R.string.weight_manual)).fetchSemanticsNodes().isEmpty()
        }
        compose.runOnIdle {
            assertEquals(false, rows.containsKey(Triple(WeightHistory.MANUAL_SOURCE, today, "weight")))
            assertEquals(true, rows.containsKey(Triple("health-connect", today, "weight")))
        }
    }

    @Test fun busyFormCannotSubmitTwice() {
        show(entry = WeightEntry("2026-09-20", 85.0, WeightHistory.MANUAL_SOURCE), busy = true)
        save().assertIsNotEnabled()
        input().assertIsNotEnabled()
    }
}
