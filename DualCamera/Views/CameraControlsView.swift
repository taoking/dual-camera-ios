import SwiftUI

struct CameraControlsView: View {
    @ObservedObject var camera: CameraViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .accessibilityLabel("相机设置")
    }

    private var controls: some View {
        HStack(alignment: .center) {
            Label(camera.isFakeCamera ? "模拟" : "双摄", systemImage: camera.isFakeCamera ? "testtube.2" : "camera.on.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 68, height: 48)
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
            Spacer()
            Button(action: camera.startRecording) {
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 48, height: 48)
                    Circle().fill(.red).frame(width: 18, height: 18)
                }
            }
            .disabled(!camera.state.isReady || camera.isCapturing || camera.isRecording || camera.countdownRemaining > 0)
            .accessibilityLabel("开始双摄视频录制")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.black.opacity(0.3), in: Capsule())
        .padding(.horizontal, 18)
    }

    private var zoomLabel: String {
        String(format: "%.1f×", camera.zoomFactor)
    }

    private func primaryAction() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.capturePhoto()
        }
    }
}
