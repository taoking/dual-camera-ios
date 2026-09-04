import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 封装视频/音频输出、写入器生命周期和临时文件清理。
final class VideoCaptureCoordinator: NSObject {
    /// 前摄帧与后摄帧的最大允许时间差。超出即视为前摄卡顿，
    /// 宁可这一帧不合成画中画，也不要把一张过期画面一直贴在成片上。
    private static let maximumFrontFrameAge = CMTime(value: 1, timescale: 5)

    private let sessionQueue: DispatchQueue
    /// 帧合成不能占用 sessionQueue：那条队列还要处理对焦、缩放、设备加锁和停止录制，
    /// 逐帧渲染会把这些操作全部排在后面。
    private let videoQueue = DispatchQueue(label: "com.taoking.dualcamera.video-output")
    private var backOutput: AVCaptureVideoDataOutput?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    // 以下状态只在 videoQueue 上读写；来自 sessionQueue 的生命周期调用一律 sync 进入。
    private var latestFrontSampleBuffer: CMSampleBuffer?
    private var recorder: DualCameraVideoRecorder?
    private var isFinishing = false

    var isRecording: Bool {
        videoQueue.sync { recorder != nil && !isFinishing }
    }

    var isFinishingRecording: Bool {
        videoQueue.sync { isFinishing }
    }

    init(sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
    }

    func configure(
        session: AVCaptureMultiCamSession,
        backPort: AVCaptureInput.Port,
        frontPort: AVCaptureInput.Port,
        audioDevice: AVCaptureDevice?
    ) throws {
        guard let audioDevice else {
            throw CameraConfigurationError("未找到可用于视频录制的麦克风。")
        }

        let backOutput = AVCaptureVideoDataOutput()
        let frontOutput = AVCaptureVideoDataOutput()
        let audioOutput = AVCaptureAudioDataOutput()
        configure(backOutput)
        configure(frontOutput)
        backOutput.setSampleBufferDelegate(self, queue: videoQueue)
        frontOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)

        try add(backOutput, to: session, label: "后置视频")
        try add(frontOutput, to: session, label: "前置视频")
        try add(audioOutput, to: session, label: "录音")

        let backConnection = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
        let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        try add(backConnection, to: session, label: "后置视频输出")
        try add(frontConnection, to: session, label: "前置视频输出")
        configureVideoConnection(backConnection)
        configureVideoConnection(frontConnection)

        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            throw CameraConfigurationError("无法将麦克风加入双摄会话。")
        }
        session.addInputWithNoConnections(audioInput)
        guard let audioPort = audioInput.ports(
            for: .audio,
            sourceDeviceType: audioDevice.deviceType,
            sourceDevicePosition: .unspecified
        ).first else {
            throw CameraConfigurationError("未能获取麦克风输入端口。")
        }
        try add(
            AVCaptureConnection(inputPorts: [audioPort], output: audioOutput),
            to: session,
            label: "录音输出"
        )

        self.backOutput = backOutput
        self.frontOutput = frontOutput
        self.audioOutput = audioOutput
    }

    func start(outputURL: URL, layout: DualCameraLayout, aspectRatio: CaptureAspectRatio) throws {
        // 采集端给出的推荐设置与麦克风实际格式一致，优于手写声道数和采样率。
        let audioSettings = audioOutput?
            .recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        try videoQueue.sync {
            guard recorder == nil, !isFinishing else {
                throw CameraError.videoRecordingFailed("已有视频录制正在进行。")
            }
            try? FileManager.default.removeItem(at: outputURL)
            recorder = try DualCameraVideoRecorder(
                outputURL: outputURL,
                layout: layout,
                aspectRatio: aspectRatio,
                audioSettings: audioSettings
            )
            latestFrontSampleBuffer = nil
        }
    }

    @discardableResult
    func stop(completion: @escaping (Result<URL, CameraError>) -> Void) -> Bool {
        let pending: DualCameraVideoRecorder? = videoQueue.sync {
            guard let recorder, !isFinishing else { return nil }
            self.recorder = nil
            isFinishing = true
            latestFrontSampleBuffer = nil
            return recorder
        }
        guard let recorder = pending else { return false }
        recorder.finish { [self] result in
            // 闸门必须保持到回调真正送达控制器，而不是 finishWriting 一返回就打开，
            // 否则媒体服务重置后可能过早开始新录像并被旧回调覆盖状态。
            // 这里对 self 的使用同时保证协调器存活到回调送达。
            sessionQueue.async { [self] in
                videoQueue.sync { isFinishing = false }
                switch result {
                case .success(let url):
                    completion(.success(url))
                case .failure(let error):
                    completion(.failure(.videoRecordingFailed("视频录制失败：\(error.localizedDescription)")))
                }
            }
        }
        return true
    }

    func cancelRecording() {
        videoQueue.sync {
            // finishWriting 已接管 writer 后无法再取消；此时保持 finishing 闸门，直到旧
            // 回调送达，避免媒体服务重置后过早开始新录像并被旧回调覆盖状态。
            guard !isFinishing else {
                latestFrontSampleBuffer = nil
                return
            }
            recorder?.cancel()
            recorder = nil
            latestFrontSampleBuffer = nil
        }
    }

    func reset(cancelRecording: Bool) {
        if cancelRecording {
            self.cancelRecording()
        }
        backOutput?.setSampleBufferDelegate(nil, queue: nil)
        frontOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        backOutput = nil
        frontOutput = nil
        audioOutput = nil
        videoQueue.sync { latestFrontSampleBuffer = nil }
    }

    func discard(url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func configure(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
    }

    private func configureVideoConnection(_ connection: AVCaptureConnection) {
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
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

extension VideoCaptureCoordinator {
    /// 只有与当前后摄帧时间接近的前摄帧才参与合成。前摄输出停顿时返回 nil，
    /// 该帧只画后摄画面，而不是把上一张过期的前摄画面继续贴上去。
    fileprivate func freshFrontSample(matching backSample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let front = latestFrontSampleBuffer else { return nil }
        let backTime = CMSampleBufferGetPresentationTimeStamp(backSample)
        let frontTime = CMSampleBufferGetPresentationTimeStamp(front)
        guard backTime.isValid, frontTime.isValid else { return front }
        let age = CMTimeAbsoluteValue(CMTimeSubtract(backTime, frontTime))
        return CMTimeCompare(age, Self.maximumFrontFrameAge) <= 0 ? front : nil
    }
}

extension VideoCaptureCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let frontOutput, output === frontOutput {
            latestFrontSampleBuffer = sampleBuffer
        } else if let backOutput, output === backOutput {
            recorder?.appendVideo(
                backSample: sampleBuffer,
                frontSample: freshFrontSample(matching: sampleBuffer)
            )
        } else if let audioOutput, output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
        }
    }
}
