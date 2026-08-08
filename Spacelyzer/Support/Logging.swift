import OSLog

enum Log {
    private static let subsystem = "co.lifehabitz.Spacelyzer"

    static let scanning = Logger(subsystem: subsystem, category: "scanning")
    static let accounting = Logger(subsystem: subsystem, category: "accounting")
    static let access = Logger(subsystem: subsystem, category: "access")
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

extension Logger {
    /// Paths and filenames are user content. They are logged with `.private` so that captured
    /// logs redact them, which Principle I requires.
    func path(_ message: String, _ url: URL) {
        debug("\(message, privacy: .public): \(url.path, privacy: .private)")
    }
}
