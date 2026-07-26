import Photos
import UIKit

final class PhotoLibraryService {
    func save(
        _ photoSet: CapturedPhotoSet,
        mode: PhotoSaveMode,
        completion: @escaping (Result<Void, CameraError>) -> Void
    ) {
        requestAddAuthorization { authorizationResult in
            switch authorizationResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let composedData = photoSet.composedImage.jpegData(compressionQuality: 0.96) else {
                    completion(.failure(.photoLibrarySaveFailed("无法编码合成照片。")))
                    return
                }
                let backData = mode == .composedAndSources ? photoSet.backImage.jpegData(compressionQuality: 0.96) : nil
                let frontData = mode == .composedAndSources ? photoSet.frontImage.jpegData(compressionQuality: 0.96) : nil
                if mode == .composedAndSources, (backData == nil || frontData == nil) {
                    completion(.failure(.photoLibrarySaveFailed("无法编码前后摄原图。")))
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    let composedRequest = PHAssetCreationRequest.forAsset()
                    composedRequest.addResource(with: .photo, data: composedData, options: nil)
                    if let backData {
                        let backRequest = PHAssetCreationRequest.forAsset()
                        backRequest.addResource(with: .photo, data: backData, options: nil)
                    }
                    if let frontData {
                        let frontRequest = PHAssetCreationRequest.forAsset()
                        frontRequest.addResource(with: .photo, data: frontData, options: nil)
                    }
                } completionHandler: { success, error in
                    if success {
                        CameraLog.photoLibrary.info("照片已写入系统相册")
                        completion(.success(()))
                    } else {
                        completion(.failure(.photoLibrarySaveFailed(error?.localizedDescription ?? "系统未返回错误原因。")))
                    }
                }
            }
        }
    }

    func requestAddAuthorization(completion: @escaping (Result<Void, CameraError>) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(.success(()))
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    completion(.success(()))
                } else {
                    completion(.failure(.photoLibraryDenied))
                }
            }
        case .denied, .restricted:
            completion(.failure(.photoLibraryDenied))
        @unknown default:
            completion(.failure(.photoLibraryDenied))
        }
    }
}
