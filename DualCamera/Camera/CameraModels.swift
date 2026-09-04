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

    var recoveryAction: CameraNoticeAction {
        switch self {
        case .permissionDenied, .microphonePermissionDenied:
            .openAppSettings
        case .failed:
            .retrySession
        case .idle, .requestingAuthorization, .requestingMicrophoneAuthorization, .ready, .unsupported:
            .none
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

enum CameraNoticeAction: Equatable {
    case none
    case openAppSettings
    case retrySession
    case retryMediaSaves

    fileprivate var recoveryPriority: Int {
        switch self {
        case .none: 0
        case .retryMediaSaves: 1
        case .openAppSettings: 2
        case .retrySession: 3
        }
    }
}

struct CameraNotice: Equatable, Identifiable {
    let id: UUID
    let message: String
    let kind: CameraNoticeKind
    let action: CameraNoticeAction
    let mediaJobID: MediaSaveJobID?

    init(
        id: UUID = UUID(),
        message: String,
        kind: CameraNoticeKind,
        action: CameraNoticeAction = .none,
        mediaJobID: MediaSaveJobID? = nil
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.action = action
        self.mediaJobID = mediaJobID
    }
}

/// 可执行错误在用户处理前不能被低优先级提示夺走入口；用户操作按提示 ID
/// 消费，媒体重试成功则只按保存任务 ID 清理对应失败，避免误清新的错误。
enum CameraNoticePolicy {
    static func shouldPublish(_ incoming: CameraNotice, replacing current: CameraNotice?) -> Bool {
        guard let current else { return true }
        return incoming.action.recoveryPriority >= current.action.recoveryPriority
    }

    static func consuming(_ consumed: CameraNotice, from current: CameraNotice?) -> CameraNotice? {
        guard consumed.action != .none, current?.id == consumed.id else { return current }
        return nil
    }

    static func resolvingMediaSave(_ id: MediaSaveJobID, from current: CameraNotice?) -> CameraNotice? {
        guard current?.mediaJobID == id else { return current }
        return nil
    }
}

enum PhotoCaptureState: Equatable {
    case idle
    case capturing
    case composing
    case failed(CameraError)
}

enum VideoRecordingState: Equatable {
    case idle
    case requestingPermission
    case recording
    case finishing
    case preview
    case failed(CameraError)

    var statusTitle: String? {
        switch self {
        case .requestingPermission:
            "正在准备录制…"
        case .recording:
            "录制中"
        case .finishing:
            "正在处理视频…"
        case .idle, .preview, .failed:
            nil
        }
    }

    var preventsNewRecording: Bool {
        switch self {
        case .requestingPermission, .recording, .finishing:
            true
        case .idle, .preview, .failed:
            false
        }
    }
}

enum MediaSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(CameraError)

    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }
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

/// 补光模式。MultiCam 会话下照片闪光灯通常不可用，但手电筒是设备级属性，
/// 前后摄并发时依然能开，因此这里以「常亮补光」而非「拍照闪光」为准。
enum TorchMode: String, CaseIterable, Identifiable {
    case off
    case on

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .on: "常亮"
        }
    }

    var symbolName: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .on: "bolt.fill"
        }
    }
}

/// 界面的拍摄模式。只决定主按键执行拍照还是录像，
/// 不改变会话的建图时机——会话仍在真正开始录制时才切换到视频模式。
enum ShootingMode: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "照片"
        case .video: "视频"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .photo: "mode-photo"
        case .video: "mode-video"
        }
    }
}

/// 后摄对焦与测光的锁定状态。
enum FocusLockState: Equatable {
    case automatic
    case locked
}

struct CapturedSourcePhoto {
    /// 相机输出的文件数据；只有系统未提供时才允许保存层回退为 JPEG 重编码。
    let originalData: Data?
    let image: UIImage
    let position: AVCaptureDevice.Position
}

struct CapturedPhotoSet {
    let id: UUID
    let capturedAt: Date
    let backPhoto: CapturedSourcePhoto
    let frontPhoto: CapturedSourcePhoto
    let composedImage: UIImage
    let layout: DualCameraLayout
    let aspectRatio: CaptureAspectRatio
    let saveMode: PhotoSaveMode

    var backImage: UIImage { backPhoto.image }
    var frontImage: UIImage { frontPhoto.image }
}

struct CaptureTransaction {
    let id: UUID
    let startedAt: Date
    let expectedPositions: Set<AVCaptureDevice.Position>
    var receivedPhotos: [AVCaptureDevice.Position: CapturedSourcePhoto] = [:]
    var errors: [AVCaptureDevice.Position: CameraError] = [:]

    var isComplete: Bool {
        expectedPositions.allSatisfy { receivedPhotos[$0] != nil || errors[$0] != nil }
    }
}

struct CameraDiagnostics: Equatable {
    var deviceSummary: String = "等待相机配置"
    var backFormat: String = "—"
    var frontFormat: String = "—"
    /// 当前格式实际可请求的最大照片尺寸，用于核对成片分辨率。
    var backPhotoDimensions: String = "—"
    var frontPhotoDimensions: String = "—"
    var frameRate: Double = 0
    var hardwareCost: Float = 0
    var systemPressureCost: Float = 0

    static let empty = CameraDiagnostics()
}
