package com.noop.analytics

// FitnessAgeEngine.kt — on-device "Fitness Age" from resting HR + activity + profile.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgeEngine.swift.
//
// INDEPENDENT implementation of published, peer-reviewed methods (NOT medical advice; a fitness
// comparison, never a "biological age"):
//   • VO₂max estimate: Nes et al. 2011 HUNT non-exercise model, WAIST-CIRCUMFERENCE variant — the
//     CONFIRMED original (Nes 2011 MSSE; coefficients reproduced verbatim in JAHA 2020 PMC7428991,
//     corroborated by CERG/NTNU). SEE ≈ 5.70 (men) / 5.14 (women). The circulating BMI-variant
//     coefficients could NOT be reliably confirmed against the original and are deliberately not used.
//   • Physical-activity index: HUNT1 PA-Q (Kurtze 2008), frequency×intensity×duration ∈ [0, 15];
//     reconstructed from NOOP's measured weekly signals.
//   • Fitness Age: invert the SAME Nes equation self-consistently — normative curve at population-
//     reference RHR and PA-index. The waist term cancels, so the headline number needs only
//     age/sex/RHR/PA, and an average-fitness person maps to their own age by construction.
object FitnessAgeEngine {

    // Nes 2011 waist-circumference coefficients (VO₂ = intercept − ageC·age + paiC·PA − wcC·waist − rhrC·RHR)
    private const val menIntercept = 100.27; private const val menAge = 0.296
    private const val menWC = 0.369; private const val menRHR = 0.155; private const val menPAI = 0.226
    private const val womenIntercept = 74.74; private const val womenAge = 0.247
    private const val womenWC = 0.259; private const val womenRHR = 0.114; private const val womenPAI = 0.198
    const val seeMen = 5.70; const val seeWomen = 5.14

    // Normative reference point — the "average peer" the Fitness Age compares against.
    const val restingHRReference = 65.0
    const val paiReference = 5.0

    /** Displayed uncertainty band (years) — a presentation constant; see the Swift file rationale. */
    const val displayBandYears = 5.0
    const val minAge = 20.0; const val maxAge = 80.0

    private fun isFemale(sex: String): Boolean = sex.lowercase() == "female"

    // (intercept, ageC, wcC, rhrC, paiC) for the user's sex.
    private fun coeffs(sex: String): DoubleArray =
        if (isFemale(sex)) doubleArrayOf(womenIntercept, womenAge, womenWC, womenRHR, womenPAI)
        else doubleArrayOf(menIntercept, menAge, menWC, menRHR, menPAI)

    /** Body-mass index from metric height/weight (used by callers; not required for Fitness Age). */
    fun bmi(weightKg: Double, heightCm: Double): Double {
        val m = heightCm / 100.0
        if (m <= 0) return 0.0
        return weightKg / (m * m)
    }

    /** Nes 2011 waist-variant VO₂max (ml/kg/min). Optional display metric — needs a waist measurement. */
    fun estimateVO2max(age: Double, sex: String, waistCm: Double, restingHR: Double, paIndex: Double): Double {
        val c = coeffs(sex)
        return c[0] - c[1] * age + c[4] * paIndex - c[2] * waistCm - c[3] * restingHR
    }

    /** Self-consistent Fitness Age (years, clamped [20,80]). The waist term cancels:
     *  FA = age + (rhrC·(RHR−RHRref) − paiC·(PAI−PAIref)) / ageC. */
    fun fitnessAge(age: Double, sex: String, restingHR: Double, paIndex: Double): Double {
        val c = coeffs(sex)
        val ageC = c[1]; val rhrC = c[3]; val paiC = c[4]
        val fa = age + (rhrC * (restingHR - restingHRReference) - paiC * (paIndex - paiReference)) / ageC
        return fa.coerceIn(minAge, maxAge)
    }

