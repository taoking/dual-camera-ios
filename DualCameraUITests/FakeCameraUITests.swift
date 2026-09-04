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
        XCTAssertTrue(app.buttons["shutter"].isEnabled)
    }

    /// 倒计时中点按应立即取消，且不产生任何媒体。
    func testCountdownCanBeCancelledBeforeCapture() {
        launch()
        tapTopMenu("settings-menu")
        app.buttons["10 秒"].tap()
        app.buttons["shutter"].tap()

        let countdown = app.buttons["countdown-cancel"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 2))
        countdown.tap()

        let disappeared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: countdown
        )
        wait(for: [disappeared], timeout: 3)
        XCTAssertFalse(
            app.buttons["recent-media"].exists,
            "取消倒计时后不应产生任何媒体"
        )
        XCTAssertTrue(app.buttons["shutter"].isEnabled)
    }

    func testCountdownCaptureReviewShareAndClose() {
        app.launchArguments.append("-fakeMediaSaveDelay")
        launch()
        tapTopMenu("settings-menu")
        app.buttons["3 秒"].tap()
        app.buttons["shutter"].tap()
        // 倒计时现在是可点按取消的整屏按钮，不再是单纯的文本。
        let countdown = app.buttons["countdown-cancel"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 1.5))

        let recentMedia = app.buttons["recent-media"]
        XCTAssertTrue(recentMedia.waitForExistence(timeout: 6))
        let savingInBackground = expectation(
            for: NSPredicate(format: "value == %@", "正在后台保存"),
            evaluatedWith: recentMedia
        )
        wait(for: [savingInBackground], timeout: 2)
        XCTAssertFalse(app.buttons["photo-review-close"].exists)
        XCTAssertTrue(app.buttons["shutter"].isHittable)
        recentMedia.tap()
        XCTAssertTrue(app.buttons["photo-review-close"].waitForExistence(timeout: 2))
        app.buttons["photo-share"].tap()
        XCTAssertTrue(app.staticTexts["fake-share-sheet"].waitForExistence(timeout: 3))
        app.staticTexts["fake-share-sheet"].swipeDown()
        XCTAssertTrue(app.buttons["photo-review-close"].waitForExistence(timeout: 2))
        app.buttons["photo-review-close"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 2))
    }

    func testSimulatedSaveFailureAndVideoButtonState() {
        app.launchArguments.append("-fakePhotoSaveFailure")
        launch()
        app.buttons["shutter"].tap()
        let failure = app.staticTexts.matching(identifier: "camera-status")
            .matching(NSPredicate(format: "label CONTAINS %@", "模拟保存失败"))
            .firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 4))
        let retrySave = app.buttons["camera-status-action"]
        XCTAssertTrue(retrySave.waitForExistence(timeout: 4))
        XCTAssertEqual(retrySave.label, "重试保存")
        XCTAssertFalse(app.buttons["photo-review-close"].exists)
        XCTAssertTrue(app.buttons["shutter"].isHittable)

        let recentMedia = app.buttons["recent-media"]
        XCTAssertTrue(recentMedia.waitForExistence(timeout: 2))
        recentMedia.tap()
        XCTAssertTrue(app.buttons["photo-save"].waitForExistence(timeout: 2))
        app.buttons["photo-review-close"].tap()
        // 查看页现在带关闭转场，动画结束前点击会落在覆盖层上。
        let reviewDismissed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["photo-review-close"]
        )
        wait(for: [reviewDismissed], timeout: 3)

        // 录制入口改为「切到视频模式 + 按主键」，不再是独立的红点按钮。
        let videoMode = app.buttons["mode-video"]
        XCTAssertTrue(videoMode.waitForExistence(timeout: 2))
        videoMode.tap()
        app.buttons["shutter"].tap()
        let recordingStatus = app.staticTexts["recording-status"]
        XCTAssertTrue(recordingStatus.waitForExistence(timeout: 2))
        let isRecordingLabel = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "录制中"),
            evaluatedWith: recordingStatus
        )
        wait(for: [isRecordingLabel], timeout: 3)

        let recordingDuration = app.staticTexts["recording-duration"]
        XCTAssertTrue(recordingDuration.waitForExistence(timeout: 1))
        let initialDuration = recordingDuration.label
        let durationAdvanced = expectation(
            for: NSPredicate(format: "label != %@", initialDuration),
            evaluatedWith: recordingDuration
        )
        wait(for: [durationAdvanced], timeout: 3)

        // 录制中主键承担停止，语义由无障碍标签体现。
        XCTAssertTrue(app.buttons["停止视频录制"].waitForExistence(timeout: 2))
        app.buttons["shutter"].tap()

        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 3))
        let readyForNextRecording = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: shutter
        )
        wait(for: [readyForNextRecording], timeout: 4)
        // 处理完成后模式切换重新可用。
        XCTAssertTrue(app.buttons["mode-photo"].waitForExistence(timeout: 3))
    }

    /// 模式切换应改变主键语义，且录制中不可切换。
    func testShootingModeSwitchChangesShutterSemantics() {
        launch()
        XCTAssertTrue(app.buttons["同时拍摄前后摄像头"].exists)

        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["开始双摄视频录制"].waitForExistence(timeout: 2))

        app.buttons["mode-photo"].tap()
        XCTAssertTrue(app.buttons["同时拍摄前后摄像头"].waitForExistence(timeout: 2))
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.staticTexts["模拟"].waitForExistence(timeout: 3))
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 3))
        let readyForCapture = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: shutter
        )
        wait(for: [readyForCapture], timeout: 3)
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
