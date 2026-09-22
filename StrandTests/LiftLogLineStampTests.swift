import XCTest
@testable import Strand

/// Every line the Lift Log writes into NOOP's strap log carries its own time.
///
/// NOOP's log takes each line's time from whoever writes it. The Lift Log's lines did not: all 98 of them in
/// Utku's 22 Sep session — every double-tap, every light-up, every session picked up after a restart — so the
/// moment one happened had to be inferred from the neighbouring lines, which is exactly what a strap log is read
/// for.
@MainActor
final class LiftLogLineStampTests: XCTestCase {

    func testAStampedLineLeadsWithItsOwnClock() {
        let line = AppModel.stamped("Double-tap → Lift Log: next")
        XCTAssertNotNil(line.range(of: #"^\[\d\d:\d\d:\d\d\] Double-tap → Lift Log: next$"#, options: .regularExpression),
                        line)
    }

    /// The same shape as the lines it sits between — `BLEManager`'s own `HH:mm:ss` — so a reader and
    /// `dist/tools/strap-log.py` see one format, not two.
    func testItMatchesTheShapeOfTheLinesAroundIt() {
        let stamp = AppModel.logTimeFormatter.string(from: Date())
        XCTAssertNotNil(stamp.range(of: #"^\d\d:\d\d:\d\d$"#, options: .regularExpression), stamp)
        XCTAssertTrue(AppModel.stamped("x").hasPrefix("[\(stamp.prefix(2))"))
    }
}
