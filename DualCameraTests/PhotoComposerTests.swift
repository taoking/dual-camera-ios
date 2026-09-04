import XCTest
@testable import DualCamera

final class PhotoComposerTests: XCTestCase {
    func testComposerUsesRequestedOutputSize() throws {
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .systemTeal),
            frontImage: image(color: .systemOrange),
            layout: .default,
            aspectRatio: .nineBySixteen
        )
        let image = try XCTUnwrap(try? result.get())
        XCTAssertEqual(image.size, CGSize(width: 810, height: 1_440))
    }

    func testSplitCompositionPlacesFrontImageInRightHalf() throws {
        var layout = DualCameraLayout.default
        layout.style = .splitVertical
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .red),
            frontImage: image(color: .blue),
            layout: layout,
            aspectRatio: .square
        )
        let image = try XCTUnwrap(try? result.get())

        XCTAssertEqual(pixelColor(in: image, at: CGPoint(x: 180, y: 720)).redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(pixelColor(in: image, at: CGPoint(x: 1_200, y: 720)).blueComponent, 1, accuracy: 0.02)
    }

    func testCaptureTransactionCompletesWhenEachCameraReturns() {
        var transaction = CaptureTransaction(id: UUID(), startedAt: .now, expectedPositions: [.back, .front])
        transaction.errors[.back] = .captureFailed("模拟错误")
        XCTAssertFalse(transaction.isComplete)
        transaction.errors[.front] = .captureFailed("模拟错误")
        XCTAssertTrue(transaction.isComplete)
    }

    func testFrontCaptureMirroringIsAppliedOnlyByComposer() throws {
        var layout = DualCameraLayout.default
        layout.style = .splitVertical
        layout.frontCaptureMirrored = true
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .black),
            frontImage: horizontalImage(left: .red, right: .blue),
            layout: layout,
            aspectRatio: .square
        )
        let composed = try XCTUnwrap(try? result.get())
        XCTAssertEqual(pixelColor(in: composed, at: CGPoint(x: 760, y: 720)).blueComponent, 1, accuracy: 0.03)
        XCTAssertEqual(pixelColor(in: composed, at: CGPoint(x: 1_400, y: 720)).redComponent, 1, accuracy: 0.03)
    }

    func testAspectFillCropsWideImageCenter() throws {
        var layout = DualCameraLayout.default
        layout.style = .splitVertical
        layout.frontCaptureMirrored = false
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .black),
            frontImage: threeBandImage(),
            layout: layout,
            aspectRatio: .threeByFour
        )
        let composed = try XCTUnwrap(try? result.get())
        XCTAssertGreaterThan(pixelColor(in: composed, at: CGPoint(x: 900, y: 720)).greenComponent, 0.9)
    }

    func testPictureInPictureCanRenderAtAllFourCorners() throws {
        for position in [
            NormalizedPoint(x: 0.035, y: 0.035),
            NormalizedPoint(x: 0.62, y: 0.035),
            NormalizedPoint(x: 0.035, y: 0.52),
            NormalizedPoint(x: 0.62, y: 0.52)
        ] {
            var layout = DualCameraLayout.default
            layout.pipPosition = position
            let result = PhotoComposer.composeSynchronously(
                backImage: image(color: .red),
                frontImage: image(color: .blue),
                layout: layout,
                aspectRatio: .threeByFour
            )
            let composed = try XCTUnwrap(try? result.get())
            let frame = DualCameraLayoutEngine.frames(
                in: CGRect(origin: .zero, size: composed.size),
                layout: layout
            ).front
            XCTAssertGreaterThan(pixelColor(in: composed, at: CGPoint(x: frame.midX, y: frame.midY)).blueComponent, 0.9)
        }
    }

    func testAllPIPSizesProduceIncreasingFrames() {
        let canvas = CGRect(x: 0, y: 0, width: 1_080, height: 1_440)
        let widths = PIPSize.allCases.map { size -> CGFloat in
            var layout = DualCameraLayout.default
            layout.pipSize = size
            return DualCameraLayoutEngine.frames(in: canvas, layout: layout).front.width
        }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, 3)
    }

    func testInvalidImageSizeFailsComposition() {
        let result = PhotoComposer.composeSynchronously(
            backImage: UIImage(),
            frontImage: image(color: .blue),
            layout: .default,
            aspectRatio: .threeByFour
        )
        guard case .failure(.compositionFailed) = result else {
            return XCTFail("无效图片应拒绝合成")
        }
    }

    func testComposerSupportsAllOutputRatios() throws {
        for ratio in CaptureAspectRatio.allCases {
            let result = PhotoComposer.composeSynchronously(
                backImage: image(color: .red),
                frontImage: image(color: .blue),
                layout: .default,
                aspectRatio: ratio
            )
            let composed = try XCTUnwrap(try? result.get())
            XCTAssertEqual(composed.size, DualCameraLayoutEngine.outputSize(for: ratio))
        }
    }

    /// 合成画布必须跟随后摄源图，而不是固定回 1440 长边。
    func testComposedImageFollowsBackImageResolution() throws {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1_536, height: 2_048)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_536, height: 2_048))
        }
        let result = PhotoComposer.composeSynchronously(
            backImage: large,
            frontImage: image(color: .blue),
            layout: .default,
            aspectRatio: .threeByFour
        )
        let composed = try XCTUnwrap(try? result.get())
        XCTAssertEqual(composed.size, CGSize(width: 1_536, height: 2_048))
    }

    func testHorizontalSplitPlacesFrontImageInBottomHalf() throws {
        var layout = DualCameraLayout.default
        layout.style = .splitHorizontal
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .red),
            frontImage: image(color: .blue),
            layout: layout,
            aspectRatio: .square
        )
        let composed = try XCTUnwrap(try? result.get())
        XCTAssertGreaterThan(pixelColor(in: composed, at: CGPoint(x: 720, y: 1_200)).blueComponent, 0.9)
    }

    func testPictureInPictureUsesRoundedClipAndWhiteBorder() throws {
        var layout = DualCameraLayout.default
        layout.frontCaptureMirrored = false
        let result = PhotoComposer.composeSynchronously(
            backImage: image(color: .red),
            frontImage: image(color: .blue),
            layout: layout,
            aspectRatio: .threeByFour
        )
        let composed = try XCTUnwrap(try? result.get())
        let frame = DualCameraLayoutEngine.frames(
            in: CGRect(origin: .zero, size: composed.size),
            layout: layout
        ).front
        let corner = pixelColor(in: composed, at: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
        let border = pixelColor(in: composed, at: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertGreaterThan(corner.redComponent, 0.9)
        XCTAssertGreaterThan(border.redComponent, 0.75)
        XCTAssertGreaterThan(border.greenComponent, 0.75)
        XCTAssertGreaterThan(border.blueComponent, 0.75)
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 160)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 160))
        }
    }

    private func horizontalImage(left: UIColor, right: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            left.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            right.setFill()
            context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
    }

    private func threeBandImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.green.setFill()
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 200, y: 0, width: 100, height: 100))
        }
    }

    private func pixelColor(in image: UIImage, at point: CGPoint) -> UIColor {
        guard let cgImage = image.cgImage else {
            XCTFail("无法读取测试图片像素")
            return .clear
        }
        let x = min(max(Int(point.x), 0), cgImage.width - 1)
        let y = min(max(Int(point.y), 0), cgImage.height - 1)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("无法创建像素测试上下文")
            return .clear
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let offset = y * cgImage.width * 4 + x * 4
        let red = CGFloat(bytes[offset]) / 255
        let green = CGFloat(bytes[offset + 1]) / 255
        let blue = CGFloat(bytes[offset + 2]) / 255
        let alpha = CGFloat(bytes[offset + 3]) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension UIColor {
    var redComponent: CGFloat {
        var value: CGFloat = 0
        getRed(&value, green: nil, blue: nil, alpha: nil)
        return value
    }

    var blueComponent: CGFloat {
        var value: CGFloat = 0
        getRed(nil, green: nil, blue: &value, alpha: nil)
        return value
    }

    var greenComponent: CGFloat {
        var value: CGFloat = 0
        getRed(nil, green: &value, blue: nil, alpha: nil)
        return value
    }
}
