import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Photos
import UIKit

private enum CaptureMode {
    case photo
    case video
}

/// 仅负责 AVFoundation 会话和媒体采集；界面状态由 CameraViewModel 订阅并呈现。
final class MultiCamSessionController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isSavingMedia = false
    @Published private(set) var latestPhotoSet: CapturedPhotoSet?
    @Published private(set) var latestVideoURL: URL?
    @Published private(set) var notice: CameraNotice?
    @Published private(set) var availableRearCameras: [RearCameraOption] = []
    @Published private(set) var selectedRearCamera: RearCameraOption = .wide
    @Published private(set) var diagnostics = CameraDiagnostics.empty
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isFakeCamera = ProcessInfo.processInfo.arguments.contains("-fakeCamera")

    let session: AVCaptureMultiCamSession
    let backPreviewLayer: AVCaptureVideoPreviewLayer
    let frontPreviewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "com.taoking.dualcamera.session")
    private var isConfigured = false
    private var isSessionRunning = false
    private var captureMode: CaptureMode = .photo
    private var desiredRearCamera: RearCameraOption = .wide
    private var supportedRearCameraOptions = [RearCameraOption]()
    private var captureLayout = DualCameraLayout.default
    private var captureAspectRatio: CaptureAspectRatio = .threeByFour
    private var captureQuality: CaptureQuality = .balanced
    private var photoSaveMode: PhotoSaveMode = .composedOnly

    private var backPhotoOutput: AVCapturePhotoOutput?
    private var frontPhotoOutput: AVCapturePhotoOutput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var frontPreviewConnection: AVCaptureConnection?
    private var frontPhotoConnection: AVCaptureConnection?
    private var backDevice: AVCaptureDevice?
    private var latestFrontSampleBuffer: CMSampleBuffer?
    private var videoRecorder: DualCameraVideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    private var activeCaptureTransaction: CaptureTransaction?
    /// 图片已从两个输出返回、但尚在合成队列时的事务标识。
    private var activeCompositionID: UUID?
    private var captureTimeoutWorkItem: DispatchWorkItem?
    private var photoProcessors = [UUID: PhotoCaptureProcessor]()
    private var notificationTokens = [NSObjectProtocol]()
    private let photoComposer = PhotoComposer()
    private let photoLibraryService = PhotoLibraryService()

    override init() {
        let multiCamSession = AVCaptureMultiCamSession()
        session = multiCamSession
        backPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        frontPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        super.init()

        backPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
        captureLayout = CameraPreferences.loadLayout()
        captureAspectRatio = CameraPreferences.loadAspectRatio()
        photoSaveMode = CameraPreferences.loadSaveMode()
        captureQuality = CameraPreferences.loadQuality()
        observeSessionNotifications()
    }

    deinit {
        recordingTimer?.invalidate()
        captureTimeoutWorkItem?.cancel()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        if isFakeCamera {
            publish(.ready)
            publishRearCameras([.wide], selected: .wide)
            publishDiagnostics(CameraDiagnostics(
                deviceSummary: "Fake Camera Mode",
                backFormat: "生成的后置占位图",
                frontFormat: "生成的前置占位图",
                frameRate: 30,
                hardwareCost: 0,
                systemPressureCost: 0
            ))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            CameraLog.authorization.info("相机权限已授权")
            configureAndStart()
        case .notDetermined:
            publish(.requestingAuthorization)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    CameraLog.authorization.info("用户已授权相机")
                    self.configureAndStart()
                } else {
                    CameraLog.authorization.error("用户拒绝相机权限")
                    self.publish(.permissionDenied)
                }
            }
        case .denied, .restricted:
            publish(.permissionDenied)
        @unknown default:
            publish(.failed("无法确定相机授权状态。"))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.cancelActiveCapture(reason: .captureCancelled, publishNotice: false)
            self.cancelPendingComposition()
            guard !self.isFakeCamera else {
                self.publish(.idle)
                return
            }
            if self.videoRecorder != nil {
                self.stopRecordingLocked(restartPhotoSession: false)
            }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.isSessionRunning = false
            CameraLog.lifecycle.info("双摄会话已停止")
            self.publish(.idle)
        }
    }

    /// 仅在没有媒体预览覆盖时恢复会话，避免预览照片／视频时仍占用双摄硬件。
    func resumePreviewIfNeeded() {
        guard latestPhotoSet == nil, latestVideoURL == nil else { return }
        start()
    }

    func capturePhoto() {
        if isFakeCamera {
            sessionQueue.async { [weak self] in
                self?.captureFakePhoto()
            }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureMode == .photo,
                  self.isConfigured,
                  self.isSessionRunning,
                  let backOutput = self.backPhotoOutput,
                  let frontOutput = self.frontPhotoOutput,
                  self.activeCaptureTransaction == nil,
                  self.activeCompositionID == nil,
                  self.videoRecorder == nil else {
                return
            }

            let captureID = UUID()
            self.activeCaptureTransaction = CaptureTransaction(
                id: captureID,
                startedAt: Date(),
                expectedPositions: [.back, .front]
            )
            self.publishCapturing(true)
            self.scheduleCaptureTimeout(for: captureID)
            CameraLog.capture.info("开始双路拍照事务 \(captureID.uuidString, privacy: .private)")

            self.capture(on: backOutput, position: .back, captureID: captureID)
            self.capture(on: frontOutput, position: .front, captureID: captureID)
        }
    }

    func startRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            publish(.requestingMicrophoneAuthorization)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.publish(.microphonePermissionDenied)
                }
            }
        case .denied, .restricted:
            publish(.microphonePermissionDenied)
        @unknown default:
            publish(.failed("无法确定麦克风授权状态。"))
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            self?.stopRecordingLocked(restartPhotoSession: true)
        }
    }

    func selectRearCamera(_ option: RearCameraOption) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.supportedRearCameraOptions.contains(option) else {
                self.publishNotice("该后置镜头不能与前摄同时运行。", kind: .error)
                return
            }
            guard self.desiredRearCamera != option else { return }
            guard self.videoRecorder == nil, self.activeCaptureTransaction == nil else {
                self.publishNotice("请在拍照或录制完成后切换镜头。", kind: .info)
                return
            }

            self.desiredRearCamera = option
            self.publishRearCameras(self.supportedRearCameraOptions, selected: option)
            _ = self.rebuildSession()
        }
    }

    func dismissLatestPhoto() {
        latestPhotoSet = nil
        resumePreviewIfNeeded()
    }

    func dismissLatestVideo() {
        latestVideoURL = nil
        resumePreviewIfNeeded()
    }

    func saveLatestPhoto() {
        guard let photoSet = latestPhotoSet, !isSavingMedia else {
            return
        }

        isSavingMedia = true
        photoLibraryService.save(photoSet, mode: photoSaveMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSavingMedia = false
                switch result {
                case .success:
                    self.latestPhotoSet = nil
                    self.publishNotice("照片已保存到系统相册。", kind: .success)
                    HapticService.success()
                    self.resumePreviewIfNeeded()
                case .failure(let error):
                    self.publishNotice(error.localizedDescription, kind: .error)
                    HapticService.error()
                }
            }
        }
    }

    func updateLayout(_ layout: DualCameraLayout, aspectRatio: CaptureAspectRatio) {
        CameraPreferences.save(layout: layout)
        CameraPreferences.save(aspectRatio: aspectRatio)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureLayout = layout
            self.captureAspectRatio = aspectRatio
            self.applyMirroringSettings()
        }
    }

    func updateSaveMode(_ mode: PhotoSaveMode) {
        CameraPreferences.save(mode: mode)
        sessionQueue.async { [weak self] in
            self?.photoSaveMode = mode
        }
    }

    func updateCaptureQuality(_ quality: CaptureQuality) {
        CameraPreferences.save(quality: quality)
        sessionQueue.async { [weak self] in
            self?.captureQuality = quality
        }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        guard !isFakeCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, let backDevice = self.backDevice else { return }
            do {
                try backDevice.lockForConfiguration()
                defer { backDevice.unlockForConfiguration() }
                if backDevice.isFocusPointOfInterestSupported {
                    backDevice.focusPointOfInterest = devicePoint
                    backDevice.focusMode = backDevice.isFocusModeSupported(.autoFocus) ? .autoFocus : .continuousAutoFocus
                }
                if backDevice.isExposurePointOfInterestSupported {
                    backDevice.exposurePointOfInterest = devicePoint
                    backDevice.exposureMode = backDevice.isExposureModeSupported(.continuousAutoExposure)
                        ? .continuousAutoExposure
                        : .autoExpose
                }
                CameraLog.session.debug("已更新后摄对焦和测光点")
            } catch {
                self.publishNotice("无法设置对焦：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func zoomBackCamera(by scale: CGFloat) {
        guard !isFakeCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, let backDevice = self.backDevice else { return }
            do {
                try backDevice.lockForConfiguration()
                defer { backDevice.unlockForConfiguration() }
                let maximum = min(backDevice.maxAvailableVideoZoomFactor, 6)
                let requested = backDevice.videoZoomFactor * scale
                let value = min(max(requested, backDevice.minAvailableVideoZoomFactor), maximum)
                backDevice.videoZoomFactor = value
                DispatchQueue.main.async { self.zoomFactor = value }
            } catch {
                self.publishNotice("无法调整缩放：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func saveLatestVideo() {
        guard let url = latestVideoURL, !isSavingMedia else { return }

        isSavingMedia = true
        requestPhotoLibraryAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isSavingMedia = false
                    self.publishNotice(CameraError.photoLibraryDenied.localizedDescription, kind: .error)
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                self.completeMediaSave(
                    message: success ? "视频已保存到系统相册。" : "视频保存失败：\(error?.localizedDescription ?? "未知错误")",
                    savedVideo: success,
                    returnToPreview: success
                )
            }
        }
    }

    private func beginRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured,
                  self.isSessionRunning,
                  self.videoRecorder == nil,
                  self.activeCaptureTransaction == nil else {
                return
            }

            self.captureMode = .video
            guard self.rebuildSession() else {
                self.captureMode = .photo
                return
            }

            do {
                self.videoRecorder = try DualCameraVideoRecorder(outputURL: self.makeVideoURL())
                self.latestFrontSampleBuffer = nil
                self.publishRecording(true)
                self.publish(.ready)
            } catch {
                self.captureMode = .photo
                _ = self.rebuildSession()
                self.publish(.failed("无法开始视频录制：\(error.localizedDescription)"))
            }
        }
    }

    private func stopRecordingLocked(restartPhotoSession: Bool) {
        guard let recorder = videoRecorder else { return }
        videoRecorder = nil
        latestFrontSampleBuffer = nil
        publishRecording(false)
        captureMode = .photo

        if restartPhotoSession {
            _ = rebuildSession()
        }

        recorder.finish { [weak self] result in
            self?.sessionQueue.async {
                switch result {
                case .success(let url):
                    DispatchQueue.main.async { [weak self] in
                        self?.latestVideoURL = url
                    }
                    self?.pauseSessionForMediaPreview()
                    self?.publishNotice("视频录制完成，点击预览后可保存到相册。", kind: .success)
                case .failure(let error):
                    self?.publish(.failed("视频录制失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    CameraLog.session.error("双摄会话配置失败：\(error.localizedDescription, privacy: .public)")
                    self.publish(.unsupported(error.localizedDescription))
                    return
                }
            }

            guard !self.session.isRunning else {
                self.isSessionRunning = true
                self.publish(.ready)
                return
            }

            self.session.startRunning()
            self.isSessionRunning = true
            self.publishDiagnostics(self.makeDiagnostics())
            CameraLog.lifecycle.info("双摄会话已启动，硬件成本 \(self.session.hardwareCost, privacy: .public)")
            self.publish(.ready)
        }
    }

    @discardableResult
    private func rebuildSession() -> Bool {
        if session.isRunning {
            session.stopRunning()
        }
        isSessionRunning = false
        tearDownSession()
        isConfigured = false

        do {
            try configureSession()
            isConfigured = true
            session.startRunning()
            isSessionRunning = true
            publishDiagnostics(makeDiagnostics())
            publish(.ready)
            return true
        } catch {
            publish(.unsupported(error.localizedDescription))
            return false
        }
    }

    private func tearDownSession() {
        session.beginConfiguration()
        session.connections.forEach(session.removeConnection)
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()

        backPhotoOutput = nil
        frontPhotoOutput = nil
        backVideoOutput = nil
        frontVideoOutput = nil
        audioOutput = nil
        latestFrontSampleBuffer = nil
        frontPreviewConnection = nil
        frontPhotoConnection = nil
        backDevice = nil
    }

    private func configureSession() throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraConfigurationError("此设备不支持同时运行前后摄像头。")
        }

        let cameras = try selectSupportedCameraPair()
        try configureMultiCamFormat(for: cameras.back)
        try configureMultiCamFormat(for: cameras.front)
        backDevice = cameras.back

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let backInput = try AVCaptureDeviceInput(device: cameras.back)
        let frontInput = try AVCaptureDeviceInput(device: cameras.front)
        try addInput(backInput, label: cameras.option.title)
        try addInput(frontInput, label: "前置")

        guard let backPort = backInput.ports(
            for: .video,
            sourceDeviceType: cameras.back.deviceType,
            sourceDevicePosition: .back
        ).first,
        let frontPort = frontInput.ports(
            for: .video,
            sourceDeviceType: cameras.front.deviceType,
            sourceDevicePosition: .front
        ).first else {
            throw CameraConfigurationError("未能获取前后摄像头的视频输入端口。")
        }

        let backPreviewConnection = AVCaptureConnection(
            inputPort: backPort,
            videoPreviewLayer: backPreviewLayer
        )
        let frontPreviewConnection = AVCaptureConnection(
            inputPort: frontPort,
            videoPreviewLayer: frontPreviewLayer
        )
        try addConnection(backPreviewConnection, label: "后置预览")
        try addConnection(frontPreviewConnection, label: "前置预览")
        configurePortraitConnection(backPreviewConnection, mirrored: false)
        configurePortraitConnection(frontPreviewConnection, mirrored: captureLayout.frontPreviewMirrored)
        self.frontPreviewConnection = frontPreviewConnection

        switch captureMode {
        case .photo:
            try configurePhotoOutputs(backPort: backPort, frontPort: frontPort)
        case .video:
            try configureVideoOutputs(
                backPort: backPort,
                frontPort: frontPort,
                audioDevice: AVCaptureDevice.default(for: .audio)
            )
        }
    }

    private func configurePhotoOutputs(
        backPort: AVCaptureInput.Port,
        frontPort: AVCaptureInput.Port
    ) throws {
        let backOutput = AVCapturePhotoOutput()
        let frontOutput = AVCapturePhotoOutput()
        try addOutput(backOutput, label: "后置照片")
        try addOutput(frontOutput, label: "前置照片")

        let backConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        try addConnection(backConnection, label: "后置照片输出")
        try addConnection(frontConnection, label: "前置照片输出")
        configurePortraitConnection(backConnection, mirrored: false)
        configurePortraitConnection(frontConnection, mirrored: captureLayout.frontCaptureMirrored)

        backPhotoOutput = backOutput
        frontPhotoOutput = frontOutput
        frontPhotoConnection = frontConnection
    }

    private func configureVideoOutputs(
        backPort: AVCaptureInput.Port,
        frontPort: AVCaptureInput.Port,
        audioDevice: AVCaptureDevice?
    ) throws {
        guard let audioDevice else {
            throw CameraConfigurationError("未找到可用于视频录制的麦克风。")
        }

        let backOutput = AVCaptureVideoDataOutput()
        let frontOutput = AVCaptureVideoDataOutput()
        let audioOutput = AVCaptureAudioDataOutput()
        configureVideoDataOutput(backOutput)
        configureVideoDataOutput(frontOutput)
        backOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        frontOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)

        try addOutput(backOutput, label: "后置视频")
        try addOutput(frontOutput, label: "前置视频")
        try addOutput(audioOutput, label: "录音")

        let backConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        try addConnection(backConnection, label: "后置视频输出")
        try addConnection(frontConnection, label: "前置视频输出")
        configureVideoDataConnection(backConnection)
        configureVideoDataConnection(frontConnection)

        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        try addInput(audioInput, label: "麦克风")
        guard let audioPort = audioInput.ports(
            for: .audio,
            sourceDeviceType: audioDevice.deviceType,
            sourceDevicePosition: .unspecified
        ).first else {
            throw CameraConfigurationError("未能获取麦克风输入端口。")
        }
        let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
        try addConnection(audioConnection, label: "录音输出")

        backVideoOutput = backOutput
        frontVideoOutput = frontOutput
        self.audioOutput = audioOutput
    }

    private func configureVideoDataOutput(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
    }

    private func configureVideoDataConnection(_ connection: AVCaptureConnection) {
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func selectSupportedCameraPair() throws -> (
        front: AVCaptureDevice,
        back: AVCaptureDevice,
        option: RearCameraOption
    ) {
        guard let frontCamera = AVCaptureDevice.default(
            .builtInTrueDepthCamera,
            for: .video,
            position: .front
        ) else {
            throw CameraConfigurationError("未找到前置原深感摄像头。")
        }

        let supportedOptions = RearCameraOption.allCases.filter { option in
            guard let device = AVCaptureDevice.default(option.deviceType, for: .video, position: .back) else {
                return false
            }
            return isMultiCamPairSupported(front: frontCamera, back: device)
        }
        guard !supportedOptions.isEmpty else {
            throw CameraConfigurationError("系统没有允许与前摄同时工作的后置镜头。")
        }

        if !supportedOptions.contains(desiredRearCamera) {
            desiredRearCamera = supportedOptions.contains(.wide) ? .wide : supportedOptions[0]
        }
        guard let backCamera = AVCaptureDevice.default(
            desiredRearCamera.deviceType,
            for: .video,
            position: .back
        ) else {
            throw CameraConfigurationError("未找到所选的\(desiredRearCamera.title)镜头。")
        }

        supportedRearCameraOptions = supportedOptions
        publishRearCameras(supportedOptions, selected: desiredRearCamera)
        return (frontCamera, backCamera, desiredRearCamera)
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

    private func configureMultiCamFormat(for device: AVCaptureDevice) throws {
        let targetFrameRates: [Double] = [30, 24]
        guard let selected = targetFrameRates.lazy.compactMap({ frameRate in
            self.selectBestFormat(for: device, targetFrameRate: frameRate).map { ($0, frameRate) }
        }).first else {
            throw CameraConfigurationError("\(device.localizedName) 没有可用于双摄的 24fps 及以上格式。")
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = selected.0

            let duration = CMTime(value: 1, timescale: CMTimeScale(selected.1.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            throw CameraConfigurationError("无法配置 \(device.localizedName) 的双摄格式：\(error.localizedDescription)")
        }
    }

    /// 优先稳定帧率和接近 720p 的低成本格式；30fps 不可用时才降到 24fps。
    private func selectBestFormat(for device: AVCaptureDevice, targetFrameRate: Double) -> AVCaptureDevice.Format? {
        let targetPixels: Int32 = 1_280 * 720
        let candidates = device.formats.filter { format in
            format.isMultiCamSupported && format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= targetFrameRate && $0.maxFrameRate >= targetFrameRate
            }
        }
        return candidates.min { lhs, rhs in
            formatScore(lhs, targetPixels: targetPixels) < formatScore(rhs, targetPixels: targetPixels)
        }
    }

    private func formatScore(_ format: AVCaptureDevice.Format, targetPixels: Int32) -> Int64 {
        let pixels = pixelCount(format)
        let resolutionPenalty = pixels < targetPixels
            ? Int64(targetPixels - pixels) * 4
            : Int64(pixels - targetPixels)
        let highResolutionPenalty = pixels > targetPixels * 3 ? Int64(pixels - targetPixels * 3) : 0
        return resolutionPenalty + highResolutionPenalty
    }

    private func pixelCount(_ format: AVCaptureDevice.Format) -> Int32 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return dimensions.width * dimensions.height
    }

    private func addInput(_ input: AVCaptureDeviceInput, label: String) throws {
        guard session.canAddInput(input) else {
            throw CameraConfigurationError("无法将\(label)摄像头加入双摄会话。")
        }
        session.addInputWithNoConnections(input)
    }

    private func addOutput(_ output: AVCaptureOutput, label: String) throws {
        guard session.canAddOutput(output) else {
            throw CameraConfigurationError("无法添加\(label)输出。")
        }
        session.addOutputWithNoConnections(output)
    }

    private func addConnection(_ connection: AVCaptureConnection, label: String) throws {
        guard session.canAddConnection(connection) else {
            throw CameraConfigurationError("无法建立\(label)连接。")
        }
        session.addConnection(connection)
    }

    private func configurePortraitConnection(_ connection: AVCaptureConnection, mirrored: Bool) {
        // 应用锁定为竖屏；AVFoundation 以顺时针角度表示该方向。
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func applyMirroringSettings() {
        if let frontPreviewConnection {
            configurePortraitConnection(frontPreviewConnection, mirrored: captureLayout.frontPreviewMirrored)
        }
        if let frontPhotoConnection {
            configurePortraitConnection(frontPhotoConnection, mirrored: captureLayout.frontCaptureMirrored)
        }
    }

    private func makeDiagnostics() -> CameraDiagnostics {
        let frontDevice = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.position == .front })
        return CameraDiagnostics(
            deviceSummary: "\(backDevice?.localizedName ?? "后摄") + \(frontDevice?.localizedName ?? "前摄")",
            backFormat: formatSummary(backDevice),
            frontFormat: formatSummary(frontDevice),
            frameRate: backDevice.map { 1 / CMTimeGetSeconds($0.activeVideoMinFrameDuration) } ?? 0,
            hardwareCost: session.hardwareCost,
            systemPressureCost: session.systemPressureCost
        )
    }

    private func formatSummary(_ device: AVCaptureDevice?) -> String {
        guard let device else { return "—" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return "\(dimensions.width)×\(dimensions.height)"
    }

    private func capture(
        on output: AVCapturePhotoOutput,
        position: AVCaptureDevice.Position,
        captureID: UUID
    ) {
        let processorID = UUID()
        let settings = AVCapturePhotoSettings()
        // MultiCam 会为各输出分别限制可用的拍照质量；不得请求高于该上限的值，
        // 否则 AVCapturePhotoOutput 会抛出 Objective-C 异常并终止应用。
        settings.photoQualityPrioritization = captureQuality == .fast ? .speed : output.maxPhotoQualityPrioritization

        let processor = PhotoCaptureProcessor { [weak self] image, errorMessage in
            self?.sessionQueue.async {
                self?.finishCapture(
                    processorID: processorID,
                    captureID: captureID,
                    position: position,
                    image: image,
                    errorMessage: errorMessage
                )
            }
        }

        photoProcessors[processorID] = processor
        output.capturePhoto(with: settings, delegate: processor)
    }

    private func finishCapture(
        processorID: UUID,
        captureID: UUID,
        position: AVCaptureDevice.Position,
        image: UIImage?,
        errorMessage: String?
    ) {
        photoProcessors[processorID] = nil
        guard var transaction = activeCaptureTransaction, transaction.id == captureID else {
            CameraLog.capture.debug("忽略过期拍照回调")
            return
        }

        if let image {
            transaction.receivedImages[position] = image.dualCameraNormalized
        } else {
            transaction.errors[position] = .captureFailed(
                "\(position == .front ? "前置" : "后置")拍照失败：\(errorMessage ?? "未返回照片数据")"
            )
        }
        activeCaptureTransaction = transaction
        guard transaction.isComplete else { return }

        captureTimeoutWorkItem?.cancel()
        captureTimeoutWorkItem = nil
        activeCaptureTransaction = nil

        guard transaction.errors.isEmpty else {
            publishCapturing(false)
            publishNotice(transaction.errors.values.map(\.localizedDescription).joined(separator: "\n"), kind: .error)
            CameraLog.capture.error("双路拍照事务返回错误")
            return
        }
        guard let backImage = transaction.receivedImages[.back],
              let frontImage = transaction.receivedImages[.front] else {
            publishCapturing(false)
            publishNotice(CameraError.captureFailed("未能同时取得前后摄照片。").localizedDescription, kind: .error)
            return
        }

        let layout = captureLayout
        let aspectRatio = captureAspectRatio
        activeCompositionID = transaction.id
        pauseSessionForMediaPreview()
        photoComposer.compose(
            backImage: backImage,
            frontImage: frontImage,
            layout: layout,
            aspectRatio: aspectRatio
        ) { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.activeCompositionID == transaction.id else {
                    CameraLog.composition.debug("忽略已取消的照片合成结果")
                    return
                }
                self.activeCompositionID = nil
                self.publishCapturing(false)
                switch result {
                case .success(let composedImage):
                    let photoSet = CapturedPhotoSet(
                        id: transaction.id,
                        capturedAt: transaction.startedAt,
                        backImage: backImage,
                        frontImage: frontImage,
                        composedImage: composedImage,
                        layout: layout,
                        aspectRatio: aspectRatio
                    )
                    DispatchQueue.main.async {
                        self.latestPhotoSet = photoSet
                        self.publishNotice("照片已生成，可保存或分享。", kind: .success)
                        HapticService.shutter()
                    }
                    CameraLog.composition.info("双摄照片合成完成")
                case .failure(let error):
                    self.publishNotice(error.localizedDescription, kind: .error)
                    self.resumePreviewIfNeeded()
                }
            }
        }
    }

    private func makeVideoURL() -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("DualCamera-\(UUID().uuidString).mov")
    }

    private func scheduleCaptureTimeout(for captureID: UUID) {
        captureTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeCaptureTransaction?.id == captureID else { return }
            self.cancelActiveCapture(reason: .captureTimedOut, publishNotice: true)
        }
        captureTimeoutWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    /// 取消只影响当前事务；后续到达的 PhotoOutput 回调会因事务 ID 不匹配而被忽略。
    private func cancelActiveCapture(reason: CameraError, publishNotice: Bool) {
        guard activeCaptureTransaction != nil else { return }
        activeCaptureTransaction = nil
        captureTimeoutWorkItem?.cancel()
        captureTimeoutWorkItem = nil
        photoProcessors.removeAll()
        publishCapturing(false)
        if publishNotice {
            self.publishNotice(reason.localizedDescription, kind: .error)
        }
        CameraLog.capture.error("拍照事务已取消：\(reason.localizedDescription, privacy: .public)")
    }

    /// 取消不会强杀正在运行的绘制任务，但其结果不会再进入 UI 或相册流程。
    private func cancelPendingComposition() {
        guard activeCompositionID != nil else { return }
        activeCompositionID = nil
        publishCapturing(false)
        CameraLog.composition.info("照片合成结果已取消")
    }

    private func captureFakePhoto() {
        guard activeCompositionID == nil else { return }
        publishCapturing(true)
        let layout = captureLayout
        let aspectRatio = captureAspectRatio
        let transactionID = UUID()
        activeCompositionID = transactionID
        let capturedAt = Date()
        let back = fakeImage(color: .systemTeal, label: "BACK")
        let front = fakeImage(color: .systemOrange, label: "FRONT")
        photoComposer.compose(backImage: back, frontImage: front, layout: layout, aspectRatio: aspectRatio) { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.activeCompositionID == transactionID else { return }
                self.activeCompositionID = nil
                self.publishCapturing(false)
                switch result {
                case .success(let image):
                    let photoSet = CapturedPhotoSet(
                        id: transactionID,
                        capturedAt: capturedAt,
                        backImage: back,
                        frontImage: front,
                        composedImage: image,
                        layout: layout,
                        aspectRatio: aspectRatio
                    )
                    DispatchQueue.main.async {
                        self.latestPhotoSet = photoSet
                        self.publishNotice("Fake Camera 已生成照片。", kind: .success)
                    }
                case .failure(let error):
                    self.publishNotice(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    private func fakeImage(color: UIColor, label: String) -> UIImage {
        let size = CGSize(width: 720, height: 1_280)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.86).setFill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 54, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let text = NSString(string: label)
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                completion(status == .authorized || status == .limited)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func completeMediaSave(
        message: String,
        savedVideo: Bool = false,
        returnToPreview: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSavingMedia = false
            if savedVideo {
                self.latestVideoURL = nil
            }
            self.publishNotice(message, kind: .success)
            if returnToPreview {
                self.resumePreviewIfNeeded()
            }
        }
    }

    /// 媒体预览覆盖实时画面时暂停会话，减少双摄功耗与热负载。
    /// 此方法仅从 sessionQueue 调用。
    private func pauseSessionForMediaPreview() {
        guard session.isRunning else { return }
        session.stopRunning()
        isSessionRunning = false
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleRuntimeError(notification)
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.sessionQueue.async {
                    self?.cancelActiveCapture(reason: .interrupted, publishNotice: false)
                    self?.cancelPendingComposition()
                }
                self?.stopRecording()
                self?.publish(.idle)
                self?.publishNotice(CameraError.interrupted.localizedDescription, kind: .error)
                CameraLog.interruption.notice("双摄会话被系统中断")
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: .main
            ) { [weak self] _ in
                CameraLog.interruption.info("双摄会话中断结束，尝试恢复")
                self?.resumePreviewIfNeeded()
            }
        )
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        if error?.code == .mediaServicesWereReset {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.cancelActiveCapture(reason: .captureCancelled, publishNotice: false)
                self.cancelPendingComposition()
                self.tearDownSession()
                self.isConfigured = false
                self.configureAndStart()
            }
        } else {
            stopRecording()
            publish(.failed("双摄会话发生运行时错误：\(error?.localizedDescription ?? "未知错误")"))
            CameraLog.session.error("双摄会话运行时错误：\(error?.localizedDescription ?? "未知错误", privacy: .public)")
        }
    }

    private func publish(_ newState: CameraState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.state = newState
            }
        }
    }

    private func publishCapturing(_ newValue: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = newValue
        }
    }

    private func publishRecording(_ newValue: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = newValue
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingDuration = 0

            guard newValue else {
                self.recordingStartedAt = nil
                return
            }

            self.recordingStartedAt = Date()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let startedAt = self?.recordingStartedAt else { return }
                self?.recordingDuration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func publishRearCameras(_ options: [RearCameraOption], selected: RearCameraOption) {
        DispatchQueue.main.async { [weak self] in
            self?.availableRearCameras = options
            self?.selectedRearCamera = selected
        }
    }

    private func publishDiagnostics(_ newValue: CameraDiagnostics) {
        DispatchQueue.main.async { [weak self] in
            self?.diagnostics = newValue
        }
    }

    private func publishNotice(_ message: String, kind: CameraNoticeKind) {
        DispatchQueue.main.async { [weak self] in
            let notice = CameraNotice(message: message, kind: kind)
            self?.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard self?.notice == notice else { return }
                self?.notice = nil
            }
        }
    }
}

extension MultiCamSessionController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let frontVideoOutput, output === frontVideoOutput {
            latestFrontSampleBuffer = sampleBuffer
            return
        }

        if let backVideoOutput, output === backVideoOutput {
            videoRecorder?.appendVideo(backSample: sampleBuffer, frontSample: latestFrontSampleBuffer)
            return
        }

        if let audioOutput, output === audioOutput {
            videoRecorder?.appendAudio(sampleBuffer)
        }
    }
}

private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?, String?) -> Void

    init(completion: @escaping (UIImage?, String?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(nil, error.localizedDescription)
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(nil, "无法读取照片数据。")
            return
        }

        completion(image, nil)
    }
}

private struct CameraConfigurationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
