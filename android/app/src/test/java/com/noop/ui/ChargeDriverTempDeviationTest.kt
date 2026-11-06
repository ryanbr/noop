package com.noop.ui

import com.noop.R
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Charge breakdown's skin-temperature row follows the reader's temperature unit. It printed the
 * engine's Celsius deviation to a Fahrenheit reader. A difference converts by 9/5 with no +32 offset, from
 * the unrounded value, and is rounded once, half away from zero, so both platforms print the same digit.
 *
 * The expected strings are the verbatim stdout of the Swift twin
 * (`ChargeBreakdownFormat.skinTempDeviationFigure`) compiled standalone over these inputs, the oracle
 * AGENTS.md asks for; the matching Swift tests are in `ChargeBreakdownFormatTests`.
 */
class ChargeDriverTempDeviationTest {

    private val celsius = listOf(
        -0.0 to "+0.0",
        0.0 to "+0.0",
        -0.04 to "+0.0",
        0.04 to "+0.0",
        0.05 to "+0.1",
        -0.05 to "-0.1",
        0.15 to "+0.2",
        -0.15 to "-0.2",
        0.25 to "+0.3",
        -0.25 to "-0.3",
        0.35 to "+0.4",
        0.44 to "+0.4",
        -0.3 to "-0.3",
        0.5 to "+0.5",
        1.35 to "+1.4",
        -1.25 to "-1.3",
        2.05 to "+2.1",
        0.0277 to "+0.0",
        -0.0277 to "+0.0",
        0.0833 to "+0.1",
        -0.083 to "-0.1",
    )

    private val fahrenheit = listOf(
        -0.0 to "+0.0",
        0.0 to "+0.0",
        -0.04 to "-0.1",
        0.04 to "+0.1",
        0.05 to "+0.1",
        -0.05 to "-0.1",
        0.15 to "+0.3",
        -0.15 to "-0.3",
        0.25 to "+0.5",
        -0.25 to "-0.5",
        0.35 to "+0.6",
        0.44 to "+0.8",
        -0.3 to "-0.5",
        0.5 to "+0.9",
        1.35 to "+2.4",
        -1.25 to "-2.3",
        2.05 to "+3.7",
        0.0277 to "+0.0",
        -0.0277 to "+0.0",
        0.0833 to "+0.1",
        -0.083 to "-0.1",
    )

    @Test fun celsiusMatchesTheSwiftOracle() {
        for ((input, expected) in celsius) {
            val (res, number) = chargeDriverTempDeviation(input, fahrenheit = false, locale = Locale.US)
            assertEquals(R.string.today_driver_value_temp_deviation, res)
            assertEquals("$input °C", expected, number)
        }
    }

    @Test fun fahrenheitMatchesTheSwiftOracle() {
        for ((input, expected) in fahrenheit) {
            val (res, number) = chargeDriverTempDeviation(input, fahrenheit = true, locale = Locale.US)
            assertEquals(R.string.today_driver_value_temp_deviation_fahrenheit, res)
            assertEquals("$input °F", expected, number)
        }
    }
}
