import Foundation
import XCTest
@testable import Strand

final class BroadcastHrCommandTests: XCTestCase {
    func testWhoop4EnableFrameMatchesExpectedBytes() {
        XCTAssertEqual(
            WhoopCommand.toggleGenericHRProfile.frame(seq: 8, payload: [1]).hex,
            "aa0800a823080e016c935474"
        )
    }

    func testWhoop4DisableFrameMatchesExpectedBytes() {
        XCTAssertEqual(
            WhoopCommand.toggleGenericHRProfile.frame(seq: 7, payload: [0]).hex,
            "aa0800a823070e00c7e40f08"
        )
    }
}

private extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
