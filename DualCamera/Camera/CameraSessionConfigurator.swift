import AVFoundation
import CoreMedia
import Foundation

struct CameraCostAttempt {
    let backSelection: CameraFormatSelection
    let frontSelection: CameraFormatSelection
    let hardwareCost: Float
    let systemPressureCost: Float

    var isAccepted: Bool { hardwareCost <= 1 && systemPressureCost <= 1 }
}

struct CameraSessionConfiguration {
    let backDevice: AVCaptureDevice
    let frontDevice: AVCaptureDevice
    let selectedRearCamera: RearCameraOption
    let supportedRearCameras: [RearCameraOption]
    let frontPreviewConnection: AVCaptureConnection
    let formatAttempt: CameraCostAttempt
}

/// 建立完整的 MultiCam 图，并对有限个前后摄格式组合执行成本验收与降级。
final class CameraSessionConfigurator {
    private let session: AVCaptureMultiCamSession
    private let backPreviewLayer: AVCaptureVideoPreviewLayer
    private let frontPreviewLayer: AVCaptureVideoPreviewLayer
    private let photoCoordinator: PhotoCaptureCoordinator
    private let videoCoordinator: VideoCaptureCoordinator

    init(
        session: AVCaptureMultiCamSession,
        backPreviewLayer: AVCaptureVideoPreviewLayer,
        frontPreviewLayer: AVCaptureVideoPreviewLayer,
        photoCoordinator: PhotoCaptureCoordinator,
        videoCoordinator: VideoCaptureCoordinator
    ) {
        self.session = session
        self.backPreviewLayer = backPreviewLayer
        self.frontPreviewLayer = frontPreviewLayer
        self.photoCoordinator = photoCoordinator
        self.videoCoordinator = videoCoordinator
    }

    func configure(
        mode: CameraCaptureMode,
        desiredRearCamera: RearCameraOption,
        layout: DualCameraLayout,
        quality: CaptureQuality
    ) throws -> CameraSessionConfiguration {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraConfigurationError("此设备不支持同时运行前后摄像头。")
        }

        let pair = try selectCameraPair(desiredRearCamera: desiredRearCamera)
        let backCandidates = CameraFormatSelector.rankedCandidates(for: pair.back, mode: mode)
        let frontCandidates = CameraFormatSelector.rankedCandidates(for: pair.front, mode: mode)
        let combinations = formatCombinations(back: backCandidates, front: frontCandidates)
        guard !combinations.isEmpty else {
            throw CameraConfigurationError("前后摄没有共同可用的 30fps 或 24fps MultiCam 格式。")
        }

        var lastAttempt: CameraCostAttempt?
        for combination in combinations.prefix(12) {
            tearDownGraph(cancelRecording: false)
            try apply(combination.back, to: pair.back)
            try apply(combination.front, to: pair.front)
            let frontPreviewConnection = try buildGraph(
                front: pair.front,
                back: pair.back,
                mode: mode,
                layout: layout,
                quality: quality
            )
            let attempt = CameraCostAttempt(
                backSelection: combination.back.selection,
                frontSelection: combination.front.selection,
                hardwareCost: session.hardwareCost,
                systemPressureCost: session.systemPressureCost
            )
            lastAttempt = attempt
            log(attempt)
            if attempt.isAccepted {
                return CameraSessionConfiguration(
                    backDevice: pair.back,
                    frontDevice: pair.front,
                    selectedRearCamera: pair.option,
                    supportedRearCameras: pair.supportedOptions,
                    frontPreviewConnection: frontPreviewConnection,
                    formatAttempt: attempt
                )
            }
        }

