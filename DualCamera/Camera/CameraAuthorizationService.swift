import AVFoundation

enum CameraAuthorizationResult: Equatable {
    case authorized
    case denied
    case unknown
}

protocol CameraAuthorizationServing {
    func requestAccess(
        for mediaType: AVMediaType,
        onRequest: @escaping () -> Void,
        completion: @escaping (CameraAuthorizationResult) -> Void
    )
}

struct CameraAuthorizationService: CameraAuthorizationServing {
    func requestAccess(
        for mediaType: AVMediaType,
        onRequest: @escaping () -> Void,
        completion: @escaping (CameraAuthorizationResult) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(.authorized)
        case .notDetermined:
            onRequest()
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                completion(granted ? .authorized : .denied)
            }
        case .denied, .restricted:
            completion(.denied)
        @unknown default:
            completion(.unknown)
        }
    }
}
