import Combine
import SwiftUI
import UIKit

/// SwiftUI 的单一界面状态入口。AVFoundation 配置与队列操作全部留在 MultiCamSessionController。
@MainActor
final class CameraViewModel: ObservableObject {
    let sessionController = MultiCamSessionController()

    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecording = false
    @Published private(set) var videoState: VideoRecordingState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var mediaSaveState: MediaSaveState = .idle
    @Published private(set) var latestPhotoSet: CapturedPhotoSet?
    @Published private(set) var latestVideoURL: URL?
    @Published private(set) var isMediaReviewPresented = false
    @Published private(set) var notice: CameraNotice?
    @Published private(set) var availableRearCameras: [RearCameraOption] = []
    @Published private(set) var selectedRearCamera: RearCameraOption = .wide
    @Published private(set) var diagnostics = CameraDiagnostics.empty
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isFakeCamera = false
    @Published var showsPhotoPermissionSettings = false
    @Published private(set) var settingsAlertMessage = "请在系统设置中允许所需权限，然后重试。"

    @Published private(set) var layout: DualCameraLayout
    @Published private(set) var aspectRatio: CaptureAspectRatio
    @Published private(set) var saveMode: PhotoSaveMode
    @Published private(set) var captureQuality: CaptureQuality
    @Published var gridEnabled: Bool
    @Published private(set) var countdownRemaining = 0

    private var cancellables = Set<AnyCancellable>()
    private var countdownTask: Task<Void, Never>?
    private var timerSeconds: Int
    private let preferences: CameraPreferences

    init(preferences: CameraPreferences = CameraPreferences()) {
        self.preferences = preferences
        if ProcessInfo.processInfo.arguments.contains("-resetCameraPreferences") {
            preferences.resetForUITesting()
        }
        layout = preferences.loadLayout()
        aspectRatio = preferences.loadAspectRatio()
        saveMode = preferences.loadSaveMode()
        captureQuality = preferences.loadQuality()
        gridEnabled = preferences.gridEnabled
        timerSeconds = preferences.timerSeconds
        bindSession()
        sessionController.commitLayout(layout, aspectRatio: aspectRatio)
        sessionController.updateMirroring(layout)
        sessionController.updateSaveMode(saveMode)
        sessionController.updateCaptureQuality(captureQuality)
    }

    deinit {
        countdownTask?.cancel()
    }

