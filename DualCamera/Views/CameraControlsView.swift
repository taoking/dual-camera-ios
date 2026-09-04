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
            modeSelector
                .padding(.bottom, 14)
            controls
        }
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    private var header: some View {
        HStack(spacing: 10) {
            rearCameraMenu
            layoutMenu
            if camera.isTorchAvailable {
                torchButton
            }
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
                Text("取景 \(camera.diagnostics.backFormat) / \(camera.diagnostics.frontFormat)")
                Text("照片 \(camera.diagnostics.backPhotoDimensions) / \(camera.diagnostics.frontPhotoDimensions)")
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

    /// 照片／视频模式切换。此前快门与录制是两个同屏按键，且录制中白快门会变成
    /// 方块承担「停止」，一个控件承担了两种语义。改为单一主键后语义唯一。
    private var modeSelector: some View {
        HStack(spacing: 4) {
            ForEach(ShootingMode.allCases) { mode in
                let isSelected = camera.shootingMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        camera.setShootingMode(mode)
                    }
                } label: {
                    Text(mode.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? .black : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(isSelected ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(mode.accessibilityIdentifier)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.black.opacity(0.42), in: Capsule())
        .opacity(camera.isRecording ? 0 : 1)
        .disabled(camera.isRecording || camera.isCapturing || camera.countdownRemaining > 0)
        .accessibilityHidden(camera.isRecording)
    }

    private var controls: some View {
        HStack(alignment: .center) {
            recentMediaControl
                .frame(width: 68, height: 58)
            Spacer()
            shutterButton
            Spacer()
            // 与左侧缩略图等宽的占位，保证主键居中。
            Color.clear.frame(width: 68, height: 58)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.black.opacity(0.3), in: Capsule())
        .padding(.horizontal, 18)
    }

    private var shutterButton: some View {
        Button(action: camera.triggerPrimaryAction) {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 76, height: 76)
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 34, height: 34)
                } else if camera.shootingMode == .video {
                    Circle().fill(.red).frame(width: 62, height: 62)
                } else {
                    Circle().fill(.white).frame(width: 62, height: 62)
                        .scaleEffect(camera.isCapturing ? 0.78 : 1)
                }
            }
        }
        .disabled(isShutterDisabled)
        .accessibilityLabel(shutterAccessibilityLabel)
        .accessibilityIdentifier("shutter")
    }

    private var isShutterDisabled: Bool {
        if camera.isRecording { return false }
        if !camera.state.isReady || camera.isCapturing { return true }
        if camera.shootingMode == .video {
            return camera.videoState.preventsNewRecording || camera.countdownRemaining > 0
        }
        // 照片模式下倒计时中仍可点按，此时代表取消。
        return false
    }

    private var shutterAccessibilityLabel: String {
        if camera.isRecording { return "停止视频录制" }
        if camera.countdownRemaining > 0 { return "取消倒计时" }
        return camera.shootingMode == .video ? "开始双摄视频录制" : "同时拍摄前后摄像头"
    }

    /// 显示等效焦距倍率，与镜头菜单的 0.5×／1× 标注同口径；
    /// 直接显示 videoZoomFactor 会在超广角下读出 1.0× 而与菜单自相矛盾。
    private var zoomLabel: String {
        let value = camera.displayZoomFactor
        return value < 10
            ? String(format: "%.1f×", value)
            : String(format: "%.0f×", value)
    }

    private var torchButton: some View {
        Button(action: camera.toggleTorch) {
            Image(systemName: camera.torchMode.symbolName)
                .foregroundStyle(camera.torchMode == .on ? .yellow : .white)
                .padding(9)
                .background(.black.opacity(0.34), in: Circle())
        }
        .accessibilityLabel(camera.torchMode == .on ? "关闭补光" : "开启补光")
        .accessibilityIdentifier("torch-toggle")
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

}
