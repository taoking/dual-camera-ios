import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Photos
import UIKit

enum RearCameraOption: String, CaseIterable, Identifiable, Equatable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide:
            return .builtInUltraWideCamera
        case .wide:
            return .builtInWideAngleCamera
        case .telephoto:
            return .builtInTelephotoCamera
        }
    }

    var title: String {
        switch self {
        case .ultraWide:
            return "超广角"
        case .wide:
            return "广角"
        case .telephoto:
            return "长焦"
        }
    }

    var zoomLabel: String {
        switch self {
        case .ultraWide:
            return "0.5×"
        case .wide:
            return "1×"
        case .telephoto:
            return "长焦"
        }
    }

    var symbolName: String {
        switch self {
        case .ultraWide:
            return "camera.metering.multispot"
        case .wide:
            return "camera"
        case .telephoto:
            return "camera.aperture"
        }
    }
}

enum CameraState: Equatable {
    case idle
    case requestingAuthorization
    case requestingMicrophoneAuthorization
    case ready
    case permissionDenied
    case microphonePermissionDenied
    case unsupported(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .ready:
            return nil
        case .requestingAuthorization:
            return "正在请求相机权限…"
        case .requestingMicrophoneAuthorization:
            return "正在请求麦克风权限…"
        case .permissionDenied:
            return "请在“设置”中允许相机权限后重试。"
        case .microphonePermissionDenied:
            return "视频录制需要麦克风权限，请在“设置”中允许后重试。"
        case .unsupported(let detail), .failed(let detail):
            return detail
        }
    }

    var symbolName: String {
        switch self {
        case .requestingAuthorization:
            return "camera.fill"
        case .requestingMicrophoneAuthorization:
            return "mic.fill"
        case .permissionDenied, .microphonePermissionDenied, .unsupported, .failed:
            return "exclamationmark.triangle.fill"
        case .idle, .ready:
            return "camera"
        }
    }
}

private enum CaptureMode {
    case photo
    case video
}

