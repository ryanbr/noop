package com.noop.ui

import com.noop.data.BackupSettingsCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the custom-background pref contract (#custom-background) so the three pref-key strings and the
 * four [BackgroundFillMode] rawValues stay byte-identical to the iOS `BackgroundImagePrefs` /
 * `BackgroundFillMode` twins — a drift on either platform would read a different value from the same
 * SharedPreferences/UserDefaults. Also asserts the keys are deliberately NOT in the `.noopbak`
 * whitelist (the image + its toggles are device-local, like the avatar).
 */
class BackgroundImagePrefsParityTest {

    @Test fun keyLiterals_matchTheIosContract() {
        assertEquals("noop.backgroundImageEnabled", NoopPrefs.KEY_BACKGROUND_IMAGE_ENABLED)
        assertEquals("noop.backgroundFillMode", NoopPrefs.KEY_BACKGROUND_FILL_MODE)
        assertEquals("noop.backgroundImagePresent", NoopPrefs.KEY_BACKGROUND_IMAGE_PRESENT)
        assertEquals("noop.backgroundRecents", NoopPrefs.KEY_BACKGROUND_RECENTS)
    }

    @Test fun fillModeRawValues_matchTheIosContract() {
        assertEquals("fill", BackgroundFillMode.FILL.storageValue)
        assertEquals("fit", BackgroundFillMode.FIT.storageValue)
        assertEquals("stretch", BackgroundFillMode.STRETCH.storageValue)
        assertEquals("tile", BackgroundFillMode.TILE.storageValue)
        // Exactly these four, in this order (parity with the Swift CaseIterable order).
        assertEquals(
            listOf("fill", "fit", "stretch", "tile"),
            BackgroundFillMode.entries.map { it.storageValue },
        )
    }

    @Test fun fromStorage_isTolerantAndDefaultsToFill() {
        assertEquals(BackgroundFillMode.TILE, BackgroundFillMode.fromStorage("tile"))
        assertEquals(BackgroundFillMode.FILL, BackgroundFillMode.fromStorage(null))
        assertEquals(BackgroundFillMode.FILL, BackgroundFillMode.fromStorage("nonsense"))
        assertEquals(BackgroundFillMode.FILL, BackgroundFillMode.fromStorage(""))
    }

    @Test fun recents_serializeAndParseRoundTrip() {
        val list = listOf(
            BackgroundImageStore.Recent("bg-1.jpg", BackgroundFillMode.FIT),
            BackgroundImageStore.Recent("bg-2.jpg", BackgroundFillMode.TILE),
            BackgroundImageStore.Recent("bg-3.jpg", BackgroundFillMode.FILL),
        )
        val s = BackgroundImageStore.serializeRecents(list)
        assertEquals("bg-1.jpg,fit;bg-2.jpg,tile;bg-3.jpg,fill", s)
        assertEquals(list, BackgroundImageStore.parseRecents(s))
        // Empty / malformed entries are dropped, and the list is capped at MAX_RECENTS.
        assertTrue(BackgroundImageStore.parseRecents("").isEmpty())
        assertTrue(BackgroundImageStore.parseRecents("garbage").isEmpty())
        assertEquals(BackgroundImageStore.MAX_RECENTS, BackgroundImageStore.parseRecents("a,fill;b,fit;c,tile;d,fill").size)
    }

    @Test fun backgroundKeys_areNotInTheNoopbakWhitelist() {
        // Device-local (like the avatar) — a restore onto another device must not carry the picture
        // toggles. Guards against someone "helpfully" whitelisting them later.
        assertFalse(BackupSettingsCodec.WHITELIST.containsKey(NoopPrefs.KEY_BACKGROUND_IMAGE_ENABLED))
        assertFalse(BackupSettingsCodec.WHITELIST.containsKey(NoopPrefs.KEY_BACKGROUND_FILL_MODE))
        assertFalse(BackupSettingsCodec.WHITELIST.containsKey(NoopPrefs.KEY_BACKGROUND_IMAGE_PRESENT))
        assertFalse(BackupSettingsCodec.WHITELIST.containsKey(NoopPrefs.KEY_BACKGROUND_RECENTS))
    }
}
