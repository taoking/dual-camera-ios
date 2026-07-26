import AVFoundation
import CoreMedia
import CoreVideo

enum CameraCaptureMode: Equatable {
    case photo
    case video
}

/// 可独立于 AVFoundation 对象构造并测试的格式评分输入。
struct CameraFormatDescriptor: Equatable {
    let identifier: String
    let width: Int32
    let height: Int32
    let supports30FPS: Bool
    let supports24FPS: Bool
    let isMultiCamSupported: Bool
    let supportsVideoPixelFormat: Bool
    let isBinned: Bool

    var pixelCount: Int64 { Int64(width) * Int64(height) }

    func supports(frameRate: Int) -> Bool {
        switch frameRate {
        case 30: supports30FPS
        case 24: supports24FPS
        default: false
        }
    }
}

struct CameraFormatSelection: Equatable {
    let descriptor: CameraFormatDescriptor
    let frameRate: Int
    let score: Int64
}

struct CameraFormatCandidate {
    let format: AVCaptureDevice.Format
    let selection: CameraFormatSelection
}

enum CameraFormatSelector {
    private static let targetPixels: Int64 = 1_280 * 720
    private static let excessivePixels: Int64 = 1_920 * 1_080

    static func rankedSelections(
        from descriptors: [CameraFormatDescriptor],
        mode: CameraCaptureMode
    ) -> [CameraFormatSelection] {
        [30, 24]
            .flatMap { frameRate in
                descriptors.compactMap { descriptor -> CameraFormatSelection? in
                    guard descriptor.isMultiCamSupported,
                          descriptor.supports(frameRate: frameRate),
                          mode == .photo || descriptor.supportsVideoPixelFormat else {
                        return nil
                    }
                    return CameraFormatSelection(
                        descriptor: descriptor,
                        frameRate: frameRate,
                        score: score(descriptor, frameRate: frameRate, mode: mode)
                    )
                }
                .sorted { $0.score < $1.score }
            }
    }

    static func select(
        from descriptors: [CameraFormatDescriptor],
        mode: CameraCaptureMode
    ) -> CameraFormatSelection? {
        rankedSelections(from: descriptors, mode: mode).first
    }

    static func score(
        _ descriptor: CameraFormatDescriptor,
        frameRate: Int,
        mode: CameraCaptureMode
    ) -> Int64 {
        let pixels = descriptor.pixelCount
        let resolutionPenalty: Int64
        if pixels < targetPixels {
            // 低于目标会明显损失细节，权重高于略高于目标的格式。
            resolutionPenalty = (targetPixels - pixels) * 4
        } else {
            resolutionPenalty = pixels - targetPixels
        }

        let excessivePenalty = pixels > excessivePixels
            ? (pixels - excessivePixels) * 6
            : 0
        let frameRatePenalty: Int64 = frameRate == 30 ? 0 : 10_000_000_000
        let binningBonus: Int64 = descriptor.isBinned ? -100_000 : 0
        let videoPenalty: Int64 = mode == .video && pixels > targetPixels ? pixels - targetPixels : 0
        return frameRatePenalty + resolutionPenalty + excessivePenalty + videoPenalty + binningBonus
    }

    static func rankedCandidates(
        for device: AVCaptureDevice,
        mode: CameraCaptureMode
    ) -> [CameraFormatCandidate] {
        let entries = device.formats.enumerated().map { index, format in
            (format, descriptor(for: format, identifier: "\(device.uniqueID)-\(index)"))
        }
        let selections = rankedSelections(from: entries.map(\.1), mode: mode)
        let formatsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.1.identifier, $0.0) })
        var seenResolutionAndRate = Set<String>()
        return selections.compactMap { selection in
            let descriptor = selection.descriptor
            let key = "\(descriptor.width)x\(descriptor.height)@\(selection.frameRate)"
            guard seenResolutionAndRate.insert(key).inserted else { return nil }
            guard let format = formatsByID[selection.descriptor.identifier] else { return nil }
            return CameraFormatCandidate(format: format, selection: selection)
        }
    }

    private static func descriptor(
        for format: AVCaptureDevice.Format,
        identifier: String
    ) -> CameraFormatDescriptor {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let mediaSubtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let supportedVideoSubtypes: Set<FourCharCode> = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        return CameraFormatDescriptor(
            identifier: identifier,
            width: dimensions.width,
            height: dimensions.height,
            supports30FPS: supports(30, format: format),
            supports24FPS: supports(24, format: format),
            isMultiCamSupported: format.isMultiCamSupported,
            supportsVideoPixelFormat: supportedVideoSubtypes.contains(mediaSubtype),
            isBinned: format.isVideoBinned
        )
    }

    private static func supports(_ frameRate: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
        }
    }
}