        tearDownGraph(cancelRecording: false)
        let cost = lastAttempt.map {
            String(format: "hardwareCost %.2f，systemPressureCost %.2f", $0.hardwareCost, $0.systemPressureCost)
        } ?? "无可用候选"
        throw CameraConfigurationError("双摄格式在有限降级后成本仍超过安全阈值（\(cost)）。")
    }

    func tearDownGraph(cancelRecording: Bool) {
        photoCoordinator.reset()
        videoCoordinator.reset(cancelRecording: cancelRecording)
        session.beginConfiguration()
        session.connections.forEach(session.removeConnection)
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    private func buildGraph(
        front: AVCaptureDevice,
        back: AVCaptureDevice,
        mode: CameraCaptureMode,
        layout: DualCameraLayout,
        quality: CaptureQuality
    ) throws -> AVCaptureConnection {
        session.beginConfiguration()
        do {
            let backInput = try AVCaptureDeviceInput(device: back)
            let frontInput = try AVCaptureDeviceInput(device: front)
            try add(backInput, label: "后置")
            try add(frontInput, label: "前置")

            guard let backPort = backInput.ports(
                for: .video,
                sourceDeviceType: back.deviceType,
                sourceDevicePosition: .back
            ).first,
            let frontPort = frontInput.ports(
                for: .video,
                sourceDeviceType: front.deviceType,
                sourceDevicePosition: .front
            ).first else {
                throw CameraConfigurationError("未能获取前后摄像头的视频输入端口。")
            }

            let backPreviewConnection = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: backPreviewLayer)
            let frontPreviewConnection = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontPreviewLayer)
            try add(backPreviewConnection, label: "后置预览")
            try add(frontPreviewConnection, label: "前置预览")
            configurePortraitConnection(backPreviewConnection, mirrored: false)
            configurePortraitConnection(frontPreviewConnection, mirrored: layout.frontPreviewMirrored)

            switch mode {
            case .photo:
                try photoCoordinator.configure(
                    session: session,
                    backPort: backPort,
                    frontPort: frontPort,
                    quality: quality,
                    // 单路原始文件始终保持相机自然方向；合成图镜像由 PhotoComposer 独立处理。
                    frontMirrored: false,
                    configurePortraitConnection: configurePortraitConnection
                )
            case .video:
                try videoCoordinator.configure(
                    session: session,
                    backPort: backPort,
                    frontPort: frontPort,
                    audioDevice: AVCaptureDevice.default(for: .audio)
                )
            }
            session.commitConfiguration()
            return frontPreviewConnection
        } catch {
            session.commitConfiguration()
            throw error
        }
    }

    private func selectCameraPair(desiredRearCamera: RearCameraOption) throws -> (
        front: AVCaptureDevice,
        back: AVCaptureDevice,
        option: RearCameraOption,
        supportedOptions: [RearCameraOption]
    ) {
        guard let front = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CameraConfigurationError("未找到前置原深感摄像头。")
        }
        let supportedOptions = RearCameraOption.allCases.filter { option in
            guard let back = AVCaptureDevice.default(option.deviceType, for: .video, position: .back) else {
                return false
            }
            return isMultiCamPairSupported(front: front, back: back)
        }
        guard !supportedOptions.isEmpty else {
            throw CameraConfigurationError("系统没有允许与前摄同时工作的后置镜头。")
        }
        let option = supportedOptions.contains(desiredRearCamera)
            ? desiredRearCamera
            : (supportedOptions.contains(.wide) ? .wide : supportedOptions[0])
        guard let back = AVCaptureDevice.default(option.deviceType, for: .video, position: .back) else {
            throw CameraConfigurationError("未找到所选的\(option.title)镜头。")
        }
        return (front, back, option, supportedOptions)
    }

    private func isMultiCamPairSupported(front: AVCaptureDevice, back: AVCaptureDevice) -> Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.supportedMultiCamDeviceSets.contains { devices in
            devices.contains { $0.uniqueID == front.uniqueID } &&
                devices.contains { $0.uniqueID == back.uniqueID }
        }
    }

    private func formatCombinations(
        back: [CameraFormatCandidate],
        front: [CameraFormatCandidate]
    ) -> [(back: CameraFormatCandidate, front: CameraFormatCandidate)] {
        var selected = [(back: CameraFormatCandidate, front: CameraFormatCandidate)]()
        // 为 30fps 和 24fps 各保留固定尝试预算，避免格式很多时 24fps 永远排不到。
        for frameRate in [30, 24] {
            let backCandidates = back.filter { $0.selection.frameRate == frameRate }.prefix(4)
            let frontCandidates = front.filter { $0.selection.frameRate == frameRate }.prefix(4)
            var sameRate = [(CameraFormatCandidate, CameraFormatCandidate)]()
            for backCandidate in backCandidates {
                for frontCandidate in frontCandidates {
                    sameRate.append((backCandidate, frontCandidate))
                }
            }
            selected.append(contentsOf: sameRate
                .sorted {
                    ($0.0.selection.score + $0.1.selection.score) <
                        ($1.0.selection.score + $1.1.selection.score)
                }
                .prefix(6)
                .map { (back: $0.0, front: $0.1) })
        }
        return selected
    }

    private func apply(_ candidate: CameraFormatCandidate, to device: AVCaptureDevice) throws {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = candidate.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(candidate.selection.frameRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            throw CameraConfigurationError("无法配置 \(device.localizedName) 格式：\(error.localizedDescription)")
        }
    }

    private func add(_ input: AVCaptureDeviceInput, label: String) throws {
        guard session.canAddInput(input) else {
            throw CameraConfigurationError("无法将\(label)摄像头加入双摄会话。")
        }
        session.addInputWithNoConnections(input)
    }

    private func add(_ connection: AVCaptureConnection, label: String) throws {
        guard session.canAddConnection(connection) else {
            throw CameraConfigurationError("无法建立\(label)连接。")
        }
        session.addConnection(connection)
    }

    private func configurePortraitConnection(_ connection: AVCaptureConnection, mirrored: Bool) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func log(_ attempt: CameraCostAttempt) {
        let back = attempt.backSelection.descriptor
        let front = attempt.frontSelection.descriptor
        CameraLog.session.info(
            "格式尝试 back=\(back.width)x\(back.height) front=\(front.width)x\(front.height) fps=\(attempt.backSelection.frameRate) hardware=\(attempt.hardwareCost, privacy: .public) pressure=\(attempt.systemPressureCost, privacy: .public) accepted=\(attempt.isAccepted, privacy: .public)"
        )
    }
}
