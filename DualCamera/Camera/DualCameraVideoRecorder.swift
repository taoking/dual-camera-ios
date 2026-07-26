import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO

/// 将两个视频数据输出合成为一条竖屏画中画视频轨道，并同步写入麦克风音频。
/// 该类型只由 `MultiCamSessionController` 的 sessionQueue 间接通过 VideoCaptureCoordinator 调用。
/// 视频沿用既有固定画中画协议，本轮不扩展布局能力。
final class DualCameraVideoRecorder {
    private let outputURL: URL
    private let canvasSize = CGSize(width: 720, height: 1_280)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let ciContext = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var hasStartedWriting = false
    private var startTime: CMTime?
    private var recordingError: Error?
    private var hasFinished = false

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw VideoRecorderError("无法创建视频或音频写入轨道。")
        }
        writer.add(videoInput)
        writer.add(audioInput)
    }

    func appendVideo(backSample: CMSampleBuffer, frontSample: CMSampleBuffer?) {
        guard CMSampleBufferDataIsReady(backSample), recordingError == nil else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(backSample)
        startWritingIfNeeded(at: timestamp)
        guard hasStartedWriting,
              videoInput.isReadyForMoreMediaData,
              let pool = pixelBufferAdaptor.pixelBufferPool else {
            return
        }

        var outputBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard result == kCVReturnSuccess, let outputBuffer else {
            recordingError = VideoRecorderError("无法为视频帧分配缓冲区。")
            return
        }

        render(backSample: backSample, frontSample: frontSample, into: outputBuffer)
        if !pixelBufferAdaptor.append(outputBuffer, withPresentationTime: timestamp) {
            recordingError = writer.error ?? VideoRecorderError("写入视频帧失败。")
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard hasStartedWriting,
              CMSampleBufferDataIsReady(sampleBuffer),
              audioInput.isReadyForMoreMediaData,
              let startTime,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), startTime) >= 0,
              recordingError == nil else {
            return
        }

        if !audioInput.append(sampleBuffer) {
            recordingError = writer.error ?? VideoRecorderError("写入音频失败。")
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !hasFinished else { return }
        hasFinished = true
        if let recordingError {
            writer.cancelWriting()
            removeOutputFile()
            completion(.failure(recordingError))
            return
        }

        guard hasStartedWriting else {
            writer.cancelWriting()
            removeOutputFile()
            completion(.failure(VideoRecorderError("未收到可用于录制的视频帧。")))
            return
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.finishWriting { [outputURL, writer] in
            if writer.status == .completed {
                completion(.success(outputURL))
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(writer.error ?? VideoRecorderError("视频文件写入未完成。")))
            }
        }
    }

    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        writer.cancelWriting()
        removeOutputFile()
    }

    private func startWritingIfNeeded(at timestamp: CMTime) {
        guard !hasStartedWriting else { return }
        guard writer.startWriting() else {
            recordingError = writer.error ?? VideoRecorderError("无法开始视频写入。")
            return
        }

        writer.startSession(atSourceTime: timestamp)
        startTime = timestamp
        hasStartedWriting = true
    }

    private func render(
        backSample: CMSampleBuffer,
        frontSample: CMSampleBuffer?,
        into pixelBuffer: CVPixelBuffer
    ) {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var composition = CIImage(color: .black).cropped(to: canvas)

        if let backBuffer = CMSampleBufferGetImageBuffer(backSample) {
            let backImage = portraitImage(from: backBuffer, mirrored: false)
            composition = aspectFill(backImage, in: canvas).composited(over: composition)
        }

        if let frontSample,
           let frontBuffer = CMSampleBufferGetImageBuffer(frontSample) {
            let pipSize = CGSize(width: 234, height: 312)
            let pipRect = CGRect(
                x: canvas.maxX - pipSize.width - 30,
                y: canvas.maxY - pipSize.height - 78,
                width: pipSize.width,
                height: pipSize.height
            )
            let frontImage = portraitImage(from: frontBuffer, mirrored: true)
            let borderRect = pipRect.insetBy(dx: -4, dy: -4)
            let border = CIImage(color: .white).cropped(to: borderRect)
            composition = border.composited(over: composition)
            composition = aspectFill(frontImage, in: pipRect).composited(over: composition)
        }

        ciContext.render(
            composition,
            to: pixelBuffer,
            bounds: canvas,
            colorSpace: colorSpace
        )
    }

    private func portraitImage(from pixelBuffer: CVPixelBuffer, mirrored: Bool) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        return mirrored ? image.oriented(.upMirrored) : image
    }

    private func aspectFill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let imageExtent = image.extent
        let scale = max(rect.width / imageExtent.width, rect.height / imageExtent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translation = CGAffineTransform(
            translationX: rect.midX - scaled.extent.midX,
            y: rect.midY - scaled.extent.midY
        )
        return scaled.transformed(by: translation).cropped(to: rect)
    }

    private func removeOutputFile() {
        try? FileManager.default.removeItem(at: outputURL)
    }
}

private struct VideoRecorderError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
