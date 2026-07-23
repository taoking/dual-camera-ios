import AVFoundation
import Combine
import CoreMedia
import UIKit

enum CameraState: Equatable {
    case idle
    case requestingAuthorization
    case ready
    case permissionDenied
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
        case .permissionDenied:
            return "请在“设置”中允许相机权限后重试。"
        case .unsupported(let detail), .failed(let detail):
            return detail
        }
    }

    var symbolName: String {
        switch self {
        case .requestingAuthorization:
            return "camera.fill"
        case .permissionDenied, .unsupported, .failed:
            return "exclamationmark.triangle.fill"
        case .idle, .ready:
            return "camera"
        }
    }
}

final class DualCameraController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var latestPhoto: UIImage?

    let session: AVCaptureMultiCamSession
    let backPreviewLayer: AVCaptureVideoPreviewLayer
    let frontPreviewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "com.example.dualcamera.session")
    private var isConfigured = false
    private var isSessionRunning = false
    private var backPhotoOutput: AVCapturePhotoOutput?
    private var frontPhotoOutput: AVCapturePhotoOutput?
    private var activeCaptureID: UUID?
    private var expectedCapturePositions = Set<AVCaptureDevice.Position>()
    private var captureResults = [AVCaptureDevice.Position: UIImage]()
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
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.isSessionRunning = false
            self.publish(.idle)
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured, self.isSessionRunning,
                  let backOutput = self.backPhotoOutput,
                  let frontOutput = self.frontPhotoOutput,
                  self.activeCaptureID == nil else {
                return
            }

            let captureID = UUID()
            self.activeCaptureID = captureID
            self.expectedCapturePositions = [.back, .front]
            self.captureResults.removeAll()
            self.publishCapturing(true)

            self.capture(on: backOutput, position: .back, captureID: captureID)
            self.capture(on: frontOutput, position: .front, captureID: captureID)
        }
    }

    func dismissLatestPhoto() {
        latestPhoto = nil
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

        try addInput(backInput, label: "后置广角")
        try addInput(frontInput, label: "前置")

        let backOutput = AVCapturePhotoOutput()
        let frontOutput = AVCapturePhotoOutput()
        try addOutput(backOutput, label: "后置照片")
        try addOutput(frontOutput, label: "前置照片")

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

        let backPhotoConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let frontPhotoConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        let backPreviewConnection = AVCaptureConnection(
            inputPort: backPort,
            videoPreviewLayer: backPreviewLayer
        )
        let frontPreviewConnection = AVCaptureConnection(
            inputPort: frontPort,
            videoPreviewLayer: frontPreviewLayer
        )

        try addConnection(backPhotoConnection, label: "后置照片输出")
        try addConnection(frontPhotoConnection, label: "前置照片输出")
        try addConnection(backPreviewConnection, label: "后置预览")
        try addConnection(frontPreviewConnection, label: "前置预览")

        configurePortraitConnection(backPhotoConnection, mirrored: false)
        configurePortraitConnection(frontPhotoConnection, mirrored: true)
        configurePortraitConnection(backPreviewConnection, mirrored: false)
        configurePortraitConnection(frontPreviewConnection, mirrored: true)

        backPhotoOutput = backOutput
        frontPhotoOutput = frontOutput
    }

    private func selectSupportedCameraPair() throws -> (front: AVCaptureDevice, back: AVCaptureDevice) {
        guard let backCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ), let frontCamera = AVCaptureDevice.default(
            .builtInTrueDepthCamera,
            for: .video,
            position: .front
        ) else {
            throw CameraConfigurationError("未找到所需的前置或后置广角摄像头。")
        }

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

        let pairIsSupported = discovery.supportedMultiCamDeviceSets.contains { devices in
            let supportsBack = devices.contains { $0.uniqueID == backCamera.uniqueID }
            let supportsFront = devices.contains { $0.uniqueID == frontCamera.uniqueID }
            return supportsBack && supportsFront
        }

        guard pairIsSupported else {
            throw CameraConfigurationError("系统不允许当前前置与后置广角摄像头同时工作。")
        }

        return (frontCamera, backCamera)
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
            return dimensions.width >= 1280 && dimensions.height >= 720
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

    private func addOutput(_ output: AVCapturePhotoOutput, label: String) throws {
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
        settings.photoQualityPrioritization = .speed

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
            publish(.failed("\(position == .front ? "前置" : "后置")拍照失败：\(errorMessage)"))
        }

        expectedCapturePositions.remove(position)
        guard expectedCapturePositions.isEmpty else { return }

        activeCaptureID = nil
        let composedPhoto = composePhoto(
            back: captureResults[.back],
            front: captureResults[.front]
        )
        publishCapturing(false)

        guard let composedPhoto else {
            publish(.failed("未能同时取得前后摄像头照片，请稍后重试。"))
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.latestPhoto = composedPhoto
        }
    }

    private func composePhoto(back: UIImage?, front: UIImage?) -> UIImage? {
        guard let back, let front else { return nil }

        let canvasSize = CGSize(width: 1080, height: 1440)
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
