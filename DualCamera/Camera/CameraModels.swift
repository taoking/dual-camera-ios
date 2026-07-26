import AVFoundation
import CoreGraphics
import UIKit

enum RearCameraOption: String, CaseIterable, Identifiable, Equatable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    var title: String {
        switch self {
        case .ultraWide: "超广角"
        case .wide: "广角"
        case .telephoto: "长焦"
        }
    }

    var zoomLabel: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "长焦"
        }
    }

    var symbolName: String {
        switch self {
        case .ultraWide: "camera.metering.multispot"
        case .wide: "camera"
        case .telephoto: "camera.aperture"
        }
    }
}

enum CameraState: Equatable {
    case idle
    case requestingAuthorization
    case requestingMicrophoneAuthorization
    case ready
    case permissionDenied
    case microphonePermissionDenied
    case unsupported(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .ready:
            nil
        case .requestingAuthorization:
            "正在请求相机权限…"
        case .requestingMicrophoneAuthorization:
            "正在请求麦克风权限…"
        case .permissionDenied:
            "请在“设置”中允许相机权限后重试。"
        case .microphonePermissionDenied:
            "视频录制需要麦克风权限，请在“设置”中允许后重试。"
        case .unsupported(let detail), .failed(let detail):
            detail
        }
    }

    var symbolName: String {
        switch self {
        case .requestingAuthorization: "camera.fill"
        case .requestingMicrophoneAuthorization: "mic.fill"
        case .permissionDenied, .microphonePermissionDenied, .unsupported, .failed:
            "exclamationmark.triangle.fill"
        case .idle, .ready: "camera"
        }
    }
}

enum CameraNoticeKind: Equatable {
    case info
    case success
    case error

    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct CameraNotice: Equatable {
    let message: String
    let kind: CameraNoticeKind
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable, Codable {
    case threeByFour
    case square
    case nineBySixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeByFour: "3:4"
        case .square: "1:1"
        case .nineBySixteen: "9:16"
        }
    }

    var ratio: CGFloat {
        switch self {
        case .threeByFour: 3.0 / 4.0
        case .square: 1
        case .nineBySixteen: 9.0 / 16.0
        }
    }
}

enum DualCameraLayoutStyle: String, CaseIterable, Identifiable, Codable {
    case pictureInPicture
    case splitVertical
    case splitHorizontal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pictureInPicture: "画中画"
        case .splitVertical: "左右分屏"
        case .splitHorizontal: "上下分屏"
        }
    }

    var symbolName: String {
        switch self {
        case .pictureInPicture: "rectangle.inset.filled"
        case .splitVertical: "rectangle.split.2x1"
        case .splitHorizontal: "rectangle.split.1x2"
        }
    }
}

enum PIPSize: String, CaseIterable, Identifiable, Codable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var widthRatio: CGFloat {
        switch self {
        case .small: 0.24
        case .medium: 0.33
        case .large: 0.42
        }
    }

    static func closest(to widthRatio: CGFloat) -> PIPSize {
        allCases.min { abs($0.widthRatio - widthRatio) < abs($1.widthRatio - widthRatio) } ?? .medium
    }
}

struct NormalizedPoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat

    static let bottomRight = NormalizedPoint(x: 0.62, y: 0.52)
}

struct DualCameraLayout: Codable, Equatable {
    var style: DualCameraLayoutStyle
    /// 画中画左上角在输出画布中的归一化坐标。
    var pipPosition: NormalizedPoint
    var pipSize: PIPSize
    var cornerRadiusRatio: CGFloat
    var borderRatio: CGFloat
    var frontPreviewMirrored: Bool
    var frontCaptureMirrored: Bool

    static let `default` = DualCameraLayout(
        style: .pictureInPicture,
        pipPosition: .bottomRight,
        pipSize: .medium,
        cornerRadiusRatio: 0.075,
        borderRatio: 0.006,
        frontPreviewMirrored: true,
        frontCaptureMirrored: true
    )
}

enum PhotoSaveMode: String, CaseIterable, Identifiable, Codable {
    case composedOnly
    case composedAndSources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composedOnly: "仅保存成片"
        case .composedAndSources: "成片和前后原图"
        }
    }
}

enum CaptureQuality: String, CaseIterable, Identifiable, Codable {
    case fast
    case balanced

    var id: String { rawValue }
    var title: String { self == .fast ? "快速" : "均衡" }
}

struct CapturedPhotoSet {
    let id: UUID
    let capturedAt: Date
    let backImage: UIImage
    let frontImage: UIImage
    let composedImage: UIImage
    let layout: DualCameraLayout
    let aspectRatio: CaptureAspectRatio
}

struct CaptureTransaction {
    let id: UUID
    let startedAt: Date
    let expectedPositions: Set<AVCaptureDevice.Position>
    var receivedImages: [AVCaptureDevice.Position: UIImage] = [:]
    var errors: [AVCaptureDevice.Position: CameraError] = [:]

    var isComplete: Bool {
        expectedPositions.allSatisfy { receivedImages[$0] != nil || errors[$0] != nil }
    }
}

struct CameraDiagnostics: Equatable {
    var deviceSummary: String = "等待相机配置"
    var backFormat: String = "—"
    var frontFormat: String = "—"
    var frameRate: Double = 0
    var hardwareCost: Float = 0
    var systemPressureCost: Float = 0

    static let empty = CameraDiagnostics()
}