    /** Reconstruct the HUNT PA-index (0–15 = frequency×intensity×duration) from measured weekly
     *  aggregates. Bucket edges mirror the HUNT1 PA-Q response options (Kurtze 2008). */
    fun physicalActivityIndex(activeDaysPerWeek: Int, avgActiveMinutesPerDay: Double,
                              highIntensityFraction: Double): Double {
        val frequency = when {
            activeDaysPerWeek < 1 -> 0.0
            activeDaysPerWeek == 1 -> 0.5
            activeDaysPerWeek == 2 -> 1.0
            activeDaysPerWeek <= 4 -> 2.5
            else -> 5.0
        }
        val intensity = when {
            highIntensityFraction < 0.15 -> 1.0
            highIntensityFraction < 0.5 -> 2.0
            else -> 3.0
        }
        val duration = when {
            avgActiveMinutesPerDay < 15 -> 0.10
            avgActiveMinutesPerDay < 30 -> 0.38
            avgActiveMinutesPerDay < 60 -> 0.75
            else -> 1.0
        }
        if (frequency == 0.0) return 0.0
        return frequency * intensity * duration
    }

    /** PA-index (0–15) from NOOP's measured weekly load — the UNIVERSAL path the orchestrator uses
     *  (strain is computed from HR on any device; zone minutes only exist for CSV-importers). `strain`
     *  already integrates intensity × duration, so map mean active-day strain to the HUNT
     *  intensity×duration product (0–3) and multiply by the frequency factor (no double-counting).
     *  Reference peer (≈4 active days, mean strain ≈60) → PA-index ≈ 5. */
    fun physicalActivityIndexFromStrain(activeDaysPerWeek: Int, meanActiveStrain: Double): Double {
        val frequency = when {
            activeDaysPerWeek < 1 -> 0.0
            activeDaysPerWeek == 1 -> 0.5
            activeDaysPerWeek == 2 -> 1.0
            activeDaysPerWeek <= 4 -> 2.5
            else -> 5.0
        }
        if (frequency == 0.0) return 0.0
        val intensityDuration = (meanActiveStrain / 30.0).coerceIn(0.0, 3.0)
        return frequency * intensityDuration
    }

    /** Full Fitness Age. Returns null only if RHR or age is missing. [vo2max] is filled only when a
     *  waist measurement is supplied; callers gate data-coverage separately. */
    fun compute(age: Double, sex: String, restingHR: Double, paIndex: Double,
                waistCm: Double? = null, lowerConfidence: Boolean = false): FitnessAgeResult? {
        if (age <= 0 || restingHR <= 0) return null
        val fa = fitnessAge(age, sex, restingHR, paIndex)
        val vo2 = if (waistCm != null && waistCm > 0)
            estimateVO2max(age, sex, waistCm, restingHR, paIndex) else null
        val nb = sex.lowercase() != "male" && sex.lowercase() != "female"
        return FitnessAgeResult(
            vo2max = vo2, fitnessAge = fa, chronoAge = age, deltaYears = age - fa,
            bandYears = displayBandYears, lowerConfidence = lowerConfidence || nb)
    }

    // ── Readiness checklist (transparency: which inputs we have, grouped by what each unlocks) ──
    const val minCoverageDays = 4
    const val goodCoverageDays = 6

    /** Nights of resting-HR still needed before the headline can compute AT ALL — the countdown the
     *  not-ready card shows ("N more nights of wear…"). 0 once [minCoverageDays] is met. Assumes continued
     *  nightly wear. Shared with the iOS engine so both platforms show the same number. */
    fun nightsUntilReady(rhrDays: Int): Int = maxOf(0, minCoverageDays - rhrDays)

    private fun coverageStatus(days: Int, floor: Int): FitnessReadinessStatus = when {
        days >= goodCoverageDays -> FitnessReadinessStatus.SATISFIED
        days >= floor || days > 0 -> FitnessReadinessStatus.PARTIAL
        else -> FitnessReadinessStatus.MISSING
    }

