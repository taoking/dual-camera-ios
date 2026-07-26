import AVKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraViewModel()
    @State private var shareImage: UIImage?
    @State private var isSharePresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DualCameraPreview(
                camera: camera.sessionController,
                layout: camera.layout,
                aspectRatio: camera.aspectRatio,
                gridEnabled: camera.gridEnabled,
                isFakeCamera: camera.isFakeCamera,
                onPIPFrameChanged: { frame, canvas, snap in
                    camera.updatePIPFrame(frame, in: canvas, snap: snap)
                },
                onPIPSizeChanged: camera.setPIPSize,
                onFocus: camera.focusAndExpose,
                onZoom: camera.zoomBackCamera
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.56), .clear, .black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            CameraControlsView(camera: camera)

            VStack {
                Spacer()
                CameraStatusView(notice: camera.notice, state: camera.state)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 126)
            }
            .allowsHitTesting(false)

            if camera.countdownRemaining > 0 {
                Text("\(camera.countdownRemaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .accessibilityLabel("倒计时 \(camera.countdownRemaining) 秒")
            }

            if let photoSet = camera.latestPhotoSet {
                CaptureReviewView(
                    photoSet: photoSet,
                    isSaving: camera.isSavingMedia,
                    saveMode: camera.saveMode,
                    onDismiss: camera.dismissLatestPhoto,
                    onSave: camera.saveLatestPhoto,
                    onShare: {
                        shareImage = photoSet.composedImage
                        isSharePresented = true
                    }
                )
            }

            if let videoURL = camera.latestVideoURL {
                videoReview(url: videoURL)
            }
        }
        .onAppear(perform: camera.start)
        .onDisappear(perform: camera.stop)
        .onChange(of: scenePhase) { _, newPhase in
            camera.handleScenePhase(newPhase)
        }
        .sheet(isPresented: $isSharePresented) {
            if let shareImage {
                ShareSheet(items: [shareImage])
            }
        }
        .alert("需要“添加照片”权限", isPresented: $camera.showsPhotoPermissionSettings) {
            Button("去设置") {
                camera.openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许双摄相机添加照片，然后再保存。")
        }
    }

    private func videoReview(url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            Button(action: camera.dismissLatestVideo) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
            VStack {
                Spacer()
                Button(action: camera.saveLatestVideo) {
                    Label(camera.isSavingMedia ? "正在保存…" : "保存并继续拍摄", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.blue.opacity(0.82), in: Capsule())
                }
                .disabled(camera.isSavingMedia)
            }
            .padding(.bottom, 30)
        }
    }
}

#Preview {
    ContentView()
}
