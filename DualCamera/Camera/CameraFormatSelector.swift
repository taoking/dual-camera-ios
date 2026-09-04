import AVFoundation
import CoreMedia
import CoreVideo

enum CameraCaptureMode: Hashable {
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
    /// 该格式允许请求的最大照片尺寸。为 0 表示未知，此时回退到视频尺寸。
    let maxPhotoWidth: Int32
    let maxPhotoHeight: Int32

    init(
        identifier: String,
        width: Int32,
        height: Int32,
        supports30FPS: Bool,
        supports24FPS: Bool,
        isMultiCamSupported: Bool,
        supportsVideoPixelFormat: Bool,
        isBinned: Bool,
        maxPhotoWidth: Int32 = 0,
        maxPhotoHeight: Int32 = 0
    ) {
        self.identifier = identifier
        self.width = width
        self.height = height
        self.supports30FPS = supports30FPS
        self.supports24FPS = supports24FPS
        self.isMultiCamSupported = isMultiCamSupported
        self.supportsVideoPixelFormat = supportsVideoPixelFormat
        self.isBinned = isBinned
        self.maxPhotoWidth = maxPhotoWidth
        self.maxPhotoHeight = maxPhotoHeight
    }

    var pixelCount: Int64 { Int64(width) * Int64(height) }

    /// 照片排序依据。系统未给出照片尺寸时退回视频尺寸，避免该格式被当成 0 像素排到最后。
    var maxPhotoPixelCount: Int64 {
        let photoPixels = Int64(maxPhotoWidth) * Int64(maxPhotoHeight)
        return photoPixels > 0 ? photoPixels : pixelCount
    }

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

/// 前后摄候选组合的身份。`AVCaptureDevice.Format` 既不可构造也不保证可判等，
/// 因此身份只取评分输入里的标识与帧率——这也让去重逻辑可以脱离真实设备测试。
struct FormatSelectionKey: Hashable {
    let backIdentifier: String
    let frontIdentifier: String
    let backFrameRate: Int
    let frontFrameRate: Int

    init(back: CameraFormatSelection, front: CameraFormatSelection) {
        backIdentifier = back.descriptor.identifier
        frontIdentifier = front.descriptor.identifier
        backFrameRate = back.frameRate
        frontFrameRate = front.frameRate
    }
}

/// 一组前后摄格式候选。作为成本验收的最小单元，也是配置器的缓存值。
struct FormatCombination {
    let back: CameraFormatCandidate
    let front: CameraFormatCandidate

    var selectionKey: FormatSelectionKey {
        FormatSelectionKey(back: back.selection, front: front.selection)
    }
}

enum CameraFormatSelector {
    /// 录像统一合成到竖屏 1080×1920 画布，采集端再高也只会被缩小，没有画质收益。
    private static let videoTargetPixels: Int64 = 1_920 * 1_080

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

    /// 分数越低越优先。两种模式对分辨率的诉求相反，因此分开评分：
    /// 照片要尽可能大，录像只需要够合成画布用。
    static func score(
        _ descriptor: CameraFormatDescriptor,
        frameRate: Int,
        mode: CameraCaptureMode
    ) -> Int64 {
        // 30fps 取景明显更顺滑，该差异的权重高于任何分辨率差异。
        let frameRatePenalty: Int64 = frameRate == 30 ? 0 : 10_000_000_000

        switch mode {
        case .photo:
            // 照片直接按可请求的最大照片尺寸倒序：像素越多分数越低。
            // binning 会牺牲细节，在照片模式下是减分项而非加分项。
            let binningPenalty: Int64 = descriptor.isBinned ? 1_000_000 : 0
            return frameRatePenalty - descriptor.maxPhotoPixelCount + binningPenalty
        case .video:
            let pixels = descriptor.pixelCount
            let resolutionPenalty: Int64
            if pixels < videoTargetPixels {
                // 低于画布分辨率会明显损失细节，权重高于略高于目标的格式。
                resolutionPenalty = (videoTargetPixels - pixels) * 4
            } else {
                resolutionPenalty = pixels - videoTargetPixels
            }
            // 录像画布本就不需要全分辨率，binning 能降低成本与噪点。
            let binningBonus: Int64 = descriptor.isBinned ? -100_000 : 0
            return frameRatePenalty + resolutionPenalty + binningBonus
        }
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
            // 照片模式下同一视频尺寸可能对应不同的最大照片尺寸，去重键必须带上后者，
            // 否则分辨率更高的那个格式会被更早出现的同尺寸格式挤掉。
            let photoKey = mode == .photo
                ? "+\(descriptor.maxPhotoWidth)x\(descriptor.maxPhotoHeight)"
                : ""
            let key = "\(descriptor.width)x\(descriptor.height)@\(selection.frameRate)\(photoKey)"
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
        let largestPhoto = format.supportedMaxPhotoDimensions.max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        return CameraFormatDescriptor(
            identifier: identifier,
            width: dimensions.width,
            height: dimensions.height,
            supports30FPS: supports(30, format: format),
            supports24FPS: supports(24, format: format),
            isMultiCamSupported: format.isMultiCamSupported,
            supportsVideoPixelFormat: supportedVideoSubtypes.contains(mediaSubtype),
            isBinned: format.isVideoBinned,
            maxPhotoWidth: largestPhoto?.width ?? 0,
            maxPhotoHeight: largestPhoto?.height ?? 0
        )
    }

    /// 该格式可请求的最大照片尺寸，供 PhotoOutput 与单次请求设置上限。
    static func maximumPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions {
        format.supportedMaxPhotoDimensions.max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        } ?? CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    private static func supports(_ frameRate: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
        }
    }
}
