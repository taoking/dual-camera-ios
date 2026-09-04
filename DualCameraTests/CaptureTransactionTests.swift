import AVFoundation
import XCTest
@testable import DualCamera

final class CaptureTransactionTests: XCTestCase {
    func testFrontAndBackSuccessCompletes() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        assertPending(manager.receive(photo: photo(.front), captureID: id))
        assertCompleted(manager.receive(photo: photo(.back), captureID: id), errorCount: 0)
    }

    func testFrontSuccessBackFailure() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        assertPending(manager.receive(photo: photo(.front), captureID: id))
        assertCompleted(manager.receive(error: .captureFailed("back"), position: .back, captureID: id), errorCount: 1)
    }

    func testFrontFailureBackSuccess() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        assertPending(manager.receive(error: .captureFailed("front"), position: .front, captureID: id))
        assertCompleted(manager.receive(photo: photo(.back), captureID: id), errorCount: 1)
    }

    func testBothFailures() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        assertPending(manager.receive(error: .captureFailed("front"), position: .front, captureID: id))
        assertCompleted(manager.receive(error: .captureFailed("back"), position: .back, captureID: id), errorCount: 2)
    }

    func testTimeoutExpiresMatchingTransaction() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        XCTAssertNotNil(manager.expire(captureID: id))
        XCTAssertNil(manager.activeTransaction)
    }

    func testCancelClearsTransaction() {
        let manager = CaptureTransactionManager()
        XCTAssertNotNil(manager.begin())
        XCTAssertNotNil(manager.cancel())
        XCTAssertNil(manager.activeTransaction)
    }

    func testStaleCallbackIsIgnored() throws {
        let manager = CaptureTransactionManager()
        _ = manager.begin()
        assertStale(manager.receive(photo: photo(.front), captureID: UUID()))
    }

    func testDuplicateCallbackIsIgnored() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        assertPending(manager.receive(photo: photo(.front), captureID: id))
        if case .duplicate = manager.receive(photo: photo(.front), captureID: id) { return }
        XCTFail("应识别重复回调")
    }

    func testCanBeginNextTransactionAfterCompletion() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        _ = manager.receive(photo: photo(.front), captureID: id)
        _ = manager.receive(photo: photo(.back), captureID: id)
        XCTAssertNotNil(manager.begin())
    }

    func testBackgroundCancellationMakesCompositionSourceCallbacksStale() throws {
        let manager = CaptureTransactionManager()
        let id = try XCTUnwrap(manager.begin()?.id)
        _ = manager.cancel()
        assertStale(manager.receive(photo: photo(.front), captureID: id))
    }

    private func photo(_ position: AVCaptureDevice.Position) -> CapturedSourcePhoto {
        CapturedSourcePhoto(originalData: Data([1]), image: UIImage(), position: position)
    }

    private func assertPending(_ update: CaptureTransactionUpdate, file: StaticString = #filePath, line: UInt = #line) {
        if case .pending = update { return }
        XCTFail("应等待另一路结果", file: file, line: line)
    }

    private func assertCompleted(_ update: CaptureTransactionUpdate, errorCount: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard case .completed(let transaction) = update else {
            XCTFail("事务应完成", file: file, line: line)
            return
        }
        XCTAssertEqual(transaction.errors.count, errorCount, file: file, line: line)
    }

    private func assertStale(_ update: CaptureTransactionUpdate, file: StaticString = #filePath, line: UInt = #line) {
        if case .stale = update { return }
        XCTFail("应忽略过期回调", file: file, line: line)
    }
}
