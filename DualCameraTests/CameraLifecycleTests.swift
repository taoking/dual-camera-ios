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

    func testPhotoPreviewPreventsResume() {
        let lifecycle = startedLifecycle()
        XCTAssertEqual(lifecycle.setMediaPreview(true, sessionIsRunning: true), .stopSession)
        XCTAssertEqual(lifecycle.didBecomeActive(sessionIsRunning: false), .none)
    }

    func testVideoPreviewPreventsResume() {
        let lifecycle = startedLifecycle()
        _ = lifecycle.setMediaPreview(true, sessionIsRunning: false)
        XCTAssertFalse(lifecycle.mayStartSession)
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

    private func startedLifecycle() -> CameraLifecycleCoordinator {
        let lifecycle = CameraLifecycleCoordinator()
        _ = lifecycle.requestStart(sessionIsRunning: false)
        return lifecycle
    }
}
