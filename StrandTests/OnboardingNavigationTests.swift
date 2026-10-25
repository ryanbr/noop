import XCTest
@testable import Strand

final class OnboardingNavigationTests: XCTestCase {
    func testUnbondedContinueAndBackSkipConnectionCelebration() {
        XCTAssertEqual(OnboardingWizard.navigationStep(from: .scan, forward: true, bonded: false), .profile)
        XCTAssertEqual(OnboardingWizard.navigationStep(from: .profile, forward: false, bonded: false), .scan)
    }

    func testBondedNavigationRetainsConnectionCelebration() {
        XCTAssertEqual(OnboardingWizard.navigationStep(from: .scan, forward: true, bonded: true), .bonded)
        XCTAssertEqual(OnboardingWizard.navigationStep(from: .profile, forward: false, bonded: true), .bonded)
    }

    func testOtherStepsKeepTheirSequentialNavigationAndEndGuards() {
        for bonded in [false, true] {
            for step in OnboardingWizard.Step.allCases {
                for forward in [false, true] {
                    if !bonded && ((forward && step == .scan) || (!forward && step == .profile)) { continue }
                    let expected = OnboardingWizard.Step(rawValue: step.rawValue + (forward ? 1 : -1))
                    XCTAssertEqual(OnboardingWizard.navigationStep(from: step, forward: forward, bonded: bonded), expected)
                }
            }
        }
    }
}
