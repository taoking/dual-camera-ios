import AVKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = DualCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DualCameraPreview(camera: camera)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()

                if let message = camera.mediaMessage ?? camera.state.message {
                    statusMessage(message)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }

                controlBar
            }
            .padding(.top, 12)
            .padding(.bottom, 28)

            if let photo = camera.latestPhoto {
                capturedPhoto(photo)
            }

            if let videoURL = camera.latestVideoURL {
                capturedVideo(videoURL)
            }
        }
        .onAppear(perform: camera.start)
        .onDisappear(perform: camera.stop)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                camera.resumePreviewIfNeeded()
            case .background:
                camera.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            rearCameraMenu

            Spacer()

            if camera.isRecording {
                Label(recordingTime, systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("正在录制，时长 \(recordingTime)")
            } else {
                Label("前置", systemImage: "person.crop.circle")
                    .foregroundStyle(.white)
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.32), in: Capsule())
        .padding(.horizontal, 18)
    }

    private var rearCameraMenu: some View {
        Menu {
            ForEach(camera.availableRearCameras) { option in
                Button {
                    camera.selectRearCamera(option)
                } label: {
                    Label(
                        "\(option.zoomLabel) \(option.title)",
                        systemImage: option.symbolName
                    )
                }
            }
        } label: {
            Label(
                "\(camera.selectedRearCamera.zoomLabel) \(camera.selectedRearCamera.title)",
                systemImage: camera.selectedRearCamera.symbolName
            )
            .foregroundStyle(.white)
        }
        .disabled(
            camera.availableRearCameras.isEmpty ||
                camera.isRecording ||
                camera.isCapturing ||
                !camera.state.isReady
        )
        .accessibilityLabel("选择后置摄像头")
    }

    private var controlBar: some View {
        HStack(alignment: .center) {
            Group {
                if camera.isRecording {
                    Label("录制中", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 48)
                } else {
                    Label("双摄", systemImage: "camera.on.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 68, height: 48)
                }
            }

            Spacer()

            Button(action: primaryAction) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 5)
                        .frame(width: 76, height: 76)

                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red)
                            .frame(width: 34, height: 34)
                    } else {
                        Circle()
                            .fill(.white)
                            .frame(width: 62, height: 62)
                            .scaleEffect(camera.isCapturing ? 0.78 : 1)
                    }
                }
            }
            .disabled(
                (!camera.state.isReady || camera.isCapturing) && !camera.isRecording
            )
            .accessibilityLabel(camera.isRecording ? "停止视频录制" : "同时拍摄前后摄像头")

            Spacer()

            Button(action: camera.startRecording) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 48, height: 48)
                    Circle()
                        .fill(.red)
                        .frame(width: 18, height: 18)
                }
            }
            .disabled(!camera.state.isReady || camera.isCapturing || camera.isRecording)
            .accessibilityLabel("开始双摄视频录制")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.black.opacity(0.26), in: Capsule())
        .padding(.horizontal, 18)
    }

    private func primaryAction() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.capturePhoto()
        }
    }

    private func statusMessage(_ message: String) -> some View {
        Label(
            message,
            systemImage: camera.mediaMessage == nil ? camera.state.symbolName : "checkmark.circle.fill"
        )
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 14))
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

            VStack {
                Spacer()
                Button(action: camera.saveLatestPhoto) {
                    Label(camera.isSavingMedia ? "正在保存…" : "保存并继续拍摄", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(camera.isSavingMedia)
                .accessibilityLabel(camera.isSavingMedia ? "正在保存照片" : "保存照片后返回双摄预览")
                .padding(.bottom, 34)
            }
        }
    }

    private func capturedVideo(_ url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()

            Button(action: camera.dismissLatestVideo) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
            .accessibilityLabel("关闭视频预览")

            VStack {
                Spacer()
                Button(action: camera.saveLatestVideo) {
                    Label(camera.isSavingMedia ? "正在保存…" : "保存并继续拍摄", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(camera.isSavingMedia)
                .accessibilityLabel(camera.isSavingMedia ? "正在保存视频" : "保存视频后返回双摄预览")
                .padding(.bottom, 34)
            }
        }
    }

    private var recordingTime: String {
        let totalSeconds = Int(camera.recordingDuration.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

}

#Preview {
    ContentView()
}
