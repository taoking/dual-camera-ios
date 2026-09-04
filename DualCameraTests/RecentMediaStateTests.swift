import UIKit
import XCTest
@testable import DualCamera

/// 这些不变量此前只能靠 3 个 Fake Camera UI 测试间接覆盖：
/// 单调排序、保存完成与替换缩略图之间的删除竞态、失败视频的唯一可重试入口。
final class RecentMediaStateTests: XCTestCase {
    private var state = RecentMediaState()

    override func setUp() {
        super.setUp()
        state = RecentMediaState()
    }

    // MARK: - 单调排序

    func testSequenceIsMonotonic() {
        XCTAssertEqual(state.nextSequence(), 1)
        XCTAssertEqual(state.nextSequence(), 2)
        XCTAssertEqual(state.nextSequence(), 3)
    }

    /// 慢完成的视频不得顶替更新的照片：判断依据是拍摄先后，不是回调到达先后。
    func testEarlierVideoCannotReplaceNewerPhoto() {
        let videoSequence = state.nextSequence()
        let photoSequence = state.nextSequence()

        XCTAssertNotNil(state.replace(withPhoto: photoSet(), sequence: photoSequence))
        XCTAssertNil(
            state.replace(withVideo: url("late"), sequence: videoSequence),
            "较早开始的视频不应顶替更新的照片"
        )
        XCTAssertNotNil(state.recentPhotoSet)
        XCTAssertNil(state.recentVideoURL)
    }

    func testNewerVideoReplacesEarlierPhoto() {
        let photoSequence = state.nextSequence()
        let videoSequence = state.nextSequence()

        state.replace(withPhoto: photoSet(), sequence: photoSequence)
        XCTAssertNotNil(state.replace(withVideo: url("new"), sequence: videoSequence))
        XCTAssertNil(state.recentPhotoSet)
        XCTAssertEqual(state.recentVideoURL, url("new"))
    }

    func testReplacingPhotoReportsPreviousVideoForDisposal() {
        state.replace(withVideo: url("old"), sequence: state.nextSequence())
        let replacement = state.replace(withPhoto: photoSet(), sequence: state.nextSequence())
        XCTAssertEqual(replacement?.previousVideoURL, url("old"))
    }

    /// 同一个 URL 重新成为最近媒体时没有旧文件需要处置，否则会把正在用的文件删掉。
    func testReplacingWithSameVideoReportsNoPreviousURL() {
        state.replace(withVideo: url("same"), sequence: state.nextSequence())
        let replacement = state.replace(withVideo: url("same"), sequence: state.nextSequence())
        XCTAssertNil(replacement?.previousVideoURL)
    }

    func testIsLatestTracksCurrentMedia() {
        let set = photoSet()
        state.replace(withPhoto: set, sequence: state.nextSequence())
        XCTAssertTrue(state.isLatest(.photo(set.id)))
        XCTAssertFalse(state.isLatest(.photo(UUID())))
        XCTAssertFalse(state.isLatest(.video(url("other"))))
    }

    // MARK: - 视频去留

    /// 正在保存的视频被顶替时不能立即删除，否则会与保存完成回调竞态。
    func testSavingVideoIsDeferredUntilSaveCompletes() {
        let target = url("saving")
        state.markVideoSaving(target)

        XCTAssertEqual(
            state.videoDisposition(for: target, isRecoverable: true),
            .deferUntilSaved
        )
        XCTAssertEqual(state.completeVideoSave(target, succeeded: true), .discardFile)
    }

    /// 失败视频被移出缩略图后，必须保留文件并重新入队，否则用户失去唯一重试入口。
    func testFailedVideoIsRetainedAndRetried() {
        let target = url("failed")
        state.markVideoSaving(target)
        _ = state.completeVideoSave(target, succeeded: false)

        XCTAssertEqual(
            state.videoDisposition(for: target, isRecoverable: true),
            .retainAndRetry
        )
    }

    func testSavedVideoIsDeletedAndClearsRecoveryIndex() {
        let target = url("saved")
        state.markVideoSaving(target)
        _ = state.completeVideoSave(target, succeeded: true)

        XCTAssertEqual(
            state.videoDisposition(for: target, isRecoverable: false),
            .deleteNow(clearRecoveryIndex: true)
        )
    }

    /// 没有本地状态但恢复索引仍认得的文件，是上个进程留下的失败视频。
    func testUntrackedButRecoverableVideoIsRetainedAndRetried() {
        XCTAssertEqual(
            state.videoDisposition(for: url("orphan"), isRecoverable: true),
            .retainAndRetry
        )
    }

