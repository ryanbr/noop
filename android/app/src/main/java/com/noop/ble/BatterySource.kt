package com.noop.ble

import com.noop.protocol.DeviceFamily

/** Where a link's battery percentage may legitimately come from - see [batterySource]. */
internal enum class BatterySource {
    /** The family is still a guess; take no reading rather than a possibly-invented one. */
    DEFER,

    /** WHOOP 4.0: the custom `GET_BATTERY_LEVEL` command (u16/10). */
    CUSTOM_COMMAND,

    /** 5/MG and other standard-profile straps: the standard 0x2A19 characteristic (whole %). */
    STANDARD_CHAR,
}

/**
 * Which battery source this link may use, given whether service discovery has established the family.
 *
 * The 4.0's standard 0x2A19 characteristic is a stub rather than a real state-of-charge (#77), so the
 * choice of source is only sound once the family is known from THIS connection. `connectedFamily`
 * defaults to WHOOP4 and is written only in onServicesDiscovered, and used to survive a disconnect
 * uncleared - so before discovery it holds either the default or the previous link's family. Asking
 * `!= WHOOP4` against that answers "use the standard characteristic" for a 4.0 whose family has not been
 * established yet, which reads the stub and banks it as a real SoC.
 *
 * That is the #171 shape the family resolver's own docs warn about - a family question answered by a
 * fall-through rather than by evidence - and it is not theoretical: a field log on a WHOOP 4.0 banked
 * 81% from the stub while the strap's own report, thirty seconds later, said 39.2%. Banked samples feed
 * the discharge-slope estimate (#713), so a phantom sample reaches the "time left" readout rather than
 * stopping at the log.
 *
 * [DEFER] is safe to act on: a periodic refresh follows within ~30s, by which point discovery has run.
 *
 * Pure so the decision is unit-tested without a strap, a GATT stack, or an Android runtime.
 */
internal fun batterySource(familyEstablished: Boolean, family: DeviceFamily): BatterySource = when {
    !familyEstablished -> BatterySource.DEFER
    family == DeviceFamily.WHOOP4 -> BatterySource.CUSTOM_COMMAND
    else -> BatterySource.STANDARD_CHAR
}
