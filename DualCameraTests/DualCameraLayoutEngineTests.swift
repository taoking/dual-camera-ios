import XCTest
@testable import DualCamera

final class DualCameraLayoutEngineTests: XCTestCase {
    func testPictureInPictureIsConstrainedToCanvas() {
        var layout = DualCameraLayout.default
        layout.pipPosition = NormalizedPoint(x: 2, y: -1)
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = DualCameraLayoutEngine.frames(in: canvas, layout: layout).front

        XCTAssertGreaterThanOrEqual(frame.minX, canvas.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, canvas.minY)
        XCTAssertLessThanOrEqual(frame.maxX, canvas.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, canvas.maxY)
    }

    func testDefaultPictureInPictureUsesBottomRightCorner() {
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = DualCameraLayoutEngine.frames(in: canvas, layout: .default).front

        XCTAssertGreaterThan(frame.minX, canvas.midX)
        XCTAssertGreaterThan(frame.minY, canvas.midY)
        XCTAssertLessThanOrEqual(frame.maxX, canvas.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, canvas.maxY)
    }

    func testPIPSnapsToCorner() {
        var layout = DualCameraLayout.default
        layout.pipPosition = NormalizedPoint(x: 0.12, y: 0.13)
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 400)
        let frame = DualCameraLayoutEngine.frames(in: canvas, layout: layout).front
        let updated = DualCameraLayoutEngine.layout(layout, movingPipTo: frame, in: canvas, snap: true)