    func start() {
        sessionController.start()
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = 0
        isMediaReviewPresented = false
        sessionController.stop()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sessionController.appDidBecomeActive()
        case .inactive:
            sessionController.appWillResignActive()
        case .background:
            countdownTask?.cancel()
            countdownTask = nil
            countdownRemaining = 0
            sessionController.appDidEnterBackground()
        @unknown default:
            break
        }
    }

    func capturePhoto() {
        guard !isCapturing, state.isReady else { return }
        countdownTask?.cancel()
        guard timerSeconds > 0 else {
            sessionController.capturePhoto()
            return
        }

        countdownRemaining = timerSeconds
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for value in stride(from: self.timerSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self.countdownRemaining = value
                HapticService.shutter()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.countdownRemaining = 0
            self.sessionController.capturePhoto()
        }
    }

    func selectRearCamera(_ option: RearCameraOption) {
        sessionController.selectRearCamera(option)
    }

    func setLayoutStyle(_ style: DualCameraLayoutStyle) {
        var updated = layout
        updated.style = style
        updateLayout(updated)
    }

    func setPIPSize(_ size: PIPSize) {
        updateLayout(DualCameraLayoutEngine.layout(layout, resizingPipTo: size))
    }

    func updatePIPFrame(_ frame: CGRect, in canvas: CGRect, snap: Bool) {
        let updated = DualCameraLayoutEngine.layout(layout, movingPipTo: frame, in: canvas, snap: snap)
        layout = updated
        if snap {
            commitLayoutConfiguration()
        }
    }

    func setAspectRatio(_ newValue: CaptureAspectRatio) {
        aspectRatio = newValue
        commitLayoutConfiguration()
    }

    func setSaveMode(_ newValue: PhotoSaveMode) {
        saveMode = newValue
        preferences.save(mode: newValue)
        sessionController.updateSaveMode(newValue)
    }

    func setCaptureQuality(_ newValue: CaptureQuality) {
        captureQuality = newValue
        preferences.save(quality: newValue)
        sessionController.updateCaptureQuality(newValue)
    }

    func setGridEnabled(_ newValue: Bool) {
        gridEnabled = newValue
        preferences.gridEnabled = newValue
    }

    func setTimerSeconds(_ seconds: Int) {
        timerSeconds = seconds
        preferences.timerSeconds = seconds
    }

    func setFrontPreviewMirrored(_ enabled: Bool) {
        var updated = layout
        updated.frontPreviewMirrored = enabled
        updateMirroring(updated)
    }

    func setFrontCaptureMirrored(_ enabled: Bool) {
        var updated = layout
        updated.frontCaptureMirrored = enabled
        updateMirroring(updated)
    }

    func focusAndExpose(at point: CGPoint) {
        sessionController.focusAndExpose(at: point)
    }

    func zoomBackCamera(by scale: CGFloat) {
        sessionController.zoomBackCamera(by: scale)
    }

    func beginZoomGesture() {
        sessionController.beginZoomGesture()
    }

    func endZoomGesture() {
        sessionController.endZoomGesture()
    }

    func presentLatestMedia() {
        guard latestPhotoSet != nil || latestVideoURL != nil else { return }
        isMediaReviewPresented = true
    }

    func dismissMediaReview() {
        isMediaReviewPresented = false
    }

    func saveLatestPhoto() {
        if let id = latestPhotoSet?.id {
            consumeCurrentNotice(for: .photo(id))
        }
        sessionController.saveLatestPhoto()
        sessionController.retryPendingMediaSaves()
    }

    func openAppSettings() {
        showsPhotoPermissionSettings = false
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func saveLatestVideo() {
        if let url = latestVideoURL {
            consumeCurrentNotice(for: .video(url))
        }
        sessionController.saveLatestVideo()
        sessionController.retryPendingMediaSaves()
    }

    func startRecording() {
        sessionController.startRecording()
    }

    func stopRecording() {
        sessionController.stopRecording()
    }

    func retrySession() {
        sessionController.retrySession()
    }

    func performStatusAction(_ action: CameraNoticeAction, notice: CameraNotice?) {
        if let notice, notice.action == action {
            sessionController.consumeNotice(notice)
        }
        switch action {
        case .none:
            break
        case .openAppSettings:
            openAppSettings()
        case .retrySession:
            retrySession()
        case .retryMediaSaves:
            sessionController.retryPendingMediaSaves()
        }
    }

    private func consumeCurrentNotice(for mediaJobID: MediaSaveJobID) {
        guard let notice, notice.mediaJobID == mediaJobID else { return }
        sessionController.consumeNotice(notice)
    }

    private func updateLayout(_ updated: DualCameraLayout) {
        layout = updated
        commitLayoutConfiguration()
    }

    private func commitLayoutConfiguration() {
        preferences.save(layout: layout)
        preferences.save(aspectRatio: aspectRatio)
        sessionController.commitLayout(layout, aspectRatio: aspectRatio)
    }

    private func updateMirroring(_ updated: DualCameraLayout) {
        layout = updated
        preferences.save(layout: updated)
        sessionController.commitLayout(updated, aspectRatio: aspectRatio)
        sessionController.updateMirroring(updated)
    }

    private func bindSession() {
        sessionController.$state.receive(on: DispatchQueue.main).assign(to: &$state)
        sessionController.$isCapturing.receive(on: DispatchQueue.main).assign(to: &$isCapturing)
        sessionController.$isRecording.receive(on: DispatchQueue.main).assign(to: &$isRecording)
        sessionController.$videoState.receive(on: DispatchQueue.main).assign(to: &$videoState)
        sessionController.$recordingDuration.receive(on: DispatchQueue.main).assign(to: &$recordingDuration)
        sessionController.$mediaSaveState.receive(on: DispatchQueue.main).assign(to: &$mediaSaveState)
        sessionController.$latestPhotoSet.receive(on: DispatchQueue.main).assign(to: &$latestPhotoSet)
        sessionController.$latestVideoURL.receive(on: DispatchQueue.main).assign(to: &$latestVideoURL)
        sessionController.noticePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                guard let self else { return }
                self.notice = notice
                let needsSettings = notice?.action == .openAppSettings
                if needsSettings {
                    self.settingsAlertMessage = notice?.message ?? "请在系统设置中允许所需权限，然后重试。"
                }
                self.showsPhotoPermissionSettings = needsSettings
            }
            .store(in: &cancellables)
        sessionController.$availableRearCameras.receive(on: DispatchQueue.main).assign(to: &$availableRearCameras)
        sessionController.$selectedRearCamera.receive(on: DispatchQueue.main).assign(to: &$selectedRearCamera)
        sessionController.$diagnostics.receive(on: DispatchQueue.main).assign(to: &$diagnostics)
        sessionController.$zoomFactor.receive(on: DispatchQueue.main).assign(to: &$zoomFactor)
        sessionController.$isFakeCamera.receive(on: DispatchQueue.main).assign(to: &$isFakeCamera)
    }
}
