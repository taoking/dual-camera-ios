import AVFoundation
import Combine
import CoreMedia
import UIKit

/// 持有 MultiCam Session、协调照片/视频模式，并把结构化状态发布给 ViewModel。
/// 所有 AVFoundation 会话和设备修改均在 sessionQueue 串行执行。
final class MultiCamSessionController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var photoState: PhotoCaptureState = .idle
    @Published private(set) var videoState: VideoRecordingState = .idle
    @Published private(set) var mediaSaveState: MediaSaveState = .idle
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
    private let lifecycle = CameraLifecycleCoordinator()
    private let authorizationService: CameraAuthorizationServing = CameraAuthorizationService()
    private let photoComposer = PhotoComposer()
    private let photoLibraryService = PhotoLibraryService()
    private lazy var photoCoordinator = PhotoCaptureCoordinator(sessionQueue: sessionQueue)
    private lazy var videoCoordinator = VideoCaptureCoordinator(sessionQueue: sessionQueue)
    private lazy var configurator = CameraSessionConfigurator(
        session: session,
        backPreviewLayer: backPreviewLayer,
        frontPreviewLayer: frontPreviewLayer,
        photoCoordinator: photoCoordinator,
        videoCoordinator: videoCoordinator
    )
    private lazy var runtimeMonitor = makeRuntimeMonitor()

    private var captureMode: CameraCaptureMode = .photo
    private var isConfigured = false
    private var isSessionRunning = false
    private var isRebuilding = false
    private var desiredRearCamera: RearCameraOption = .wide
    private var supportedRearCameras = [RearCameraOption]()
    private var captureLayout = DualCameraLayout.default
    private var captureAspectRatio: CaptureAspectRatio = .threeByFour
    private var captureQuality: CaptureQuality = .balanced
    private var photoSaveMode: PhotoSaveMode = .composedOnly
    private var backDevice: AVCaptureDevice?
    private var frontDevice: AVCaptureDevice?
    private var frontPreviewConnection: AVCaptureConnection?
    private var activeCompositionID: UUID?
    private var pressureSeverity = 0
    private var recordingBlockedByPressure = false
    private var pressureThrottled = false
    private var zoomGestureBaseFactor: CGFloat?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var fakeRecordingActive = false

    override init() {
        let multiCamSession = AVCaptureMultiCamSession()
        session = multiCamSession
        backPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        frontPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        super.init()
        backPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
        _ = runtimeMonitor
    }

    deinit {
        recordingTimer?.invalidate()
        videoCoordinator.discard(url: latestVideoURL)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            _ = self.lifecycle.requestStart(sessionIsRunning: self.isSessionRunning)
            if self.isFakeCamera {
                self.publishFakeReady()
            } else {
                self.authorizeAndStartLocked()
            }
        }
    }

    /// View 消失代表用户不再希望相机运行；后台事件则保留该意图供返回时恢复。
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            _ = self.lifecycle.requestStop(sessionIsRunning: self.isSessionRunning)
            self.stopSessionLocked(finishRecording: true)
        }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let action = self.lifecycle.didBecomeActive(sessionIsRunning: self.isSessionRunning)
            self.performLifecycleAction(action)
        }
    }

    func appWillResignActive() {
        sessionQueue.async { [weak self] in
            _ = self?.lifecycle.willResignActive()
        }
    }

    func appDidEnterBackground() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            _ = self.lifecycle.didEnterBackground(sessionIsRunning: self.isSessionRunning)
            self.cancelPendingPhotoWork()
            self.stopSessionLocked(finishRecording: true)
        }
    }

    func retrySession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.lifecycle.mayStartSession else { return }
            self.rebuildAfterMediaResetLocked()
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isFakeCamera {
                self.captureFakePhotoLocked()
                return
            }
            guard self.captureMode == .photo,
                  self.isConfigured,
                  self.isSessionRunning,
                  !self.photoCoordinator.isCapturing,
                  self.activeCompositionID == nil,
                  !self.videoCoordinator.isRecording else { return }

            self.publishPhotoState(.capturing)
            self.photoCoordinator.capture(quality: self.captureQuality) { [weak self] result in
                self?.handlePhotoCaptureResult(result)
            }
        }
    }

    func startRecording() {
        if isFakeCamera {
            sessionQueue.async { [weak self] in self?.beginFakeRecordingLocked() }
            return
        }
        authorizationService.requestAccess(
            for: .audio,
            onRequest: { [weak self] in self?.publishVideoState(.requestingPermission) },
            completion: { [weak self] result in
                self?.sessionQueue.async {
                    guard let self else { return }
                    guard self.lifecycle.mayStartSession else {
                        self.publishVideoState(.idle)
                        CameraLog.authorization.info("麦克风授权返回时生命周期不允许录制，已忽略启动")
                        return
                    }
                    switch result {
                    case .authorized: self.beginRecordingLocked()
                    case .denied: self.handleMicrophoneDenied()
                    case .unknown:
                        self.publishNotice(.videoRecordingFailed("无法确定麦克风授权状态。"), kind: .error)
                    }
                }
            }
        )
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isFakeCamera {
                self.stopFakeRecordingLocked()
            } else {
                self.stopRecordingLocked(restartPhotoSession: true)
            }
        }
    }

    func selectRearCamera(_ option: RearCameraOption) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.supportedRearCameras.contains(option) else {
                self.publishNotice(message: "该后置镜头不能与前摄同时运行。", kind: .error)
                return
            }
            guard option != self.desiredRearCamera else { return }
            guard self.captureMode == .photo,
                  !self.photoCoordinator.isCapturing,
                  self.activeCompositionID == nil else {
                self.publishNotice(message: "请在拍照或录制完成后切换镜头。", kind: .info)
                return
            }
            let previous = self.desiredRearCamera
            self.desiredRearCamera = option
            do {
                try self.rebuildSessionLocked()
            } catch {
                self.desiredRearCamera = previous
                try? self.rebuildSessionLocked()
                self.publishNotice(message: "镜头切换失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func focusAndExpose(at devicePoint: CGPoint) {
        guard !isFakeCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.backDevice else { return }
            let point = CGPoint(
                x: min(max(devicePoint.x, 0), 1),
                y: min(max(devicePoint.y, 0), 1)
            )
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    } else if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch {
                self.publishNotice(message: "无法设置对焦：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func beginZoomGesture() {
        guard !isFakeCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.backDevice else { return }
            self.zoomGestureBaseFactor = device.videoZoomFactor
        }
    }

    func zoomBackCamera(by scale: CGFloat) {
        guard !isFakeCamera else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.backDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let base = self.zoomGestureBaseFactor ?? device.videoZoomFactor
                let maximum = min(device.maxAvailableVideoZoomFactor, 6)
                let value = min(max(base * scale, device.minAvailableVideoZoomFactor), maximum)
                device.videoZoomFactor = value
                self.publishZoom(value)
            } catch {
                self.publishNotice(message: "无法调整缩放：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func endZoomGesture() {
        sessionQueue.async { [weak self] in self?.zoomGestureBaseFactor = nil }
    }

    /// 仅更新拍摄内存快照，不持久化、不入 Session Queue 做镜像工作。
    func updateTransientLayout(_ layout: DualCameraLayout, aspectRatio: CaptureAspectRatio) {
        sessionQueue.async { [weak self] in
            self?.captureLayout = layout
            self?.captureAspectRatio = aspectRatio
        }
    }

    func commitLayout(_ layout: DualCameraLayout, aspectRatio: CaptureAspectRatio) {
        sessionQueue.async { [weak self] in
            self?.captureLayout = layout
            self?.captureAspectRatio = aspectRatio
        }
    }

    func updateMirroring(_ layout: DualCameraLayout) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureLayout = layout
            if let connection = self.frontPreviewConnection {
                self.configurePortraitConnection(connection, mirrored: layout.frontPreviewMirrored)
            }
            // 前摄单路原始文件保持不镜像；frontCaptureMirrored 只由 PhotoComposer 应用于成片。
            self.photoCoordinator.updateFrontMirroring(
                false,
                configurePortraitConnection: self.configurePortraitConnection
            )
        }
    }

    func updateSaveMode(_ mode: PhotoSaveMode) {
        sessionQueue.async { [weak self] in self?.photoSaveMode = mode }
    }

    func updateCaptureQuality(_ quality: CaptureQuality) {
        sessionQueue.async { [weak self] in
            guard let self, quality != self.captureQuality else { return }
            let previous = self.captureQuality
            self.captureQuality = quality
            guard self.isConfigured, self.captureMode == .photo else { return }
            guard !self.photoCoordinator.isCapturing, self.activeCompositionID == nil else {
                self.captureQuality = previous
                self.publishNotice(message: "请在当前拍摄完成后修改质量。", kind: .info)
                return
            }
            do {
                try self.rebuildSessionLocked()
            } catch {
                self.captureQuality = previous
                try? self.rebuildSessionLocked()
                self.publishNotice(message: "质量模式切换失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    func dismissLatestPhoto() {
        DispatchQueue.main.async { [weak self] in self?.latestPhotoSet = nil }
        endMediaPreviewAndResume()
    }

    func dismissLatestVideo() {
        let url = latestVideoURL
        DispatchQueue.main.async { [weak self] in
            self?.latestVideoURL = nil
            self?.videoState = .idle
        }
        videoCoordinator.discard(url: url)
        endMediaPreviewAndResume()
    }

    func saveLatestPhoto() {
        guard let photoSet = latestPhotoSet, !isSavingMedia else { return }
        publishMediaSaveState(.saving)
        if isFakeCamera && ProcessInfo.processInfo.arguments.contains("-fakePhotoSaveFailure") {
            completePhotoSave(.failure(.photoLibrarySaveFailed("Fake Camera 模拟保存失败。")))
            return
        }
        photoLibraryService.save(photoSet, mode: photoSaveMode) { [weak self] result in
            self?.completePhotoSave(result)
        }
    }

    func saveLatestVideo() {
        guard let url = latestVideoURL, !isSavingMedia else { return }
        publishMediaSaveState(.saving)
        photoLibraryService.saveVideo(at: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.videoCoordinator.discard(url: url)
                    self.latestVideoURL = nil
                    self.videoState = .idle
                    self.publishMediaSaveState(.idle)
                    self.publishNotice(message: "视频已保存到系统相册。", kind: .success)
                    self.endMediaPreviewAndResume()
                case .failure(let error):
                    self.publishMediaSaveState(.failed(error))
                    self.publishNotice(error, kind: .error, action: Self.action(for: error))
                }
            }
        }
    }

    private func authorizeAndStartLocked() {
        guard lifecycle.mayStartSession else { return }
        authorizationService.requestAccess(
            for: .video,
            onRequest: { [weak self] in self?.publish(.requestingAuthorization) },
            completion: { [weak self] result in
                self?.sessionQueue.async {
                    guard let self else { return }
                    guard self.lifecycle.mayStartSession else {
                        CameraLog.authorization.info("相机授权返回时生命周期不允许启动，已忽略")
                        return
                    }
                    switch result {
                    case .authorized:
                        self.configureAndStartLocked()
                    case .denied:
                        self.publish(.permissionDenied)
                        self.publishNotice(.permissionDenied, kind: .error, action: .openAppSettings)
                    case .unknown:
                        self.publish(.failed("无法确定相机授权状态。"))
                    }
                }
            }
        )
    }

    private func configureAndStartLocked() {
        guard lifecycle.mayStartSession, !isRebuilding else { return }
        do {
            if !isConfigured {
                try configureSessionLocked()
            }
            guard !session.isRunning else {
                isSessionRunning = true
                publish(.ready)
                return
            }
            session.startRunning()
            isSessionRunning = true
            publishDiagnostics()
            publish(.ready)
        } catch {
            configurator.tearDownGraph(cancelRecording: false)
            isConfigured = false
            isSessionRunning = false
            publish(.unsupported(error.localizedDescription))
            publishNotice(message: error.localizedDescription, kind: .error)
        }
    }

    private func configureSessionLocked() throws {
        let configuration = try configurator.configure(
            mode: captureMode,
            desiredRearCamera: desiredRearCamera,
            layout: captureLayout,
            quality: captureQuality
        )
        backDevice = configuration.backDevice
        frontDevice = configuration.frontDevice
        frontPreviewConnection = configuration.frontPreviewConnection
        desiredRearCamera = configuration.selectedRearCamera
        supportedRearCameras = configuration.supportedRearCameras
        isConfigured = true
        publishRearCameras(configuration.supportedRearCameras, selected: configuration.selectedRearCamera)
        resetZoom(for: configuration.backDevice)
        pressureThrottled = false
        runtimeMonitor.observePressure(back: configuration.backDevice, front: configuration.frontDevice)
        publishDiagnostics()
    }

    private func rebuildSessionLocked() throws {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        if session.isRunning {
            session.stopRunning()
        }
        isSessionRunning = false
        runtimeMonitor.stopObservingPressure()
        configurator.tearDownGraph(cancelRecording: false)
        isConfigured = false
        try configureSessionLocked()
        if lifecycle.mayStartSession {
            session.startRunning()
            isSessionRunning = true
        }
        publishDiagnostics()
        publish(.ready)
    }

    private func beginRecordingLocked() {
        guard lifecycle.mayStartSession,
              isConfigured,
              isSessionRunning,
              captureMode == .photo,
              !photoCoordinator.isCapturing,
              activeCompositionID == nil else { return }
        guard !recordingBlockedByPressure else {
            publishNotice(.systemPressureCritical, kind: .error)
            return
        }

        discardLatestVideoLocked()
        captureMode = .video
        do {
            try rebuildSessionLocked()
            try videoCoordinator.start(outputURL: makeVideoURL())
            publishRecording(true)
            publishVideoState(.recording)
            publish(.ready)
        } catch {
            captureMode = .photo
            try? rebuildSessionLocked()
            let cameraError = CameraError.videoRecordingFailed("无法开始视频录制：\(error.localizedDescription)")
            publishVideoState(.failed(cameraError))
            publishNotice(cameraError, kind: .error)
        }
    }

    private func stopRecordingLocked(restartPhotoSession: Bool) {
        guard videoCoordinator.isRecording else { return }
        publishRecording(false)
        publishVideoState(.finishing)
        captureMode = .photo
        let didStop = videoCoordinator.stop { [weak self] result in
            self?.handleVideoFinish(result)
        }
        guard didStop else { return }

        if restartPhotoSession && lifecycle.mayStartSession {
            do {
                try rebuildSessionLocked()
            } catch {
                publish(.unsupported(error.localizedDescription))
            }
        } else {
            if session.isRunning { session.stopRunning() }
            isSessionRunning = false
            runtimeMonitor.stopObservingPressure()
            configurator.tearDownGraph(cancelRecording: false)
            isConfigured = false
        }
    }

    private func handleVideoFinish(_ result: Result<URL, CameraError>) {
        switch result {
        case .success(let url):
            DispatchQueue.main.async { [weak self] in self?.latestVideoURL = url }
            publishVideoState(.preview)
            pauseForMediaPreviewLocked()
            publishNotice(message: "视频录制完成，可预览、保存或关闭。", kind: .success)
        case .failure(let error):
            publishVideoState(.failed(error))
            publishNotice(error, kind: .error)
            if lifecycle.mayStartSession && !isSessionRunning {
                configureAndStartLocked()
            }
        }
    }

    private func handlePhotoCaptureResult(_ result: Result<CapturedPhotoPair, CameraError>) {
        switch result {
        case .failure(let error):
            publishPhotoState(.failed(error))
            publishNotice(error, kind: .error)
        case .success(let pair):
            publishPhotoState(.composing)
            activeCompositionID = pair.transactionID
            let layout = captureLayout
            let aspectRatio = captureAspectRatio
            pauseForMediaPreviewLocked()
            photoComposer.compose(
                backImage: pair.backPhoto.image,
                frontImage: pair.frontPhoto.image,
                layout: layout,
                aspectRatio: aspectRatio
            ) { [weak self] result in
                self?.sessionQueue.async {
                    guard let self, self.activeCompositionID == pair.transactionID else {
                        CameraLog.composition.debug("忽略已取消的照片合成结果")
                        return
                    }
                    self.activeCompositionID = nil
                    switch result {
                    case .success(let composedImage):
                        let set = CapturedPhotoSet(
                            id: pair.transactionID,
                            capturedAt: pair.capturedAt,
                            backPhoto: pair.backPhoto,
                            frontPhoto: pair.frontPhoto,
                            composedImage: composedImage,
                            layout: layout,
                            aspectRatio: aspectRatio
                        )
                        DispatchQueue.main.async { [weak self] in self?.latestPhotoSet = set }
                        self.publishPhotoState(.idle)
                        self.publishNotice(message: "照片已生成，可保存或分享。", kind: .success)
                        DispatchQueue.main.async { HapticService.shutter() }
                    case .failure(let error):
                        self.publishPhotoState(.failed(error))
                        self.publishNotice(error, kind: .error)
                        self.endMediaPreviewAndResume()
                    }
                }
            }
        }
    }

    private func captureFakePhotoLocked() {
        guard activeCompositionID == nil else { return }
        let id = UUID()
        let capturedAt = Date()
        let layout = captureLayout
        let aspectRatio = captureAspectRatio
        let back = FakeCameraFactory.sourcePhoto(position: .back, color: .systemTeal, label: "BACK")
        let front = FakeCameraFactory.sourcePhoto(position: .front, color: .systemOrange, label: "FRONT")
        activeCompositionID = id
        publishPhotoState(.composing)
        pauseForMediaPreviewLocked()
        photoComposer.compose(
            backImage: back.image,
            frontImage: front.image,
            layout: layout,
            aspectRatio: aspectRatio
        ) { [weak self] result in
            self?.sessionQueue.async {
                guard let self, self.activeCompositionID == id else { return }
                self.activeCompositionID = nil
                switch result {
                case .success(let image):
                    let set = CapturedPhotoSet(
                        id: id,
                        capturedAt: capturedAt,
                        backPhoto: back,
                        frontPhoto: front,
                        composedImage: image,
                        layout: layout,
                        aspectRatio: aspectRatio
                    )
                    DispatchQueue.main.async { [weak self] in self?.latestPhotoSet = set }
                    self.publishPhotoState(.idle)
                    self.publishNotice(message: "Fake Camera 已生成照片。", kind: .success)
                case .failure(let error):
                    self.publishPhotoState(.failed(error))
                    self.publishNotice(error, kind: .error)
                }
            }
        }
    }

    private func beginFakeRecordingLocked() {
        guard !fakeRecordingActive else { return }
        fakeRecordingActive = true
        publishRecording(true)
        publishVideoState(.recording)
    }

    private func stopFakeRecordingLocked() {
        guard fakeRecordingActive else { return }
        fakeRecordingActive = false
        publishRecording(false)
        publishVideoState(.idle)
        publishNotice(message: "Fake Camera 视频按钮状态验证完成。", kind: .success)
    }

    private func completePhotoSave(_ result: Result<Void, CameraError>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch result {
            case .success:
                self.latestPhotoSet = nil
                self.publishMediaSaveState(.idle)
                self.publishNotice(message: "照片已保存到系统相册。", kind: .success)
                HapticService.success()
                self.endMediaPreviewAndResume()
            case .failure(let error):
                self.publishMediaSaveState(.failed(error))
                self.publishNotice(error, kind: .error, action: Self.action(for: error))
                HapticService.error()
            }
        }
    }

    private func endMediaPreviewAndResume() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let action = self.lifecycle.setMediaPreview(false, sessionIsRunning: self.isSessionRunning)
            self.performLifecycleAction(action)
        }
    }

    private func pauseForMediaPreviewLocked() {
        let action = lifecycle.setMediaPreview(true, sessionIsRunning: isSessionRunning)
        if action == .stopSession, session.isRunning {
            session.stopRunning()
            isSessionRunning = false
        }
    }

    private func performLifecycleAction(_ action: CameraLifecycleAction) {
        switch action {
        case .none:
            break
        case .startSession:
            if isFakeCamera { publishFakeReady() } else { authorizeAndStartLocked() }
        case .stopSession:
            stopSessionLocked(finishRecording: true)
        case .rebuildSession:
            rebuildAfterMediaResetLocked()
        }
    }

    private func stopSessionLocked(finishRecording: Bool) {
        cancelPendingPhotoWork()
        if finishRecording {
            if isFakeCamera {
                stopFakeRecordingLocked()
            } else if videoCoordinator.isRecording {
                stopRecordingLocked(restartPhotoSession: false)
            }
        }
        if session.isRunning { session.stopRunning() }
        isSessionRunning = false
        publish(.idle)
    }

    private func cancelPendingPhotoWork() {
        photoCoordinator.cancel(reason: .captureCancelled, reportResult: false)
        if activeCompositionID != nil {
            activeCompositionID = nil
            publishPhotoState(.idle)
            _ = lifecycle.setMediaPreview(false, sessionIsRunning: isSessionRunning)
        }
    }

    private func rebuildAfterMediaResetLocked() {
        guard lifecycle.mayStartSession else { return }
        videoCoordinator.cancelRecording()
        publishRecording(false)
        captureMode = .photo
        do {
            try rebuildSessionLocked()
        } catch {
            publish(.failed("相机服务重置后恢复失败：\(error.localizedDescription)"))
            publishNotice(message: error.localizedDescription, kind: .error, action: .retrySession)
        }
    }

    private func handleMicrophoneDenied() {
        let error = CameraError.microphonePermissionDenied
        publishVideoState(.failed(error))
        publishNotice(error, kind: .error, action: .openAppSettings)
    }

    private func discardLatestVideoLocked() {
        let url = latestVideoURL
        videoCoordinator.discard(url: url)
        DispatchQueue.main.async { [weak self] in self?.latestVideoURL = nil }
    }

    private func makeVideoURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DualCamera-\(UUID().uuidString).mov")
    }

    private func resetZoom(for device: AVCaptureDevice) {
        zoomGestureBaseFactor = nil
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let value = min(max(1, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = value
            publishZoom(value)
        } catch {
            publishZoom(1)
        }
    }

    private func handleSystemPressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
        let severity: Int
        switch level {
        case .nominal: severity = 0
        case .fair: severity = 1
        case .serious: severity = 2
        case .critical: severity = 3
        case .shutdown: severity = 4
        default: severity = 3
        }
        guard severity != pressureSeverity else { return }
        pressureSeverity = severity
        recordingBlockedByPressure = severity >= 3
        switch severity {
        case 0, 1:
            break
        case 2:
            throttleFrameRateForPressureLocked()
            publishNotice(message: "设备压力较高，建议暂停连续拍摄并等待降温。", kind: .info)
        case 3:
            if videoCoordinator.isRecording {
                stopRecordingLocked(restartPhotoSession: true)
            }
            publishNotice(.systemPressureCritical, kind: .error)
        default:
            stopSessionLocked(finishRecording: true)
            publishNotice(.systemPressureShutdown, kind: .error)
        }
    }

    private func throttleFrameRateForPressureLocked() {
        guard !pressureThrottled else { return }
        let frameRate = 24.0
        var changed = false
        for device in [backDevice, frontDevice].compactMap({ $0 }) {
            guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
            }) else { continue }
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: 24)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                changed = true
            } catch {
                CameraLog.session.error("系统压力降帧失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        pressureThrottled = changed
        if changed {
            CameraLog.session.notice("系统压力 serious：已将支持的双摄输入降至 24fps")
            publishDiagnostics()
        }
    }

    private func makeRuntimeMonitor() -> CameraRuntimeMonitor {
        let monitor = CameraRuntimeMonitor(session: session)
        monitor.onPressureChanged = { [weak self] level in
            self?.sessionQueue.async { self?.handleSystemPressure(level) }
        }
        monitor.onInterruptionBegan = { [weak self] in
            self?.sessionQueue.async {
                guard let self else { return }
                _ = self.lifecycle.interruptionBegan(sessionIsRunning: self.isSessionRunning)
                self.cancelPendingPhotoWork()
                self.stopSessionLocked(finishRecording: true)
                self.publishNotice(.interrupted, kind: .error, action: .retrySession)
            }
        }
        monitor.onInterruptionEnded = { [weak self] in
            self?.sessionQueue.async {
                guard let self else { return }
                let action = self.lifecycle.interruptionEnded(sessionIsRunning: self.isSessionRunning)
                self.performLifecycleAction(action)
            }
        }
        monitor.onRuntimeError = { [weak self] error in
            self?.sessionQueue.async {
                guard let self else { return }
                if error?.code == .mediaServicesWereReset {
                    self.performLifecycleAction(self.lifecycle.mediaServicesWereReset())
                } else {
                    self.stopSessionLocked(finishRecording: true)
                    let detail = error?.localizedDescription ?? "未知错误"
                    self.publish(.failed("双摄会话发生运行时错误：\(detail)"))
                    self.publishNotice(message: detail, kind: .error, action: .retrySession)
                }
            }
        }
        return monitor
    }

    private func configurePortraitConnection(_ connection: AVCaptureConnection, mirrored: Bool) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func publishFakeReady() {
        supportedRearCameras = [.wide]
        publish(.ready)
        publishRearCameras([.wide], selected: .wide)
        DispatchQueue.main.async { [weak self] in
            self?.diagnostics = CameraDiagnostics(
                deviceSummary: "Fake Camera Mode",
                backFormat: "生成的后置占位图",
                frontFormat: "生成的前置占位图",
                frameRate: 30,
                hardwareCost: 0,
                systemPressureCost: 0
            )
        }
    }

    private func publishDiagnostics() {
        let value = CameraDiagnosticsProvider.make(
            session: session,
            backDevice: backDevice,
            frontDevice: frontDevice
        )
        DispatchQueue.main.async { [weak self] in self?.diagnostics = value }
    }

    private func publish(_ newState: CameraState) {
        DispatchQueue.main.async { [weak self] in self?.state = newState }
    }

    private func publishPhotoState(_ newState: PhotoCaptureState) {
        DispatchQueue.main.async { [weak self] in
            self?.photoState = newState
            self?.isCapturing = newState == .capturing || newState == .composing
        }
    }

    private func publishVideoState(_ newState: VideoRecordingState) {
        DispatchQueue.main.async { [weak self] in self?.videoState = newState }
    }

    private func publishMediaSaveState(_ newState: MediaSaveState) {
        DispatchQueue.main.async { [weak self] in
            self?.mediaSaveState = newState
            self?.isSavingMedia = newState == .saving
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

    private func publishZoom(_ value: CGFloat) {
        DispatchQueue.main.async { [weak self] in self?.zoomFactor = value }
    }

    private func publishNotice(
        _ error: CameraError,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none
    ) {
        publishNotice(message: error.localizedDescription, kind: kind, action: action)
    }

    private func publishNotice(
        message: String,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none
    ) {
        DispatchQueue.main.async { [weak self] in
            let notice = CameraNotice(message: message, kind: kind, action: action)
            self?.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.notice == notice else { return }
                self?.notice = nil
            }
        }
    }

    private static func action(for error: CameraError) -> CameraNoticeAction {
        switch error {
        case .permissionDenied, .microphonePermissionDenied, .photoLibraryDenied:
            .openAppSettings
        default:
            .none
        }
    }
}
