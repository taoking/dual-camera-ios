import Foundation
import XCTest
@testable import DualCamera

final class VideoResourceTests: XCTestCase {
    func testDiscardRemovesTemporaryVideo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("discard-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: url)
        let coordinator = VideoCaptureCoordinator(sessionQueue: DispatchQueue(label: "video-test"))
        coordinator.discard(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecorderWithoutVideoFramesFailsClearlyAndRemovesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).mov")
        let recorder = try DualCameraVideoRecorder(outputURL: url)
        var message: String?
        recorder.finish {
            if case .failure(let error) = $0 { message = error.localizedDescription }
        }
        XCTAssertEqual(message, "未收到可用于录制的视频帧。")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecorderFinishOnlyCompletesOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("once-\(UUID().uuidString).mov")
        let recorder = try DualCameraVideoRecorder(outputURL: url)
        var count = 0
        recorder.finish { _ in count += 1 }
        recorder.finish { _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testVideoCoordinatorRetainsItselfUntilFinishCallbackIsDelivered() throws {
        let queue = DispatchQueue(label: "video-finish-retention-test")
        queue.suspend()
        var coordinator: VideoCaptureCoordinator? = VideoCaptureCoordinator(sessionQueue: queue)
        let retainedCoordinator = TestWeakBox(coordinator)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-\(UUID().uuidString).mov")
        let completed = expectation(description: "停止结果已送达")

        try coordinator?.start(outputURL: url)
        XCTAssertTrue(coordinator?.stop { result in
            if case .success = result {
                XCTFail("没有视频帧时应失败")
            }
            completed.fulfill()
        } ?? false)

        coordinator = nil
        XCTAssertNotNil(retainedCoordinator.value)
        queue.resume()
        wait(for: [completed], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelDoesNotReopenRecordingGateWhileFinishCallbackIsPending() throws {
        let queue = DispatchQueue(label: "video-finish-gate-test")
        queue.suspend()
        let coordinator = VideoCaptureCoordinator(sessionQueue: queue)
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finishing-\(UUID().uuidString).mov")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-\(UUID().uuidString).mov")
        let thirdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resumed-\(UUID().uuidString).mov")
        let completed = expectation(description: "旧录像收尾回调已送达")

        try coordinator.start(outputURL: firstURL)
        XCTAssertTrue(coordinator.stop { _ in completed.fulfill() })
        XCTAssertTrue(coordinator.isFinishingRecording)

        coordinator.cancelRecording()
        XCTAssertTrue(coordinator.isFinishingRecording)
        XCTAssertThrowsError(try coordinator.start(outputURL: secondURL))

        queue.resume()
        wait(for: [completed], timeout: 1)
        XCTAssertFalse(coordinator.isFinishingRecording)

        try coordinator.start(outputURL: thirdURL)
        coordinator.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: thirdURL.path))
    }
}

final class TestWeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
