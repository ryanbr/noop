package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Keytel 2005 FITNESS-ADJUSTED calorie path: when a resting HR is known, a Uth VO2max
 * (15.3·HRmax/HRrest) is threaded into the more accurate Keytel equation that reads fitness;
 * with no resting HR the estimator falls back to the base (fitness-blind) model, byte-identical
 * to before. Expected values hand-computed from the published coefficients (see the Swift twin
 * Vo2maxCaloriesTests — the two MUST agree, that is the cross-platform contract).
 */
class Vo2maxCaloriesTest {

    @Test
    fun vo2maxForIsUthAndNullWithoutRestingHr() {
        assertEquals(58.14, Calories.vo2maxFor(hrmax = 190.0, restingHR = 50.0)!!, 1e-9)
        assertNull(Calories.vo2maxFor(hrmax = 190.0, restingHR = null))
        assertNull(Calories.vo2maxFor(hrmax = 190.0, restingHR = 0.0))
        assertNull(Calories.vo2maxFor(hrmax = 0.0, restingHR = 50.0))
    }

    @Test
    fun activeRateUsesFitnessModelWhenVo2maxKnown() {
        val r = Calories.activeKcalPerS(Calories.male, hr = 150.0, hrmax = 190.0, weightKg = 80.0, age = 30.0, vo2max = 58.14)
        assertEquals(0.248825127469726, r, 1e-12)
    }

    @Test
    fun activeRateFallsBackToBaseWhenNoVo2max() {
        val base = Calories.activeKcalPerS(Calories.male, hr = 150.0, hrmax = 190.0, weightKg = 80.0, age = 30.0, vo2max = null)
        assertEquals(0.24495339388145318, base, 1e-12)
        // The whole point: the fitness anchor MOVES the number (here it is higher).
        val fit = Calories.activeKcalPerS(Calories.male, hr = 150.0, hrmax = 190.0, weightKg = 80.0, age = 30.0, vo2max = 58.14)
        assertTrue(fit != base)
    }

    @Test
    fun femaleAndNonbinaryFitnessCoeffs() {
        assertEquals(0.18585803059273417,
            Calories.activeKcalPerS(Calories.female, hr = 150.0, hrmax = 190.0, weightKg = 80.0, age = 30.0, vo2max = 58.14), 1e-12)
        assertEquals(0.2173415790312301,
            Calories.activeKcalPerS(Calories.nonbinary, hr = 150.0, hrmax = 190.0, weightKg = 80.0, age = 30.0, vo2max = 58.14), 1e-12)
    }

    @Test
    fun caloriesActiveAndRestingMale_matchesSwiftGolden() {
        // Twin of Swift WorkoutDetectorTests.testCaloriesActiveAndRestingMale (which had NO Kotlin
        // equivalent — this closes that gap). 600 s @150 bpm, male 80 kg / 30 y, hrmax 190, RHR 60 →
        // Uth VO2max 48.45 → fitness model 58.5503 kJ/min × 600 / 251.04 = 139.9386 kcal.
        val hr = (0 until 600).map { com.noop.data.HrSample(deviceId = "test", ts = it.toLong(), bpm = 150) }
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 30.0, sex = "male")
        val kcal = Calories.estimateBoutCalories(hr, profile, hrmax = 190.0, restingHR = 60.0).first
        assertEquals(139.9386, kcal, 0.1)
    }

    @Test
    fun boutThreadsVo2maxWhenRestingHrKnown() {
        // Dense 1 Hz bout, 60 s all at HR 150 (well above the 92 bpm active gate for RHR 50 / HRmax 190),
        // male 80 kg / age 30. Every second is billed the fitness active rate → total = 60 × that rate.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 30.0, sex = "male")
        val hr = (0 until 60).map { com.noop.data.HrSample(deviceId = "test", ts = it.toLong(), bpm = 150) }
        val kcal = Calories.estimateBoutCalories(hr, profile, hrmax = 190.0, restingHR = 50.0).first
        assertEquals(0.248825127469726 * 60, kcal, 1e-9)
    }
}
