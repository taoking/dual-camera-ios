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
                onZoomEnded: camera.endZoomGesture,
                onFocusLockToggle: camera.toggleFocusLock
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

            if camera.exposureBiasRange.lowerBound < camera.exposureBiasRange.upperBound {
                ExposureBiasSlider(
                    value: camera.exposureBias,
                    range: camera.exposureBiasRange,
                    isLocked: camera.focusLockState == .locked,
                    onChange: camera.setExposureBias
                )
            }

            VStack {
                Spacer()
                CameraStatusView(
                    notice: camera.notice,
                    state: camera.state,
                    onAction: camera.performStatusAction
                )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 126)
            }

            if camera.countdownRemaining > 0 {
                // 整屏可点：倒计时中最需要的操作就是立刻取消。
                Button(action: camera.cancelCountdown) {
                    ZStack {
                        Color.black.opacity(0.001)
                        VStack(spacing: 10) {
                            Text("\(camera.countdownRemaining)")
                                .font(.system(size: 96, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .shadow(radius: 8)
                            Text("点按取消")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(.plain)
                .ignoresSafeArea()
                .accessibilityLabel("倒计时 \(camera.countdownRemaining) 秒，点按取消")
                .accessibilityIdentifier("countdown-cancel")
            }

            if camera.isMediaReviewPresented, let photoSet = camera.latestPhotoSet {
                CaptureReviewView(
                    photoSet: photoSet,
                    saveState: camera.mediaSaveState,
                    saveMode: photoSet.saveMode,
                    onDismiss: camera.dismissMediaReview,
                    onSave: camera.saveLatestPhoto,
                    onShare: {
                        shareImage = photoSet.composedImage
                        isSharePresented = true
                    }
                )
            }

            if camera.isMediaReviewPresented, let videoURL = camera.latestVideoURL {
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
                camera.performStatusAction(.openAppSettings, notice: camera.notice)
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
            Button(action: camera.dismissMediaReview) {
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
                VStack(spacing: 12) {
                    Label(videoSaveStatusText, systemImage: videoSaveStatusSymbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.62), in: Capsule())

                    if camera.mediaSaveState.canRetry {
                        Button(action: camera.saveLatestVideo) {
                            Label("重试保存", systemImage: "arrow.clockwise")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.blue.opacity(0.82), in: Capsule())
                        }
                        .accessibilityIdentifier("video-save")
                    }
                }
            }
            .padding(.bottom, 30)
        }
    }

    private var videoSaveStatusText: String {
        switch camera.mediaSaveState {
        case .idle: "等待后台保存"
        case .saving: "正在后台保存，实时预览不受影响"
        case .saved: "视频已保存到系统相册"
        case .failed: "视频保存失败，可重试"
        }
    }

    private var videoSaveStatusSymbol: String {
        switch camera.mediaSaveState {
        case .idle: "clock"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

#Preview {
    ContentView()
}
