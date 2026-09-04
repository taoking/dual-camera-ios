import AVFoundation
import Foundation

/// 统一持有 Session 通知与设备压力 KVO，避免 Controller 直接管理 Observer 生命周期。
final class CameraRuntimeMonitor {
    var onRuntimeError: ((AVError?) -> Void)?
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onPressureChanged: ((AVCaptureDevice.SystemPressureState.Level) -> Void)?

    private weak var session: AVCaptureSession?
    private var notificationTokens = [NSObjectProtocol]()
    private var pressureObservations = [NSKeyValueObservation]()
    private var pressureLevels = [String: AVCaptureDevice.SystemPressureState.Level]()
    private let pressureLock = NSLock()

    init(session: AVCaptureSession) {
        self.session = session
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.onRuntimeError?(notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.onInterruptionBegan?()
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.onInterruptionEnded?()
        })
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func observePressure(back: AVCaptureDevice, front: AVCaptureDevice) {
        pressureObservations.removeAll()
        pressureLock.lock()
        pressureLevels.removeAll()
        pressureLock.unlock()
        for device in [back, front] {
            pressureObservations.append(device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                self?.publishWorstPressure(device: device)
            })
        }
    }

    func stopObservingPressure() {
        pressureObservations.removeAll()
        pressureLock.lock()
        pressureLevels.removeAll()
        pressureLock.unlock()
    }

    private func publishWorstPressure(device: AVCaptureDevice) {
        pressureLock.lock()
        pressureLevels[device.uniqueID] = device.systemPressureState.level
        let worst = pressureLevels.values.max { severity($0) < severity($1) }
        pressureLock.unlock()
        if let worst { onPressureChanged?(worst) }
    }

    private func severity(_ level: AVCaptureDevice.SystemPressureState.Level) -> Int {
        switch level {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .shutdown: 4
        default: 3
        }
    }
}
