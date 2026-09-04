import XCTest
@testable import DualCamera

final class CameraPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: CameraPreferences!

    override func setUp() {
        super.setUp()
        let name = "CameraPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        preferences = CameraPreferences(defaults: defaults)
    }

    override func tearDown() {
        preferences = nil
        defaults = nil
        super.tearDown()
    }

    func testLayoutRoundTripIncludingMirroring() {
        var layout = DualCameraLayout.default
        layout.style = .splitHorizontal
        layout.frontPreviewMirrored = false
        layout.frontCaptureMirrored = false
        preferences.save(layout: layout)
        XCTAssertEqual(preferences.loadLayout(), layout)
    }

    func testCorruptLayoutFallsBackToDefault() {
        defaults.set(Data([0x00, 0x01]), forKey: "camera.layout")
        XCTAssertEqual(preferences.loadLayout(), .default)
    }

    func testAspectRatioRoundTrip() {
        preferences.save(aspectRatio: .nineBySixteen)
        XCTAssertEqual(preferences.loadAspectRatio(), .nineBySixteen)
    }

    func testSaveModeRoundTrip() {
        preferences.save(mode: .composedAndSources)
        XCTAssertEqual(preferences.loadSaveMode(), .composedAndSources)
    }

    func testQualityRoundTrip() {
        preferences.save(quality: .fast)
        XCTAssertEqual(preferences.loadQuality(), .fast)
    }

    func testGridRoundTrip() {
        preferences.gridEnabled = true
        XCTAssertTrue(preferences.gridEnabled)
    }

    func testTimerRoundTrip() {
        preferences.timerSeconds = 10
        XCTAssertEqual(preferences.timerSeconds, 10)
    }
}
