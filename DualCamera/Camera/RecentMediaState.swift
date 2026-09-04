import Foundation

/// 视频文件相对 PhotoKit 的显式保存状态。删除决策依赖它，而不是依赖缩略图是否还在，
/// 否则「保存完成回调」与「被更新媒体替换」同时发生时会产生删除竞态。
enum VideoSaveStatus: Equatable {
    case saving
    case saved
    case failed
}

/// 最近媒体与视频保存状态的纯状态机。
///
/// 这里只做排序与去留判断，不接触 AVFoundation、PhotoKit、文件系统或界面，
/// 因此项目里最难的几条不变量——单调排序、保存成功与替换缩略图之间的删除竞态、
/// 失败视频的唯一可重试入口——可以直接做单元测试，而不必依赖真机或 Fake Camera。
///
/// 由 `MultiCamSessionController` 在 sessionQueue 上独占持有，本身不做同步。
struct RecentMediaState {
    /// 一个视频被移出「最近媒体」时该如何处置。
    enum VideoDisposition: Equatable {
        /// 正在保存：先记入待删集合，等真实回调成功后再删。
        case deferUntilSaved
        /// 保留唯一的 `.mov` 并重新入队保存。用户失去缩略图入口后不应只剩无主缓存。
        case retainAndRetry
        /// 可以立即清理。`clearRecoveryIndex` 表示是否同时移除恢复索引。
        case deleteNow(clearRecoveryIndex: Bool)
    }

    /// 视频保存回调返回后该做什么。
    enum VideoCompletion: Equatable {
        /// 保存成功且该文件此前已排入待删，可以清理缓存。
        case discardFile
        /// 保存成功但它仍是最近媒体，缓存要留着供查看页使用。
        case keepFile
        /// 保存失败且尚未自动重试过，安排一次自动重试。
        case scheduleAutoRetry
        /// 保存失败但已重试过或不在待删集合，等用户手动重试。
        case awaitManualRetry
    }

    /// 替换最近媒体的结果。`nil` 表示被单调序号闸门拒绝。
    struct Replacement: Equatable {
        /// 被顶替下去、需要按 `VideoDisposition` 处置的旧视频。
        let previousVideoURL: URL?
    }

    private(set) var recentPhotoSet: CapturedPhotoSet?
    private(set) var recentVideoURL: URL?
    private(set) var latestJobID: MediaSaveJobID?

    private var sequenceCounter: UInt64 = 0
    private var recentSequence: UInt64 = 0
    private var videoSaveStatuses = [URL: VideoSaveStatus]()
    private var videoURLsPendingDeletion = Set<URL>()
    private var videoAutoRetryAttempted = Set<URL>()

    // MARK: - 单调排序

    /// 为一次成功开始的录像或一次拍照分配序号。慢完成的视频不能顶替更新的照片，
    /// 判断依据只能是拍摄先后，而不是回调到达先后。
    mutating func nextSequence() -> UInt64 {
        sequenceCounter &+= 1
        return sequenceCounter
    }

    mutating func replace(withPhoto photoSet: CapturedPhotoSet, sequence: UInt64) -> Replacement? {
        guard sequence >= recentSequence else { return nil }
        let previous = recentVideoURL
        recentSequence = sequence
        recentPhotoSet = photoSet
        recentVideoURL = nil
        latestJobID = .photo(photoSet.id)
        return Replacement(previousVideoURL: previous)
    }

    mutating func replace(withVideo url: URL, sequence: UInt64) -> Replacement? {
        guard sequence >= recentSequence else { return nil }
        let previous = recentVideoURL
        recentSequence = sequence
        recentPhotoSet = nil
        recentVideoURL = url
        latestJobID = .video(url)
        // 同一个 URL 重新成为最近媒体时没有旧文件需要处置。
        return Replacement(previousVideoURL: previous == url ? nil : previous)
    }

    func isLatest(_ id: MediaSaveJobID) -> Bool {
        latestJobID == id
    }

    // MARK: - 视频去留

    /// 决定一个即将移出最近媒体的视频如何处置。`isRecoverable` 由恢复索引提供：
    /// 本状态机没有状态记录、但恢复索引仍认得的文件，属于跨进程留下来的失败视频。
    mutating func videoDisposition(for url: URL, isRecoverable: Bool) -> VideoDisposition {
        switch videoSaveStatuses[url] {
        case .saving:
            videoURLsPendingDeletion.insert(url)
            return .deferUntilSaved
        case .failed:
            videoURLsPendingDeletion.insert(url)
            return .retainAndRetry
        case .saved:
            videoSaveStatuses.removeValue(forKey: url)
            return .deleteNow(clearRecoveryIndex: true)
        case nil:
            guard isRecoverable else { return .deleteNow(clearRecoveryIndex: false) }
            videoSaveStatuses[url] = .failed
            videoURLsPendingDeletion.insert(url)
            return .retainAndRetry
        }
    }

    mutating func markVideoSaving(_ url: URL) {
        videoSaveStatuses[url] = .saving
    }

    /// 该视频不会出现在缩略图里（界面已退出，或已被更新媒体顶替），
    /// 只有排入待删集合，保存成功后才有地方清理它的缓存。
    mutating func markVideoPendingDeletion(_ url: URL) {
        videoURLsPendingDeletion.insert(url)
    }

    mutating func completeVideoSave(_ url: URL, succeeded: Bool) -> VideoCompletion {
        guard succeeded else {
            videoSaveStatuses[url] = .failed
            // 只有已排入待删（即不再是最近媒体）且没自动重试过的，才安排一次自动重试。
            guard videoURLsPendingDeletion.contains(url),
                  videoAutoRetryAttempted.insert(url).inserted else {
                return .awaitManualRetry
            }
            return .scheduleAutoRetry
        }

        videoSaveStatuses[url] = .saved
        videoAutoRetryAttempted.remove(url)
        guard videoURLsPendingDeletion.remove(url) != nil else { return .keepFile }
        videoSaveStatuses.removeValue(forKey: url)
        return .discardFile
    }

    /// 自动重试真正执行前的复核：期间状态可能已经改变。
    func shouldRunScheduledRetry(for url: URL) -> Bool {
        videoURLsPendingDeletion.contains(url) && videoSaveStatuses[url] == .failed
    }

    /// 相机界面正常退出时释放最近视频，返回需要处置的 URL。
    mutating func releaseRecentVideoOnStop() -> URL? {
        guard let url = recentVideoURL else { return nil }
        recentVideoURL = nil
        if latestJobID == .video(url) {
            latestJobID = nil
        }
        return url
    }

    // MARK: - 跨进程恢复

    /// 恢复索引里的文件已不存在，丢弃与它相关的全部本地状态。
    mutating func forgetVideo(_ url: URL) {
        videoSaveStatuses.removeValue(forKey: url)
        videoURLsPendingDeletion.remove(url)
        videoAutoRetryAttempted.remove(url)
    }

    /// 重新发现一个待恢复视频。不是最近媒体的要记入待删集合，
    /// 否则保存成功后没有任何地方会清理它的缓存。
    mutating func rediscoverVideo(_ url: URL, isEnqueued: Bool) {
        videoSaveStatuses[url] = isEnqueued ? .saving : .failed
        if url != recentVideoURL {
            videoURLsPendingDeletion.insert(url)
        }
    }
}

extension Result {
    /// 保存回调只关心成败，不关心具体错误时使用。
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
