import AVFoundation
import SwiftUI

/// 共享布局引擎的双路实时预览与触控层。
struct DualCameraPreview: UIViewRepresentable {
    let camera: MultiCamSessionController
    let layout: DualCameraLayout
    let aspectRatio: CaptureAspectRatio
    let gridEnabled: Bool
    let isFakeCamera: Bool
    let onPIPFrameChanged: (CGRect, CGRect, Bool) -> Void
    let onPIPSizeChanged: (PIPSize) -> Void
    let onFocus: (CGPoint) -> Void
    let onZoomBegan: () -> Void
    let onZoom: (CGFloat) -> Void
    let onZoomEnded: () -> Void

    func makeUIView(context: Context) -> DualCameraPreviewView {
        let view = DualCameraPreviewView()
        view.install(backLayer: camera.backPreviewLayer, frontLayer: camera.frontPreviewLayer)
        view.onPIPFrameChanged = onPIPFrameChanged
        view.onPIPSizeChanged = onPIPSizeChanged
        view.onFocus = onFocus
        view.onZoomBegan = onZoomBegan
        view.onZoom = onZoom
        view.onZoomEnded = onZoomEnded
        return view
    }

    func updateUIView(_ uiView: DualCameraPreviewView, context: Context) {
        uiView.onPIPFrameChanged = onPIPFrameChanged
        uiView.onPIPSizeChanged = onPIPSizeChanged
        uiView.onFocus = onFocus
        uiView.onZoomBegan = onZoomBegan
        uiView.onZoom = onZoom
        uiView.onZoomEnded = onZoomEnded
        uiView.update(
            layout: layout,
            aspectRatio: aspectRatio,
            gridEnabled: gridEnabled,
            isFakeCamera: isFakeCamera
        )
    }
}

final class DualCameraPreviewView: UIView {
    private var backLayer: AVCaptureVideoPreviewLayer?
    private var frontLayer: AVCaptureVideoPreviewLayer?
    private let backPlaceholderLayer = CAGradientLayer()
    private let frontPlaceholderLayer = CAGradientLayer()
    private let gridLayer = CAShapeLayer()
    private let focusLayer = CAShapeLayer()

    private var currentLayout = DualCameraLayout.default
    private var currentAspectRatio: CaptureAspectRatio = .threeByFour
    private var currentFrames = DualCameraFrames(canvas: .zero, back: .zero, front: .zero)
    private var fakeCameraEnabled = false
    private var panInitialFrame = CGRect.zero
    private var pinchControlsPIP = false

    var onPIPFrameChanged: ((CGRect, CGRect, Bool) -> Void)?
    var onPIPSizeChanged: ((PIPSize) -> Void)?
    var onFocus: ((CGPoint) -> Void)?
    var onZoomBegan: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onZoomEnded: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black

