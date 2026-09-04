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

    func testPhotoPrefersHighestResolution() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("720", width: 1280, height: 720),
            descriptor("4k", width: 3840, height: 2160)
        ], mode: .photo))
        XCTAssertEqual(result.descriptor.identifier, "4k")
    }

    /// 照片排序看的是可请求的最大照片尺寸，而不是取景用的视频尺寸。
    func testPhotoRanksByMaxPhotoDimensionsNotVideoDimensions() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("big-video-small-photo", width: 1920, height: 1080, maxPhotoWidth: 1920, maxPhotoHeight: 1080),
            descriptor("small-video-big-photo", width: 1280, height: 720, maxPhotoWidth: 4032, maxPhotoHeight: 3024)
        ], mode: .photo))
        XCTAssertEqual(result.descriptor.identifier, "small-video-big-photo")
    }

    func testPhotoFallsBackToVideoDimensionsWhenPhotoDimensionsUnknown() {
        let known = descriptor("known", width: 1280, height: 720, maxPhotoWidth: 4032, maxPhotoHeight: 3024)
        let unknown = descriptor("unknown", width: 1280, height: 720)
        XCTAssertEqual(unknown.maxPhotoPixelCount, unknown.pixelCount)
        XCTAssertLessThan(
            CameraFormatSelector.score(known, frameRate: 30, mode: .photo),
            CameraFormatSelector.score(unknown, frameRate: 30, mode: .photo)
        )
    }

    /// binning 牺牲细节，照片模式下同尺寸时应劣于非 binned。
    func testPhotoPenalizesBinnedFormat() {
        let binned = descriptor("binned", width: 1280, height: 720, isBinned: true, maxPhotoWidth: 4032, maxPhotoHeight: 3024)
        let full = descriptor("full", width: 1280, height: 720, maxPhotoWidth: 4032, maxPhotoHeight: 3024)
        XCTAssertLessThan(
            CameraFormatSelector.score(full, frameRate: 30, mode: .photo),
            CameraFormatSelector.score(binned, frameRate: 30, mode: .photo)
        )
    }

    /// 录像统一合成到 1080×1920 画布，采集端再高只会被缩小。
    func testVideoTargetsTenEightyAndRejectsExcess() throws {
        let result = try XCTUnwrap(CameraFormatSelector.select(from: [
            descriptor("4k", width: 3840, height: 2160),
            descriptor("1080", width: 1920, height: 1080),
            descriptor("720", width: 1280, height: 720)
        ], mode: .video))
        XCTAssertEqual(result.descriptor.identifier, "1080")
    }

    func testVideoBelowTargetHasStrongerPenaltyThanSlightlyAbove() {
        let low = descriptor("low", width: 1280, height: 720)
        let above = descriptor("above", width: 2208, height: 1242)
        XCTAssertGreaterThan(
            CameraFormatSelector.score(low, frameRate: 30, mode: .video),
            CameraFormatSelector.score(above, frameRate: 30, mode: .video)
        )
    }

    /// 帧率差异的权重必须高于分辨率差异，否则取景会为了像素牺牲流畅度。
    func testFrameRateOutweighsResolutionInBothModes() {
        for mode in [CameraCaptureMode.photo, .video] {
            let big24 = descriptor("big24", width: 3840, height: 2160, maxPhotoWidth: 8064, maxPhotoHeight: 6048)
            let small30 = descriptor("small30", width: 1280, height: 720, maxPhotoWidth: 1280, maxPhotoHeight: 720)
            XCTAssertLessThan(
                CameraFormatSelector.score(small30, frameRate: 30, mode: mode),
                CameraFormatSelector.score(big24, frameRate: 24, mode: mode),
                "\(mode) 下 30fps 应优先于更高分辨率的 24fps"
            )
        }
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
        supportsVideo: Bool = true,
        isBinned: Bool = false,
        maxPhotoWidth: Int32 = 0,
        maxPhotoHeight: Int32 = 0
    ) -> CameraFormatDescriptor {
        CameraFormatDescriptor(
            identifier: id,
            width: width,
            height: height,
            supports30FPS: fps30,
            supports24FPS: fps24,
            isMultiCamSupported: isMultiCam,
            supportsVideoPixelFormat: supportsVideo,
            isBinned: isBinned,
            maxPhotoWidth: maxPhotoWidth,
            maxPhotoHeight: maxPhotoHeight
        )
    }
}
