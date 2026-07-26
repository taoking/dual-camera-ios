import Foundation

enum CameraError: LocalizedError, Equatable {
    case permissionDenied
    case microphonePermissionDenied
    case unsupportedMultiCam(String)
    case sessionConfiguration(String)
    case sessionRuntime(String)
    case interrupted
    case captureFailed(String)
    case captureTimedOut
    case captureCancelled
    case compositionFailed(String)
    case photoLibraryDenied
    case photoLibrarySaveFailed(String)
    case videoRecordingFailed(String)
    case systemPressureCritical
    case systemPressureShutdown

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "请在“设置”中允许相机权限后重试。"
        case .microphonePermissionDenied:
            "视频录制需要麦克风权限，请在“设置”中允许后重试；拍照仍可使用。"
        case .unsupportedMultiCam(let detail), .sessionConfiguration(let detail), .sessionRuntime(let detail),
             .captureFailed(let detail), .compositionFailed(let detail), .photoLibrarySaveFailed(let detail),
             .videoRecordingFailed(let detail):
            detail
        case .interrupted:
            "双摄会话被系统中断，恢复后可继续拍摄。"
        case .captureTimedOut:
            "拍照等待超时，请重试。"
        case .captureCancelled:
            "拍照已取消。"
        case .photoLibraryDenied:
            "请允许“添加照片”权限后再保存。"
        case .systemPressureCritical:
            "设备压力过高，已停止或暂时禁止视频录制。"
        case .systemPressureShutdown:
            "设备温度或系统压力过高，相机会话已安全停止。"
        }
    }
}

struct CameraConfigurationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