    func testUntrackedAndUnrecoverableVideoIsDeletedWithoutTouchingRecoveryIndex() {
        XCTAssertEqual(
            state.videoDisposition(for: url("junk"), isRecoverable: false),
            .deleteNow(clearRecoveryIndex: false)
        )
    }

    // MARK: - 保存完成

    /// 仍是最近媒体的视频保存成功后要留着文件供查看页使用。
    func testSuccessKeepsFileWhenVideoIsStillRecentMedia() {
        let target = url("recent")
        state.replace(withVideo: target, sequence: state.nextSequence())
        state.markVideoSaving(target)

        XCTAssertEqual(state.completeVideoSave(target, succeeded: true), .keepFile)
    }

    /// 每个文件只自动重试一次，避免失败时无限循环。
    func testFailureSchedulesAutoRetryOnlyOnce() {
        let target = url("retry-once")
        state.markVideoPendingDeletion(target)

        XCTAssertEqual(state.completeVideoSave(target, succeeded: false), .scheduleAutoRetry)
        XCTAssertEqual(state.completeVideoSave(target, succeeded: false), .awaitManualRetry)
    }

    /// 仍是最近媒体的失败视频不自动重试，由查看页提供手动入口。
    func testFailureOfRecentMediaAwaitsManualRetry() {
        let target = url("manual")
        state.replace(withVideo: target, sequence: state.nextSequence())

        XCTAssertEqual(state.completeVideoSave(target, succeeded: false), .awaitManualRetry)
    }

    func testScheduledRetryIsSkippedAfterVideoSavesSuccessfully() {
        let target = url("raced")
        state.markVideoPendingDeletion(target)
        XCTAssertEqual(state.completeVideoSave(target, succeeded: false), .scheduleAutoRetry)
        XCTAssertTrue(state.shouldRunScheduledRetry(for: target))

        // 两秒延迟期间保存成功了，延迟到点时不应再入队。
        state.markVideoSaving(target)
        _ = state.completeVideoSave(target, succeeded: true)
        XCTAssertFalse(state.shouldRunScheduledRetry(for: target))
    }

    // MARK: - 退出与跨进程恢复

    func testReleaseRecentVideoOnStopClearsLatestJob() {
        let target = url("stopping")
        state.replace(withVideo: target, sequence: state.nextSequence())

        XCTAssertEqual(state.releaseRecentVideoOnStop(), target)
        XCTAssertNil(state.recentVideoURL)
        XCTAssertFalse(state.isLatest(.video(target)))
        XCTAssertNil(state.releaseRecentVideoOnStop(), "重复调用不应再返回 URL")
    }

    /// 重新发现的待恢复视频若不是最近媒体，必须记入待删集合，
    /// 否则保存成功后没有任何地方会清理它的缓存。
    func testRediscoveredVideoIsPendingDeletionUnlessItIsRecentMedia() {
        let other = url("rediscovered")
        state.rediscoverVideo(other, isEnqueued: false)
        XCTAssertEqual(state.completeVideoSave(other, succeeded: true), .discardFile)

        let recent = url("recent-rediscovered")
        state.replace(withVideo: recent, sequence: state.nextSequence())
        state.rediscoverVideo(recent, isEnqueued: false)
        XCTAssertEqual(state.completeVideoSave(recent, succeeded: true), .keepFile)
    }

    func testForgetVideoClearsAllLocalState() {
        let target = url("gone")
        state.markVideoPendingDeletion(target)
        _ = state.completeVideoSave(target, succeeded: false)

        state.forgetVideo(target)
        XCTAssertFalse(state.shouldRunScheduledRetry(for: target))
        // 状态清空后应按“未跟踪且不可恢复”处理。
        XCTAssertEqual(
            state.videoDisposition(for: target, isRecoverable: false),
            .deleteNow(clearRecoveryIndex: false)
        )
    }

    // MARK: - Helpers

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/DualCamera-\(name).mov")
    }

    private func photoSet() -> CapturedPhotoSet {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let source = CapturedSourcePhoto(originalData: nil, image: image, position: .back)
        return CapturedPhotoSet(
            id: UUID(),
            capturedAt: Date(),
            backPhoto: source,
            frontPhoto: source,
            composedImage: image,
            layout: .default,
            aspectRatio: .threeByFour,
            saveMode: .composedOnly
        )
    }
}
