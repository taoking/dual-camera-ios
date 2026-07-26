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
