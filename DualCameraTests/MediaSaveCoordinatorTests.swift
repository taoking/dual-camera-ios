import Foundation
import XCTest
@testable import DualCamera

final class MediaSaveCoordinatorTests: XCTestCase {
    func testRejectsDuplicateJobWhileMatchingIDIsActive() throws {
        let coordinator = MediaSaveCoordinator()
        let id = MediaSaveJobID.photo(UUID())
        let operationStarted = expectation(description: "首个保存任务已开始")
        let firstCompletion = expectation(description: "首个保存任务已完成")
        let rejectedWork = expectation(description: "重复任务不应执行")
        rejectedWork.isInverted = true

        let lock = NSLock()
        var finishOperation: ((Result<Void, CameraError>) -> Void)?

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { completion in
                lock.lock()
                finishOperation = completion
                lock.unlock()
                operationStarted.fulfill()
            },
            completion: { completedID, result in
                XCTAssertEqual(completedID, id)
                self.assertSuccess(result)
                firstCompletion.fulfill()
            }
        ))

        wait(for: [operationStarted], timeout: 1)
        XCTAssertTrue(coordinator.contains(id))
        XCTAssertEqual(coordinator.activeJobCount, 1)

        XCTAssertFalse(coordinator.enqueue(
            id: id,
            operation: { _ in rejectedWork.fulfill() },
            completion: { _, _ in rejectedWork.fulfill() }
        ))

        lock.lock()
        let capturedFinish = finishOperation
        lock.unlock()
        try XCTUnwrap(capturedFinish)(.success(()))

        wait(for: [firstCompletion, rejectedWork], timeout: 0.2)
        XCTAssertFalse(coordinator.contains(id))
    }

    func testAcceptsDifferentIDsWhileAnotherJobIsActive() {
        let coordinator = MediaSaveCoordinator()
        let firstID = MediaSaveJobID.photo(UUID())
        let secondID = MediaSaveJobID.photo(UUID())
        let firstStarted = expectation(description: "首个任务保持活跃")
        let bothCompleted = expectation(description: "两个不同任务均完成")
        bothCompleted.expectedFulfillmentCount = 2

        let lock = NSLock()
        var finishFirst: ((Result<Void, CameraError>) -> Void)?
        var completedIDs = Set<MediaSaveJobID>()

        XCTAssertTrue(coordinator.enqueue(
            id: firstID,
            operation: { completion in
                lock.lock()
                finishFirst = completion
                lock.unlock()
                firstStarted.fulfill()
            },
            completion: { id, _ in
                lock.lock()
                completedIDs.insert(id)
                lock.unlock()
                bothCompleted.fulfill()
            }
        ))

        wait(for: [firstStarted], timeout: 1)
        XCTAssertTrue(coordinator.enqueue(
            id: secondID,
            operation: { $0(.success(())) },
            completion: { id, _ in
                lock.lock()
                completedIDs.insert(id)
                lock.unlock()
                bothCompleted.fulfill()
            }
        ))
        XCTAssertEqual(coordinator.activeJobCount, 2)

        lock.lock()
        let capturedFinish = finishFirst
        lock.unlock()
        capturedFinish?(.success(()))

        wait(for: [bothCompleted], timeout: 1)
        lock.lock()
        let capturedIDs = completedIDs
        lock.unlock()
        XCTAssertEqual(capturedIDs, [firstID, secondID])
        waitUntil("任务完成回调返回后才释放 active") {
            coordinator.activeJobCount == 0
        }
        XCTAssertEqual(coordinator.activeJobCount, 0)
    }

    func testForwardsOperationErrorToCompletion() {
        let coordinator = MediaSaveCoordinator()
        let id = MediaSaveJobID.photo(UUID())
        let expectedError = CameraError.photoLibrarySaveFailed("模拟保存失败")
        let completed = expectation(description: "错误已透传")

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { $0(.failure(expectedError)) },
            completion: { completedID, result in
                XCTAssertEqual(completedID, id)
                guard case .failure(let error) = result else {
                    return XCTFail("应透传保存失败")
                }
                XCTAssertEqual(error, expectedError)
                completed.fulfill()
            }
        ))

        wait(for: [completed], timeout: 1)
    }

    func testCompletesOnlyOnceWhenOperationCallsBackRepeatedly() {
        let coordinator = MediaSaveCoordinator()
        let id = MediaSaveJobID.photo(UUID())
        let completed = expectation(description: "保存完成回调")
        let operationReturned = expectation(description: "重复回调已发出")

        let lock = NSLock()
        var completionCount = 0

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { completion in
                completion(.success(()))
                completion(.failure(.photoLibrarySaveFailed("不应透传的第二次回调")))
                operationReturned.fulfill()
            },
            completion: { _, result in
                lock.lock()
                completionCount += 1
                lock.unlock()
                self.assertSuccess(result)
                completed.fulfill()
            }
        ))

        wait(for: [completed, operationReturned], timeout: 1)
        lock.lock()
        let capturedCount = completionCount
        lock.unlock()
        XCTAssertEqual(capturedCount, 1)
        waitUntil("重复回调收尾后释放 active") {
            !coordinator.contains(id)
        }
        XCTAssertFalse(coordinator.contains(id))
    }

    func testAcceptsMatchingIDAgainAfterCompletion() {
        let coordinator = MediaSaveCoordinator()
        let id = MediaSaveJobID.video(URL(fileURLWithPath: "/tmp/media-save-test.mov"))
        let firstCompletion = expectation(description: "首轮任务完成")
        let secondCompletion = expectation(description: "第二轮任务完成")

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { $0(.success(())) },
            completion: { _, result in
                self.assertSuccess(result)
                firstCompletion.fulfill()
            }
        ))

        wait(for: [firstCompletion], timeout: 1)
        waitUntil("首轮完成收尾") {
            !coordinator.contains(id)
        }
        XCTAssertFalse(coordinator.contains(id))

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { $0(.success(())) },
            completion: { _, result in
                self.assertSuccess(result)
                secondCompletion.fulfill()
            }
        ))

        wait(for: [secondCompletion], timeout: 1)
        waitUntil("第二轮完成收尾") {
            !coordinator.contains(id)
        }
        XCTAssertFalse(coordinator.contains(id))
    }

    func testTracksActiveVideoURLsUntilSaveCompletes() throws {
        let coordinator = MediaSaveCoordinator()
        let url = URL(fileURLWithPath: "/tmp/active-video-\(UUID().uuidString).mov")
        let id = MediaSaveJobID.video(url)
        let started = expectation(description: "视频保存已开始")
        let completed = expectation(description: "视频保存已结束")
        let lock = NSLock()
        var finish: ((Result<Void, CameraError>) -> Void)?

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { completion in
                lock.lock()
                finish = completion
                lock.unlock()
                started.fulfill()
            },
            completion: { _, _ in completed.fulfill() }
        ))
        wait(for: [started], timeout: 1)
        XCTAssertEqual(coordinator.activeVideoURLs, [url.standardizedFileURL])

        lock.lock()
        let capturedFinish = finish
        lock.unlock()
        try XCTUnwrap(capturedFinish)(.success(()))
        wait(for: [completed], timeout: 1)
        XCTAssertTrue(coordinator.activeVideoURLs.isEmpty)
    }

    func testVideoRemainsActiveUntilRecoveryCompletionReturns() {
        let coordinator = MediaSaveCoordinator()
        let url = URL(fileURLWithPath: "/tmp/active-during-completion-\(UUID().uuidString).mov")
        let id = MediaSaveJobID.video(url)
        let observed = expectation(description: "完成回调执行期间仍计入 active")

        XCTAssertTrue(coordinator.enqueue(
            id: id,
            operation: { $0(.failure(.photoLibrarySaveFailed("模拟失败"))) },
            completion: { _, _ in
                XCTAssertTrue(coordinator.contains(id))
                XCTAssertEqual(coordinator.activeVideoURLs, [url.standardizedFileURL])
                observed.fulfill()
            }
        ))

        wait(for: [observed], timeout: 1)
        XCTAssertFalse(coordinator.contains(id))
    }

    func testAcceptedJobFinishesAfterOwnerReleasesCoordinator() throws {
        var coordinator: MediaSaveCoordinator? = MediaSaveCoordinator()
        let retainedCoordinator = TestWeakBox(coordinator)
        let id = MediaSaveJobID.video(URL(fileURLWithPath: "/tmp/media-save-retention-test.mov"))
        let operationStarted = expectation(description: "释放外部引用后任务仍开始")
        let jobCompleted = expectation(description: "释放外部引用后任务仍完成")
        let lock = NSLock()
        var finishOperation: ((Result<Void, CameraError>) -> Void)?

        XCTAssertTrue(coordinator?.enqueue(
            id: id,
            operation: { completion in
                lock.lock()
                finishOperation = completion
                lock.unlock()
                operationStarted.fulfill()
            },
            completion: { completedID, result in
                XCTAssertEqual(completedID, id)
                self.assertSuccess(result)
                jobCompleted.fulfill()
            }
        ) ?? false)

        coordinator = nil
        wait(for: [operationStarted], timeout: 1)
        XCTAssertNotNil(retainedCoordinator.value)

        lock.lock()
        let capturedFinish = finishOperation
        lock.unlock()
        try XCTUnwrap(capturedFinish)(.success(()))
        wait(for: [jobCompleted], timeout: 1)
    }

    func testRecoveryStoreRetainsFailedPhotoUntilSuccessfulRetry() {
        let defaults = makeIsolatedDefaults()
        let key = "failed-videos"
        let store = MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)
        let id = UUID()
        let job = RecoverablePhotoSaveJob(id: id, operation: { _ in })

        store.rememberPhoto(job)
        XCTAssertEqual(store.pendingPhotos().map(\.id), [id])

        store.completePhoto(
            id: id,
            result: .failure(.photoLibrarySaveFailed("模拟失败"))
        )
        XCTAssertEqual(store.pendingPhotos().map(\.id), [id])

        store.completePhoto(id: id, result: .success(()))
        XCTAssertTrue(store.pendingPhotos().isEmpty)
    }

    func testRecoveryStorePersistsTwoPhaseVideoStateUntilSuccess() {
        let defaults = makeIsolatedDefaults()
        let key = "failed-videos"
        let url = URL(fileURLWithPath: "/tmp/recoverable-video-\(UUID().uuidString).mov")
        let firstStore = MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)

        firstStore.markVideoInFlight(url)
        XCTAssertFalse(firstStore.isRecoverableVideo(url))
        XCTAssertEqual(firstStore.inFlightVideos(), [url.standardizedFileURL])

        let writingRestoredStore = MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)
        XCTAssertEqual(writingRestoredStore.inFlightVideos(), [url.standardizedFileURL])
        writingRestoredStore.markVideoReadyToSave(url)
        XCTAssertTrue(writingRestoredStore.inFlightVideos().isEmpty)
        XCTAssertTrue(writingRestoredStore.isRecoverableVideo(url))

        writingRestoredStore.recordVideoResult(
            url: url,
            result: .failure(.photoLibrarySaveFailed("模拟失败"))
        )
        XCTAssertTrue(writingRestoredStore.isRecoverableVideo(url))

        let restoredStore = MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)
        XCTAssertEqual(restoredStore.recoverableVideos(), [url.standardizedFileURL])

        restoredStore.recordVideoResult(url: url, result: .success(()))
        XCTAssertFalse(restoredStore.isRecoverableVideo(url))
        XCTAssertTrue(
            MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)
                .recoverableVideos()
                .isEmpty
        )
    }

    func testRecoveryStoreRemovesMissingVideoExplicitly() {
        let defaults = makeIsolatedDefaults()
        let key = "failed-videos"
        let store = MediaRecoveryStore(defaults: defaults, failedVideoPathsKey: key)
        let url = URL(fileURLWithPath: "/tmp/missing-video-\(UUID().uuidString).mov")

        store.recordVideoResult(
            url: url,
            result: .failure(.photoLibrarySaveFailed("模拟失败"))
        )
        store.removeVideo(url)

        XCTAssertFalse(store.isRecoverableVideo(url))
        XCTAssertTrue(store.recoverableVideos().isEmpty)
    }

    func testRecoveryStoreFindsOnlyUntrackedOwnedVideoCaches() throws {
        let store = MediaRecoveryStore(
            defaults: makeIsolatedDefaults(),
            failedVideoPathsKey: "recoverable-videos"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-video-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeFile(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1])))
            return url
        }

        let recoverable = makeFile("DualCamera-recoverable.mov")
        let active = makeFile("DualCamera-active.mov")
        let recent = makeFile("DualCamera-recent.mov")
        let orphan = makeFile("DualCamera-orphan.mov")
        _ = makeFile("DualCamera-fresh-orphan.mov")
        _ = makeFile("OtherApp-orphan.mov")
        _ = makeFile("DualCamera-not-video.jpg")
        store.markVideoInFlight(recoverable)
        let cutoff = Date().addingTimeInterval(-300)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)],
            ofItemAtPath: orphan.path
        )

        XCTAssertEqual(
            store.orphanedVideoCaches(
                in: directory,
                filenamePrefix: "DualCamera-",
                activeVideoURLs: [active],
                recentVideoURL: recent,
                olderThan: cutoff
            ),
            [orphan]
        )

        // 候选扫描后若另一个 Controller 登记了同一文件，删除前的锁内二次检查
        // 必须保留它；只有再次确认未跟踪后才能清理。
        store.markVideoInFlight(orphan)
        XCTAssertFalse(try store.removeVideoCacheIfStillOrphaned(
            orphan,
            filenamePrefix: "DualCamera-",
            activeVideoURLs: [],
            recentVideoURL: nil,
            olderThan: cutoff
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        store.removeVideo(orphan)
        XCTAssertTrue(try store.removeVideoCacheIfStillOrphaned(
            orphan,
            filenamePrefix: "DualCamera-",
            activeVideoURLs: [],
            recentVideoURL: nil,
            olderThan: cutoff
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testColdStartPromotesFinalizedMovieAndDiscardsOnlyStaleInvalidWriter() throws {
        let defaults = makeIsolatedDefaults()
        let readyKey = "ready-videos"
        let writerKey = "writer-videos"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unfinished = directory.appendingPathComponent("unfinished.mov")
        let finalized = directory.appendingPathComponent("finalized.mov")
        let readyOverlap = directory.appendingPathComponent("ready-overlap.mov")
        let missing = directory.appendingPathComponent("missing.mov")
        let currentProcessWriter = directory.appendingPathComponent("current-writer.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: unfinished.path, contents: Data([1])))
        XCTAssertTrue(FileManager.default.createFile(atPath: finalized.path, contents: finalizedMovieData()))
        XCTAssertTrue(FileManager.default.createFile(atPath: readyOverlap.path, contents: finalizedMovieData()))
        defaults.set([readyOverlap.path], forKey: readyKey)
        defaults.set(
            [unfinished.path, finalized.path, readyOverlap.path, missing.path],
            forKey: writerKey
        )
        let store = MediaRecoveryStore(
            defaults: defaults,
            failedVideoPathsKey: readyKey,
            inFlightVideoPathsKey: writerKey
        )

        let result = store.recoverStaleInFlightVideos()
        XCTAssertEqual(Set(result.promoted), [finalized])
        XCTAssertEqual(Set(result.discarded), [unfinished])
        XCTAssertEqual(Set(result.missing), [missing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unfinished.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyOverlap.path))
        XCTAssertTrue(store.inFlightVideos().isEmpty)
        XCTAssertEqual(Set(store.recoverableVideos()), [finalized, readyOverlap])

        // 冷启动快照处理完后，本进程刚登记的 writer 不能被后续重复调用误删。
        XCTAssertTrue(FileManager.default.createFile(atPath: currentProcessWriter.path, contents: Data([3])))
        store.markVideoInFlight(currentProcessWriter)
        XCTAssertEqual(
            store.recoverStaleInFlightVideos(),
            StaleInFlightVideoRecoveryResult(promoted: [], discarded: [], missing: [])
        )
        XCTAssertEqual(store.inFlightVideos(), [currentProcessWriter.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentProcessWriter.path))
    }

    func testRecoveryStoreBoundsPendingPhotosWithoutDroppingExistingJobs() {
        let store = MediaRecoveryStore(
            defaults: makeIsolatedDefaults(),
            failedVideoPathsKey: "failed-videos"
        )
        let jobs = (0...MediaRecoveryStore.maximumPendingPhotoCount).map { _ in
            RecoverablePhotoSaveJob(id: UUID(), operation: { _ in })
        }

        for job in jobs.prefix(MediaRecoveryStore.maximumPendingPhotoCount) {
            XCTAssertTrue(store.rememberPhoto(job))
        }
        XCTAssertFalse(store.canAcceptPhoto)
        XCTAssertFalse(store.rememberPhoto(jobs.last!))
        XCTAssertEqual(
            Set(store.pendingPhotos().map(\.id)),
            Set(jobs.prefix(MediaRecoveryStore.maximumPendingPhotoCount).map(\.id))
        )

        store.completePhoto(id: jobs[0].id, result: .success(()))
        XCTAssertTrue(store.canAcceptPhoto)
        XCTAssertTrue(store.rememberPhoto(jobs.last!))
    }

    func testRecoveryStoreBoundsFailedAndActiveVideosAsOneSet() {
        let store = MediaRecoveryStore(
            defaults: makeIsolatedDefaults(),
            failedVideoPathsKey: "failed-videos"
        )
        let failedURLs = (0..<(MediaRecoveryStore.maximumPendingVideoCount - 1)).map { index in
            URL(fileURLWithPath: "/tmp/pending-video-\(index)-\(UUID().uuidString).mov")
        }
        for url in failedURLs {
            store.recordVideoResult(
                url: url,
                result: .failure(.photoLibrarySaveFailed("模拟失败"))
            )
        }

        XCTAssertTrue(store.canAcceptVideo(activeVideoURLs: [failedURLs[0]]))
        let distinctActive = URL(fileURLWithPath: "/tmp/active-video-\(UUID().uuidString).mov")
        XCTAssertFalse(store.canAcceptVideo(activeVideoURLs: [distinctActive]))

        store.removeVideo(failedURLs[0])
        XCTAssertTrue(store.canAcceptVideo(activeVideoURLs: [distinctActive]))
    }

    func testRecoveryStoreBoundsRetainedVideoBytes() throws {
        let store = MediaRecoveryStore(
            defaults: makeIsolatedDefaults(),
            failedVideoPathsKey: "failed-videos"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-pending-video-\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(MediaRecoveryStore.maximumPendingVideoBytes))
        try handle.close()
        store.recordVideoResult(
            url: url,
            result: .failure(.photoLibrarySaveFailed("模拟失败"))
        )

        XCTAssertFalse(store.canAcceptVideo(activeVideoURLs: []))
    }

    private func assertSuccess(
        _ result: Result<Void, CameraError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("预期保存成功，实际失败：\(error.localizedDescription)", file: file, line: line)
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) {
        let fulfilled = expectation(description: description)
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() {
                    fulfilled.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if condition() {
                fulfilled.fulfill()
            }
        }
        wait(for: [fulfilled], timeout: timeout + 0.2)
    }

    private func finalizedMovieData() -> Data {
        func atom(_ type: String) -> Data {
            var data = Data([0, 0, 0, 8])
            data.append(contentsOf: type.utf8)
            return data
        }
        return atom("ftyp") + atom("mdat") + atom("moov")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "MediaSaveCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
