import XCTest
@testable import DualCamera

final class CameraFormatSelectorTests: XCTestCase {
    func testPrefers30FPS() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("24", width: 1280, height: 720, fps30: false, fps24: true),
            descriptor("30", width: 1280, height: 720, fps30: true, fps24: true)
        ], mode: .photo))
        XCTAssertEqual(result.frameRate, 30)
        XCTAssertEqual(result.descriptor.identifier, "30")
    }

    func testFallsBackTo24FPS() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("24", width: 1280, height: 720, fps30: false, fps24: true)
        ], mode: .photo))
        XCTAssertEqual(result.frameRate, 24)
    }

    func testExcessiveResolutionIsPenalized() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("4k", width: 3840, height: 2160),
            descriptor("720", width: 1280, height: 720)
        ], mode: .photo))
        XCTAssertEqual(result.descriptor.identifier, "720")
    }

    func testBelowTargetHasStrongerPenaltyThanSlightlyAbove() {
        let low = descriptor("low", width: 960, height: 540)
        let above = descriptor("above", width: 1440, height: 810)
        XCTAssertGreaterThan(
            CameraFormatSelector.score(low, frameRate: 30, mode: .photo),
            CameraFormatSelector.score(above, frameRate: 30, mode: .photo)
        )
    }

    func testReturnsNilWithoutMultiCamFormat() {
        let result = CameraFormatSelector.select(from: [
            descriptor("single", width: 1280, height: 720, isMultiCam: false)
        ], mode: .photo)
        XCTAssertNil(result)
    }

    func testVideoRejectsUnsupportedPixelFormatWhilePhotoAcceptsIt() {
        let descriptor = descriptor("photo-only", width: 1280, height: 720, supportsVideo: false)
        XCTAssertNotNil(CameraFormatSelector.select(from: [descriptor], mode: .photo))
        XCTAssertNil(CameraFormatSelector.select(from: [descriptor], mode: .video))
    }

    private func descriptor(
        _ id: String,
        width: Int32,
        height: Int32,
        fps30: Bool = true,
        fps24: Bool = true,
        isMultiCam: Bool = true,
        supportsVideo: Bool = true
    ) -> CameraFormatDescriptor {
        CameraFormatDescriptor(
            identifier: id,
            width: width,
            height: height,
            supports30FPS: fps30,
            supports24FPS: fps24,
            isMultiCamSupported: isMultiCam,
            supportsVideoPixelFormat: supportsVideo,
            isBinned: false
        )
    }
}