        XCTAssertEqual(updated.pipPosition.x, 0.035, accuracy: 0.0001)
        XCTAssertEqual(updated.pipPosition.y, 0.035, accuracy: 0.0001)
    }

    func testVerticalSplitFramesCoverCanvas() {
        var layout = DualCameraLayout.default
        layout.style = .splitVertical
        let frames = DualCameraLayoutEngine.frames(in: CGRect(x: 0, y: 0, width: 300, height: 400), layout: layout)

        XCTAssertEqual(frames.back, CGRect(x: 0, y: 0, width: 150, height: 400))
        XCTAssertEqual(frames.front, CGRect(x: 150, y: 0, width: 150, height: 400))
    }

    func testHorizontalSplitFramesCoverCanvas() {
        var layout = DualCameraLayout.default
        layout.style = .splitHorizontal
        let frames = DualCameraLayoutEngine.frames(in: CGRect(x: 0, y: 0, width: 300, height: 400), layout: layout)

        XCTAssertEqual(frames.back, CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(frames.front, CGRect(x: 0, y: 200, width: 300, height: 200))
    }

    func testAspectOutputSizes() {
        XCTAssertEqual(DualCameraLayoutEngine.outputSize(for: .threeByFour), CGSize(width: 1_080, height: 1_440))
        XCTAssertEqual(DualCameraLayoutEngine.outputSize(for: .square), CGSize(width: 1_440, height: 1_440))
        XCTAssertEqual(DualCameraLayoutEngine.outputSize(for: .nineBySixteen), CGSize(width: 810, height: 1_440))
    }

    /// 画布长边跟随源图，避免把高分辨率成片压回固定的 1440。
    func testOutputSizeFollowsSourceLongEdge() {
        let size = DualCameraLayoutEngine.outputSize(
            for: .threeByFour,
            sourceSize: CGSize(width: 3_024, height: 4_032)
        )
        XCTAssertEqual(size, CGSize(width: 3_024, height: 4_032))
    }

    func testOutputSizeUsesSourceLongEdgeRegardlessOfOrientation() {
        let portrait = DualCameraLayoutEngine.outputSize(
            for: .nineBySixteen,
            sourceSize: CGSize(width: 3_024, height: 4_032)
        )
        let landscape = DualCameraLayoutEngine.outputSize(
            for: .nineBySixteen,
            sourceSize: CGSize(width: 4_032, height: 3_024)
        )
        XCTAssertEqual(portrait, landscape)
        XCTAssertEqual(portrait.height, 4_032)
    }

    /// 小源图不应把画布拉到比既有成片更低的水平。
    func testOutputSizeNeverDropsBelowFallbackLongEdge() {
        let size = DualCameraLayoutEngine.outputSize(
            for: .threeByFour,
            sourceSize: CGSize(width: 100, height: 160)
        )
        XCTAssertEqual(size, DualCameraLayoutEngine.outputSize(for: .threeByFour))
        XCTAssertEqual(size.height, DualCameraLayoutEngine.fallbackLongEdge)
    }

    /// 超大源图要被上限截断，避免合成位图的内存峰值失控。
    func testOutputSizeIsClampedToMaximumLongEdge() {
        let size = DualCameraLayoutEngine.outputSize(
            for: .square,
            sourceSize: CGSize(width: 8_064, height: 6_048)
        )
        XCTAssertEqual(size.height, DualCameraLayoutEngine.maximumLongEdge)
        XCTAssertEqual(size.width, DualCameraLayoutEngine.maximumLongEdge)
    }

    /// 画布不得超过源图能覆盖的范围，否则 aspectFill 会上采样出没有细节的像素。
    func testOutputSizeNeverUpscalesSourceForAnyAspectRatio() {
        let source = CGSize(width: 3_024, height: 4_032)
        for ratio in CaptureAspectRatio.allCases {
            let size = DualCameraLayoutEngine.outputSize(for: ratio, sourceSize: source)
            // aspectFill 缩放系数不超过 1 即代表没有放大。
            let scale = max(size.width / source.width, size.height / source.height)
            XCTAssertLessThanOrEqual(scale, 1.0001, "\(ratio.title) 画布放大了源图")
        }
    }

    func testSquareCanvasIsLimitedBySourceShortEdge() {
        let size = DualCameraLayoutEngine.outputSize(
            for: .square,
            sourceSize: CGSize(width: 3_024, height: 4_032)
        )
        XCTAssertEqual(size, CGSize(width: 3_024, height: 3_024))
    }

    /// 9:16 比源图更窄，短边约束不会生效，应保留完整长边。
    func testTallCanvasKeepsFullSourceLongEdge() {
        let size = DualCameraLayoutEngine.outputSize(
            for: .nineBySixteen,
            sourceSize: CGSize(width: 3_024, height: 4_032)
        )
        XCTAssertEqual(size, CGSize(width: 2_268, height: 4_032))
    }

    /// 视频合成走 CoreImage（原点左下、y 向上），布局引擎输出 UIKit 坐标（原点左上、y 向下）。
    /// 漏掉这次翻转会让画中画在成片里跑到上下相反的角落。
    func testCoreImageRectFlipsVerticalAxis() {
        let canvasHeight: CGFloat = 1_920
        // 贴住画布顶部的矩形，翻转后应贴住 CoreImage 的顶部（y 最大处）。
        let topRect = CGRect(x: 100, y: 0, width: 200, height: 300)
        let flippedTop = DualCameraLayoutEngine.coreImageRect(from: topRect, canvasHeight: canvasHeight)
        XCTAssertEqual(flippedTop, CGRect(x: 100, y: 1_620, width: 200, height: 300))

        // 贴住画布底部的矩形，翻转后 y 应为 0。
        let bottomRect = CGRect(x: 100, y: 1_620, width: 200, height: 300)
        let flippedBottom = DualCameraLayoutEngine.coreImageRect(from: bottomRect, canvasHeight: canvasHeight)
        XCTAssertEqual(flippedBottom, CGRect(x: 100, y: 0, width: 200, height: 300))
    }

    func testCoreImageRectIsItsOwnInverse() {
        let canvasHeight: CGFloat = 1_920
        let original = CGRect(x: 40, y: 275, width: 320, height: 480)
        let once = DualCameraLayoutEngine.coreImageRect(from: original, canvasHeight: canvasHeight)
        let twice = DualCameraLayoutEngine.coreImageRect(from: once, canvasHeight: canvasHeight)
        XCTAssertEqual(twice, original)
    }

    /// 水平方向不参与翻转：左边的东西在成片里仍应在左边。
    func testCoreImageRectPreservesHorizontalPosition() {
        let rect = CGRect(x: 0, y: 100, width: 200, height: 200)
        let flipped = DualCameraLayoutEngine.coreImageRect(from: rect, canvasHeight: 1_920)
        XCTAssertEqual(flipped.minX, 0)
        XCTAssertEqual(flipped.width, 200)
    }

    func testZeroSourceSizeFallsBackToDefaultCanvas() {
        let size = DualCameraLayoutEngine.outputSize(for: .threeByFour, sourceSize: .zero)
        XCTAssertEqual(size, DualCameraLayoutEngine.outputSize(for: .threeByFour))
    }

    func testNonZeroOriginCanvasIsPreserved() {
        var layout = DualCameraLayout.default
        layout.style = .splitVertical
        let canvas = CGRect(x: 40, y: 70, width: 300, height: 400)
        let frames = DualCameraLayoutEngine.frames(in: canvas, layout: layout)
        XCTAssertEqual(frames.back.minX, 40)
        XCTAssertEqual(frames.front.maxX, 340)
        XCTAssertEqual(frames.front.minY, 70)
    }
}
