import XCTest
import StrandAnalytics
@testable import Strand

/// #1848: the skin-temp explorer's two explanatory notes (#1847), pure-function twins of Android's
/// `shouldExplainSkinTempFallback` and `shouldExplainShortenedSkinTempSeries`.
///
/// Both notes are gated so they fire ONLY when the sentence they carry is true — a note that says the
/// opposite of what happened is worse than silence. The fallback note fires when the user asked for
/// temperatures and the window has none; the shortened-series note fires when leading with absolutes
/// dropped deviation-only nights. The deviation-led branch also drops rows (calibrating nights with
/// only an absolute), but those are the OPPOSITE kind, so the shortened-series note is gated to
/// absolute-led only.
final class SkinTempExplorerNoteTests: XCTestCase {

    // MARK: - shouldExplainSkinTempFallback

    func testFallbackExplainedWhenUserAskedForAbsoluteButWindowHasNone() {
        XCTAssertTrue(shouldExplainSkinTempFallback(
            prefer: .absolute, leadsAbsolute: false, anyAbsoluteInWindow: false))
    }

    func testFallbackSilentWhenWindowHasAbsoluteEvenIfLatestLacksOne() {
        // #1850: the preference applies across the window. A window with one stored temperature
        // and twenty deltas still leads with temperatures, so the fallback note stays silent.
        XCTAssertFalse(shouldExplainSkinTempFallback(
            prefer: .absolute, leadsAbsolute: true, anyAbsoluteInWindow: true))
    }

    func testFallbackSilentWhenUserAskedForDeviation() {
        // The user chose "vs baseline" — showing deviations is honouring the choice, not falling back.
        XCTAssertFalse(shouldExplainSkinTempFallback(
            prefer: .deviation, leadsAbsolute: false, anyAbsoluteInWindow: false))
    }

    func testFallbackSilentWhenLeadingAbsoluteAsRequested() {
        XCTAssertFalse(shouldExplainSkinTempFallback(
            prefer: .absolute, leadsAbsolute: true, anyAbsoluteInWindow: true))
    }

    // MARK: - shouldExplainShortenedSkinTempSeries

    func testShortenedSeriesExplainedWhenAbsoluteLedDropsNights() {
        XCTAssertTrue(shouldExplainShortenedSkinTempSeries(
            leadsAbsolute: true, shownReadings: 21, rowsWithEitherNumber: 40))
    }

    func testShortenedSeriesSilentWhenEveryNightIsShown() {
        XCTAssertFalse(shouldExplainShortenedSkinTempSeries(
            leadsAbsolute: true, shownReadings: 23, rowsWithEitherNumber: 23))
    }

    func testShortenedSeriesSilentWhenNothingToShow() {
        XCTAssertFalse(shouldExplainShortenedSkinTempSeries(
            leadsAbsolute: true, shownReadings: 0, rowsWithEitherNumber: 0))
    }

    func testShortenedSeriesNeverExplainsWhenLeadingWithDeviation() {
        // The deviation-led branch ALSO drops rows (calibrating nights with only an absolute), but
        // those are the OPPOSITE kind — "only nights with a measured temperature are shown" would be
        // precisely backwards. Ungated, this fired the moment a wearer picked "vs baseline" with any
        // calibrating night in the window.
        XCTAssertFalse(shouldExplainShortenedSkinTempSeries(
            leadsAbsolute: false, shownReadings: 21, rowsWithEitherNumber: 40))
    }
}
