import AVFoundation
import SwiftUI

struct DualCameraPreview: UIViewRepresentable {
    let camera: DualCameraController

    func makeUIView(context: Context) -> DualCameraPreviewView {
        let view = DualCameraPreviewView()
        view.install(backLayer: camera.backPreviewLayer, frontLayer: camera.frontPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: DualCameraPreviewView, context: Context) {}
}

final class DualCameraPreviewView: UIView {
    private var backLayer: AVCaptureVideoPreviewLayer?
    private var frontLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        nil
    }

    func install(backLayer: AVCaptureVideoPreviewLayer, frontLayer: AVCaptureVideoPreviewLayer) {
        self.backLayer?.removeFromSuperlayer()
        self.frontLayer?.removeFromSuperlayer()

        self.backLayer = backLayer
        self.frontLayer = frontLayer

        layer.addSublayer(backLayer)
        layer.addSublayer(frontLayer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        backLayer?.frame = bounds

        let width = min(bounds.width * 0.34, 154)
        let height = width * 1.34
        let inset: CGFloat = 18
        let frame = CGRect(
            x: bounds.maxX - width - inset,
            y: bounds.maxY - height - inset - safeAreaInsets.bottom,
            width: width,
            height: height
        )
        frontLayer?.frame = frame
        frontLayer?.cornerRadius = 18
        frontLayer?.masksToBounds = true
        frontLayer?.borderWidth = 2
        frontLayer?.borderColor = UIColor.white.withAlphaComponent(0.82).cgColor

        CATransaction.commit()
    }
}
