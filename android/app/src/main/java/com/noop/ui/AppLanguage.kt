package com.noop.ui

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.LocaleList
import java.util.Locale

/**
 * App-owned UI language. Units and time zone remain independent, while locale-sensitive display
 * formatting follows this selection through [Locale.setDefault]. Adding a language here therefore
 * requires auditing default-locale parsers and formatters, especially persistent day keys: storage
 * formats must pin their locale and chronology before supporting different numeral or calendar systems.
 */
enum class AppLanguage(val storageValue: String?, val autonym: String) {
    SYSTEM(null, ""),
    ENGLISH("en", "English"),
    GERMAN("de", "Deutsch"),
    SPANISH("es", "Español"),
    FRENCH("fr", "Français"),
    PORTUGUESE("pt-PT", "Português"),
    POLISH("pl", "Polski"),
    CHINESE("zh", "中文");

    companion object {
        fun fromStorage(raw: String?): AppLanguage =
            entries.firstOrNull { it.storageValue == raw } ?: SYSTEM
    }
}

/**
 * Process-wide locale owner. Both the Application and Activity wrap their base contexts through this
 * object, which keeps composable `stringResource`, non-composable `uiString`, services, and widgets on
 * one locale. `Locale.setDefault` also keeps date/month words and locale-aware casing aligned with the
 * selected UI language instead of leaking the phone language into otherwise translated copy.
 */
object AppLanguagePrefs {
    private const val FILE = "noop_prefs"
    private const val KEY = "noop.appLanguage"

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun selected(context: Context): AppLanguage =
        AppLanguage.fromStorage(prefs(context).getString(KEY, null))

    fun wrap(context: Context): Context {
        val language = selected(context)
        val locales = localesFor(language)
        Locale.setDefault(locales[0])
        if (language == AppLanguage.SYSTEM) return context

        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(locales)
        return context.createConfigurationContext(configuration)
    }

    fun set(context: Context, language: AppLanguage) {
        prefs(context).edit().apply {
            if (language == AppLanguage.SYSTEM) remove(KEY)
            else putString(KEY, language.storageValue)
        }.apply()

        // The Application outlives Activity.recreate(), so update its Resources too. That keeps
        // uiString() and a running foreground service from retaining the previous language.
        val appResources = context.applicationContext.resources
        val configuration = Configuration(appResources.configuration)
        val locales = localesFor(language)
        configuration.setLocales(locales)
        Locale.setDefault(locales[0])
        @Suppress("DEPRECATION")
        appResources.updateConfiguration(configuration, appResources.displayMetrics)
    }

    private fun localesFor(language: AppLanguage): LocaleList {
        if (language == AppLanguage.SYSTEM) {
            val system = Resources.getSystem().configuration.locales
            return if (system.isEmpty) LocaleList(Locale.ENGLISH) else system
        }
        return LocaleList(Locale.forLanguageTag(checkNotNull(language.storageValue)))
    }
}
