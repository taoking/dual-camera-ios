import AVFoundation
import Combine
import CoreMedia
import UIKit

private enum VideoSaveStatus {
    case saving
    case saved
    case failed
}

/// 持有 MultiCam Session、协调照片/视频模式，并把结构化状态发布给 ViewModel。
/// 所有 AVFoundation 会话和设备修改均在 sessionQueue 串行执行。
final class MultiCamSessionController: NSObject, ObservableObject {
    private static let videoCacheFilenamePrefix = "DualCamera-"
    private static let orphanVideoMinimumAge: TimeInterval = 5 * 60
    private static let orphanCleanupLock = NSLock()
    private static var didClaimOrphanCleanup = false

    @Published private(set) var state: CameraState = .idle
    @Published private(set) var photoState: PhotoCaptureState = .idle
    @Published private(set) var videoState: VideoRecordingState = .idle
    @Published private(set) var mediaSaveState: MediaSaveState = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
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
    private let mediaSaveCoordinator = MediaSaveCoordinator.shared
    private let mediaRecoveryStore = MediaRecoveryStore.shared
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
    private var isControllerStopping = false
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
    private var recordingStartedAtUptime: TimeInterval?
    private var recordingAuthorizationPending = false
    private var fakeRecordingActive = false
    private var recentPhotoSet: CapturedPhotoSet?
    private var recentVideoURL: URL?
    private var latestMediaJobID: MediaSaveJobID?
    private var mediaSequence: UInt64 = 0
    private var recentMediaSequence: UInt64 = 0
    private var activeRecordingMediaSequence: UInt64?
    private var activeRecordingURL: URL?
    private var videoURLsPendingDeletion = Set<URL>()
    private var videoSaveStatuses = [URL: VideoSaveStatus]()
    private var videoAutoRetryAttempted = Set<URL>()

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
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isControllerStopping = false
            _ = self.lifecycle.requestStart(sessionIsRunning: self.isSessionRunning)
            if self.isFakeCamera {
                self.publishFakeReady()
            } else {
                self.authorizeAndStartLocked()
            }
            if Self.claimInitialOrphanCleanup() {
                let recovery = self.mediaRecoveryStore.recoverStaleInFlightVideos()
                for url in recovery.promoted {
                    CameraLog.media.info("已恢复上次进程完成封口的视频：\(url.lastPathComponent, privacy: .public)")
                }
                for url in recovery.discarded {
                    CameraLog.media.info("已清理上次进程未封口的视频：\(url.lastPathComponent, privacy: .public)")
                }
                self.cleanupOrphanedVideoCachesLocked()
            }
            self.retryRecoverableMediaSavesLocked()
        }
    }

    /// View 消失代表用户不再希望相机运行；后台事件则保留该意图供返回时恢复。
    func stop() {
        // 该一次性任务必须把 Controller 保留到录制收尾真正启动。否则 View 先释放
        // StateObject 时，尚未执行的 weak 闭包会直接丢弃最后一段视频。
        sessionQueue.async {
            self.isControllerStopping = true
            _ = self.lifecycle.requestStop(sessionIsRunning: self.isSessionRunning)
            self.stopSessionLocked(finishRecording: true)
            self.releaseRecentVideoOnStopLocked()
        }
    }

    func appDidBecomeActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let action = self.lifecycle.didBecomeActive(sessionIsRunning: self.isSessionRunning)
            self.performLifecycleAction(action)
            self.retryRecoverableMediaSavesLocked()
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
            self.retryRecoverableMediaSavesLocked()
        }
    }

    func retryPendingMediaSaves() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.retryRecoverableMediaSavesLocked()
            self.publishNotice(message: "正在重试未完成的媒体保存。", kind: .info)
        }
    }

    func consumeNotice(_ consumed: CameraNotice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notice = CameraNoticePolicy.consuming(consumed, from: self.notice)
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.mediaRecoveryStore.canAcceptPhoto else {
                self.publishNotice(
                    message: "已有 \(MediaRecoveryStore.maximumPendingPhotoCount) 张照片等待保存，请先重试保存或允许相册权限。",
                    kind: .error,
                    action: .retryMediaSaves
                )
                return
            }
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
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.mediaRecoveryStore.canAcceptVideo(
                activeVideoURLs: self.mediaSaveCoordinator.activeVideoURLs
            ) else {
                let error = CameraError.videoRecordingFailed(
                    "现有待保存视频已达到阈值（\(MediaRecoveryStore.maximumPendingVideoCount) 个或文件累计 1 GiB），请先重试保存。"
                )
                self.publishVideoState(.failed(error))
                self.publishNotice(error, kind: .error, action: .retryMediaSaves)
                return
            }
            if self.isFakeCamera {
                self.beginFakeRecordingLocked()
                return
            }
            guard !self.recordingAuthorizationPending,
                  !self.videoCoordinator.isFinishingRecording,
                  self.captureMode == .photo else { return }
            self.recordingAuthorizationPending = true
            self.publishVideoState(.requestingPermission)
            self.authorizationService.requestAccess(
                for: .audio,
                onRequest: {},
                completion: { [weak self] result in
                    self?.sessionQueue.async {
                        guard let self else { return }
                        self.recordingAuthorizationPending = false
                        guard self.lifecycle.mayStartSession else {
                            self.publishVideoState(.idle)
                            CameraLog.authorization.info("麦克风授权返回时生命周期不允许录制，已忽略启动")
                            return
                        }
                        switch result {
                        case .authorized: self.beginRecordingLocked()
                        case .denied: self.handleMicrophoneDenied()
                        case .unknown:
                            self.publishVideoState(.idle)
                            self.publishNotice(.videoRecordingFailed("无法确定麦克风授权状态。"), kind: .error)
                        }
                    }
                }
            )
        }
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

    func saveLatestPhoto() {
        sessionQueue.async { [weak self] in
            guard let self, let photoSet = self.recentPhotoSet else { return }
            self.enqueuePhotoSaveLocked(photoSet, mode: photoSet.saveMode)
        }
    }

    func saveLatestVideo() {
        sessionQueue.async { [weak self] in
            guard let self, let url = self.recentVideoURL else { return }
            self.enqueueVideoSaveLocked(url)
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
              activeCompositionID == nil,
              !videoCoordinator.isFinishingRecording else {
            publishVideoState(.idle)
            return
        }
        guard !recordingBlockedByPressure else {
            publishVideoState(.failed(.systemPressureCritical))
            publishNotice(.systemPressureCritical, kind: .error)
            return
        }

        captureMode = .video
        let outputURL = makeVideoURL()
        mediaRecoveryStore.markVideoInFlight(outputURL)
        do {
            try rebuildSessionLocked()
            try videoCoordinator.start(outputURL: outputURL)
            activeRecordingURL = outputURL
            activeRecordingMediaSequence = nextMediaSequenceLocked()
            publishRecording(true)
            publishVideoState(.recording)
            publish(.ready)
        } catch {
            mediaRecoveryStore.removeVideo(outputURL)
            videoCoordinator.discard(url: outputURL)
            activeRecordingURL = nil
            activeRecordingMediaSequence = nil
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
        let recordingMediaSequence = activeRecordingMediaSequence ?? nextMediaSequenceLocked()
        let recordingURL = activeRecordingURL
        activeRecordingMediaSequence = nil
        let videoCoordinator = self.videoCoordinator
        let photoLibraryService = self.photoLibraryService
        let mediaSaveCoordinator = self.mediaSaveCoordinator
        let recoveryStore = self.mediaRecoveryStore
        let didStop = videoCoordinator.stop {
            [weak self, videoCoordinator, photoLibraryService, mediaSaveCoordinator, recoveryStore] result in
            guard let self else {
                switch result {
                case .success(let url):
                    Self.saveDetachedVideo(
                        url,
                        photoLibraryService: photoLibraryService,
                        mediaSaveCoordinator: mediaSaveCoordinator,
                        recoveryStore: recoveryStore,
                        videoCoordinator: videoCoordinator
                    )
                case .failure:
                    if let recordingURL {
                        recoveryStore.removeVideo(recordingURL)
                        videoCoordinator.discard(url: recordingURL)
                    }
                }
                return
            }
            self.handleVideoFinish(
                result,
                mediaSequence: recordingMediaSequence,
                recordingURL: recordingURL
            )
        }
        guard didStop else {
            activeRecordingMediaSequence = recordingMediaSequence
            captureMode = .video
            publishRecording(true)
            publishVideoState(.recording)
            return
        }

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

    private func handleVideoFinish(
        _ result: Result<URL, CameraError>,
        mediaSequence: UInt64,
        recordingURL: URL?
    ) {
        activeRecordingURL = nil
        switch result {
        case .success(let url):
            mediaRecoveryStore.markVideoReadyToSave(url)
            if isControllerStopping {
                // 页面已退出但 finishWriting 才返回：仍完成后台保存，成功后清理，
                // 不再把这个视频发布到已经离开的界面。
                videoURLsPendingDeletion.insert(url)
                publishVideoState(.idle)
                enqueueVideoSaveLocked(url)
                return
            }
            let becameRecent = replaceRecentMediaLocked(
                withVideo: url,
                mediaSequence: mediaSequence
            )
            if !becameRecent {
                // 用户在 finishWriting 期间拍了更新的照片；旧视频仍保存，
                // 但不回退最近媒体，且只在保存成功后清理临时文件。
                videoURLsPendingDeletion.insert(url)
            }
            publishVideoState(.preview)
            enqueueVideoSaveLocked(url)
            if becameRecent {
                publishNotice(message: "视频录制完成，正在后台保存。", kind: .info)
            }
        case .failure(let error):
            if let recordingURL {
                mediaRecoveryStore.removeVideo(recordingURL)
                videoCoordinator.discard(url: recordingURL)
            }
            publishVideoState(.failed(error))
            publishNotice(error, kind: .error)
            if lifecycle.mayStartSession && !isSessionRunning {
                configureAndStartLocked()
            }
        }
    }

    private static func saveDetachedVideo(
        _ url: URL,
        photoLibraryService: PhotoLibraryService,
        mediaSaveCoordinator: MediaSaveCoordinator,
        recoveryStore: MediaRecoveryStore,
        videoCoordinator: VideoCaptureCoordinator
    ) {
        let id = MediaSaveJobID.video(url)
        recoveryStore.markVideoReadyToSave(url)
        _ = mediaSaveCoordinator.enqueue(
            id: id,
            operation: { completion in
                photoLibraryService.saveVideo(at: url, completion: completion)
            },
            completion: { _, result in
                recoveryStore.recordVideoResult(url: url, result: result)
                if case .success = result {
                    videoCoordinator.discard(url: url)
                }
            }
        )
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
            let saveMode = photoSaveMode
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
                            aspectRatio: aspectRatio,
                            saveMode: saveMode
                        )
                        self.replaceRecentMediaLocked(
                            withPhoto: set,
                            mediaSequence: self.nextMediaSequenceLocked()
                        )
                        self.publishPhotoState(.idle)
                        self.enqueuePhotoSaveLocked(set, mode: saveMode)
                        self.publishNotice(message: "照片已拍摄，正在后台保存。", kind: .info)
                        DispatchQueue.main.async { HapticService.shutter() }
                    case .failure(let error):
                        self.publishPhotoState(.failed(error))
                        self.publishNotice(error, kind: .error)
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
        let saveMode = photoSaveMode
        activeCompositionID = id
        publishPhotoState(.composing)
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
                        aspectRatio: aspectRatio,
                        saveMode: saveMode
                    )
                    self.replaceRecentMediaLocked(
                        withPhoto: set,
                        mediaSequence: self.nextMediaSequenceLocked()
                    )
                    self.publishPhotoState(.idle)
                    self.enqueuePhotoSaveLocked(set, mode: saveMode)
                    self.publishNotice(message: "Fake Camera 已生成照片，正在后台保存。", kind: .info)
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

    private func enqueuePhotoSaveLocked(_ photoSet: CapturedPhotoSet, mode: PhotoSaveMode) {
        let id = MediaSaveJobID.photo(photoSet.id)
        let simulatesFailure = isFakeCamera && ProcessInfo.processInfo.arguments.contains("-fakePhotoSaveFailure")
        let simulatesDelay = isFakeCamera && ProcessInfo.processInfo.arguments.contains("-fakeMediaSaveDelay")
        let isFakeSave = isFakeCamera
        let operation: MediaSaveCoordinator.Operation = { [photoLibraryService] completion in
            if isFakeSave {
                let result: Result<Void, CameraError> = simulatesFailure
                    ? .failure(.photoLibrarySaveFailed("Fake Camera 模拟保存失败。"))
                    : .success(())
                if simulatesDelay {
                    // 留出足够的 XCUI 轮询窗口，稳定观察“正在后台保存”。
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                        completion(result)
                    }
                } else {
                    completion(result)
                }
            } else {
                photoLibraryService.save(photoSet, mode: mode, completion: completion)
            }
        }

        let job = RecoverablePhotoSaveJob(id: photoSet.id, operation: operation)
        guard mediaRecoveryStore.rememberPhoto(job) else {
            let error = CameraError.photoLibrarySaveFailed("待保存照片已达到上限，请先重试之前的保存。")
            publishMediaSaveState(.failed(error), for: id)
            publishNotice(error, kind: .error, action: .retryMediaSaves, mediaJobID: id)
            return
        }
        enqueuePhotoSaveJobLocked(job, mediaID: id)
    }

    private func enqueuePhotoSaveJobLocked(
        _ job: RecoverablePhotoSaveJob,
        mediaID id: MediaSaveJobID? = nil
    ) {
        let mediaID = id ?? .photo(job.id)
        let recoveryStore = mediaRecoveryStore
        let didEnqueue = mediaSaveCoordinator.enqueue(
            id: mediaID,
            operation: job.operation,
            completion: { [weak self, recoveryStore] completedID, result in
                recoveryStore.completePhoto(id: job.id, result: result)
                self?.sessionQueue.async {
                    self?.handleMediaSaveCompletionLocked(id: completedID, result: result)
                }
            }
        )
        if didEnqueue {
            publishMediaSaveState(.saving, for: mediaID)
        }
    }

    private func enqueueVideoSaveLocked(_ url: URL) {
        let id = MediaSaveJobID.video(url)
        let videoCoordinator = self.videoCoordinator
        let recoveryStore = mediaRecoveryStore
        recoveryStore.markVideoReadyToSave(url)
        let didEnqueue = mediaSaveCoordinator.enqueue(
            id: id,
            operation: { [photoLibraryService] completion in
                photoLibraryService.saveVideo(at: url, completion: completion)
            },
            completion: { [weak self, videoCoordinator, recoveryStore] id, result in
                recoveryStore.recordVideoResult(url: url, result: result)
                guard let self else {
                    if case .success = result, case .video(let completedURL) = id {
                        videoCoordinator.discard(url: completedURL)
                    }
                    return
                }
                self.sessionQueue.async {
                    self.handleMediaSaveCompletionLocked(id: id, result: result)
                }
            }
        )
        if didEnqueue {
            videoSaveStatuses[url] = .saving
            publishMediaSaveState(.saving, for: id)
        }
    }

    private func handleMediaSaveCompletionLocked(
        id: MediaSaveJobID,
        result: Result<Void, CameraError>
    ) {
        // 旧媒体可在新拍摄之后才完成保存。它仍需要做资源收尾，
        // 但不应用旧结果覆盖当前缩略图的状态、提示或触感。
        let isLatestMedia = latestMediaJobID == id
        switch result {
        case .success:
            resolveMediaNotice(for: id)
            if isLatestMedia {
                publishMediaSaveState(.saved, for: id)
                switch id {
                case .photo:
                    publishNotice(message: "照片已保存到系统相册。", kind: .success)
                case .video:
                    publishNotice(message: "视频已保存到系统相册。", kind: .success)
                }
                DispatchQueue.main.async { HapticService.success() }
            }
        case .failure(let error):
            if isLatestMedia {
                publishMediaSaveState(.failed(error), for: id)
                publishNotice(
                    error,
                    kind: .error,
                    action: Self.action(for: error),
                    mediaJobID: id
                )
                DispatchQueue.main.async { HapticService.error() }
            } else {
                // 较早媒体已不在缩略图中，但恢复仓库仍保留它的保存任务；
                // 明确提示用户并提供即时重试，避免静默失败。
                let mediaName: String
                switch id {
                case .photo: mediaName = "照片"
                case .video: mediaName = "视频"
                }
                publishNotice(
                    message: "一个较早\(mediaName)未能保存：\(error.localizedDescription)",
                    kind: .error,
                    action: Self.action(for: error),
                    mediaJobID: id
                )
            }
        }

        if case .video(let url) = id {
            switch result {
            case .success:
                videoSaveStatuses[url] = .saved
                videoAutoRetryAttempted.remove(url)
                if videoURLsPendingDeletion.remove(url) != nil {
                    videoCoordinator.discard(url: url)
                    videoSaveStatuses.removeValue(forKey: url)
                }
            case .failure:
                // 保留唯一的 .mov：当它已被更新媒体替换时，下次回到
                // active 会再尝试保存；当它仍是最近媒体时，查看页也可手动重试。
                videoSaveStatuses[url] = .failed
                scheduleOneVideoRetryIfNeededLocked(url)
            }
        }
    }

    private func replaceRecentMediaLocked(
        withPhoto photoSet: CapturedPhotoSet,
        mediaSequence: UInt64
    ) {
        guard mediaSequence >= recentMediaSequence else { return }
        let previousVideoURL = recentVideoURL
        recentMediaSequence = mediaSequence
        recentPhotoSet = photoSet
        recentVideoURL = nil
        latestMediaJobID = .photo(photoSet.id)
        if let previousVideoURL {
            discardVideoWhenSafeLocked(previousVideoURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.latestPhotoSet = photoSet
            self?.latestVideoURL = nil
            self?.mediaSaveState = .idle
        }
    }

    @discardableResult
    private func replaceRecentMediaLocked(
        withVideo url: URL,
        mediaSequence: UInt64
    ) -> Bool {
        guard mediaSequence >= recentMediaSequence else { return false }
        let previousVideoURL = recentVideoURL
        recentMediaSequence = mediaSequence
        recentPhotoSet = nil
        recentVideoURL = url
        latestMediaJobID = .video(url)
        if let previousVideoURL, previousVideoURL != url {
            discardVideoWhenSafeLocked(previousVideoURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.latestPhotoSet = nil
            self?.latestVideoURL = url
            self?.mediaSaveState = .idle
        }
        return true
    }

    private func discardVideoWhenSafeLocked(_ url: URL) {
        switch videoSaveStatuses[url] {
        case .saving:
            videoURLsPendingDeletion.insert(url)
        case .failed:
            // 该失败视频即将从“最近媒体”移出，先保留文件并自动再试，
            // 避免用户失去唯一可重试入口后只留下无主缓存。
            videoURLsPendingDeletion.insert(url)
            enqueueVideoSaveLocked(url)
        case .saved:
            mediaRecoveryStore.removeVideo(url)
            videoSaveStatuses.removeValue(forKey: url)
            videoCoordinator.discard(url: url)
        case nil:
            if mediaRecoveryStore.isRecoverableVideo(url) {
                videoSaveStatuses[url] = .failed
                videoURLsPendingDeletion.insert(url)
                enqueueVideoSaveLocked(url)
            } else {
                videoCoordinator.discard(url: url)
            }
        }
    }

    private func releaseRecentVideoOnStopLocked() {
        guard let url = recentVideoURL else { return }
        discardVideoWhenSafeLocked(url)
        recentVideoURL = nil
        if latestMediaJobID == .video(url) {
            latestMediaJobID = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.latestVideoURL = nil
        }
    }

    private func retryRecoverableMediaSavesLocked() {
        for job in mediaRecoveryStore.pendingPhotos()
        where !mediaSaveCoordinator.contains(.photo(job.id)) {
            enqueuePhotoSaveJobLocked(job)
        }

        for url in mediaRecoveryStore.recoverableVideos() {
            guard FileManager.default.fileExists(atPath: url.path) else {
                mediaRecoveryStore.removeVideo(url)
                videoSaveStatuses.removeValue(forKey: url)
                videoURLsPendingDeletion.remove(url)
                continue
            }
            videoSaveStatuses[url] = mediaSaveCoordinator.contains(.video(url)) ? .saving : .failed
            if url != recentVideoURL {
                videoURLsPendingDeletion.insert(url)
            }
            guard !mediaSaveCoordinator.contains(.video(url)) else { continue }
            enqueueVideoSaveLocked(url)
        }
    }

    private func scheduleOneVideoRetryIfNeededLocked(_ url: URL) {
        guard videoURLsPendingDeletion.contains(url),
              videoAutoRetryAttempted.insert(url).inserted else { return }
        sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  self.videoURLsPendingDeletion.contains(url),
                  self.videoSaveStatuses[url] == .failed,
                  FileManager.default.fileExists(atPath: url.path) else { return }
            self.enqueueVideoSaveLocked(url)
        }
    }

    private func nextMediaSequenceLocked() -> UInt64 {
        mediaSequence &+= 1
        return mediaSequence
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
        }
    }

    private func rebuildAfterMediaResetLocked() {
        guard lifecycle.mayStartSession else { return }
        let wasFinishingRecording = videoCoordinator.isFinishingRecording
        videoCoordinator.cancelRecording()
        if !wasFinishingRecording, let activeRecordingURL {
            mediaRecoveryStore.removeVideo(activeRecordingURL)
            videoCoordinator.discard(url: activeRecordingURL)
            self.activeRecordingURL = nil
        }
        recordingAuthorizationPending = false
        fakeRecordingActive = false
        activeRecordingMediaSequence = nil
        publishRecording(false)
        // 已进入 finishWriting 的旧录像仍会回调；保持 finishing 既能阻止新录像，
        // 也避免先发布 idle 再被旧结果突兀覆盖。
        publishVideoState(wasFinishingRecording ? .finishing : .idle)
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

    private func makeVideoURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Self.videoCacheFilenamePrefix)\(UUID().uuidString).mov")
    }

    private func cleanupOrphanedVideoCachesLocked() {
        let fileManager = FileManager.default
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.orphanVideoMinimumAge)
        let orphanedURLs = mediaRecoveryStore.orphanedVideoCaches(
            in: cacheDirectory,
            filenamePrefix: Self.videoCacheFilenamePrefix,
            activeVideoURLs: mediaSaveCoordinator.activeVideoURLs,
            recentVideoURL: recentVideoURL,
            olderThan: cutoff
        )
        for url in orphanedURLs {
            do {
                let removed = try mediaRecoveryStore.removeVideoCacheIfStillOrphaned(
                    url,
                    filenamePrefix: Self.videoCacheFilenamePrefix,
                    activeVideoURLs: mediaSaveCoordinator.activeVideoURLs,
                    recentVideoURL: recentVideoURL,
                    olderThan: cutoff
                )
                if removed {
                    CameraLog.media.info("已清理未被恢复索引跟踪的视频缓存：\(url.lastPathComponent, privacy: .public)")
                }
            } catch {
                CameraLog.media.error("清理孤立视频缓存失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func claimInitialOrphanCleanup() -> Bool {
        orphanCleanupLock.lock()
        defer { orphanCleanupLock.unlock() }
        guard !didClaimOrphanCleanup else { return false }
        didClaimOrphanCleanup = true
        return true
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
            self?.sessionQueue.async { [weak self] in
                guard let self, !self.isFakeCamera else { return }
                self.handleSystemPressure(level)
            }
        }
        monitor.onInterruptionBegan = { [weak self] in
            self?.sessionQueue.async {
                guard let self, !self.isFakeCamera else { return }
                _ = self.lifecycle.interruptionBegan(sessionIsRunning: self.isSessionRunning)
                self.cancelPendingPhotoWork()
                self.stopSessionLocked(finishRecording: true)
                self.publishNotice(.interrupted, kind: .error, action: .retrySession)
            }
        }
        monitor.onInterruptionEnded = { [weak self] in
            self?.sessionQueue.async {
                guard let self, !self.isFakeCamera else { return }
                let action = self.lifecycle.interruptionEnded(sessionIsRunning: self.isSessionRunning)
                self.performLifecycleAction(action)
            }
        }
        monitor.onRuntimeError = { [weak self] error in
            self?.sessionQueue.async {
                guard let self, !self.isFakeCamera else { return }
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

    private func publishMediaSaveState(_ newState: MediaSaveState, for id: MediaSaveJobID) {
        guard latestMediaJobID == id else { return }
        DispatchQueue.main.async { [weak self] in
            self?.mediaSaveState = newState
        }
    }

    private func publishRecording(_ newValue: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = newValue
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            guard newValue else {
                self.recordingStartedAtUptime = nil
                return
            }
            self.recordingDuration = 0
            self.recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let startedAt = self?.recordingStartedAtUptime else { return }
                self?.recordingDuration = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
            }
            self.recordingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
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
        action: CameraNoticeAction = .none,
        mediaJobID: MediaSaveJobID? = nil
    ) {
        publishNotice(
            message: error.localizedDescription,
            kind: kind,
            action: action,
            mediaJobID: mediaJobID
        )
    }

    private func publishNotice(
        message: String,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none,
        mediaJobID: MediaSaveJobID? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            let notice = CameraNotice(
                message: message,
                kind: kind,
                action: action,
                mediaJobID: mediaJobID
            )
            guard let self,
                  CameraNoticePolicy.shouldPublish(notice, replacing: self.notice) else { return }
            self.notice = notice
            guard action == .none else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.notice == notice else { return }
                self?.notice = nil
            }
        }
    }

    private func resolveMediaNotice(for id: MediaSaveJobID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notice = CameraNoticePolicy.resolvingMediaSave(id, from: self.notice)
        }
    }

    private static func action(for error: CameraError) -> CameraNoticeAction {
        switch error {
        case .permissionDenied, .microphonePermissionDenied, .photoLibraryDenied:
            .openAppSettings
        default:
            .retryMediaSaves
        }
    }
}
