import CoreGraphics

struct DualCameraFrames: Equatable {
    let canvas: CGRect
    let back: CGRect
    let front: CGRect
}

enum DualCameraLayoutEngine {
    /// 源图尺寸不可用时的兜底画布长边。
    static let fallbackLongEdge: CGFloat = 1_440
    /// 画布长边上限。合成位图按 4 字节/像素常驻，再高的画布对观感提升有限，
    /// 却会显著抬高内存峰值与 JPEG 编码耗时。
    static let maximumLongEdge: CGFloat = 4_032

    static func outputSize(for aspectRatio: CaptureAspectRatio, longEdge: CGFloat = fallbackLongEdge) -> CGSize {
        let clamped = min(max(longEdge.rounded(), fallbackLongEdge), maximumLongEdge)
        let width = (clamped * aspectRatio.ratio).rounded()
        return CGSize(width: width, height: clamped)
    }

    /// 由后摄源图推导画布长边。后摄在三种布局里都是铺满或半幅的底图，
    /// 以它为准可以让成片接近 1:1 呈现相机实际输出，而不是被固定画布压缩。
    ///
    /// 画布按 aspectFill 裁切源图，缩放系数取 `max(画布宽/源宽, 画布高/源高)`。
    /// 只用源图长边会让窄画幅之外的比例发生上采样：例如 3024×4032 的源图配 1:1 画布
    /// 会得到 4032×4032，宽度方向被放大 1.33 倍，凭空插值而没有真实细节。
    /// 因此长边还要受 `源图短边 / 画幅比` 约束，保证任何画幅都不会上采样。
    static func outputSize(for aspectRatio: CaptureAspectRatio, sourceSize: CGSize) -> CGSize {
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        let sourceShortEdge = min(sourceSize.width, sourceSize.height)
        guard sourceLongEdge > 0, sourceShortEdge > 0, aspectRatio.ratio > 0 else {
            return outputSize(for: aspectRatio)
        }
        let widthLimitedLongEdge = sourceShortEdge / aspectRatio.ratio
        return outputSize(for: aspectRatio, longEdge: min(sourceLongEdge, widthLimitedLongEdge))
    }

    static func aspectFitCanvas(in bounds: CGRect, aspectRatio: CaptureAspectRatio) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let targetRatio = aspectRatio.ratio
        let boundsRatio = bounds.width / bounds.height
        if boundsRatio > targetRatio {
            let width = bounds.height * targetRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        }
        let height = bounds.width / targetRatio
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    static func frames(
        in canvas: CGRect,
        layout: DualCameraLayout
    ) -> DualCameraFrames {
        switch layout.style {
        case .pictureInPicture:
            let front = pipFrame(in: canvas, layout: layout)
            return DualCameraFrames(canvas: canvas, back: canvas, front: front)
        case .splitVertical:
            let halfWidth = canvas.width / 2
            return DualCameraFrames(
                canvas: canvas,
                back: CGRect(x: canvas.minX, y: canvas.minY, width: halfWidth, height: canvas.height),
                front: CGRect(x: canvas.midX, y: canvas.minY, width: halfWidth, height: canvas.height)
            )
        case .splitHorizontal:
            let halfHeight = canvas.height / 2
            return DualCameraFrames(
                canvas: canvas,
                back: CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: halfHeight),
                front: CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: halfHeight)
            )
        }
    }

    static func pipFrame(in canvas: CGRect, layout: DualCameraLayout) -> CGRect {
        let width = canvas.width * layout.pipSize.widthRatio
        let height = width * 4.0 / 3.0
        let constrained = constrainedPipPosition(
            layout.pipPosition,
            size: CGSize(width: width, height: height),
            canvasSize: canvas.size
        )
        return CGRect(
            x: canvas.minX + constrained.x * canvas.width,
            y: canvas.minY + constrained.y * canvas.height,
            width: width,
            height: height
        )
    }

    static func layout(
        _ layout: DualCameraLayout,
        movingPipTo frame: CGRect,
        in canvas: CGRect,
        snap: Bool
    ) -> DualCameraLayout {
        guard layout.style == .pictureInPicture, canvas.width > 0, canvas.height > 0 else { return layout }
        var updated = layout
        let candidate = NormalizedPoint(
            x: (frame.minX - canvas.minX) / canvas.width,
            y: (frame.minY - canvas.minY) / canvas.height
        )
        let constrained = constrainedPipPosition(candidate, size: frame.size, canvasSize: canvas.size)
        updated.pipPosition = snap ? snappedPipPosition(constrained, size: frame.size, canvasSize: canvas.size) : constrained
        return updated
    }

    static func layout(_ layout: DualCameraLayout, resizingPipTo size: PIPSize) -> DualCameraLayout {
        var updated = layout
        updated.pipSize = size
        let visualSize = CGSize(width: size.widthRatio, height: size.widthRatio * 4.0 / 3.0)
        updated.pipPosition = constrainedPipPosition(updated.pipPosition, size: visualSize, canvasSize: .init(width: 1, height: 1))
        return updated
    }

    static func constrainedPipPosition(
        _ position: NormalizedPoint,
        size: CGSize,
        canvasSize: CGSize = CGSize(width: 1, height: 1)
    ) -> NormalizedPoint {
        let width = size.width / max(canvasSize.width, 0.0001)
        let height = size.height / max(canvasSize.height, 0.0001)
        let inset: CGFloat = 0.035
        return NormalizedPoint(
            x: min(max(position.x, inset), max(inset, 1 - width - inset)),
            y: min(max(position.y, inset), max(inset, 1 - height - inset))
        )
    }

    static func snappedPipPosition(
        _ position: NormalizedPoint,
        size: CGSize,
        canvasSize: CGSize
    ) -> NormalizedPoint {
        let constrained = constrainedPipPosition(position, size: size, canvasSize: canvasSize)
        let width = size.width / canvasSize.width
        let height = size.height / canvasSize.height
        let inset: CGFloat = 0.035
        let left = inset
        let right = max(inset, 1 - width - inset)
        let top = inset
        let bottom = max(inset, 1 - height - inset)
        return NormalizedPoint(
            x: abs(constrained.x - left) < abs(constrained.x - right) ? left : right,
            y: abs(constrained.y - top) < abs(constrained.y - bottom) ? top : bottom
        )
    }
}
