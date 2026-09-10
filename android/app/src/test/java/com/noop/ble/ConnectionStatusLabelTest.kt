package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A disconnect status is an HCI link-end reason. An ATT operation status is a different enumeration
 * that collides with it on small integers, and #1635 already lost effort to a diagnosis built from one
 * rendered through the other. The line these labels feed exists solely to name why a link ended, so
 * naming it from the wrong table is worse than printing the bare number.
 *
 * This pins that the two tables disagree exactly where they must.
 */
class ConnectionStatusLabelTest {

    @Test fun theReasonsAnInvestigationTurnsOnAreNamed() {
        assertTrue(connectionStatusLabel(19).contains("the strap closed the link"))
        assertTrue(connectionStatusLabel(22).contains("this phone closed the link"))
        assertTrue(connectionStatusLabel(8).contains("supervision timeout"))
        assertTrue(connectionStatusLabel(62).contains("never came up"))
    }

    @Test fun theCollidingCodesAreNotBorrowedFromTheOperationTable() {
        // 5, 13 and 15 are authentication, attribute length and encryption in ATT. As link-end reasons
        // they mean none of those things, and claiming otherwise is the #1635 mistake.
        for (code in listOf(3, 5, 13, 15)) {
            val conn = connectionStatusLabel(code)
            val att = gattStatusLabel(code)
            assertEquals("code $code must not borrow the ATT name", "unmapped", conn)
            assertTrue("the ATT table still names $code", att.contains("GATT_"))
        }
    }

    @Test fun anUnknownCodeSaysSoRatherThanGuessing() {
        assertEquals("unmapped", connectionStatusLabel(9_999))
    }

    @Test fun successIsNotDressedUpAsAFailure() {
        assertEquals("SUCCESS", connectionStatusLabel(0))
    }
}
