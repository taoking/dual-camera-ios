import Foundation

enum CameraError: LocalizedError, Equatable {
    case permissionDenied
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

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "请在“设置”中允许相机权限后重试。"
        case .unsupportedMultiCam(let detail), .sessionConfiguration(let detail), .sessionRuntime(let detail),
             .captureFailed(let detail), .compositionFailed(let detail), .photoLibrarySaveFailed(let detail):
            detail
        case .interrupted:
            "双摄会话被系统中断，恢复后可继续拍摄。"
        case .captureTimedOut:
            "拍照等待超时，请重试。"
        case .captureCancelled:
            "拍照已取消。"
        case .photoLibraryDenied:
            "请允许“添加照片”权限后再保存。"
        }
    }
}
