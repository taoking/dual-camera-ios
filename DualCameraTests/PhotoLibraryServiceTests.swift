import AVFoundation
import UIKit
import XCTest
@testable import DualCamera

final class PhotoLibraryServiceTests: XCTestCase {
    func testAlreadyAuthorizedDoesNotRequestAgain() {
        let client = MockPhotoLibraryClient(status: .authorized)
        let service = PhotoLibraryService(client: client)
        var result: Result<Void, CameraError>?
        service.requestAddAuthorization { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(client.requestCount, 0)
    }

    func testFirstAuthorizationRequestSucceeds() {
        let client = MockPhotoLibraryClient(status: .notDetermined)
        client.requestResult = .authorized
        let service = PhotoLibraryService(client: client)
        var result: Result<Void, CameraError>?
        service.requestAddAuthorization { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(client.requestCount, 1)
    }

    func testDeniedAuthorizationFails() {
        let client = MockPhotoLibraryClient(status: .denied)
        let service = PhotoLibraryService(client: client)
        var captured: CameraError?
        service.save(makePhotoSet(), mode: .composedOnly) {
            if case .failure(let error) = $0 { captured = error }
        }
        XCTAssertEqual(captured, .photoLibraryDenied)
        XCTAssertTrue(client.savedResources.isEmpty)
    }

    func testComposedOnlyWritesOneResource() {
        let client = MockPhotoLibraryClient(status: .authorized)
        let service = PhotoLibraryService(client: client)
        service.save(makePhotoSet(), mode: .composedOnly) { _ in }
        XCTAssertEqual(client.savedResources.map(\.kind), [.composedPhoto])
    }

    func testComposedAndSourcesPreservesOriginalCameraData() {
        let client = MockPhotoLibraryClient(status: .authorized)
        let set = makePhotoSet(backData: Data([0xBA]), frontData: Data([0xFA]))
        PhotoLibraryService(client: client).save(set, mode: .composedAndSources) { _ in }
        XCTAssertEqual(client.savedResources.map(\.kind), [.composedPhoto, .backSourcePhoto, .frontSourcePhoto])
        XCTAssertEqual(data(for: .backSourcePhoto, resources: client.savedResources), Data([0xBA]))
        XCTAssertEqual(data(for: .frontSourcePhoto, resources: client.savedResources), Data([0xFA]))
    }

    func testSourceFallbackEncodingFailureNamesAffectedSource() {
        let client = MockPhotoLibraryClient(status: .authorized)
        let encoder = QueueImageEncoder(results: [Data([1]), nil])
        let service = PhotoLibraryService(client: client, encoder: encoder)
        var captured: CameraError?
        service.save(makePhotoSet(backData: nil, frontData: Data([2])), mode: .composedAndSources) {
            if case .failure(let error) = $0 { captured = error }
        }
        guard case .photoLibrarySaveFailed(let message) = captured else {
            return XCTFail("应返回相册保存错误")
        }
        XCTAssertTrue(message.contains("后摄"))
    }

    func testSystemSaveFailureIsForwarded() {
        let client = MockPhotoLibraryClient(status: .authorized)
        client.saveResult = .failure(MockError.failed)
        var captured: CameraError?
        PhotoLibraryService(client: client).save(makePhotoSet(), mode: .composedOnly) {
            if case .failure(let error) = $0 { captured = error }
        }
        XCTAssertEqual(captured, .photoLibrarySaveFailed("模拟系统保存失败"))
    }

    func testCompletionOnlyRunsOnceWhenClientMisbehaves() {
        let client = MockPhotoLibraryClient(status: .authorized)
        client.completesSaveTwice = true
        var completionCount = 0
        PhotoLibraryService(client: client).save(makePhotoSet(), mode: .composedOnly) { _ in
            completionCount += 1
        }
        XCTAssertEqual(completionCount, 1)
    }

    private func makePhotoSet(
        backData: Data? = Data([1]),
        frontData: Data? = Data([2])
    ) -> CapturedPhotoSet {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        return CapturedPhotoSet(
            id: UUID(),
            capturedAt: .now,
            backPhoto: CapturedSourcePhoto(originalData: backData, image: image, position: .back),
            frontPhoto: CapturedSourcePhoto(originalData: frontData, image: image, position: .front),
            composedImage: image,
            layout: .default,
            aspectRatio: .threeByFour
        )
    }

    private func data(
        for kind: PhotoLibraryResourceKind,
        resources: [PhotoLibraryResource]
    ) -> Data? {
        guard let resource = resources.first(where: { $0.kind == kind }),
              case .data(let data) = resource.payload else { return nil }
        return data
    }
}

private final class MockPhotoLibraryClient: PhotoLibraryClient {
    var addAuthorizationStatus: PhotoLibraryAuthorizationState
    var requestResult: PhotoLibraryAuthorizationState = .denied
    var requestCount = 0
    var savedResources = [PhotoLibraryResource]()
    var saveResult: Result<Void, Error> = .success(())
    var completesSaveTwice = false

    init(status: PhotoLibraryAuthorizationState) {
        addAuthorizationStatus = status
    }

    func requestAddAuthorization(completion: @escaping (PhotoLibraryAuthorizationState) -> Void) {
        requestCount += 1
        completion(requestResult)
    }

    func save(resources: [PhotoLibraryResource], completion: @escaping (Result<Void, Error>) -> Void) {
        savedResources = resources
        completion(saveResult)
        if completesSaveTwice { completion(saveResult) }
    }
}

private final class QueueImageEncoder: PhotoImageEncoding {
    var results: [Data?]

    init(results: [Data?]) {
        self.results = results
    }

    func jpegData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        results.isEmpty ? nil : results.removeFirst()
    }
}

private enum MockError: LocalizedError {
    case failed
    var errorDescription: String? { "模拟系统保存失败" }
}
