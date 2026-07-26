import AVFoundation
import UIKit

enum FakeCameraFactory {
    static func sourcePhoto(
        position: AVCaptureDevice.Position,
        color: UIColor,
        label: String
    ) -> CapturedSourcePhoto {
        let size = CGSize(width: 720, height: 1_280)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 54, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.86)
            ]
            let text = NSString(string: label)
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
        return CapturedSourcePhoto(
            originalData: image.jpegData(compressionQuality: 1),
            image: image,
            position: position
        )
    }
}
