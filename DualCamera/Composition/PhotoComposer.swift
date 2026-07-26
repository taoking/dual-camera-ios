import UIKit

final class PhotoComposer {
    private let queue = DispatchQueue(label: "dual.camera.composition", qos: .userInitiated)

    func compose(
        backImage: UIImage,
        frontImage: UIImage,
        layout: DualCameraLayout,
        aspectRatio: CaptureAspectRatio,
        completion: @escaping (Result<UIImage, CameraError>) -> Void
    ) {
        queue.async {
            let result = Self.composeSynchronously(
                backImage: backImage,
                frontImage: frontImage,
                layout: layout,
                aspectRatio: aspectRatio
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func composeSynchronously(
        backImage: UIImage,
        frontImage: UIImage,
        layout: DualCameraLayout,
        aspectRatio: CaptureAspectRatio
    ) -> Result<UIImage, CameraError> {
        guard backImage.size.width > 0, backImage.size.height > 0,
              frontImage.size.width > 0, frontImage.size.height > 0 else {
            return .failure(.compositionFailed("无法读取前后摄照片尺寸。"))
        }

        let outputSize = DualCameraLayoutEngine.outputSize(for: aspectRatio)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: rendererFormat)
        let frames = DualCameraLayoutEngine.frames(in: CGRect(origin: .zero, size: outputSize), layout: layout)

        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            drawAspectFill(backImage, in: frames.back, mirrored: false, context: context)

            context.cgContext.saveGState()
            if layout.style == .pictureInPicture {
                let radius = frames.front.width * layout.cornerRadiusRatio
                UIBezierPath(roundedRect: frames.front, cornerRadius: radius).addClip()
            } else {
                context.cgContext.clip(to: frames.front)
            }
            drawAspectFill(
                frontImage,
                in: frames.front,
                mirrored: layout.frontCaptureMirrored,
                context: context
            )
            context.cgContext.restoreGState()

            UIColor.white.withAlphaComponent(0.9).setStroke()
            let border = UIBezierPath(
                roundedRect: frames.front,
                cornerRadius: layout.style == .pictureInPicture ? frames.front.width * layout.cornerRadiusRatio : 0
            )
            border.lineWidth = max(2, outputSize.width * layout.borderRatio)
            border.stroke()
        }
        return .success(image)
    }

    private static func drawAspectFill(
        _ image: UIImage,
        in rect: CGRect,
        mirrored: Bool,
        context: UIGraphicsImageRendererContext
    ) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageRect = CGRect(
            x: rect.midX - scaledSize.width / 2,
            y: rect.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
        context.cgContext.saveGState()
        context.cgContext.clip(to: rect)
        if mirrored {
            context.cgContext.translateBy(x: rect.midX * 2, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
        }
        image.draw(in: imageRect)
        context.cgContext.restoreGState()
    }
}

extension UIImage {
    var dualCameraNormalized: UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
