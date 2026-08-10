package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the exact conversion factors and the formatted-string shapes for the Imperial/Metric display
 * layer (D#103). NOOP stores everything in SI; this is the only place the conversions live, so a wrong
 * factor here would silently mis-display every weight/distance/height/temperature in the app. These
 * tests exist specifically so that can't ship. Mirrors the macOS UnitFormatterTests case-for-case.
 */
class UnitFormatterTest {

    // --- Factors (the load-bearing numbers) ---

    @Test
    fun distanceFactorIsExact() {
        // 1 km = 0.621371 mi
        assertEquals(0.621371, UnitFormatter.MILES_PER_KILOMETER, 1e-12)
        assertEquals(0.621371, UnitFormatter.kmToMiles(1.0), 1e-9)
        assertEquals(6.21371, UnitFormatter.kmToMiles(10.0), 1e-9)
        assertEquals(0.0, UnitFormatter.kmToMiles(0.0), 1e-12)
    }

    @Test
    fun massFactorIsExact() {
        // 1 kg = 2.20462 lb
        assertEquals(2.20462, UnitFormatter.POUNDS_PER_KILOGRAM, 1e-12)
        assertEquals(2.20462, UnitFormatter.kgToPounds(1.0), 1e-9)
        assertEquals(165.3465, UnitFormatter.kgToPounds(75.0), 1e-4)
    }

    @Test
    fun heightFactorIsExact() {
        // 1 inch = 2.54 cm  →  1 cm = 0.393700787 in
        assertEquals(2.54, UnitFormatter.CENTIMETERS_PER_INCH, 1e-12)
        assertEquals(1.0, UnitFormatter.cmToInches(2.54), 1e-9)
        assertEquals(12.0, UnitFormatter.cmToInches(30.48), 1e-9)
    }

    @Test
    fun temperatureFactorIsExact() {
        // °F = °C * 9/5 + 32
        assertEquals(32.0, UnitFormatter.celsiusToFahrenheit(0.0), 1e-9)
        assertEquals(212.0, UnitFormatter.celsiusToFahrenheit(100.0), 1e-9)
        assertEquals(98.6, UnitFormatter.celsiusToFahrenheit(37.0), 1e-9)
        assertEquals(-40.0, UnitFormatter.celsiusToFahrenheit(-40.0), 1e-9) // the crossover
    }

    // --- Distance formatting ---

    @Test
    fun distanceFromMetersMetric() {
        assertEquals("1.2 km", UnitFormatter.distanceFromMeters(1200.0, UnitSystem.METRIC))
        assertEquals("850 m", UnitFormatter.distanceFromMeters(850.0, UnitSystem.METRIC))
    }

    @Test
    fun distanceFromMetersImperial() {
        // 5000 m = 5 km = 3.106855 mi
        assertEquals("3.1 mi", UnitFormatter.distanceFromMeters(5000.0, UnitSystem.IMPERIAL))
        // 100 m is well below a tenth of a mile → yards (100 m ≈ 109 yd)
        assertEquals("109 yd", UnitFormatter.distanceFromMeters(100.0, UnitSystem.IMPERIAL))
    }

    @Test
    fun distanceFromKilometers() {
        assertEquals("12.4 km", UnitFormatter.distanceFromKilometers(12.4, UnitSystem.METRIC))
        // 12.4 km * 0.621371 = 7.704... → "7.7 mi"
        assertEquals("7.7 mi", UnitFormatter.distanceFromKilometers(12.4, UnitSystem.IMPERIAL))
    }

    // --- Mass formatting ---

    @Test
    fun massFromKilograms() {
        assertEquals("74.5 kg", UnitFormatter.massFromKilograms(74.5, UnitSystem.METRIC))
        // 74.5 * 2.20462 = 164.24419 → "164.2 lb"
        assertEquals("164.2 lb", UnitFormatter.massFromKilograms(74.5, UnitSystem.IMPERIAL))
    }

    // --- Height formatting ---

    @Test
    fun heightFromCentimetersMetric() {
        assertEquals("178 cm", UnitFormatter.heightFromCentimeters(178.0, UnitSystem.METRIC))
    }

    @Test
    fun heightFromCentimetersImperial() {
        // 178 cm = 70.07 in = 5 ft 10 in
        assertEquals("5′ 10″", UnitFormatter.heightFromCentimeters(178.0, UnitSystem.IMPERIAL))
        // 152.4 cm = exactly 60 in = 5 ft 0 in
        assertEquals("5′ 0″", UnitFormatter.heightFromCentimeters(152.4, UnitSystem.IMPERIAL))
    }

    @Test
    fun heightRoundingCarriesInchesIntoFeet() {
        // 182.7 cm ≈ 71.93 in → rounds to 72 in, which must carry to 6 ft 0 in (never "5 ft 12 in").
        val (ft, inch) = UnitFormatter.cmToFeetInches(182.7)
        assertEquals(6, ft)
        assertEquals(0, inch)
    }

    // --- Temperature formatting ---

    @Test
    fun absoluteTemperature() {
        assertEquals("33.4 °C", UnitFormatter.temperatureFromCelsius(33.4, TemperatureUnit.CELSIUS))
        // 33.4 °C = 92.12 °F → "92.1 °F"
        assertEquals("92.1 °F", UnitFormatter.temperatureFromCelsius(33.4, TemperatureUnit.FAHRENHEIT))
    }

    @Test
    fun temperatureDeltaHasNoOffset() {
        // A +0.6 °C deviation is a 1.08 °F deviation — scale by 9/5, do NOT add 32.
        assertEquals("1.1 °F", UnitFormatter.temperatureDeltaFromCelsius(0.6, TemperatureUnit.FAHRENHEIT))
        assertEquals("0.6 °C", UnitFormatter.temperatureDeltaFromCelsius(0.6, TemperatureUnit.CELSIUS))
    }

    // --- Preference resolution ---

    @Test
    fun temperatureOverrideResolution() {
        // No explicit override → follows the length/mass system.
        assertEquals(TemperatureUnit.CELSIUS, UnitPrefs.resolveTemperature(UnitSystem.METRIC, ""))
        assertEquals(TemperatureUnit.FAHRENHEIT, UnitPrefs.resolveTemperature(UnitSystem.IMPERIAL, ""))
        assertEquals(TemperatureUnit.CELSIUS, UnitPrefs.resolveTemperature(UnitSystem.METRIC, null))
        // Explicit override wins regardless of the system.
        assertEquals(TemperatureUnit.CELSIUS, UnitPrefs.resolveTemperature(UnitSystem.IMPERIAL, "celsius"))
        assertEquals(TemperatureUnit.FAHRENHEIT, UnitPrefs.resolveTemperature(UnitSystem.METRIC, "fahrenheit"))
    }

    // --- Unit labels ---

    @Test
    fun unitLabels() {
        assertEquals("km", UnitFormatter.distanceUnit(UnitSystem.METRIC))
        assertEquals("mi", UnitFormatter.distanceUnit(UnitSystem.IMPERIAL))
        assertEquals("kg", UnitFormatter.massUnit(UnitSystem.METRIC))
        assertEquals("lb", UnitFormatter.massUnit(UnitSystem.IMPERIAL))
        assertEquals("°C", UnitFormatter.temperatureUnit(TemperatureUnit.CELSIUS))
        assertEquals("°F", UnitFormatter.temperatureUnit(TemperatureUnit.FAHRENHEIT))
    }

    // --- Enum raw-value round-trips (the SharedPreferences/@AppStorage contract) ---

    @Test
    fun enumRawValuesAreStable() {
        assertEquals(UnitSystem.METRIC, UnitSystem.fromRaw("metric"))
        assertEquals(UnitSystem.IMPERIAL, UnitSystem.fromRaw("imperial"))
        assertEquals(UnitSystem.METRIC, UnitSystem.fromRaw(null)) // default
        assertEquals(TemperatureUnit.CELSIUS, TemperatureUnit.fromRaw("celsius"))
        assertEquals(TemperatureUnit.FAHRENHEIT, TemperatureUnit.fromRaw("fahrenheit"))
        assertEquals(null, TemperatureUnit.fromRaw(""))
    }

    // --- Pace (#1195): the live-workout distance/pace surface. Must byte-match the Swift formatter. ---

    @Test
    fun paceFormatsAndConvertsPerUnit() {
        // 5:00 /km (300 s/km) stays 5:00 /km in metric.
        assertEquals("5:00 /km", UnitFormatter.paceFromSecPerKm(300.0, UnitSystem.METRIC))
        // Same pace in imperial is per MILE: 300 / 0.621371 = 482.8 s ≈ 8:03 /mi.
        assertEquals("8:03 /mi", UnitFormatter.paceFromSecPerKm(300.0, UnitSystem.IMPERIAL))
        // Seconds pad to two digits.
        assertEquals("4:05 /km", UnitFormatter.paceFromSecPerKm(245.0, UnitSystem.METRIC))
    }

    @Test
    fun paceIsDashWhenUndefined() {
        // Null (no distance yet) and non-positive are both "—" — never "0:00", which would read as instant.
        assertEquals("—", UnitFormatter.paceFromSecPerKm(null, UnitSystem.METRIC))
        assertEquals("—", UnitFormatter.paceFromSecPerKm(0.0, UnitSystem.IMPERIAL))
        assertEquals("—", UnitFormatter.paceFromSecPerKm(-1.0, UnitSystem.METRIC))
    }
}
