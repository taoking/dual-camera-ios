import Photos
import UIKit

enum PhotoLibraryAuthorizationState: Equatable {
    case authorized
    case notDetermined
    case denied
}

enum PhotoLibraryResourceKind: Equatable {
    case composedPhoto
    case backSourcePhoto
    case frontSourcePhoto
    case video
}

enum PhotoLibraryResourcePayload: Equatable {
    case data(Data)
    case fileURL(URL)
}

struct PhotoLibraryResource: Equatable {
    let kind: PhotoLibraryResourceKind
    let payload: PhotoLibraryResourcePayload
}

protocol PhotoLibraryClient {
    var addAuthorizationStatus: PhotoLibraryAuthorizationState { get }
    func requestAddAuthorization(completion: @escaping (PhotoLibraryAuthorizationState) -> Void)
    func save(resources: [PhotoLibraryResource], completion: @escaping (Result<Void, Error>) -> Void)
}

protocol PhotoImageEncoding {
    func jpegData(from image: UIImage, compressionQuality: CGFloat) -> Data?
}

struct JPEGPhotoImageEncoder: PhotoImageEncoding {
    func jpegData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        image.jpegData(compressionQuality: compressionQuality)
    }
}

final class PhotoLibraryService {
    private let client: PhotoLibraryClient
    private let encoder: PhotoImageEncoding

    init(
        client: PhotoLibraryClient = SystemPhotoLibraryClient(),
        encoder: PhotoImageEncoding = JPEGPhotoImageEncoder()
    ) {
        self.client = client
        self.encoder = encoder
    }

    func save(
        _ photoSet: CapturedPhotoSet,
        mode: PhotoSaveMode,
        completion: @escaping (Result<Void, CameraError>) -> Void
    ) {
        let completionGate = CompletionGate(completion)
        withAddAuthorization { [client, encoder] authorization in
            guard case .success = authorization else {
                completionGate.complete(.failure(.photoLibraryDenied))
                return
            }
            guard let composedData = encoder.jpegData(from: photoSet.composedImage, compressionQuality: 0.96) else {
                completionGate.complete(.failure(.photoLibrarySaveFailed("无法编码合成照片。")))
                return
            }

            var resources = [PhotoLibraryResource(kind: .composedPhoto, payload: .data(composedData))]
            if mode == .composedAndSources {
                guard let backData = Self.sourceData(photoSet.backPhoto, label: "后摄", encoder: encoder) else {
                    completionGate.complete(.failure(.photoLibrarySaveFailed("后摄原始数据不可用，JPEG 回退编码也失败。")))
                    return
                }
                guard let frontData = Self.sourceData(photoSet.frontPhoto, label: "前摄", encoder: encoder) else {
                    completionGate.complete(.failure(.photoLibrarySaveFailed("前摄原始数据不可用，JPEG 回退编码也失败。")))
                    return
                }
                resources.append(PhotoLibraryResource(kind: .backSourcePhoto, payload: .data(backData)))
                resources.append(PhotoLibraryResource(kind: .frontSourcePhoto, payload: .data(frontData)))
            }

            client.save(resources: resources) { result in
                switch result {
                case .success:
                    CameraLog.photoLibrary.info("照片资源已写入系统相册")
                    completionGate.complete(.success(()))
                case .failure(let error):
                    completionGate.complete(.failure(.photoLibrarySaveFailed(error.localizedDescription)))
                }
            }
        }
    }

    func saveVideo(
        at url: URL,
        completion: @escaping (Result<Void, CameraError>) -> Void
    ) {
        let completionGate = CompletionGate(completion)
        withAddAuthorization { [client] authorization in
            guard case .success = authorization else {
                completionGate.complete(.failure(.photoLibraryDenied))
                return
            }
            let resource = PhotoLibraryResource(kind: .video, payload: .fileURL(url))
            client.save(resources: [resource]) { result in
                switch result {
                case .success:
                    completionGate.complete(.success(()))
                case .failure(let error):
                    completionGate.complete(.failure(.photoLibrarySaveFailed("视频保存失败：\(error.localizedDescription)")))
                }
            }
        }
    }

    func requestAddAuthorization(completion: @escaping (Result<Void, CameraError>) -> Void) {
        withAddAuthorization(completion: completion)
    }

    private func withAddAuthorization(
        completion: @escaping (Result<Void, CameraError>) -> Void
    ) {
        let gate = CompletionGate(completion)
        switch client.addAuthorizationStatus {
        case .authorized:
            gate.complete(.success(()))
        case .denied:
            gate.complete(.failure(.photoLibraryDenied))
        case .notDetermined:
            client.requestAddAuthorization { status in
                gate.complete(status == .authorized ? .success(()) : .failure(.photoLibraryDenied))
            }
        }
    }

    private static func sourceData(
        _ photo: CapturedSourcePhoto,
        label: String,
        encoder: PhotoImageEncoding
    ) -> Data? {
        if let originalData = photo.originalData, !originalData.isEmpty {
            return originalData
        }
        CameraLog.photoLibrary.notice("\(label, privacy: .public)未返回原始文件数据，回退为 JPEG")
        return encoder.jpegData(from: photo.image, compressionQuality: 0.96)
    }
}

final class SystemPhotoLibraryClient: PhotoLibraryClient {
    var addAuthorizationStatus: PhotoLibraryAuthorizationState {
        Self.authorizationState(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAddAuthorization(completion: @escaping (PhotoLibraryAuthorizationState) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            completion(Self.authorizationState(status))
        }
    }

    func save(resources: [PhotoLibraryResource], completion: @escaping (Result<Void, Error>) -> Void) {
        let gate = CompletionGate(completion)
        PHPhotoLibrary.shared().performChanges {
            for resource in resources {
                let request = PHAssetCreationRequest.forAsset()
                switch resource.payload {
                case .data(let data):
                    request.addResource(with: .photo, data: data, options: nil)
                case .fileURL(let url):
                    request.addResource(with: .video, fileURL: url, options: nil)
                }
            }
        } completionHandler: { success, error in
            if success {
                gate.complete(.success(()))
            } else {
                gate.complete(.failure(error ?? PhotoLibraryClientError.saveFailed))
            }
        }
    }

    private static func authorizationState(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorizationState {
        switch status {
        case .authorized, .limited: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

private final class CompletionGate<Value> {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func complete(_ value: Value) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(value)
    }
}

private enum PhotoLibraryClientError: LocalizedError {
    case saveFailed

    var errorDescription: String? { "系统未返回保存失败原因。" }
}
