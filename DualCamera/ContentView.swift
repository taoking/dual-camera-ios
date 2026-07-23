import SwiftUI

struct ContentView: View {
    @StateObject private var camera = DualCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DualCameraPreview(camera: camera)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()

                if let message = camera.state.message {
                    statusMessage(message)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }

                shutterBar
            }
            .padding(.top, 12)
            .padding(.bottom, 28)

            if let photo = camera.latestPhoto {
                capturedPhoto(photo)
            }
        }
        .onAppear(perform: camera.start)
        .onDisappear(perform: camera.stop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("后置广角", systemImage: "camera")
            Spacer()
            Label("前置", systemImage: "person.crop.circle")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.28), in: Capsule())
        .padding(.horizontal, 18)
    }

    private var shutterBar: some View {
        HStack {
            Button {
                camera.dismissLatestPhoto()
            } label: {
                Image(systemName: "photo")
                    .font(.title2)
                    .frame(width: 48, height: 48)
            }
            .opacity(camera.latestPhoto == nil ? 0 : 1)
            .disabled(camera.latestPhoto == nil)

            Spacer()

            Button(action: camera.capturePhoto) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 5)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                        .scaleEffect(camera.isCapturing ? 0.78 : 1)
                }
            }
            .disabled(!camera.state.isReady || camera.isCapturing)
            .accessibilityLabel("同时拍摄前后摄像头")

            Spacer()

            Color.clear
                .frame(width: 48, height: 48)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
    }

    private func statusMessage(_ message: String) -> some View {
        Label(message, systemImage: camera.state.symbolName)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
    }

    private func capturedPhoto(_ photo: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .padding(18)

            Button(action: camera.dismissLatestPhoto) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
            .accessibilityLabel("关闭照片预览")
        }
    }
}

#Preview {
    ContentView()
}
