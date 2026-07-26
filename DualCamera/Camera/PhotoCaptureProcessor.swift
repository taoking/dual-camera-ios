import AVFoundation
import UIKit

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let position: AVCaptureDevice.Position
    private let completion: (Result<CapturedSourcePhoto, CameraError>) -> Void

    init(
        position: AVCaptureDevice.Position,
        completion: @escaping (Result<CapturedSourcePhoto, CameraError>) -> Void
    ) {
        self.position = position
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(.captureFailed(error.localizedDescription)))
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(.failure(.captureFailed("无法读取照片文件数据。")))
            return
        }

        completion(.success(CapturedSourcePhoto(
            originalData: data,
            image: image.dualCameraNormalized,
            position: position
        )))
    }
}
