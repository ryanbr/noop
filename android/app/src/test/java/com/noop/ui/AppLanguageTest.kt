package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AppLanguageTest {
    @Test
    fun unknownOrMissingStoredLanguageFallsBackToSystem() {
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage(null))
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage("unsupported"))
    }

    @Test
    fun chineseCatalogTagIsSupported() {
        assertEquals(AppLanguage.CHINESE, AppLanguage.fromStorage("zh"))
        assertEquals("中文", AppLanguage.CHINESE.autonym)
    }

    @Test
    fun polishCatalogTagIsSupported() {
        assertEquals(AppLanguage.POLISH, AppLanguage.fromStorage("pl"))
        assertEquals("Polski", AppLanguage.POLISH.autonym)
    }

    @Test
    fun everyExplicitLanguageRoundTripsItsStableTag() {
        AppLanguage.entries.filter { it != AppLanguage.SYSTEM }.forEach { language ->
            assertEquals(language, AppLanguage.fromStorage(language.storageValue))
        }
    }
}
