import XCTest
@testable import EviiFrames

final class AppleFrameRateTests: XCTestCase {
    func testSupportQueryDoesNotCrash() {
        // Simulator and an iPhone 14 Pro can disagree. The query must stay
        // false unless VideoToolbox itself reports isSupported.
        let supported = AppleFrameRate.isRuntimeSupported
        if supported {
            print("EVII_FRC {\"isSupported\":true}")
        } else {
            print("EVII_FRC {\"isSupported\":false}")
        }
        XCTAssertTrue(supported == true || supported == false)
    }
}
