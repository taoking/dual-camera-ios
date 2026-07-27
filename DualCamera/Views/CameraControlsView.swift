import SwiftUI

struct CameraControlsView: View {
    @ObservedObject var camera: CameraViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if camera.videoState.statusTitle != nil {
                recordingStatus
                    .padding(.top, 12)
            }
            Spacer()
            controls
        }
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    private var header: some View {
        HStack(spacing: 10) {
            rearCameraMenu
            layoutMenu
            Spacer()
            settingsMenu
            Text(zoomLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.black.opacity(0.34), in: Capsule())
        }
        .padding(.horizontal, 18)
    }

    private var rearCameraMenu: some View {
        Menu {
            ForEach(camera.availableRearCameras) { option in
                Button {
                    camera.selectRearCamera(option)
                } label: {
                    Label("\(option.zoomLabel) \(option.title)", systemImage: option.symbolName)
                }
            }
        } label: {
            Label("\(camera.selectedRearCamera.zoomLabel)", systemImage: camera.selectedRearCamera.symbolName)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.34), in: Capsule())
        }
        .disabled(camera.availableRearCameras.isEmpty || camera.isCapturing || camera.isRecording || !camera.state.isReady)
        .accessibilityLabel("选择后置摄像头")
    }

    private var layoutMenu: some View {
        Menu {
            Section("双摄布局") {
                ForEach(DualCameraLayoutStyle.allCases) { style in
                    Button {
                        camera.setLayoutStyle(style)
                    } label: {
                        Label(style.title, systemImage: style.symbolName)
                    }
                }
            }
            Section("输出画幅") {
                ForEach(CaptureAspectRatio.allCases) { ratio in
                    Button(ratio.title) { camera.setAspectRatio(ratio) }
                }
            }
            if camera.layout.style == .pictureInPicture {
                Section("画中画大小") {
                    ForEach(PIPSize.allCases) { size in
                        Button(size.title) { camera.setPIPSize(size) }
                    }
                }
            }
        } label: {
            Image(systemName: camera.layout.style.symbolName)
                .foregroundStyle(.white)
                .padding(9)
                .background(.black.opacity(0.34), in: Circle())
        }
        .disabled(camera.isCapturing || camera.isRecording)
        .accessibilityLabel("选择双摄布局与输出画幅")
        .accessibilityIdentifier("layout-menu")
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("九宫格", isOn: Binding(
                get: { camera.gridEnabled },
                set: camera.setGridEnabled
            ))
            Toggle("前摄预览镜像", isOn: Binding(
                get: { camera.layout.frontPreviewMirrored },
                set: camera.setFrontPreviewMirrored
            ))
            Toggle("前摄成片镜像", isOn: Binding(
                get: { camera.layout.frontCaptureMirrored },
                set: camera.setFrontCaptureMirrored
            ))
            Section("保存模式") {
                ForEach(PhotoSaveMode.allCases) { mode in
                    Button(mode.title) { camera.setSaveMode(mode) }
                }
            }
            Section("拍照质量") {
                ForEach(CaptureQuality.allCases) { quality in
                    Button(quality.title) { camera.setCaptureQuality(quality) }
                }
            }
            Section("倒计时") {
                ForEach([0, 3, 5, 10], id: \.self) { seconds in
                    Button(seconds == 0 ? "关闭" : "\(seconds) 秒") { camera.setTimerSeconds(seconds) }
                }
            }
            Section("诊断") {
                Text("\(camera.diagnostics.backFormat) / \(camera.diagnostics.frontFormat)")
                Text(String(format: "%.0f fps · 硬件 %.2f · 压力 %.2f", camera.diagnostics.frameRate, camera.diagnostics.hardwareCost, camera.diagnostics.systemPressureCost))
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.white)
                .padding(9)
                .background(.black.opacity(0.34), in: Circle())
        }
        .disabled(camera.isCapturing || camera.isRecording)
        .accessibilityLabel("相机设置")
        .accessibilityIdentifier("settings-menu")
    }

    private var controls: some View {
        HStack(alignment: .center) {
            recentMediaControl
                .frame(width: 68, height: 58)
            Spacer()
            Button(action: primaryAction) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 76, height: 76)
                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 34, height: 34)
                    } else {
                        Circle().fill(.white).frame(width: 62, height: 62).scaleEffect(camera.isCapturing ? 0.78 : 1)
                    }
                }
            }
            .disabled((!camera.state.isReady || camera.isCapturing || camera.countdownRemaining > 0) && !camera.isRecording)
            .accessibilityLabel(camera.isRecording ? "停止视频录制" : "同时拍摄前后摄像头")
            .accessibilityIdentifier("photo-shutter")
            Spacer()
            Button(action: camera.startRecording) {
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 48, height: 48)
                    Circle().fill(.red).frame(width: 18, height: 18)
                }
            }
            .disabled(
                !camera.state.isReady
                    || camera.isCapturing
                    || camera.videoState.preventsNewRecording
                    || camera.countdownRemaining > 0
            )
            .accessibilityLabel("开始双摄视频录制")
            .accessibilityIdentifier("video-record")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.black.opacity(0.3), in: Capsule())
        .padding(.horizontal, 18)
    }

    private var zoomLabel: String {
        String(format: "%.1f×", camera.zoomFactor)
    }

    private var recordingStatus: some View {
        HStack(spacing: 8) {
            if camera.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            }
            Text(camera.videoState.statusTitle ?? "")
                .accessibilityIdentifier("recording-status")
            if camera.isRecording || camera.videoState == .finishing {
                Text(formattedDuration)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .accessibilityIdentifier("recording-duration")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.58), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var recentMediaControl: some View {
        if camera.latestPhotoSet != nil || camera.latestVideoURL != nil {
            Button(action: camera.presentLatestMedia) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = camera.latestPhotoSet?.composedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [.indigo.opacity(0.9), .black],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "play.fill")
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.9), lineWidth: 2))

                    saveStateBadge
                        .offset(x: 5, y: -5)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                camera.isCapturing
                    || camera.videoState.preventsNewRecording
                    || camera.countdownRemaining > 0
            )
            .accessibilityLabel(camera.latestPhotoSet == nil ? "查看最近视频" : "查看最近照片")
            .accessibilityValue(recentMediaSaveAccessibilityValue)
            .accessibilityIdentifier("recent-media")
        } else {
            Label(
                camera.isFakeCamera ? "模拟" : "双摄",
                systemImage: camera.isFakeCamera ? "testtube.2" : "camera.on.rectangle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    @ViewBuilder
    private var saveStateBadge: some View {
        switch camera.mediaSaveState {
        case .saving:
            ProgressView()
                .tint(.white)
                .padding(4)
                .background(.black.opacity(0.72), in: Circle())
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green, .white)
                .background(.black.opacity(0.72), in: Circle())
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red, .white)
                .background(.black.opacity(0.72), in: Circle())
        case .idle:
            EmptyView()
        }
    }

    private var formattedDuration: String {
        let totalSeconds = max(0, Int(camera.recordingDuration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var recentMediaSaveAccessibilityValue: String {
        switch camera.mediaSaveState {
        case .idle: "等待保存"
        case .saving: "正在后台保存"
        case .saved: "已保存"
        case .failed: "保存失败"
        }
    }

    private func primaryAction() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.capturePhoto()
        }
    }
}
