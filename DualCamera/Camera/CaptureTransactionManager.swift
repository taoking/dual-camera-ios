import AVFoundation
import Foundation

enum CaptureTransactionUpdate {
    case pending
    case completed(CaptureTransaction)
    case stale
    case duplicate
}

/// 只管理双路结果聚合；超时调度和 PhotoOutput delegate 由 PhotoCaptureCoordinator 负责。
final class CaptureTransactionManager {
    private(set) var activeTransaction: CaptureTransaction?

    @discardableResult
    func begin(id: UUID = UUID(), at date: Date = Date()) -> CaptureTransaction? {
        guard activeTransaction == nil else { return nil }
        let transaction = CaptureTransaction(
            id: id,
            startedAt: date,
            expectedPositions: [.back, .front]
        )
        activeTransaction = transaction
        return transaction
    }

    func receive(
        photo: CapturedSourcePhoto,
        captureID: UUID
    ) -> CaptureTransactionUpdate {
        update(captureID: captureID, position: photo.position) { transaction in
            transaction.receivedPhotos[photo.position] = photo
        }
    }

    func receive(
        error: CameraError,
        position: AVCaptureDevice.Position,
        captureID: UUID
    ) -> CaptureTransactionUpdate {
        update(captureID: captureID, position: position) { transaction in
            transaction.errors[position] = error
        }
    }

    @discardableResult
    func cancel() -> CaptureTransaction? {
        defer { activeTransaction = nil }
        return activeTransaction
    }

    @discardableResult
    func expire(captureID: UUID) -> CaptureTransaction? {
        guard activeTransaction?.id == captureID else { return nil }
        return cancel()
    }

    private func update(
        captureID: UUID,
        position: AVCaptureDevice.Position,
        mutation: (inout CaptureTransaction) -> Void
    ) -> CaptureTransactionUpdate {
        guard var transaction = activeTransaction, transaction.id == captureID else {
            return .stale
        }
        guard transaction.receivedPhotos[position] == nil, transaction.errors[position] == nil else {
            return .duplicate
        }
        mutation(&transaction)
        activeTransaction = transaction
        guard transaction.isComplete else { return .pending }
        activeTransaction = nil
        return .completed(transaction)
    }
}
