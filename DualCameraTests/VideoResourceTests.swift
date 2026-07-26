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
}
