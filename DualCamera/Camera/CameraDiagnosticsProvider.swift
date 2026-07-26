import AVFoundation
import CoreMedia

enum CameraDiagnosticsProvider {
    static func make(
        session: AVCaptureMultiCamSession,
        backDevice: AVCaptureDevice?,
        frontDevice: AVCaptureDevice?
    ) -> CameraDiagnostics {
        CameraDiagnostics(
            deviceSummary: "\(backDevice?.localizedName ?? "后摄") + \(frontDevice?.localizedName ?? "前摄")",
            backFormat: formatSummary(backDevice),
            frontFormat: formatSummary(frontDevice),
            frameRate: frameRate(backDevice),
            hardwareCost: session.hardwareCost,
            systemPressureCost: session.systemPressureCost
        )
    }

    private static func formatSummary(_ device: AVCaptureDevice?) -> String {
        guard let device else { return "—" }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return "\(dimensions.width)×\(dimensions.height)"
    }

    private static func frameRate(_ device: AVCaptureDevice?) -> Double {
        guard let device else { return 0 }
        let seconds = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        return seconds > 0 ? 1 / seconds : 0
    }
}
