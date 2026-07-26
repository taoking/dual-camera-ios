import AVFoundation
import XCTest
@testable import DualCamera

final class PhotoQualityTests: XCTestCase {
    func testFastAlwaysRequestsSpeed() {
        XCTAssertEqual(PhotoCaptureCoordinator.requestedPrioritization(.fast, maximum: .quality), .speed)
    }

    func testBalancedRequestsBalancedWhenAllowed() {
        XCTAssertEqual(PhotoCaptureCoordinator.requestedPrioritization(.balanced, maximum: .balanced), .balanced)
    }

    func testBalancedClampsToSpeedMaximum() {
        XCTAssertEqual(PhotoCaptureCoordinator.requestedPrioritization(.balanced, maximum: .speed), .speed)
    }
}
