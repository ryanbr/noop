package com.noop.analytics

/*
 * MarkerCatalog.kt — Kotlin twin of StrandImport/MarkerCatalog.swift: the small
 * dictionary of common, NON-DIAGNOSTIC marker definitions for the Health Records
 * "Lab Book" pillar (spec 2026-06-19-v5-health-records-design.md).
 *
 * Per the spec §"New" and §"Non-clinical / legal framing":
 *   - Ships NO reference-range tables. `referenceTextHint` is a neutral placeholder
 *     prompting the user to copy the range FROM THEIR OWN REPORT — NOOP never defines,
 *     computes, or asserts a normal range.
 *   - `higherIsBetter` is intentionally null for every entry: NOOP makes no value
 *     judgement about a marker's direction.
 *   - The catalog is NOT a gate: a user can always add a custom marker (free name +
 *     unit), so the store is never limited by this dictionary.
 *
 * Pure data — no DB, no Android deps. The entries (keys, names, categories, units,
 * decimals) are byte-identical to the Swift builtIn list so a marker logged on one
 * platform reads the same on the other.
 */

/** The category a marker belongs to — value-for-value with the Swift `LabMarkerCategory`
 *  raw strings (the value stored in the `labMarker.category` column). */
enum class LabMarkerCategory(val raw: String, val displayName: String) {
    BLOOD_PANEL("bloodPanel", "Blood panel"),
    BLOOD_PRESSURE("bloodPressure", "Blood pressure"),
    BODY_MEASUREMENT("bodyMeasurement", "Body"),
    IMAGING("imaging", "Imaging"),
    APPOINTMENT_NOTE("appointmentNote", "Notes"),
    OTHER("other", "Custom");

    companion object {
        fun fromRaw(raw: String): LabMarkerCategory =
            entries.firstOrNull { it.raw == raw } ?: OTHER
    }
}

/** A non-diagnostic marker definition: how to label and format one marker. Carries NO
 *  clinical thresholds. Mirrors the Swift `MarkerDefinition`. */
data class MarkerDefinition(
    /** Stable key stored on every marker row (e.g. "ldl", "bp_systolic"). */
    val key: String,
    val displayName: String,
    val category: LabMarkerCategory,
    /** Canonical unit prefilled in the editor (e.g. "mmol/L", "mmHg"). */
    val canonicalUnit: String,
    /** How many decimals to show for this marker's values. */
    val decimals: Int,
    /** Neutral placeholder prompting the user to copy the range from their own report.
     *  NOT a shipped reference range. null where a range makes no sense. */
    val referenceTextHint: String? = null,
    /** Direction hint — ALWAYS null (NOOP makes no value judgement). */
    val higherIsBetter: Boolean? = null,
)

/** The built-in, non-diagnostic marker dictionary. Extensible at runtime via [custom]. */
object MarkerCatalog {

    /** Neutral hint shown in the range field — the user copies their own report's range; NOOP ships none. */
    private const val FROM_REPORT = "From your own report (optional)"

