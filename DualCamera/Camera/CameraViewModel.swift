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
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isSavingMedia = false
    @Published private(set) var latestPhotoSet: CapturedPhotoSet?
    @Published private(set) var latestVideoURL: URL?
    @Published private(set) var notice: CameraNotice?
    @Published private(set) var availableRearCameras: [RearCameraOption] = []
    @Published private(set) var selectedRearCamera: RearCameraOption = .wide
    @Published private(set) var diagnostics = CameraDiagnostics.empty
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isFakeCamera = false
    @Published var showsPhotoPermissionSettings = false

    @Published private(set) var layout: DualCameraLayout
    @Published private(set) var aspectRatio: CaptureAspectRatio
    @Published private(set) var saveMode: PhotoSaveMode
    @Published private(set) var captureQuality: CaptureQuality
    @Published var gridEnabled: Bool
    @Published private(set) var countdownRemaining = 0

    private var cancellables = Set<AnyCancellable>()
    private var countdownTask: Task<Void, Never>?
    private var timerSeconds: Int

    init() {
        layout = CameraPreferences.loadLayout()
        aspectRatio = CameraPreferences.loadAspectRatio()
        saveMode = CameraPreferences.loadSaveMode()
        captureQuality = CameraPreferences.loadQuality()
        gridEnabled = CameraPreferences.gridEnabled
        timerSeconds = CameraPreferences.timerSeconds
        bindSession()
        sessionController.updateLayout(layout, aspectRatio: aspectRatio)
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
        sessionController.stop()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sessionController.resumePreviewIfNeeded()
        case .inactive, .background:
            stop()
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
        updateLayout(DualCameraLayoutEngine.layout(layout, movingPipTo: frame, in: canvas, snap: snap))
    }

    func setAspectRatio(_ newValue: CaptureAspectRatio) {
        aspectRatio = newValue
        persistLayoutConfiguration()
    }

    func setSaveMode(_ newValue: PhotoSaveMode) {
        saveMode = newValue
        sessionController.updateSaveMode(newValue)
    }

    func setCaptureQuality(_ newValue: CaptureQuality) {
        captureQuality = newValue
        sessionController.updateCaptureQuality(newValue)
    }

    func setGridEnabled(_ newValue: Bool) {
        gridEnabled = newValue
        CameraPreferences.gridEnabled = newValue
    }

    func setTimerSeconds(_ seconds: Int) {
        timerSeconds = seconds
        CameraPreferences.timerSeconds = seconds
    }

    func setFrontPreviewMirrored(_ enabled: Bool) {
        var updated = layout
        updated.frontPreviewMirrored = enabled
        updateLayout(updated)
    }

    func setFrontCaptureMirrored(_ enabled: Bool) {
        var updated = layout
        updated.frontCaptureMirrored = enabled
        updateLayout(updated)
    }

    func focusAndExpose(at point: CGPoint) {
        sessionController.focusAndExpose(at: point)
    }

    func zoomBackCamera(by scale: CGFloat) {
        sessionController.zoomBackCamera(by: scale)
    }

    func dismissLatestPhoto() {
        sessionController.dismissLatestPhoto()
    }

    func saveLatestPhoto() {
        sessionController.saveLatestPhoto()
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func dismissLatestVideo() {
        sessionController.dismissLatestVideo()
    }

    func saveLatestVideo() {
        sessionController.saveLatestVideo()
    }

    func startRecording() {
        sessionController.startRecording()
    }

    func stopRecording() {
        sessionController.stopRecording()
    }

    private func updateLayout(_ updated: DualCameraLayout) {
        layout = updated
        persistLayoutConfiguration()
    }

    private func persistLayoutConfiguration() {
        sessionController.updateLayout(layout, aspectRatio: aspectRatio)
    }

    private func bindSession() {
        sessionController.$state.receive(on: DispatchQueue.main).assign(to: &$state)
        sessionController.$isCapturing.receive(on: DispatchQueue.main).assign(to: &$isCapturing)
        sessionController.$isRecording.receive(on: DispatchQueue.main).assign(to: &$isRecording)
        sessionController.$recordingDuration.receive(on: DispatchQueue.main).assign(to: &$recordingDuration)
        sessionController.$isSavingMedia.receive(on: DispatchQueue.main).assign(to: &$isSavingMedia)
        sessionController.$latestPhotoSet.receive(on: DispatchQueue.main).assign(to: &$latestPhotoSet)
        sessionController.$latestVideoURL.receive(on: DispatchQueue.main).assign(to: &$latestVideoURL)
        sessionController.$notice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                self?.notice = notice
                if notice?.message == CameraError.photoLibraryDenied.localizedDescription {
                    self?.showsPhotoPermissionSettings = true
                }
            }
            .store(in: &cancellables)
        sessionController.$availableRearCameras.receive(on: DispatchQueue.main).assign(to: &$availableRearCameras)
        sessionController.$selectedRearCamera.receive(on: DispatchQueue.main).assign(to: &$selectedRearCamera)
        sessionController.$diagnostics.receive(on: DispatchQueue.main).assign(to: &$diagnostics)
        sessionController.$zoomFactor.receive(on: DispatchQueue.main).assign(to: &$zoomFactor)
        sessionController.$isFakeCamera.receive(on: DispatchQueue.main).assign(to: &$isFakeCamera)
    }
}
