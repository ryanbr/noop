import Foundation

/// WHOOP 5 type-40 and v18 interval words use the same 1/1024-second ticks as BLE 0x2A37.
/// Verified by matching complete native/standard beat arrays on firmware 50.41.1.0.
/// Keep this separate from WHOOP 4 decoding, whose existing millisecond contract is unchanged.
public enum Whoop5RR {
    public static func milliseconds(ticks: UInt16) -> Int {
        (Int(ticks) * 1000 + 512) / 1024
    }

    /// Labelled wire observations resolve an unknown registry entry, but cannot override another family.
    public static func usesCanonicalSource(model: String?, brand: String?, hasTaggedIntervals: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame { return false }
        switch DeviceFamily.confirmedRegistryFamily(model: model, brand: brand) {
        case .whoop4: return false
        case .whoop5: return true
        case nil: return hasTaggedIntervals
        }
    }

    /// Whether a stored night is one this unit policy has to leave unscored, rather than one that simply
    /// has no data.
    ///
    /// The policy reads a window through a SINGLE labelled transport. Rows recorded before the label
    /// existed carry no transport, so they mix millisecond and tick units with nothing on disk to tell
    /// them apart, and a window holding only those rows yields no beats at all. HRV is nil, and Charge,
    /// which needs a nightly HRV, is nil behind it. That is indistinguishable on screen from a night the
    /// strap was not worn, which is why this exists: it is the one case where the cause is known.
    ///
    /// Deliberately CONSERVATIVE, per the rule that a diagnostic may only assert what it can attribute.
    /// The claim is bounded on BOTH sides, to the window where this strap was recording and nothing was
    /// yet labelled:
    /// - `strictWhoop5` gates it, so a WHOOP 4 or another brand can never see this explanation.
    /// - `firstRecordedDay` is required and bounds it below. Without that bound, a wearer who imported
    ///   years of history before ever owning the strap would be told those nights lost their beats to a
    ///   labelling change that had not been invented yet, which is a fabricated cause. A device that has
    ///   banked no beats at all never qualifies for the same reason.
    /// - `firstScorableDay` bounds it above: a night on or after it is NOT claimed, even though a
    ///   particular window there can still come up empty. Past that day the app is labelling, so the
    ///   honest general statement stops. Nil means nothing labelled has been banked yet, which for a
    ///   confirmed WHOOP 5 is exactly the wearer who has not synced since the units were corrected.
    /// - `totalSleepMin` must be positive. A night that staged is a night the wearer was wearing it;
    ///   without that, an empty HRV is far more likely a strap left on the charger.
    ///
    /// One gap is left un-narrowed and is stated rather than hidden: inside those bounds, a night staged
    /// purely from an imported source while the strap itself banked nothing would also be claimed. Ruling
    /// that out needs a per-night beat count, and the statement stays true of the wearer's situation
    /// either way. Day keys are `yyyy-MM-dd`, so comparing them as strings orders them by date.
    public static func legacyUnscorableNight(strictWhoop5: Bool, day: String, firstRecordedDay: String?,
                                             firstScorableDay: String?,
                                             avgHrv: Double?, totalSleepMin: Double?) -> Bool {
        guard strictWhoop5, avgHrv == nil, (totalSleepMin ?? 0) > 0 else { return false }
        guard let firstRecordedDay, !firstRecordedDay.isEmpty, day >= firstRecordedDay else { return false }
        if let firstScorableDay, !firstScorableDay.isEmpty, day >= firstScorableDay { return false }
        return true
    }

}
