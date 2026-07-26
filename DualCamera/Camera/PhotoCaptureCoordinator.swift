import AVFoundation
import OSLog

struct CapturedPhotoPair {
    let transactionID: UUID
    let capturedAt: Date
    let backPhoto: CapturedSourcePhoto
    let frontPhoto: CapturedSourcePhoto
}

/// 管理 PhotoOutput、双路事务、超时和过期 delegate 回调，不负责图片合成或相册写入。
final class PhotoCaptureCoordinator {
    private let sessionQueue: DispatchQueue
    private let transactions = CaptureTransactionManager()
    private var backOutput: AVCapturePhotoOutput?
    private var frontOutput: AVCapturePhotoOutput?
    private var frontConnection: AVCaptureConnection?
    private var processors = [UUID: PhotoCaptureProcessor]()
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((Result<CapturedPhotoPair, CameraError>) -> Void)?

    var isCapturing: Bool { transactions.activeTransaction != nil }

    init(sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
    }

    func configure(
        session: AVCaptureMultiCamSession,
        backPort: AVCaptureInput.Port,
        frontPort: AVCaptureInput.Port,
        quality: CaptureQuality,
        frontMirrored: Bool,
        configurePortraitConnection: (AVCaptureConnection, Bool) -> Void
    ) throws {
        let backOutput = AVCapturePhotoOutput()
        let frontOutput = AVCapturePhotoOutput()
        try add(backOutput, to: session, label: "后置照片")
        try add(frontOutput, to: session, label: "前置照片")
        configurePhotoQuality(for: backOutput, quality: quality, label: "后摄")
        configurePhotoQuality(for: frontOutput, quality: quality, label: "前摄")

        let backConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        try add(backConnection, to: session, label: "后置照片输出")
        try add(frontConnection, to: session, label: "前置照片输出")
        configurePortraitConnection(backConnection, false)
        configurePortraitConnection(frontConnection, frontMirrored)

        self.backOutput = backOutput
        self.frontOutput = frontOutput
        self.frontConnection = frontConnection
    }

    func capture(
        quality: CaptureQuality,
        completion: @escaping (Result<CapturedPhotoPair, CameraError>) -> Void
    ) {
        guard let backOutput, let frontOutput,
              let transaction = transactions.begin() else {
            return
        }
        self.completion = completion
        scheduleTimeout(for: transaction.id)
        CameraLog.capture.info("开始双路拍照事务 \(transaction.id.uuidString, privacy: .private)")
        capture(on: backOutput, position: .back, captureID: transaction.id, quality: quality)
        capture(on: frontOutput, position: .front, captureID: transaction.id, quality: quality)
    }

    func cancel(reason: CameraError, reportResult: Bool) {
        guard transactions.cancel() != nil else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        processors.removeAll()
        let callback = completion
        completion = nil
        if reportResult {
            callback?(.failure(reason))
        }
        CameraLog.capture.info("拍照事务取消：\(reason.localizedDescription, privacy: .public)")
    }

    func updateFrontMirroring(
        _ mirrored: Bool,
        configurePortraitConnection: (AVCaptureConnection, Bool) -> Void
    ) {
        guard let frontConnection else { return }
        configurePortraitConnection(frontConnection, mirrored)
    }

    func reset() {
        cancel(reason: .captureCancelled, reportResult: false)
        backOutput = nil
        frontOutput = nil
        frontConnection = nil
        processors.removeAll()
    }

    private func capture(
        on output: AVCapturePhotoOutput,
        position: AVCaptureDevice.Position,
        captureID: UUID,
        quality: CaptureQuality
    ) {
        let processorID = UUID()
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = Self.requestedPrioritization(
            quality,
            maximum: output.maxPhotoQualityPrioritization
        )
        let processor = PhotoCaptureProcessor(position: position) { [weak self] result in
            self?.sessionQueue.async {
                self?.finishCapture(
                    result,
                    processorID: processorID,
                    captureID: captureID,
                    position: position
                )
            }
        }
        processors[processorID] = processor
        output.capturePhoto(with: settings, delegate: processor)
    }

    private func finishCapture(
        _ result: Result<CapturedSourcePhoto, CameraError>,
        processorID: UUID,
        captureID: UUID,
        position: AVCaptureDevice.Position
    ) {
        processors[processorID] = nil
        let update: CaptureTransactionUpdate
        switch result {
        case .success(let photo):
            update = transactions.receive(photo: photo, captureID: captureID)
        case .failure(let error):
            update = transactions.receive(
                error: .captureFailed("\(position == .front ? "前置" : "后置")拍照失败：\(error.localizedDescription)"),
                position: position,
                captureID: captureID
            )
        }

        switch update {
        case .pending:
            break
        case .stale:
            CameraLog.capture.debug("忽略过期拍照回调")
        case .duplicate:
            CameraLog.capture.debug("忽略重复拍照回调")
        case .completed(let transaction):
            complete(transaction)
        }
    }

    private func complete(_ transaction: CaptureTransaction) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let callback = completion
        completion = nil
        guard transaction.errors.isEmpty else {
            let detail = transaction.errors.values.map(\.localizedDescription).joined(separator: "\n")
            callback?(.failure(.captureFailed(detail)))
            return
        }
        guard let backPhoto = transaction.receivedPhotos[.back],
              let frontPhoto = transaction.receivedPhotos[.front] else {
            callback?(.failure(.captureFailed("未能同时取得前后摄照片。")))
            return
        }
        callback?(.success(CapturedPhotoPair(
            transactionID: transaction.id,
            capturedAt: transaction.startedAt,
            backPhoto: backPhoto,
            frontPhoto: frontPhoto
        )))
    }

    private func scheduleTimeout(for captureID: UUID) {
        timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.transactions.activeTransaction?.id == captureID else { return }
            self?.cancel(reason: .captureTimedOut, reportResult: true)
        }
        timeoutWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func configurePhotoQuality(
        for output: AVCapturePhotoOutput,
        quality: CaptureQuality,
        label: String
    ) {
        let systemMaximum = output.maxPhotoQualityPrioritization
        let requested = Self.requestedPrioritization(quality, maximum: systemMaximum)
        // 必须在 Session 启动前设置；运行中变更由 Controller 受控重建。
        output.maxPhotoQualityPrioritization = requested
        CameraLog.capture.info("\(label, privacy: .public) max quality=\(String(describing: systemMaximum), privacy: .public)，本次请求=\(String(describing: requested), privacy: .public)")
    }

    static func requestedPrioritization(
        _ quality: CaptureQuality,
        maximum: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        let desired: AVCapturePhotoOutput.QualityPrioritization = quality == .fast ? .speed : .balanced
        switch maximum {
        case .speed:
            return .speed
        case .balanced, .quality:
            return desired
        @unknown default:
            return .speed
        }
    }

    private func add(_ output: AVCaptureOutput, to session: AVCaptureMultiCamSession, label: String) throws {
        guard session.canAddOutput(output) else {
            throw CameraConfigurationError("无法添加\(label)输出。")
        }
        session.addOutputWithNoConnections(output)
    }

    private func add(_ connection: AVCaptureConnection, to session: AVCaptureMultiCamSession, label: String) throws {
        guard session.canAddConnection(connection) else {
            throw CameraConfigurationError("无法建立\(label)连接。")
        }
        session.addConnection(connection)
    }
}
