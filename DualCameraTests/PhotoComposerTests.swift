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

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 160)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 160))
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
        let offset = (cgImage.height - y - 1) * cgImage.width * 4 + x * 4
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
}