    /** Build the readiness checklist + overall confidence. Weight/height/waist sit under the VO₂max
     *  role — they don't move the headline age (body term cancels). */
    fun assessReadiness(hasAge: Boolean, hasSex: Boolean, rhrDays: Int, activityDays: Int,
                        hasHeightWeight: Boolean, hasWaist: Boolean): FitnessAgeReadiness {
        val items = listOf(
            FitnessReadinessItem("age", "Your age",
                if (hasAge) FitnessReadinessStatus.SATISFIED else FitnessReadinessStatus.MISSING,
                required = true, role = FitnessReadinessRole.DRIVES_AGE,
                detail = if (hasAge) "Set" else "Add it in Settings"),
            FitnessReadinessItem("sex", "Biological sex",
                if (hasSex) FitnessReadinessStatus.SATISFIED else FitnessReadinessStatus.MISSING,
                required = true, role = FitnessReadinessRole.DRIVES_AGE,
                detail = if (hasSex) "Set" else "Add it in Settings"),
            FitnessReadinessItem("rhr", "Resting heart rate",
                coverageStatus(rhrDays, minCoverageDays), required = true,
                role = FitnessReadinessRole.DRIVES_AGE, detail = "$rhrDays of last 7 nights"),
            FitnessReadinessItem("activity", "Recent activity",
                coverageStatus(activityDays, minCoverageDays), required = false,
                role = FitnessReadinessRole.DRIVES_AGE, detail = "$activityDays of last 7 days"),
            FitnessReadinessItem("bodyMetrics", "Height & weight",
                if (hasHeightWeight) FitnessReadinessStatus.SATISFIED else FitnessReadinessStatus.MISSING,
                required = false, role = FitnessReadinessRole.UNLOCKS_VO2MAX,
                // Height/weight feed calories/BMI, not the VO₂max estimate (Nes uses waist; the Uth
                // fallback uses HR only). So neutral "Set" — never implying they gate or sharpen VO₂max.
                detail = if (hasHeightWeight) "Set" else "Add it in Settings"),
            FitnessReadinessItem("waist", "Waist (optional)",
                if (hasWaist) FitnessReadinessStatus.SATISFIED else FitnessReadinessStatus.MISSING,
                required = false, role = FitnessReadinessRole.UNLOCKS_VO2MAX,
                detail = if (hasWaist) "Sharpens VO₂max" else "Optional - sharpens VO₂max"),
        )
        val confidence = when {
            !hasAge || !hasSex || rhrDays < minCoverageDays -> FitnessAgeConfidence.NOT_READY
            rhrDays >= goodCoverageDays && activityDays >= goodCoverageDays -> FitnessAgeConfidence.READY
            else -> FitnessAgeConfidence.ESTIMATE
        }
        return FitnessAgeReadiness(items, confidence)
    }
}

enum class FitnessReadinessStatus { SATISFIED, PARTIAL, MISSING }
enum class FitnessReadinessRole { DRIVES_AGE, UNLOCKS_VO2MAX }
enum class FitnessAgeConfidence { READY, ESTIMATE, NOT_READY }

data class FitnessReadinessItem(
    val key: String,
    val label: String,
    val status: FitnessReadinessStatus,
    val required: Boolean,
    val role: FitnessReadinessRole,
    val detail: String,
)

data class FitnessAgeReadiness(
    val items: List<FitnessReadinessItem>,
    val confidence: FitnessAgeConfidence,
) {
    val canCompute: Boolean get() = confidence != FitnessAgeConfidence.NOT_READY
}

/** A computed Fitness Age plus the inputs needed to present it honestly. [vo2max] is optional. */
data class FitnessAgeResult(
    val vo2max: Double?,
    val fitnessAge: Double,
    val chronoAge: Double,
    val deltaYears: Double,
    val bandYears: Double,
    val lowerConfidence: Boolean,
)
