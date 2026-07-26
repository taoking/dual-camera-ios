import XCTest

final class FakeCameraUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fakeCamera", "-fakeShareSheet", "-resetCameraPreferences"]
    }

    func testFakeCameraLaunchLayoutsRatiosAndPIPSizes() {
        launch()
        selectFromLayoutMenu("左右分屏")
        selectFromLayoutMenu("上下分屏")
        selectFromLayoutMenu("画中画")
        selectFromLayoutMenu("1:1")
        selectFromLayoutMenu("9:16")
        selectFromLayoutMenu("3:4")
        selectFromLayoutMenu("小")
        selectFromLayoutMenu("中")
        selectFromLayoutMenu("大")
        XCTAssertTrue(app.buttons["photo-shutter"].isEnabled)
    }

    func testCountdownCaptureReviewShareAndClose() {
        launch()
        app.buttons["settings-menu"].tap()
        app.buttons["3 秒"].tap()
        app.buttons["photo-shutter"].tap()
        let countdown = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "倒计时")
        ).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 1.5))
        XCTAssertTrue(app.buttons["photo-review-close"].waitForExistence(timeout: 6))
        app.buttons["photo-share"].tap()
        XCTAssertTrue(app.staticTexts["fake-share-sheet"].waitForExistence(timeout: 3))
        app.staticTexts["fake-share-sheet"].swipeDown()
        XCTAssertTrue(app.buttons["photo-review-close"].waitForExistence(timeout: 2))
        app.buttons["photo-review-close"].tap()
        XCTAssertTrue(app.buttons["photo-shutter"].waitForExistence(timeout: 2))
    }

    func testSimulatedSaveFailureAndVideoButtonState() {
        app.launchArguments.append("-fakePhotoSaveFailure")
        launch()
        app.buttons["photo-shutter"].tap()
        XCTAssertTrue(app.buttons["photo-save"].waitForExistence(timeout: 3))
        app.buttons["photo-save"].tap()
        let failure = app.staticTexts.matching(identifier: "camera-status")
            .containing(NSPredicate(format: "label CONTAINS %@", "模拟保存失败"))
            .firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 2))
        app.buttons["photo-review-close"].tap()

        app.buttons["video-record"].tap()
        XCTAssertTrue(app.buttons["停止视频录制"].waitForExistence(timeout: 2))
        app.buttons["photo-shutter"].tap()
        XCTAssertTrue(app.buttons["video-record"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["video-record"].isEnabled)
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.staticTexts["模拟"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["photo-shutter"].waitForExistence(timeout: 3))
    }

    private func selectFromLayoutMenu(_ title: String) {
        app.buttons["layout-menu"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "布局菜单缺少 \(title)")
        item.tap()
    }
}
