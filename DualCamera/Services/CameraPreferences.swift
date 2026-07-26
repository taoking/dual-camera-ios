import Foundation

enum CameraPreferences {
    private static let layoutKey = "camera.layout"
    private static let aspectRatioKey = "camera.aspectRatio"
    private static let saveModeKey = "camera.saveMode"
    private static let qualityKey = "camera.quality"
    private static let gridKey = "camera.grid"
    private static let timerKey = "camera.timer"

    static func loadLayout() -> DualCameraLayout {
        guard let data = UserDefaults.standard.data(forKey: layoutKey),
              let layout = try? JSONDecoder().decode(DualCameraLayout.self, from: data) else {
            return .default
        }
        return layout
    }

    static func save(layout: DualCameraLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: layoutKey)
    }

    static func loadAspectRatio() -> CaptureAspectRatio {
        CaptureAspectRatio(rawValue: UserDefaults.standard.string(forKey: aspectRatioKey) ?? "") ?? .threeByFour
    }

    static func save(aspectRatio: CaptureAspectRatio) {
        UserDefaults.standard.set(aspectRatio.rawValue, forKey: aspectRatioKey)
    }

    static func loadSaveMode() -> PhotoSaveMode {
        PhotoSaveMode(rawValue: UserDefaults.standard.string(forKey: saveModeKey) ?? "") ?? .composedOnly
    }

    static func save(mode: PhotoSaveMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: saveModeKey)
    }

    static func loadQuality() -> CaptureQuality {
        CaptureQuality(rawValue: UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .balanced
    }

    static func save(quality: CaptureQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: qualityKey)
    }

    static var gridEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: gridKey) }
        set { UserDefaults.standard.set(newValue, forKey: gridKey) }
    }

    static var timerSeconds: Int {
        get { UserDefaults.standard.object(forKey: timerKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: timerKey) }
    }
}
