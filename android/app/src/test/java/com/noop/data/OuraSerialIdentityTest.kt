package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class OuraSerialIdentityTest {

    @Test fun logSafeNeverLeaksTheFullSerial() {
        assertEquals("2H3…", OuraSerialIdentity.logSafe("2H3B2405003655"))
        assertEquals("203…", OuraSerialIdentity.logSafe("2038082631034041"))
        assertEquals("?", OuraSerialIdentity.logSafe(null))
        assertEquals("?", OuraSerialIdentity.logSafe("  "))
        assertFalse(OuraSerialIdentity.logSafe("2H3B2405003655").contains("2405003655"))
    }

    @Test fun logSafeUppercasesAndTrims() {
        assertEquals("2H3…", OuraSerialIdentity.logSafe("  2h3b2405003655  "))
    }

    @Test fun idPrefixMatchesTheBrandCatalog() {
        assertEquals("oura", OuraSerialIdentity.ID_PREFIX)
    }
}
