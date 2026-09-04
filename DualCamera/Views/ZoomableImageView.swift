import SwiftUI

/// 查看页的照片显示层：支持双指缩放、双击切换、放大后拖动查看细节，
/// 未放大时下滑关闭。成片分辨率提升后，看清细节需要能放大。
struct ZoomableImageView: View {
    let image: UIImage
    let onDismiss: () -> Void

    private static let maximumScale: CGFloat = 6

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
    @State private var dismissOffset: CGFloat = 0

    private var effectiveScale: CGFloat { scale * gestureScale }
    private var isZoomed: Bool { effectiveScale > 1.01 }

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(effectiveScale)
                .offset(
                    x: offset.width + gestureOffset.width,
                    y: offset.height + gestureOffset.height + dismissOffset
                )
                .gesture(magnification(in: proxy.size))
                .simultaneousGesture(drag(in: proxy.size))
                .onTapGesture(count: 2) { toggleZoom(in: proxy.size) }
        }
        .opacity(dismissProgressOpacity)
    }

    /// 下滑越远越透明，给出「即将关闭」的即时反馈。
    private var dismissProgressOpacity: Double {
        guard dismissOffset > 0 else { return 1 }
        return max(0.35, 1 - Double(dismissOffset) / 400)
    }

    private func magnification(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in gestureScale = value.magnification }
            .onEnded { _ in
                scale = min(max(scale * gestureScale, 1), Self.maximumScale)
                gestureScale = 1
                clampOffset(in: size)
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomed {
                    gestureOffset = value.translation
                } else if value.translation.height > 0 {
                    // 未放大时下滑关闭；上滑不做处理，避免与其他手势抢占。
                    dismissOffset = value.translation.height
                }
            }
            .onEnded { value in
                if isZoomed {
                    offset.width += gestureOffset.width
                    offset.height += gestureOffset.height
                    gestureOffset = .zero
                    clampOffset(in: size)
                    return
                }
                // 位移或速度任一足够即关闭，快速轻扫也能生效。
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func toggleZoom(in size: CGSize) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if isZoomed {
                scale = 1
                offset = .zero
            } else {
                scale = 3
            }
        }
    }

    /// 把图片留在可视范围内，避免拖到完全看不见。
    private func clampOffset(in size: CGSize) {
        guard scale > 1 else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = .zero }
            return
        }
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            offset.width = min(max(offset.width, -maxX), maxX)
            offset.height = min(max(offset.height, -maxY), maxY)
        }
    }
}