final class DualCameraController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isSavingMedia = false
    @Published private(set) var latestPhoto: UIImage?
    @Published private(set) var latestVideoURL: URL?
    @Published private(set) var mediaMessage: String?
    @Published private(set) var availableRearCameras: [RearCameraOption] = []
    @Published private(set) var selectedRearCamera: RearCameraOption = .wide

    let session: AVCaptureMultiCamSession
    let backPreviewLayer: AVCaptureVideoPreviewLayer
    let frontPreviewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "com.taoking.dualcamera.session")
    private var isConfigured = false
    private var isSessionRunning = false
    private var captureMode: CaptureMode = .photo
    private var desiredRearCamera: RearCameraOption = .wide
    private var supportedRearCameraOptions = [RearCameraOption]()

    private var backPhotoOutput: AVCapturePhotoOutput?
    private var frontPhotoOutput: AVCapturePhotoOutput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var latestFrontSampleBuffer: CMSampleBuffer?
    private var videoRecorder: DualCameraVideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    private var activeCaptureID: UUID?
    private var expectedCapturePositions = Set<AVCaptureDevice.Position>()
    private var captureResults = [AVCaptureDevice.Position: UIImage]()
    private var captureErrors = [String]()
    private var photoProcessors = [UUID: PhotoCaptureProcessor]()
    private var notificationTokens = [NSObjectProtocol]()

    override init() {
        let multiCamSession = AVCaptureMultiCamSession()
        session = multiCamSession
        backPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        frontPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        super.init()

        backPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
        observeSessionNotifications()
    }

    deinit {
        recordingTimer?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            publish(.requestingAuthorization)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
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
            if self.videoRecorder != nil {
                self.stopRecordingLocked(restartPhotoSession: false)
            }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.isSessionRunning = false
            self.publish(.idle)
        }
    }

    /// 仅在没有媒体预览覆盖时恢复会话，避免预览照片／视频时仍占用双摄硬件。
    func resumePreviewIfNeeded() {
        guard latestPhoto == nil, latestVideoURL == nil else { return }
        start()
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureMode == .photo,
                  self.isConfigured,
                  self.isSessionRunning,
                  let backOutput = self.backPhotoOutput,
                  let frontOutput = self.frontPhotoOutput,
                  self.activeCaptureID == nil,
                  self.videoRecorder == nil else {
                return
            }

            let captureID = UUID()
            self.activeCaptureID = captureID
            self.expectedCapturePositions = [.back, .front]
            self.captureResults.removeAll()
            self.captureErrors.removeAll()
            self.publishCapturing(true)

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
                self.publishMediaMessage("该后置镜头不能与前摄同时运行。")
                return
            }
            guard self.desiredRearCamera != option else { return }
            guard self.videoRecorder == nil, self.activeCaptureID == nil else {
                self.publishMediaMessage("请在拍照或录制完成后切换镜头。")
                return
            }

            self.desiredRearCamera = option
            self.publishRearCameras(self.supportedRearCameraOptions, selected: option)
            _ = self.rebuildSession()
        }
    }

    func dismissLatestPhoto() {
        latestPhoto = nil
        resumePreviewIfNeeded()
    }

    func dismissLatestVideo() {
        latestVideoURL = nil
        resumePreviewIfNeeded()
    }

    func saveLatestPhoto() {
        guard let photo = latestPhoto,
              let data = photo.jpegData(compressionQuality: 0.95),
              !isSavingMedia else {
            return
        }

        isSavingMedia = true
        requestPhotoLibraryAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.completeMediaSave(message: "请允许“添加照片”权限后再保存。")
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                self.completeMediaSave(
                    message: success ? "照片已保存到系统相册。" : "照片保存失败：\(error?.localizedDescription ?? "未知错误")",
                    savedPhoto: success,
                    returnToPreview: success
                )
            }
        }
    }

    func saveLatestVideo() {
        guard let url = latestVideoURL, !isSavingMedia else { return }

        isSavingMedia = true
        requestPhotoLibraryAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.completeMediaSave(message: "请允许“添加照片”权限后再保存。")
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
                  self.activeCaptureID == nil else {
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
                    self?.publishMediaMessage("视频录制完成，点击预览后可保存到相册。")
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
    }

    private func configureSession() throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraConfigurationError("此设备不支持同时运行前后摄像头。")
        }

        let cameras = try selectSupportedCameraPair()
        try configureMultiCamFormat(for: cameras.back)
        try configureMultiCamFormat(for: cameras.front)

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
        configurePortraitConnection(frontPreviewConnection, mirrored: true)

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
        configurePortraitConnection(frontConnection, mirrored: true)

        backPhotoOutput = backOutput
        frontPhotoOutput = frontOutput
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
        let multiCamFormats = device.formats.filter { format in
            format.isMultiCamSupported && supportsThirtyFramesPerSecond(format)
        }

        guard !multiCamFormats.isEmpty else {
            throw CameraConfigurationError("\(device.localizedName) 没有可用于双摄的 30fps 格式。")
        }

        let preferredFormats = multiCamFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 1_280 && dimensions.height >= 720
        }
        let selectedFormat = (preferredFormats.isEmpty ? multiCamFormats : preferredFormats)
            .min { pixelCount($0) < pixelCount($1) }!

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = selectedFormat

            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            throw CameraConfigurationError("无法配置 \(device.localizedName) 的双摄格式：\(error.localizedDescription)")
        }
    }

    private func supportsThirtyFramesPerSecond(_ format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }
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

    private func capture(
        on output: AVCapturePhotoOutput,
        position: AVCaptureDevice.Position,
        captureID: UUID
    ) {
        let processorID = UUID()
        let settings = AVCapturePhotoSettings()
        // MultiCam 会为各输出分别限制可用的拍照质量；不得请求高于该上限的值，
        // 否则 AVCapturePhotoOutput 会抛出 Objective-C 异常并终止应用。
        settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization

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
        guard activeCaptureID == captureID else { return }

        if let image {
            captureResults[position] = image.normalized
        } else if let errorMessage {
            captureErrors.append("\(position == .front ? "前置" : "后置")拍照失败：\(errorMessage)")
        }

        expectedCapturePositions.remove(position)
        guard expectedCapturePositions.isEmpty else { return }

        activeCaptureID = nil
        publishCapturing(false)

        guard captureErrors.isEmpty else {
            publish(.failed(captureErrors.joined(separator: "\n")))
            return
        }

        guard let composedPhoto = composePhoto(
            back: captureResults[.back],
            front: captureResults[.front]
        ) else {
            publish(.failed("未能同时取得前后摄像头照片，请稍后重试。"))
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.latestPhoto = composedPhoto
        }
        pauseSessionForMediaPreview()
        publishMediaMessage("照片已生成，预览后可保存到相册。")
    }

    private func composePhoto(back: UIImage?, front: UIImage?) -> UIImage? {
        guard let back, let front else { return nil }

        let canvasSize = CGSize(width: 1_080, height: 1_440)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            let backgroundRect = CGRect(origin: .zero, size: canvasSize)
            drawAspectFill(back, in: backgroundRect, context: context)

            let inset: CGFloat = 48
            let pipRect = CGRect(
                x: canvasSize.width - 360 - inset,
                y: canvasSize.height - 480 - inset,
                width: 360,
                height: 480
            )
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: pipRect, cornerRadius: 30).addClip()
            drawAspectFill(front, in: pipRect, context: context)
            context.cgContext.restoreGState()

            UIColor.white.withAlphaComponent(0.9).setStroke()
            let border = UIBezierPath(roundedRect: pipRect, cornerRadius: 30)
            border.lineWidth = 7
            border.stroke()
        }
    }

    private func drawAspectFill(
        _ image: UIImage,
        in rect: CGRect,
        context: UIGraphicsImageRendererContext
    ) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        context.cgContext.saveGState()
        context.cgContext.clip(to: rect)
        image.draw(in: imageRect)
        context.cgContext.restoreGState()
    }

    private func makeVideoURL() -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("DualCamera-\(UUID().uuidString).mov")
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
        savedPhoto: Bool = false,
        savedVideo: Bool = false,
        returnToPreview: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSavingMedia = false
            if savedPhoto {
                self.latestPhoto = nil
            }
            if savedVideo {
                self.latestVideoURL = nil
            }
            self.publishMediaMessage(message)
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
                self?.stopRecording()
                self?.publish(.failed("双摄会话被系统中断，等待恢复。"))
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.configureAndStart()
            }
        )
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        if error?.code == .mediaServicesWereReset {
            configureAndStart()
        } else {
            stopRecording()
            publish(.failed("双摄会话发生运行时错误：\(error?.localizedDescription ?? "未知错误")"))
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

    private func publishMediaMessage(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mediaMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard self?.mediaMessage == message else { return }
                self?.mediaMessage = nil
            }
        }
    }
}

extension DualCameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
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

private extension UIImage {
    var normalized: UIImage {
        guard imageOrientation != .up else { return self }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
