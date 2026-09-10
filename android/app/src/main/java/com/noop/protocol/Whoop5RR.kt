package com.noop.protocol

/** WHOOP 5 type-40/v18 words are 1/1024-second ticks. Swift Whoop5RR; WHOOP 4 stays unchanged. */
object Whoop5RR {
    fun milliseconds(ticks: Int): Int {
        require(ticks in 0..65535)
        return (ticks * 1000 + 512) / 1024
    }

    fun usesCanonicalSource(model: String?, brand: String?, hasTaggedIntervals: Boolean): Boolean {
        if (!brand.isNullOrEmpty() && !brand.equals("WHOOP", ignoreCase = true)) return false
        return when (DeviceFamily.confirmedRegistryFamily(model, brand)) {
            DeviceFamily.WHOOP4 -> false
            DeviceFamily.WHOOP5 -> true
            null -> hasTaggedIntervals
        }
    }

    /**
     * Whether a stored night is one this unit policy has to leave unscored, rather than one that simply
     * has no data.
     *
     * The policy reads a window through a SINGLE labelled transport. Rows recorded before the label
     * existed carry no transport, so they mix millisecond and tick units with nothing on disk to tell
     * them apart, and a window holding only those rows yields no beats at all. HRV is null, and Charge,
     * which needs a nightly HRV, is null behind it. That is indistinguishable on screen from a night the
     * strap was not worn, which is why this exists: it is the one case where the cause is known.
     *
     * Deliberately CONSERVATIVE, per the rule that a diagnostic may only assert what it can attribute.
     * The claim is bounded on BOTH sides, to the window where this strap was recording and nothing was
     * yet labelled:
     * - [strictWhoop5] gates it, so a WHOOP 4 or another brand can never see this explanation.
     * - [firstRecordedDay] is required and bounds it below. Without that bound, a wearer who imported
     *   years of history before ever owning the strap would be told those nights lost their beats to a
     *   labelling change that had not been invented yet, which is a fabricated cause. A device that has
     *   banked no beats at all never qualifies for the same reason.
     * - [firstScorableDay] bounds it above: a night on or after it is NOT claimed, even though a
     *   particular window there can still come up empty. Past that day the app is labelling, so the
     *   honest general statement stops. Null means nothing labelled has been banked yet, which for a
     *   confirmed WHOOP 5 is exactly the wearer who has not synced since the units were corrected.
     * - [totalSleepMin] must be positive. A night that staged is a night the wearer was wearing it;
     *   without that, an empty HRV is far more likely a strap left on the charger.
     *
     * One gap is left un-narrowed and is stated rather than hidden: inside those bounds, a night staged
     * purely from an imported source while the strap itself banked nothing would also be claimed. Ruling
     * that out needs a per-night beat count, and the statement stays true of the wearer's situation
     * either way. Day keys are `yyyy-MM-dd`, so comparing them as strings orders them by date.
     *
     * Byte-identical twin of Swift `Whoop5RR.legacyUnscorableNight`.
     */
    fun legacyUnscorableNight(
        strictWhoop5: Boolean,
        day: String,
        firstRecordedDay: String?,
        firstScorableDay: String?,
        avgHrv: Double?,
        totalSleepMin: Double?,
    ): Boolean {
        if (!strictWhoop5 || avgHrv != null || (totalSleepMin ?: 0.0) <= 0.0) return false
        if (firstRecordedDay.isNullOrEmpty() || day < firstRecordedDay) return false
        if (!firstScorableDay.isNullOrEmpty() && day >= firstScorableDay) return false
        return true
    }

}
