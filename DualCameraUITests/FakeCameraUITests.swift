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
        app.launchArguments.append("-fakeMediaSaveDelay")
        launch()
        tapTopMenu("settings-menu")
        app.buttons["3 秒"].tap()
        app.buttons["photo-shutter"].tap()
        let countdown = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "倒计时")
        ).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 1.5))

        let recentMedia = app.buttons["recent-media"]
        XCTAssertTrue(recentMedia.waitForExistence(timeout: 6))
        let savingInBackground = expectation(
            for: NSPredicate(format: "value == %@", "正在后台保存"),
            evaluatedWith: recentMedia
        )
        wait(for: [savingInBackground], timeout: 2)
        XCTAssertFalse(app.buttons["photo-review-close"].exists)
        XCTAssertTrue(app.buttons["photo-shutter"].isHittable)
        recentMedia.tap()
        XCTAssertTrue(app.buttons["photo-review-close"].waitForExistence(timeout: 2))
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
        let failure = app.staticTexts.matching(identifier: "camera-status")
            .containing(NSPredicate(format: "label CONTAINS %@", "模拟保存失败"))
            .firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 4))
        let retrySave = app.buttons["camera-status-action"]
        XCTAssertTrue(retrySave.waitForExistence(timeout: 2))
        XCTAssertEqual(retrySave.label, "重试保存")
        XCTAssertFalse(app.buttons["photo-review-close"].exists)
        XCTAssertTrue(app.buttons["photo-shutter"].isHittable)

        let recentMedia = app.buttons["recent-media"]
        XCTAssertTrue(recentMedia.waitForExistence(timeout: 2))
        recentMedia.tap()
        XCTAssertTrue(app.buttons["photo-save"].waitForExistence(timeout: 2))
        app.buttons["photo-review-close"].tap()

        app.buttons["video-record"].tap()
        let recordingStatus = app.staticTexts["recording-status"]
        XCTAssertTrue(recordingStatus.waitForExistence(timeout: 2))
        XCTAssertTrue(recordingStatus.label.contains("录制中"))

        let recordingDuration = app.staticTexts["recording-duration"]
        XCTAssertTrue(recordingDuration.waitForExistence(timeout: 1))
        let initialDuration = recordingDuration.label
        let durationAdvanced = expectation(
            for: NSPredicate(format: "label != %@", initialDuration),
            evaluatedWith: recordingDuration
        )
        wait(for: [durationAdvanced], timeout: 3)

        XCTAssertTrue(app.buttons["停止视频录制"].waitForExistence(timeout: 2))
        app.buttons["photo-shutter"].tap()
        let videoRecord = app.buttons["video-record"]
        XCTAssertTrue(videoRecord.waitForExistence(timeout: 3))
        let videoRecordEnabled = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: videoRecord
        )
        wait(for: [videoRecordEnabled], timeout: 4)
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.staticTexts["模拟"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["photo-shutter"].waitForExistence(timeout: 3))
    }

    private func selectFromLayoutMenu(_ title: String) {
        tapTopMenu("layout-menu")
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "布局菜单缺少 \(title)")
        item.tap()
    }

    private func tapTopMenu(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = app.buttons[identifier]
        XCTAssertTrue(
            menu.waitForExistence(timeout: 2),
            "顶部菜单不存在：\(identifier)",
            file: file,
            line: line
        )

        if menu.isHittable {
            menu.tap()
        } else {
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
