import Foundation

struct CameraPreferences {
    private enum Key {
        static let layout = "camera.layout"
        static let aspectRatio = "camera.aspectRatio"
        static let saveMode = "camera.saveMode"
        static let quality = "camera.quality"
        static let grid = "camera.grid"
        static let timer = "camera.timer"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLayout() -> DualCameraLayout {
        guard let data = defaults.data(forKey: Key.layout),
              let layout = try? JSONDecoder().decode(DualCameraLayout.self, from: data) else {
            return .default
        }
        return layout
    }

    func save(layout: DualCameraLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: Key.layout)
    }

    func loadAspectRatio() -> CaptureAspectRatio {
        CaptureAspectRatio(rawValue: defaults.string(forKey: Key.aspectRatio) ?? "") ?? .threeByFour
    }

    func save(aspectRatio: CaptureAspectRatio) {
        defaults.set(aspectRatio.rawValue, forKey: Key.aspectRatio)
    }

    func loadSaveMode() -> PhotoSaveMode {
        PhotoSaveMode(rawValue: defaults.string(forKey: Key.saveMode) ?? "") ?? .composedOnly
    }

    func save(mode: PhotoSaveMode) {
        defaults.set(mode.rawValue, forKey: Key.saveMode)
    }

    func loadQuality() -> CaptureQuality {
        CaptureQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced
    }

    func save(quality: CaptureQuality) {
        defaults.set(quality.rawValue, forKey: Key.quality)
    }

    var gridEnabled: Bool {
        get { defaults.bool(forKey: Key.grid) }
        nonmutating set { defaults.set(newValue, forKey: Key.grid) }
    }

    var timerSeconds: Int {
        get { defaults.object(forKey: Key.timer) as? Int ?? 0 }
        nonmutating set { defaults.set(newValue, forKey: Key.timer) }
    }

    func resetForUITesting() {
        [Key.layout, Key.aspectRatio, Key.saveMode, Key.quality, Key.grid, Key.timer]
            .forEach(defaults.removeObject(forKey:))
    }
}
