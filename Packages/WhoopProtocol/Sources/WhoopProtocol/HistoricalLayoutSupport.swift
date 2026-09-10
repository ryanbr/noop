import Foundation

/// How well this platform handles a historical record's layout version, for the strap-log line that tells
/// a user why their nights are not staging.
///
/// The two negative cases are kept apart because they are different facts with different remedies, and the
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
}

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
        return carriesNamedSignal ? .supported : .decodesWithoutNamedSignal
    case .whoop4:
        return carriesNamedSignal ? .supported : .unmapped
    }
}
