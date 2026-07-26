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
                onZoomBegan: camera.beginZoomGesture,
                onZoom: camera.zoomBackCamera,
                onZoomEnded: camera.endZoomGesture
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
            if ProcessInfo.processInfo.arguments.contains("-fakeShareSheet") {
                Text("Fake 分享面板")
                    .font(.headline)
                    .accessibilityIdentifier("fake-share-sheet")
                    .presentationDetents([.medium])
            } else if let shareImage {
                ShareSheet(items: [shareImage])
            }
        }
        .alert("需要系统权限", isPresented: $camera.showsPhotoPermissionSettings) {
            Button("去设置") {
                camera.openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(camera.settingsAlertMessage)
        }
    }

    private func videoReview(url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ManagedVideoPlayer(url: url).ignoresSafeArea()
            Button(action: camera.dismissLatestVideo) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .accessibilityIdentifier("video-review-close")
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
                .accessibilityIdentifier("video-save")
            }
            .padding(.bottom, 30)
        }
    }
}

#Preview {
    ContentView()
}
