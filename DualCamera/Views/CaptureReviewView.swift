import SwiftUI

struct CaptureReviewView: View {
    let photoSet: CapturedPhotoSet
    let saveState: MediaSaveState
    let saveMode: PhotoSaveMode
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: photoSet.composedImage, onDismiss: onDismiss)
                .padding(18)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
            .accessibilityLabel("关闭照片预览")
            .accessibilityIdentifier("photo-review-close")

            VStack(spacing: 10) {
                Spacer()
                Text("\(photoSet.layout.style.title) · \(photoSet.aspectRatio.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())

                HStack(spacing: 12) {
                    Button(action: onShare) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(ReviewActionButtonStyle())
                    .accessibilityIdentifier("photo-share")

                    if saveState.canRetry {
                        Button(action: onSave) {
                            Label("重试保存", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(ReviewActionButtonStyle(primary: true))
                        .accessibilityIdentifier("photo-save")
                    }
                }
                Text(saveStatusText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.bottom, 30)
        }
    }

    private var saveStatusText: String {
        let content = saveMode == .composedOnly ? "合成照片" : "合成照片及前后摄原图"
        switch saveState {
        case .idle:
            return "等待保存\(content)"
        case .saving:
            return "正在后台保存\(content)，实时预览不受影响"
        case .saved:
            return "\(content)已保存到系统相册"
        case .failed:
            return "保存失败，可重试"
        }
    }
}

private struct ReviewActionButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(primary ? Color.blue.opacity(0.82) : Color.black.opacity(0.58), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
