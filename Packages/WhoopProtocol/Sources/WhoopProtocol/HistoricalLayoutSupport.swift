import Foundation

/// Whether a historical record's layout version is one this platform has NO field map for, and so should
/// be reported to the user as undecodable.
///
/// #1992. The old form of this question listed the signature field of every mapped layout and warned when
/// a record carried none of them: `heart_rate`, then `gravity_x` once v25 was mapped, then `ppg_waveform`
/// once v26 was. A list like that has to be extended by hand every time NOOP learns a layout, and twice it
/// silently was not. #156 was v25 and v26 being reported as undecodable after they had been decoding for
/// releases. v20 has been reported the same way ever since it was mapped, because the 5/MG optical record
/// decodes to `sensor_block_count` and per-block headers rather than to any of the three names.
///
/// On WHOOP 5.0/MG the question is therefore asked of `mappedWhoop5HistoricalVersions`, which is the list
/// `decodeWhoop5Historical` itself dispatches on. It cannot drift from what NOOP decodes, because a layout
/// that decodes is a layout with a `case` in that switch and an entry in that set.
///
/// WHOOP 4.0 keeps the field test. There is no equivalent dispatch set on that side, and every layout it
/// does map emits one of the three names, so the test is accurate there today. If a 4.0 layout is ever
/// mapped that emits none of them, this is the function that has to learn about it, and
/// `HistoricalLayoutSupportTests` is where that shows up as a failure rather than as a false warning in
/// somebody's strap log.
public func historicalLayoutIsUnmapped(version: Int,
                                       family: DeviceFamily,
                                       hasHeartRate: Bool,
                                       hasGravity: Bool,
                                       hasPpgWaveform: Bool) -> Bool {
    switch family {
    case .whoop5: return !mappedWhoop5HistoricalVersions.contains(version)
    case .whoop4: return !hasHeartRate && !hasGravity && !hasPpgWaveform
    }
}
