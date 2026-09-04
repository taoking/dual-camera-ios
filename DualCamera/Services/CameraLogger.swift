import OSLog

enum CameraLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dual.camera"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let authorization = Logger(subsystem: subsystem, category: "authorization")
    static let capability = Logger(subsystem: subsystem, category: "capability")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let composition = Logger(subsystem: subsystem, category: "composition")
    static let photoLibrary = Logger(subsystem: subsystem, category: "photoLibrary")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let interruption = Logger(subsystem: subsystem, category: "interruption")
}
