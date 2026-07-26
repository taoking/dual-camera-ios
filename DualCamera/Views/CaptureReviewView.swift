import SwiftUI

struct CaptureReviewView: View {
    let photoSet: CapturedPhotoSet
    let isSaving: Bool
    let saveMode: PhotoSaveMode
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: photoSet.composedImage)
                .resizable()
                .scaledToFit()
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
                    .disabled(isSaving)

                    Button(action: onSave) {
                        Label(isSaving ? "正在保存…" : "保存并继续拍摄", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ReviewActionButtonStyle(primary: true))
                    .disabled(isSaving)
                }
                Text(saveMode == .composedOnly ? "将保存合成照片" : "将保存合成照片、前摄原图和后摄原图")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.bottom, 30)
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
