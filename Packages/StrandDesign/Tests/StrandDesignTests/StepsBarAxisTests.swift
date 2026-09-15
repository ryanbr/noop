#if !os(watchOS)
import XCTest
@testable import StrandDesign

final class StepsBarAxisTests: XCTestCase {
    func testStepAxisIncludesOccupiedBlockAndKeepsZero() {
        for (maximum, upper) in [(0.0, 5000.0), (4999, 5000), (5000, 5000),
                                 (5001, 10000), (19000, 20000), (20001, 25000)] {
            let chart = TrendChart(points: [.init(date: Date(), value: maximum)],
                                   showsBars: true, yAxisStep: 5000)
            XCTAssertEqual(chart.plotYDomain, 0...upper)
        }
    }

    func testExistingChartDomainUnchangedWithoutStepConfiguration() {
        let chart = TrendChart(points: [], valueRange: 40...80, showsBars: true)
        XCTAssertEqual(chart.plotYDomain, 0...80)
        XCTAssertEqual(TrendChart(points: [], valueRange: 40...80).plotYDomain, 40...80)
    }
}
#endif
