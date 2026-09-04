import XCTest
@testable import DualCamera

final class CameraLifecycleTests: XCTestCase {
    func testActiveStartsWhenWanted() {
        let lifecycle = CameraLifecycleCoordinator()
        XCTAssertEqual(lifecycle.requestStart(sessionIsRunning: false), .startSession)
    }

    func testInactiveDoesNotStopRunningSession() {
        let lifecycle = startedLifecycle()
        XCTAssertEqual(lifecycle.willResignActive(), .none)
        XCTAssertFalse(lifecycle.mayStartSession)
    }

    func testBackgroundStopsSession() {
        let lifecycle = startedLifecycle()
        XCTAssertEqual(lifecycle.didEnterBackground(sessionIsRunning: true), .stopSession)
    }

    func testAuthorizationRequestEnteringBackgroundCannotStartOnCallback() {
        let lifecycle = startedLifecycle()
        _ = lifecycle.didEnterBackground(sessionIsRunning: false)
        XCTAssertFalse(lifecycle.mayStartSession)
    }

    func testAuthorizedCallbackCanStartAfterReturningActive() {
        let lifecycle = startedLifecycle()
        _ = lifecycle.didEnterBackground(sessionIsRunning: false)
        XCTAssertEqual(lifecycle.didBecomeActive(sessionIsRunning: false), .startSession)
    }

    func testInterruptionEndRestoresSession() {
        let lifecycle = startedLifecycle()
        XCTAssertEqual(lifecycle.interruptionBegan(sessionIsRunning: true), .stopSession)
        XCTAssertEqual(lifecycle.interruptionEnded(sessionIsRunning: false), .startSession)
    }

    func testMediaServicesResetRequestsRebuild() {
        let lifecycle = startedLifecycle()
        XCTAssertEqual(lifecycle.mediaServicesWereReset(), .rebuildSession)
    }

    func testActionableNoticeSurvivesTransientNoticeUntilConsumed() {
        let actionable = CameraNotice(
            message: "需要重试",
            kind: .error,
            action: .retrySession
        )
        let transient = CameraNotice(message: "保存成功", kind: .success)

        XCTAssertFalse(CameraNoticePolicy.shouldPublish(transient, replacing: actionable))
        XCTAssertNil(CameraNoticePolicy.consuming(actionable, from: actionable))
    }

    func testSessionRecoveryKeepsPriorityAndOldClickCannotConsumeNewNotice() {
        let sessionNotice = CameraNotice(
            message: "需要重试相机",
            kind: .error,
            action: .retrySession
        )
        let mediaNotice = CameraNotice(
            message: "需要重试保存",
            kind: .error,
            action: .retryMediaSaves
        )
        let newerSessionNotice = CameraNotice(
            message: "新的相机错误",
            kind: .error,
            action: .retrySession
        )

        XCTAssertFalse(CameraNoticePolicy.shouldPublish(mediaNotice, replacing: sessionNotice))
        XCTAssertEqual(
            CameraNoticePolicy.consuming(sessionNotice, from: newerSessionNotice),
            newerSessionNotice
        )
        XCTAssertEqual(CameraState.failed("模拟错误").recoveryAction, .retrySession)
        XCTAssertEqual(CameraState.permissionDenied.recoveryAction, .openAppSettings)
    }

    func testSuccessfulMediaRetryClearsOnlyItsOwnFailureNotice() {
        let photoID = MediaSaveJobID.photo(UUID())
        let videoID = MediaSaveJobID.video(URL(fileURLWithPath: "/tmp/other.mov"))
        let photoNotice = CameraNotice(
            message: "照片保存失败",
            kind: .error,
            action: .retryMediaSaves,
            mediaJobID: photoID
        )

        XCTAssertNil(CameraNoticePolicy.resolvingMediaSave(photoID, from: photoNotice))
        XCTAssertEqual(
            CameraNoticePolicy.resolvingMediaSave(videoID, from: photoNotice),
            photoNotice
        )
    }

    private func startedLifecycle() -> CameraLifecycleCoordinator {
        let lifecycle = CameraLifecycleCoordinator()
        _ = lifecycle.requestStart(sessionIsRunning: false)
        return lifecycle
    }
}
