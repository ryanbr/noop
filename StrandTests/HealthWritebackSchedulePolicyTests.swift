import XCTest
@testable import Strand

final class HealthWritebackSchedulePolicyTests: XCTestCase {
    func testSchedulesOnlyAfterAppleHealthAuthorization() {
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: true))
        XCTAssertFalse(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: false))
    }

    func testRequestsNextRefreshOneHourAfterScheduling() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            HealthWritebackSchedulePolicy.earliestBeginDate(after: now),
            now.addingTimeInterval(3_600)
        )
    }
}
