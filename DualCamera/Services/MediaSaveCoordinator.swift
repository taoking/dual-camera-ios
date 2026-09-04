import Foundation

enum MediaSaveJobID: Hashable {
    case photo(UUID)
    case video(URL)
}

/// 在独立队列执行 JPEG 编码与 PhotoKit 调度，并按媒体 ID 防止重复入队。
final class MediaSaveCoordinator {
    typealias Operation = (@escaping (Result<Void, CameraError>) -> Void) -> Void
    typealias Completion = (MediaSaveJobID, Result<Void, CameraError>) -> Void

    static let shared = MediaSaveCoordinator()

    private let workQueue: DispatchQueue
    private let lock = NSLock()
    private var activeJobs = Set<MediaSaveJobID>()
    private var finishingJobs = Set<MediaSaveJobID>()

    init(workQueue: DispatchQueue = DispatchQueue(
        label: "com.taoking.dualcamera.media-save",
        qos: .utility
    )) {
        self.workQueue = workQueue
    }

    @discardableResult
    func enqueue(
        id: MediaSaveJobID,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) -> Bool {
        lock.lock()
        let inserted = activeJobs.insert(id).inserted
        lock.unlock()
        guard inserted else { return false }

        // 保存任务一旦入队就应独立完成；即使上层界面在 PhotoKit
        // 回调前释放，也不能因弱引用而直接丢弃任务与收尾回调。
        workQueue.async {
            operation { result in
                self.finish(id: id, result: result, completion: completion)
            }
        }
        return true
    }

    func contains(_ id: MediaSaveJobID) -> Bool {
        lock.lock()
        let contains = activeJobs.contains(id)
        lock.unlock()
        return contains
    }

    var activeJobCount: Int {
        lock.lock()
        let count = activeJobs.count
        lock.unlock()
        return count
    }

    var activeVideoURLs: Set<URL> {
        lock.lock()
        let urls = Set(activeJobs.compactMap { id -> URL? in
            guard case .video(let url) = id else { return nil }
            return url.standardizedFileURL
        })
        lock.unlock()
        return urls
    }

    private func finish(
        id: MediaSaveJobID,
        result: Result<Void, CameraError>,
        completion: @escaping Completion
    ) {
        lock.lock()
        let shouldComplete = activeJobs.contains(id) && finishingJobs.insert(id).inserted
        lock.unlock()
        guard shouldComplete else { return }

        // completion 会先把失败视频原子转移到恢复索引。转移完成前仍把任务
        // 计入 active，避免录制容量检查短暂漏掉该文件并放行第六个视频。
        completion(id, result)

        lock.lock()
        activeJobs.remove(id)
        finishingJobs.remove(id)
        lock.unlock()
    }

}

struct RecoverablePhotoSaveJob {
    let id: UUID
    let operation: MediaSaveCoordinator.Operation
}

enum VideoFileFinalizationInspector {
    static func isFinalizedMovie(at url: URL) -> Bool {
        guard let fileSizeNumber = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return false
        }
        let fileSize = fileSizeNumber.uint64Value
        guard fileSize >= 8, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var hasFileType = false
        var hasMediaData = false
        var hasMovieMetadata = false
        while offset <= fileSize - 8 {
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 16), header.count >= 8 else {
                    return false
                }
                let shortSize = integer(in: header, offset: 0, length: 4)
                guard let type = String(data: header.subdata(in: 4..<8), encoding: .ascii) else {
                    return false
                }
                let headerSize: UInt64
                let atomSize: UInt64
                switch shortSize {
                case 0:
                    headerSize = 8
                    atomSize = fileSize - offset
                case 1:
                    guard header.count >= 16 else { return false }
                    headerSize = 16
                    atomSize = integer(in: header, offset: 8, length: 8)
                default:
                    headerSize = 8
                    atomSize = shortSize
                }
                guard atomSize >= headerSize, atomSize <= fileSize - offset else { return false }
                switch type {
                case "ftyp": hasFileType = true
                case "mdat": hasMediaData = true
                case "moov": hasMovieMetadata = true
                default: break
                }
                offset += atomSize
            } catch {
                return false
            }
        }
        return hasFileType && hasMediaData && hasMovieMetadata
    }

    private static func integer(in data: Data, offset: Int, length: Int) -> UInt64 {
        guard offset >= 0, length > 0, offset + length <= data.count else { return 0 }
        return (offset..<(offset + length)).reduce(into: UInt64.zero) { value, index in
            value = (value << 8) | UInt64(data[data.startIndex + index])
        }
    }
}

