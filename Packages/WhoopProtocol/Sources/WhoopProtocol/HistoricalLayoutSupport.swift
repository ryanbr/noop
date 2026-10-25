import Foundation

/// How well this platform handles a historical record's layout version, for the strap-log line that tells
/// a user why their nights are not staging.
///
/// The negative cases are kept apart because they are different facts with different remedies, and the
/// single line that used to cover both stated one of them wrongly. See `historicalLayoutSupport`.
public enum HistoricalLayoutSupport: Equatable, Sendable {
    /// The layout decodes and the record carries a named signal NOOP scores from.
    case supported
    /// The layout decodes, but this record carries no per-second heart rate and no motion, so a night made
    /// only of these cannot be staged. What is missing is the meaning of the channels, not the layout: the
    /// 5/MG optical record (v20) and raw IMU record (v21) both decode into raw arrays that no engine reads.
    case decodesWithoutNamedSignal
    /// This platform has no field map for the layout at all; the record does not decode.
    case unmapped
    /// The layout decodes, carries no scoreable signal, AND its whole payload is persisted in a stream of
    /// its own, so there is nothing missing and nothing for the user to report (#2847).
    ///
    /// This exists because the line for `decodesWithoutNamedSignal` asks the user to report the layout on
    /// #1992, and for a layout NOOP decodes, stores and deliberately scores nothing from, that request is
    /// for a report about working software. The MG ECG record is the case: it reaches NOOP only because
    /// the user took a reading, it is banked whole in `ecgWaveformSample`, and #752 is what keeps anything
    /// from being derived off it.
    ///
    /// WHAT THIS GIVES UP, stated rather than hidden: the staging half of the other line is true of these
    /// records too, so a night made ONLY of them could not be staged and this case says nothing about
    /// that. The trade is deliberate, because such a night does not occur — an ECG reading lasts at most
    /// the strap's own ten minutes and the strap keeps banking its ordinary per-second records throughout,
    /// so a real offload carrying ECG records carries v18 records as well.
    case decodesIntoItsOwnStream
}

/// The 5/MG layouts whose ENTIRE payload is persisted in a stream of its own, so a record of one is
/// neither unmapped nor missing anything. Only v16, the flash-banked ECG record (#2847): it is banked
/// whole in `ecgWaveformSample`, and it carries no per-second heart rate or motion to score.
///
/// v26 is NOT here and must not be added. Its waveform is persisted the same way, but it also decodes
/// `ppg_waveform`, which the field test already counts as a named signal, so it answers `.supported` and
/// nothing in it needs a special case. Keyed on the version rather than on a caller-supplied flag because
/// the answer is a property of the LAYOUT, which is the question this whole function asks.
private let whoop5HistoricalVersionsWithOwnStream: Set<Int> = [16]

/// Classify a historical record's layout version.
///
/// #1992. This used to be one question — "did the record decode any of `heart_rate`, `gravity_x` or
/// `ppg_waveform`?" — and one message, which said NOOP could not decode the layout. That is a list which
/// has to be extended by hand every time NOOP learns a layout, and twice it silently was not: #156 was v25
/// and v26 being reported as undecodable after they had been decoding for releases, and v20 has been
/// reported the same way ever since it was mapped, because the 5/MG optical record decodes to block counts
/// and per-block headers rather than to any of the three names.
///
/// Suppressing the line for v20 would have been the wrong correction, though, because the SECOND half of
/// what it said is true: those records really do carry no heart rate or motion, and a night made only of
/// them really cannot be staged. So the question splits. On WHOOP 5.0/MG, whether the layout decodes is
/// asked of `mappedWhoop5HistoricalVersions`, the set `decodeWhoop5Historical` itself dispatches on, which
/// cannot drift from what NOOP decodes. Whether the record carries anything scoreable stays the field test,
/// which is what it was always actually measuring.
///
/// WHOOP 4.0 has no equivalent dispatch set, and every layout it maps emits one of the three names, so a
/// record carrying none of them is genuinely unmapped there. If a 4.0 layout is ever mapped that emits
/// none of them, this is the function that has to learn about it, and `HistoricalLayoutSupportTests` is
/// where that shows up as a failure rather than as a wrong line in somebody's strap log.
public func historicalLayoutSupport(version: Int,
                                    family: DeviceFamily,
                                    hasHeartRate: Bool,
                                    hasGravity: Bool,
                                    hasPpgWaveform: Bool) -> HistoricalLayoutSupport {
    let carriesNamedSignal = hasHeartRate || hasGravity || hasPpgWaveform
    switch family {
    case .whoop5:
        if !mappedWhoop5HistoricalVersions.contains(version) { return .unmapped }
        if carriesNamedSignal { return .supported }
        if whoop5HistoricalVersionsWithOwnStream.contains(version) { return .decodesIntoItsOwnStream }
        return .decodesWithoutNamedSignal
    case .whoop4:
        return carriesNamedSignal ? .supported : .unmapped
    }
}