    /** ~30 common markers across the categories. Order is the suggested picker order.
     *  Byte-identical to the Swift builtIn list. */
    val builtIn: List<MarkerDefinition> = listOf(
        // Lipids (blood panel)
        MarkerDefinition("total_cholesterol", "Total cholesterol", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 2, FROM_REPORT),
        MarkerDefinition("ldl", "LDL cholesterol", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 2, FROM_REPORT),
        MarkerDefinition("hdl", "HDL cholesterol", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 2, FROM_REPORT),
        MarkerDefinition("triglycerides", "Triglycerides", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 2, FROM_REPORT),
        // Glucose
        MarkerDefinition("fasting_glucose", "Fasting glucose", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 1, FROM_REPORT),
        MarkerDefinition("hba1c", "HbA1c", LabMarkerCategory.BLOOD_PANEL, "mmol/mol", 0, FROM_REPORT),
        // Iron studies
        MarkerDefinition("ferritin", "Ferritin", LabMarkerCategory.BLOOD_PANEL, "µg/L", 0, FROM_REPORT),
        MarkerDefinition("iron", "Serum iron", LabMarkerCategory.BLOOD_PANEL, "µmol/L", 1, FROM_REPORT),
        MarkerDefinition("transferrin_saturation", "Transferrin saturation", LabMarkerCategory.BLOOD_PANEL, "%", 0, FROM_REPORT),
        MarkerDefinition("haemoglobin", "Haemoglobin", LabMarkerCategory.BLOOD_PANEL, "g/L", 0, FROM_REPORT),
        // Vitamins
        MarkerDefinition("vitamin_d", "Vitamin D", LabMarkerCategory.BLOOD_PANEL, "nmol/L", 0, FROM_REPORT),
        MarkerDefinition("vitamin_b12", "Vitamin B12", LabMarkerCategory.BLOOD_PANEL, "ng/L", 0, FROM_REPORT),
        MarkerDefinition("folate", "Folate", LabMarkerCategory.BLOOD_PANEL, "µg/L", 1, FROM_REPORT),
        // Thyroid
        MarkerDefinition("tsh", "TSH", LabMarkerCategory.BLOOD_PANEL, "mIU/L", 2, FROM_REPORT),
        MarkerDefinition("free_t4", "Free T4", LabMarkerCategory.BLOOD_PANEL, "pmol/L", 1, FROM_REPORT),
        // Inflammation
        MarkerDefinition("crp", "C-reactive protein (CRP)", LabMarkerCategory.BLOOD_PANEL, "mg/L", 1, FROM_REPORT),
        // Kidney
        MarkerDefinition("egfr", "eGFR", LabMarkerCategory.BLOOD_PANEL, "mL/min/1.73m²", 0, FROM_REPORT),
        MarkerDefinition("creatinine", "Creatinine", LabMarkerCategory.BLOOD_PANEL, "µmol/L", 0, FROM_REPORT),
        // Liver
        MarkerDefinition("alt", "ALT", LabMarkerCategory.BLOOD_PANEL, "U/L", 0, FROM_REPORT),
        MarkerDefinition("ast", "AST", LabMarkerCategory.BLOOD_PANEL, "U/L", 0, FROM_REPORT),
        MarkerDefinition("ggt", "GGT", LabMarkerCategory.BLOOD_PANEL, "U/L", 0, FROM_REPORT),
        // Electrolytes
        MarkerDefinition("sodium", "Sodium", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 0, FROM_REPORT),
        MarkerDefinition("potassium", "Potassium", LabMarkerCategory.BLOOD_PANEL, "mmol/L", 1, FROM_REPORT),
        // Blood pressure (the paired marker — see LabBookProjection.BP_SYSTOLIC_KEY / BP_DIASTOLIC_KEY)
        MarkerDefinition("bp_systolic", "Blood pressure (systolic)", LabMarkerCategory.BLOOD_PRESSURE, "mmHg", 0, FROM_REPORT),
        MarkerDefinition("bp_diastolic", "Blood pressure (diastolic)", LabMarkerCategory.BLOOD_PRESSURE, "mmHg", 0, FROM_REPORT),
        MarkerDefinition("resting_pulse", "Resting pulse", LabMarkerCategory.BLOOD_PRESSURE, "bpm", 0, FROM_REPORT),
        // Body measurements
        MarkerDefinition("weight", "Weight", LabMarkerCategory.BODY_MEASUREMENT, "kg", 1),
        MarkerDefinition("body_fat", "Body fat", LabMarkerCategory.BODY_MEASUREMENT, "%", 1),
        MarkerDefinition("waist", "Waist circumference", LabMarkerCategory.BODY_MEASUREMENT, "cm", 1),
        MarkerDefinition("height", "Height", LabMarkerCategory.BODY_MEASUREMENT, "cm", 1),
    )

    private val byKey: Map<String, MarkerDefinition> = builtIn.associateBy { it.key }

    /** The built-in definition for [key], or null if it's a custom marker. */
    fun definition(key: String): MarkerDefinition? = byKey[key]

    /** Build a definition for a user-added custom marker (category Other, no range, no judgement). */
    fun custom(key: String, displayName: String, unit: String, decimals: Int = 1): MarkerDefinition =
        MarkerDefinition(
            key = key,
            displayName = displayName,
            category = LabMarkerCategory.OTHER,
            canonicalUnit = unit,
            decimals = decimals,
            referenceTextHint = null,
            higherIsBetter = null,
        )
}