struct StaleInFlightVideoRecoveryResult: Equatable {
    let promoted: [URL]
    let discarded: [URL]
    let missing: [URL]
}

/// 保存未完成后的应用级恢复索引。照片任务在当前进程内保留；视频用持久化的
/// in-flight／ready 两阶段区分“writer 尚未封口”和“可交给 PhotoKit 保存”。
final class MediaRecoveryStore {
    static let shared = MediaRecoveryStore()
    static let maximumPendingPhotoCount = 5
    static let maximumPendingVideoCount = 5
    static let maximumPendingVideoBytes: Int64 = 1_073_741_824

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let recoverableVideoPathsKey: String
    private let inFlightVideoPathsKey: String
    private var photoJobs = [UUID: RecoverablePhotoSaveJob]()
    private var recoverableVideoPaths: Set<String>
    private var inFlightVideoPaths: Set<String>
    private var staleInFlightVideoPaths: Set<String>

    init(
        defaults: UserDefaults = .standard,
        failedVideoPathsKey: String = "DualCamera.failedVideoSavePaths",
        inFlightVideoPathsKey: String = "DualCamera.inFlightVideoPaths"
    ) {
        self.defaults = defaults
        recoverableVideoPathsKey = failedVideoPathsKey
        self.inFlightVideoPathsKey = inFlightVideoPathsKey
        recoverableVideoPaths = Set(defaults.stringArray(forKey: failedVideoPathsKey) ?? [])
        inFlightVideoPaths = Set(defaults.stringArray(forKey: inFlightVideoPathsKey) ?? [])
        staleInFlightVideoPaths = inFlightVideoPaths
    }

    @discardableResult
    func rememberPhoto(_ job: RecoverablePhotoSaveJob) -> Bool {
        lock.lock()
        guard photoJobs[job.id] != nil || photoJobs.count < Self.maximumPendingPhotoCount else {
            lock.unlock()
            return false
        }
        photoJobs[job.id] = job
        lock.unlock()
        return true
    }

    func completePhoto(id: UUID, result: Result<Void, CameraError>) {
        guard case .success = result else { return }
        lock.lock()
        photoJobs.removeValue(forKey: id)
        lock.unlock()
    }

    func pendingPhotos() -> [RecoverablePhotoSaveJob] {
        lock.lock()
        let jobs = Array(photoJobs.values)
        lock.unlock()
        return jobs
    }

    var canAcceptPhoto: Bool {
        lock.lock()
        let canAccept = photoJobs.count < Self.maximumPendingPhotoCount
        lock.unlock()
        return canAccept
    }

