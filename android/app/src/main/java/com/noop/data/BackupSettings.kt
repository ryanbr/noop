package com.noop.data

import android.content.Context
import com.noop.ui.HostedCardPrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import org.json.JSONObject

/**
 * The `settings.json` payload inside a `.noopbak` backup (#1000) — the Android twin of the Apple
 * `BackupSettings` in Packages/WhoopStore.
 *
 * A `.noopbak` is a ZIP whose first entry is the SQLite database. That round-trips every row, but the
 * user's profile (age / sex / weight / height / HR-max override) and display preferences live in
 * SharedPreferences (UserDefaults on Apple), so a restore onto a fresh device silently reset them —
 * the "restore doesn't bring back settings/weight/height" half of #1000. This adds a SECOND, optional
 * ZIP entry — `settings.json`, a flat JSON object — carrying exactly one WHITELISTED set of keys.
 *
 * The whitelist is the contract, defined once per platform and mirrored byte-for-byte by the Apple
 * `BackupSettings.whitelist` (same canonical key strings, same JSON kinds). Only stable, user-set,
 * non-device-specific values are allowed. NEVER add device ids, peripheral ids, tokens, sync cursors,
 * or anything anonymity-sensitive: backups get copied into cloud folders and attached to GitHub
 * issues, so this file must stay safe to share. Unknown keys in an incoming `settings.json` are
 * dropped; a backup with no `settings.json` (every pre-#1000 backup) is a DB-only restore, as before.
 *
 * [BackupSettingsCodec] is pure JSON + whitelist (plain-JVM unit-testable, no Context); the
 * SharedPreferences boundary lives in [BackupSettingsBridge] below.
 */
object BackupSettingsCodec {

    /** Canonical entry name inside the `.noopbak` ZIP. Matches the Apple exporter byte-for-byte. */
    const val ENTRY_NAME = "settings.json"

    /** The JSON kind a whitelisted key must decode to. Anything else is dropped, never guessed at. */
    enum class Kind { INT, DOUBLE, STRING }

    /**
     * THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
     * (platform-neutral) names. Mirrors the Apple `BackupSettings.whitelist` exactly.
     *
     * Profile: the body metrics that power HR zones / calories / recovery baselines, plus the manual
     * HR-max override (`profile.hrMax`, 0 = auto/Tanaka). Display: the metric/imperial system, the
     * separate temperature override ("" = match the system), and the Effort axis (#268). Deliberately
     * EXCLUDED: step calibration (per-strap, not per-person), the steps-engine fitted outputs
     * (derived), and every noop.* toggle that is device- or install-specific.
     */
    val WHITELIST: Map<String, Kind> = linkedMapOf(
        "profile.age" to Kind.INT,
        "profile.sex" to Kind.STRING,
        "profile.weightKg" to Kind.DOUBLE,
        "profile.heightCm" to Kind.DOUBLE,
        "profile.waistCm" to Kind.DOUBLE,
        "profile.hrMax" to Kind.INT,
        "profile.hrZoneThresholds" to Kind.STRING,
        "units.system" to Kind.STRING,
        "units.temperature" to Kind.STRING,
        "effort.scale" to Kind.STRING,
        // The ONE layout pref carried (#today-hosted-cards): the Trends/Sleep cards the user chose to host
        // in Today, a JSON [String] of ids. Unlike section order, this is a deliberate composition the user
        // built and expects across a restore. Its POSITION (the addedCards slot in today.sectionOrder) is
        // not carried, so on restore the set + internal order return but the section sits at its default.
        HostedCardPrefs.KEY_SELECTION to Kind.STRING,
    )

    /**
     * Encode the whitelisted subset of [values] as the flat `settings.json` object, or null when
     * nothing whitelisted is present (the exporter then writes a DB-only backup — indistinguishable
     * from a legacy one, which is exactly the right degrade).
     */
    fun encode(values: Map<String, Any?>): String? {
        val obj = JSONObject()
        for ((key, kind) in WHITELIST) {
            val coerced = coerce(values[key], kind) ?: continue
            obj.put(key, coerced)
        }
        return if (obj.length() == 0) null else obj.toString()
    }

