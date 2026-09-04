import XCTest
@testable import DualCamera

/// `CameraNoticePolicy` 已覆盖「能否发布」的判定，这里覆盖此前没有直接测试的
/// 发布时序：唯一 ID 消费、按媒体任务解除、无操作提示的自动消失。
final class CameraNoticeCenterTests: XCTestCase {
    /// 手动驱动的调度器，避免测试真的等待自动消失时长。
    private final class ManualScheduler {
        private var pending = [(delay: TimeInterval, work: () -> Void)]()

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((delay, work))
        }

        var scheduledDelays: [TimeInterval] { pending.map(\.delay) }

        func fireAll() {
            let work = pending.map(\.work)
            pending.removeAll()
            work.forEach { $0() }
        }

        /// 只触发最早排入的那一条，用于验证旧计时器不会清掉后来的提示。
        func fireFirst() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().work()
        }
    }

    private var scheduler: ManualScheduler!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
    }

    private func makeCenter() -> CameraNoticeCenter {
        let scheduler = scheduler!
        return CameraNoticeCenter(autoDismissInterval: 4) { delay, work in
            scheduler.schedule(delay, work)
        }
    }

    func testPublishesNoticeAndSchedulesAutoDismissForPlainNotice() {
        let center = makeCenter()
        center.publish(message: "已拍摄", kind: .info)

        XCTAssertEqual(center.notice?.message, "已拍摄")
        XCTAssertEqual(scheduler.scheduledDelays, [4])

        scheduler.fireAll()
        XCTAssertNil(center.notice)
    }

    /// 带操作的提示要等用户处理，不能自动消失。
    func testActionableNoticeIsNotAutoDismissed() {
        let center = makeCenter()
        center.publish(message: "保存失败", kind: .error, action: .retryMediaSaves)

        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
        scheduler.fireAll()
        XCTAssertNotNil(center.notice)
    }

    /// 第一条提示的自动消失计时到点时，若显示的已经是后来的第二条，不能把它清掉。
    func testAutoDismissOfEarlierNoticeDoesNotClearLaterOne() {
        let center = makeCenter()
        center.publish(message: "第一条", kind: .info)
        center.publish(message: "第二条", kind: .info)
        XCTAssertEqual(scheduler.scheduledDelays.count, 2)

        scheduler.fireFirst()
        XCTAssertEqual(center.notice?.message, "第二条")

        // 第二条自己的计时器到点后才应清除。
        scheduler.fireAll()
        XCTAssertNil(center.notice)
    }

    /// 低优先级提示不得覆盖尚未处理的可操作提示。
    func testLowerPriorityNoticeDoesNotReplaceActionableOne() {
        let center = makeCenter()
        center.publish(message: "权限被拒", kind: .error, action: .openAppSettings)
        center.publish(message: "已拍摄", kind: .info)

        XCTAssertEqual(center.notice?.message, "权限被拒")
    }

    func testConsumeClearsMatchingNotice() throws {
        let center = makeCenter()
        center.publish(message: "保存失败", kind: .error, action: .retryMediaSaves)
        let published = try XCTUnwrap(center.notice)

        center.consume(published)
        XCTAssertNil(center.notice)
    }

    /// 旧界面按钮持有的是旧提示，不能清除之后发布的新提示。
    func testConsumingStaleNoticeLeavesNewerNoticeIntact() throws {
        let center = makeCenter()
        center.publish(message: "旧的失败", kind: .error, action: .retryMediaSaves)
        let stale = try XCTUnwrap(center.notice)
        center.publish(message: "新的失败", kind: .error, action: .retryMediaSaves)

        center.consume(stale)
        XCTAssertEqual(center.notice?.message, "新的失败")
    }

    func testResolveMediaSaveClearsOnlyMatchingJob() {
        let center = makeCenter()
        let job = MediaSaveJobID.photo(UUID())
        center.publish(message: "照片保存失败", kind: .error, action: .retryMediaSaves, mediaJobID: job)

        center.resolveMediaSave(.photo(UUID()))
        XCTAssertNotNil(center.notice, "不同任务的结果不应解除本条提示")

        center.resolveMediaSave(job)
        XCTAssertNil(center.notice)
    }

    func testActionForErrorRoutesPermissionIssuesToSettings() {
        XCTAssertEqual(CameraNoticeCenter.action(for: .permissionDenied), .openAppSettings)
        XCTAssertEqual(CameraNoticeCenter.action(for: .microphonePermissionDenied), .openAppSettings)
        XCTAssertEqual(CameraNoticeCenter.action(for: .photoLibraryDenied), .openAppSettings)
        XCTAssertEqual(CameraNoticeCenter.action(for: .captureTimedOut), .retryMediaSaves)
    }
}
