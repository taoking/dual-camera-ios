import Foundation

/// 拥有提示状态及其发布时序：唯一 ID 消费、按媒体任务解除、无操作提示的自动消失。
/// 是否允许覆盖仍由 `CameraNoticePolicy` 判定，这里只负责状态与计时。
///
/// 所有方法都必须在主线程调用——`notice` 是驱动界面的 `@Published`。
/// Controller 在 sessionQueue 上产生提示，因此由它负责切主队列后再调用本类型。
final class CameraNoticeCenter: ObservableObject {
    /// 无操作提示的自动消失时长。注入以便测试不必真的等待。
    static let defaultAutoDismissInterval: TimeInterval = 4

    @Published private(set) var notice: CameraNotice?

    private let autoDismissInterval: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(
        autoDismissInterval: TimeInterval = CameraNoticeCenter.defaultAutoDismissInterval,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.autoDismissInterval = autoDismissInterval
        self.schedule = schedule
    }

    func publish(
        _ error: CameraError,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none,
        mediaJobID: MediaSaveJobID? = nil
    ) {
        publish(
            message: error.localizedDescription,
            kind: kind,
            action: action,
            mediaJobID: mediaJobID
        )
    }

    func publish(
        message: String,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none,
        mediaJobID: MediaSaveJobID? = nil
    ) {
        let incoming = CameraNotice(
            message: message,
            kind: kind,
            action: action,
            mediaJobID: mediaJobID
        )
        guard CameraNoticePolicy.shouldPublish(incoming, replacing: notice) else { return }
        notice = incoming

        // 带操作的提示要等用户处理，不参与自动消失。
        guard action == .none else { return }
        schedule(autoDismissInterval) { [weak self] in
            // 只有仍是同一条提示才清除：期间可能已经发布了新的提示。
            guard self?.notice == incoming else { return }
            self?.notice = nil
        }
    }

    /// 按提示的唯一 ID 消费，旧界面事件无法清除后来发布的提示。
    func consume(_ consumed: CameraNotice) {
        notice = CameraNoticePolicy.consuming(consumed, from: notice)
    }

    /// 对应媒体任务已有结果时解除其提示。
    func resolveMediaSave(_ id: MediaSaveJobID) {
        notice = CameraNoticePolicy.resolvingMediaSave(id, from: notice)
    }

    /// 错误对应的恢复操作。权限类问题只能去设置解决，其余按重试媒体保存处理。
    static func action(for error: CameraError) -> CameraNoticeAction {
        switch error {
        case .permissionDenied, .microphonePermissionDenied, .photoLibraryDenied:
            .openAppSettings
        default:
            .retryMediaSaves
        }
    }
}