    /**
     * Decode a `settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
     * JSON, unknown keys and wrong-typed values all degrade to "fewer keys" — never an error, because
     * a bad settings entry must not fail a restore whose DB half is fine.
     */
    fun decode(json: String): Map<String, Any> {
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return emptyMap()
        val out = LinkedHashMap<String, Any>()
        for ((key, kind) in WHITELIST) {
            if (!obj.has(key)) continue
            coerce(obj.opt(key), kind)?.let { out[key] = it }
        }
        return out
    }

    /**
     * Coerce a JSON-decoded (or caller-supplied) value to the whitelist's declared kind, or null.
     * JSON booleans are not [Number]s on the JVM, so `true` can never become age 1 (the Apple side
     * refuses NSNumber-booleans explicitly for the same reason).
     */
    private fun coerce(value: Any?, kind: Kind): Any? = when (kind) {
        Kind.STRING -> value as? String
        Kind.INT -> (value as? Number)?.toInt()
        Kind.DOUBLE -> (value as? Number)?.toDouble()
    }
}

/**
 * The SharedPreferences boundary for [BackupSettingsCodec]: snapshot this device's whitelisted
 * settings for export, and re-apply a restored payload. Kept separate from the codec so the codec
 * stays plain-JVM testable (this object needs a real Context).
 *
 * Storage mapping (canonical key → where it actually lives here):
 *  - `profile.*`  → the `noop_profile` prefs via [ProfileStore.backupSnapshot]/[ProfileStore.applyBackup]
 *                   (canonical `profile.hrMax` ↔ ProfileStore's `hr_max_override`).
 *  - `units.*` / `effort.scale` → [NoopPrefs] under the SAME literal key strings as the canonical names
 *                   (they were already kept identical to the Apple @AppStorage keys).
 */
object BackupSettingsBridge {

    /** The whitelisted, user-SET settings of this device as the `settings.json` string, or null. */
    fun snapshotJson(context: Context): String? {
        val values = LinkedHashMap<String, Any>()
        values.putAll(ProfileStore.from(context).backupSnapshot())
        val noop = NoopPrefs.of(context)
        if (noop.contains(NoopPrefs.KEY_UNIT_SYSTEM)) {
            noop.getString(NoopPrefs.KEY_UNIT_SYSTEM, null)?.let { values["units.system"] = it }
        }
        if (noop.contains(NoopPrefs.KEY_TEMPERATURE_UNIT)) {
            noop.getString(NoopPrefs.KEY_TEMPERATURE_UNIT, null)?.let { values["units.temperature"] = it }
        }
        if (noop.contains(UnitPrefs.KEY_EFFORT_SCALE)) {
            noop.getString(UnitPrefs.KEY_EFFORT_SCALE, null)?.let { values["effort.scale"] = it }
        }
        if (noop.contains(HostedCardPrefs.KEY_SELECTION)) {
            noop.getString(HostedCardPrefs.KEY_SELECTION, null)?.let { values[HostedCardPrefs.KEY_SELECTION] = it }
        }
        return BackupSettingsCodec.encode(values)
    }

    /**
     * Re-apply a restored `settings.json` to this device. The caller ([DataBackup.importFrom]) invokes
     * this only AFTER the DB swap succeeded — never on a failed or rolled-back restore. Keys absent
     * from the payload leave the device's current values alone; the profile setters clamp to their
     * normal ranges, so a hand-edited payload can't write absurd values.
     */
    fun apply(context: Context, json: String) {
        val values = BackupSettingsCodec.decode(json)
        if (values.isEmpty()) return

        ProfileStore.from(context).applyBackup(values)

        val editor = NoopPrefs.of(context).edit()
        (values["units.system"] as? String)?.let { editor.putString(NoopPrefs.KEY_UNIT_SYSTEM, it) }
        (values["units.temperature"] as? String)?.let { raw ->
            // "" is the Apple side's "match the length/mass system"; here that state is key-absent.
            if (raw.isEmpty()) editor.remove(NoopPrefs.KEY_TEMPERATURE_UNIT)
            else editor.putString(NoopPrefs.KEY_TEMPERATURE_UNIT, raw)
        }
        (values["effort.scale"] as? String)?.let { editor.putString(UnitPrefs.KEY_EFFORT_SCALE, it) }
        (values[HostedCardPrefs.KEY_SELECTION] as? String)?.let { editor.putString(HostedCardPrefs.KEY_SELECTION, it) }
        editor.apply()
    }
}
