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
    fun everyExplicitLanguageRoundTripsItsStableTag() {
        AppLanguage.entries.filter { it != AppLanguage.SYSTEM }.forEach { language ->
            assertEquals(language, AppLanguage.fromStorage(language.storageValue))
        }
    }
}