        backPlaceholderLayer.colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor]
        frontPlaceholderLayer.colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor]
        backPlaceholderLayer.isHidden = true
        frontPlaceholderLayer.isHidden = true
        layer.addSublayer(backPlaceholderLayer)
        layer.addSublayer(frontPlaceholderLayer)

        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.42).cgColor
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 1
        layer.addSublayer(gridLayer)

        focusLayer.strokeColor = UIColor.systemYellow.cgColor
        focusLayer.fillColor = UIColor.clear.cgColor
        focusLayer.lineWidth = 2
        focusLayer.isHidden = true
        layer.addSublayer(focusLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func install(backLayer: AVCaptureVideoPreviewLayer, frontLayer: AVCaptureVideoPreviewLayer) {
        self.backLayer?.removeFromSuperlayer()
        self.frontLayer?.removeFromSuperlayer()
        self.backLayer = backLayer
        self.frontLayer = frontLayer
        layer.insertSublayer(backLayer, above: backPlaceholderLayer)
        layer.insertSublayer(frontLayer, above: backLayer)
        setNeedsLayout()
    }

    func update(
        layout: DualCameraLayout,
        aspectRatio: CaptureAspectRatio,
        gridEnabled: Bool,
        isFakeCamera: Bool
    ) {
        currentLayout = layout
        currentAspectRatio = aspectRatio
        fakeCameraEnabled = isFakeCamera
        gridLayer.isHidden = !gridEnabled
        backLayer?.isHidden = isFakeCamera
        frontLayer?.isHidden = isFakeCamera
        backPlaceholderLayer.isHidden = !isFakeCamera
        frontPlaceholderLayer.isHidden = !isFakeCamera
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let canvas = DualCameraLayoutEngine.aspectFitCanvas(in: bounds, aspectRatio: currentAspectRatio)
        currentFrames = DualCameraLayoutEngine.frames(in: canvas, layout: currentLayout)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backLayer?.frame = currentFrames.back
        frontLayer?.frame = currentFrames.front
        backPlaceholderLayer.frame = currentFrames.back
        frontPlaceholderLayer.frame = currentFrames.front

        let radius = currentLayout.style == .pictureInPicture
            ? currentFrames.front.width * currentLayout.cornerRadiusRatio
            : 0
        frontLayer?.cornerRadius = radius
        frontLayer?.masksToBounds = true
        frontLayer?.borderWidth = max(1.5, currentFrames.canvas.width * currentLayout.borderRatio)
        frontLayer?.borderColor = UIColor.white.withAlphaComponent(0.84).cgColor
        frontPlaceholderLayer.cornerRadius = radius
        frontPlaceholderLayer.masksToBounds = true
        frontPlaceholderLayer.borderWidth = max(1.5, currentFrames.canvas.width * currentLayout.borderRatio)
        frontPlaceholderLayer.borderColor = UIColor.white.withAlphaComponent(0.84).cgColor
        drawGrid(in: currentFrames.canvas)
        CATransaction.commit()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard currentLayout.style == .pictureInPicture else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard currentFrames.front.contains(location) else {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
            panInitialFrame = currentFrames.front
        case .changed, .ended, .cancelled:
            let translation = gesture.translation(in: self)
            let proposed = panInitialFrame.offsetBy(dx: translation.x, dy: translation.y)
            let shouldSnap = gesture.state == .ended || gesture.state == .cancelled
            onPIPFrameChanged?(proposed, currentFrames.canvas, shouldSnap)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: self)
        if gesture.state == .began {
            pinchControlsPIP = currentLayout.style == .pictureInPicture && currentFrames.front.contains(location)
            if !pinchControlsPIP {
                onZoomBegan?()
            }
        }
        if pinchControlsPIP {
            if gesture.state == .ended {
                onPIPSizeChanged?(PIPSize.closest(to: currentLayout.pipSize.widthRatio * gesture.scale))
            }
        } else {
            if gesture.state == .changed {
                onZoom?(gesture.scale)
            } else if gesture.state == .ended || gesture.state == .cancelled {
                onZoomEnded?()
            }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // 前摄画面不承接后摄的对焦／测光手势；分屏时同样如此。
        guard currentFrames.back.contains(point), !currentFrames.front.contains(point) else {
            return
        }
        let devicePoint = backLayer?.captureDevicePointConverted(fromLayerPoint: point) ?? CGPoint(x: 0.5, y: 0.5)
        showFocusIndicator(at: point)
        onFocus?(devicePoint)
    }

    private func drawGrid(in canvas: CGRect) {
        guard !gridLayer.isHidden else { return }
        let path = UIBezierPath()
        for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            let x = canvas.minX + canvas.width * fraction
            path.move(to: CGPoint(x: x, y: canvas.minY))
            path.addLine(to: CGPoint(x: x, y: canvas.maxY))
            let y = canvas.minY + canvas.height * fraction
            path.move(to: CGPoint(x: canvas.minX, y: y))
            path.addLine(to: CGPoint(x: canvas.maxX, y: y))
        }
        gridLayer.path = path.cgPath
    }

    private func showFocusIndicator(at point: CGPoint) {
        let frame = CGRect(x: point.x - 34, y: point.y - 34, width: 68, height: 68)
        focusLayer.path = UIBezierPath(rect: frame).cgPath
        focusLayer.isHidden = false
        focusLayer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.8
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        focusLayer.add(animation, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.focusLayer.isHidden = true
        }
    }
}
