import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 封装视频/音频输出、写入器生命周期和临时文件清理。
final class VideoCaptureCoordinator: NSObject {
    private let sessionQueue: DispatchQueue
    private var backOutput: AVCaptureVideoDataOutput?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var latestFrontSampleBuffer: CMSampleBuffer?
    private var recorder: DualCameraVideoRecorder?
    private var isFinishing = false

    var isRecording: Bool { recorder != nil && !isFinishing }

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
        backOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        frontOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)

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

    func start(outputURL: URL) throws {
        guard recorder == nil, !isFinishing else {
            throw CameraError.videoRecordingFailed("已有视频录制正在进行。")
        }
        discard(url: outputURL)
        recorder = try DualCameraVideoRecorder(outputURL: outputURL)
        latestFrontSampleBuffer = nil
    }

    @discardableResult
    func stop(completion: @escaping (Result<URL, CameraError>) -> Void) -> Bool {
        guard let recorder, !isFinishing else { return false }
        self.recorder = nil
        isFinishing = true
        latestFrontSampleBuffer = nil
        recorder.finish { [weak self] result in
            self?.sessionQueue.async {
                self?.isFinishing = false
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
        recorder?.cancel()
        recorder = nil
        isFinishing = false
        latestFrontSampleBuffer = nil
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
        latestFrontSampleBuffer = nil
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

extension VideoCaptureCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let frontOutput, output === frontOutput {
            latestFrontSampleBuffer = sampleBuffer
        } else if let backOutput, output === backOutput {
            recorder?.appendVideo(backSample: sampleBuffer, frontSample: latestFrontSampleBuffer)
        } else if let audioOutput, output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
        }
    }
}
