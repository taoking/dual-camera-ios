import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal

/// 将两个视频数据输出合成为一条竖屏视频轨道，并同步写入麦克风音频。
/// 该类型只在 `VideoCaptureCoordinator` 的 videoQueue 上被调用。
/// 布局与预览、照片共用 `DualCameraLayoutEngine`，不再使用固定画中画位置。
final class DualCameraVideoRecorder {
    /// 成片长边。1080×1920 是 MultiCam 下兼顾画质与编码负载的档位。
    static let canvasLongEdge: CGFloat = 1_920

    /// CIContext 创建开销大且可安全共享，按 Metal 设备建一次即可。
    /// 缺少 Metal 设备时回退到默认上下文，仅影响性能不影响正确性。
    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private let outputURL: URL
    private let canvasSize: CGSize
    private let layout: DualCameraLayout
    private let backRect: CGRect
    private let frontRect: CGRect
    private let borderWidth: CGFloat
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var hasStartedWriting = false
    private var startTime: CMTime?
    private var recordingError: Error?
    private var hasFinished = false

    init(
        outputURL: URL,
        layout: DualCameraLayout,
        aspectRatio: CaptureAspectRatio,
        audioSettings: [String: Any]?
    ) throws {
        self.outputURL = outputURL
        self.layout = layout

        let size = DualCameraLayoutEngine.outputSize(for: aspectRatio, longEdge: Self.canvasLongEdge)
        // 编码器要求偶数边长。
        canvasSize = CGSize(
            width: (size.width / 2).rounded() * 2,
            height: (size.height / 2).rounded() * 2
        )
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let frames = DualCameraLayoutEngine.frames(in: canvas, layout: layout)
        // 布局引擎输出 UIKit 坐标；CoreImage 的 y 轴方向相反，必须翻转后再用。
        backRect = DualCameraLayoutEngine.coreImageRect(from: frames.back, canvasHeight: canvasSize.height)
        frontRect = DualCameraLayoutEngine.coreImageRect(from: frames.front, canvasHeight: canvasSize.height)
        borderWidth = max(2, canvasSize.width * layout.borderRatio)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                // 约 5 bit/像素，随画幅缩放，避免 1:1 等更大画布被同一码率拖垮。
                AVVideoAverageBitRateKey: Int(canvasSize.width * canvasSize.height * 5),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
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

        // 优先采用采集端给出的推荐设置，声道数与采样率与实际输入一致，
        // 避免手写参数与麦克风格式不符导致写入失败。
        let resolvedAudioSettings = audioSettings ?? [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: resolvedAudioSettings)
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
            composition = aspectFill(backImage, in: backRect).composited(over: composition)
        }

        if let frontSample,
           let frontBuffer = CMSampleBufferGetImageBuffer(frontSample) {
            let frontImage = portraitImage(from: frontBuffer, mirrored: layout.frontCaptureMirrored)
            let borderRect = frontRect.insetBy(dx: -borderWidth, dy: -borderWidth)
            let border = CIImage(color: .white).cropped(to: borderRect)
            composition = border.composited(over: composition)
            composition = aspectFill(frontImage, in: frontRect).composited(over: composition)
        }

        Self.sharedCIContext.render(
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
        guard imageExtent.width > 0, imageExtent.height > 0 else { return image }
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
