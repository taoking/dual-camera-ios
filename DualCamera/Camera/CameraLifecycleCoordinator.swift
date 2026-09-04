import Foundation

enum CameraLifecycleAction: Equatable {
    case none
    case startSession
    case stopSession
    case rebuildSession
}

/// 把 ScenePhase 和系统中断归并为可测试的启动意图。
/// 它不直接触碰 AVCaptureSession，具体动作仍由 Session Controller 的串行队列执行。
final class CameraLifecycleCoordinator {
    private(set) var wantsSessionRunning = false
    private(set) var appIsActive = true
    private(set) var appIsBackgrounded = false
    private(set) var isInterrupted = false

    var mayStartSession: Bool {
        wantsSessionRunning && appIsActive && !appIsBackgrounded && !isInterrupted
    }

    func requestStart(sessionIsRunning: Bool) -> CameraLifecycleAction {
        wantsSessionRunning = true
        return actionForCurrentState(sessionIsRunning: sessionIsRunning)
    }

    func requestStop(sessionIsRunning: Bool) -> CameraLifecycleAction {
        wantsSessionRunning = false
        return sessionIsRunning ? .stopSession : .none
    }

    func didBecomeActive(sessionIsRunning: Bool) -> CameraLifecycleAction {
        appIsActive = true
        appIsBackgrounded = false
        return actionForCurrentState(sessionIsRunning: sessionIsRunning)
    }

    /// inactive 仅阻止新的异步授权回调启动 Session，不停止已经运行的会话。
    func willResignActive() -> CameraLifecycleAction {
        appIsActive = false
        return .none
    }

    func didEnterBackground(sessionIsRunning: Bool) -> CameraLifecycleAction {
        appIsActive = false
        appIsBackgrounded = true
        return sessionIsRunning ? .stopSession : .none
    }

    func interruptionBegan(sessionIsRunning: Bool) -> CameraLifecycleAction {
        isInterrupted = true
        return sessionIsRunning ? .stopSession : .none
    }

    func interruptionEnded(sessionIsRunning: Bool) -> CameraLifecycleAction {
        isInterrupted = false
        return actionForCurrentState(sessionIsRunning: sessionIsRunning)
    }

    func mediaServicesWereReset() -> CameraLifecycleAction {
        mayStartSession ? .rebuildSession : .none
    }

    private func actionForCurrentState(sessionIsRunning: Bool) -> CameraLifecycleAction {
        if mayStartSession {
            return sessionIsRunning ? .none : .startSession
        }
        return sessionIsRunning ? .stopSession : .none
    }
}