    func canAcceptVideo(activeVideoURLs: Set<URL>) -> Bool {
        lock.lock()
        let retainedIndexPaths = recoverableVideoPaths.union(inFlightVideoPaths)
        lock.unlock()

        let activePaths = Set(activeVideoURLs.map { $0.standardizedFileURL.path })
        let retainedPaths = retainedIndexPaths.union(activePaths)
        guard retainedPaths.count < Self.maximumPendingVideoCount else { return false }

        let retainedBytes = retainedPaths.reduce(into: Int64.zero) { total, path in
            guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
                return
            }
            total += size.int64Value
        }
        return retainedBytes < Self.maximumPendingVideoBytes
    }

    func recordVideoResult(url: URL, result: Result<Void, CameraError>) {
        let path = url.standardizedFileURL.path
        lock.lock()
        switch result {
        case .success:
            recoverableVideoPaths.remove(path)
            inFlightVideoPaths.remove(path)
        case .failure:
            recoverableVideoPaths.insert(path)
            inFlightVideoPaths.remove(path)
        }
        persistRecoverableVideoPathsLocked()
        persistInFlightVideoPathsLocked()
        lock.unlock()
    }

    func markVideoInFlight(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        inFlightVideoPaths.insert(path)
        persistInFlightVideoPathsLocked()
        lock.unlock()
    }

    func markVideoReadyToSave(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        recoverableVideoPaths.insert(path)
        inFlightVideoPaths.remove(path)
        // 先持久化 ready，再移除 in-flight；若进程恰好中断，冷启动会优先
        // 保留同时存在于 ready 的文件，不会把已封口视频当作残缺 writer 删除。
        persistRecoverableVideoPathsLocked()
        persistInFlightVideoPathsLocked()
        lock.unlock()
    }

    func recoverableVideos() -> [URL] {
        lock.lock()
        let paths = recoverableVideoPaths
        lock.unlock()
        return paths.map(URL.init(fileURLWithPath:))
    }

    func isRecoverableVideo(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        lock.lock()
        let contains = recoverableVideoPaths.contains(path)
        lock.unlock()
        return contains
    }

    func inFlightVideos() -> [URL] {
        lock.lock()
        let paths = inFlightVideoPaths
        lock.unlock()
        return paths.map(URL.init(fileURLWithPath:))
    }

    func recoverStaleInFlightVideos() -> StaleInFlightVideoRecoveryResult {
        lock.lock()
        let stalePaths = staleInFlightVideoPaths
        var promoted = [URL]()
        var discarded = [URL]()
        var missing = [URL]()
        for path in stalePaths.sorted() {
            let url = URL(fileURLWithPath: path)
            if recoverableVideoPaths.contains(path) {
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                missing.append(url)
                continue
            }
            if VideoFileFinalizationInspector.isFinalizedMovie(at: url) {
                recoverableVideoPaths.insert(path)
                promoted.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
                discarded.append(url)
            }
        }
        inFlightVideoPaths.subtract(stalePaths)
        staleInFlightVideoPaths.removeAll()
        // 与 markVideoReadyToSave 相同：先落 ready，再清 in-flight。
        persistRecoverableVideoPathsLocked()
        persistInFlightVideoPathsLocked()
        lock.unlock()
        return StaleInFlightVideoRecoveryResult(
            promoted: promoted,
            discarded: discarded,
            missing: missing
        )
    }

    func removeVideo(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        recoverableVideoPaths.remove(path)
        inFlightVideoPaths.remove(path)
        persistRecoverableVideoPathsLocked()
        persistInFlightVideoPathsLocked()
        lock.unlock()
    }

    func orphanedVideoCaches(
        in directory: URL,
        filenamePrefix: String,
        activeVideoURLs: Set<URL>,
        recentVideoURL: URL?,
        olderThan cutoff: Date
    ) -> [URL] {
        lock.lock()
        var trackedPaths = recoverableVideoPaths.union(inFlightVideoPaths)
        lock.unlock()
        trackedPaths.formUnion(activeVideoURLs.map { $0.standardizedFileURL.path })
        if let recentVideoURL {
            trackedPaths.insert(recentVideoURL.standardizedFileURL.path)
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let fileDate = values?.contentModificationDate ?? values?.creationDate ?? .distantFuture
            return url.pathExtension.lowercased() == "mov" &&
                url.lastPathComponent.hasPrefix(filenamePrefix) &&
                !trackedPaths.contains(url.standardizedFileURL.path) &&
                fileDate < cutoff
        }
    }

    @discardableResult
    func removeVideoCacheIfStillOrphaned(
        _ url: URL,
        filenamePrefix: String,
        activeVideoURLs: Set<URL>,
        recentVideoURL: URL?,
        olderThan cutoff: Date
    ) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        let activePaths = Set(activeVideoURLs.map { $0.standardizedFileURL.path })
        guard standardizedURL.pathExtension.lowercased() == "mov",
              standardizedURL.lastPathComponent.hasPrefix(filenamePrefix),
              !activePaths.contains(path),
              recentVideoURL?.standardizedFileURL.path != path else { return false }

        // 与 writer 登记共用同一把锁，并把最终文件检查和删除放在锁内。
        // 新 writer 总是在创建文件前先登记，因此不会落入检查与删除之间的窗口。
        lock.lock()
        defer { lock.unlock() }
        guard !recoverableVideoPaths.contains(path), !inFlightVideoPaths.contains(path) else {
            return false
        }
        let values = try standardizedURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )
        let fileDate = values.contentModificationDate ?? values.creationDate ?? .distantFuture
        guard fileDate < cutoff, FileManager.default.fileExists(atPath: path) else { return false }
        try FileManager.default.removeItem(at: standardizedURL)
        return true
    }

    private func persistRecoverableVideoPathsLocked() {
        defaults.set(Array(recoverableVideoPaths).sorted(), forKey: recoverableVideoPathsKey)
    }

    private func persistInFlightVideoPathsLocked() {
        defaults.set(Array(inFlightVideoPaths).sorted(), forKey: inFlightVideoPathsKey)
    }
}
