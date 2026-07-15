import Foundation

enum QuickPreviewDebugLog {
    private static let queue = DispatchQueue(label: "com.jboive.quickpreview.debuglog")

    private static let lineTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("QuickPreview", isDirectory: true)
        return folder.appendingPathComponent("debug.log", isDirectory: false)
    }

    private static func ensureDirectoryExists() {
        let directory = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func appendUnchecked(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        ensureDirectoryExists()
        let path = logFileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        defer {
            try? handle.close()
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }

    static func log(_ message: String) {
        queue.async {
            let line = "[\(lineTimestampFormatter.string(from: Date()))] \(message)\n"
            appendUnchecked(line)
        }
    }

    static func appendSessionBanner() {
        queue.async {
            ensureDirectoryExists()
            let bundle = Bundle.main
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            let edition = AppEdition.current.rawValue
            let bridge = AppEdition.current.bridgeAPIBaseURL?.absoluteString ?? "(nil)"
            let bundlePath = bundle.bundlePath
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let logPath = logFileURL.path
            let banner = """

            ===== QuickPreview session \(lineTimestampFormatter.string(from: Date())) =====
            edition=\(edition)  version=\(version) (\(build))
            bridgeAPIBaseURL=\(bridge)
            bundlePath=\(bundlePath)
            debugLogFile=\(logPath)
            \(os)
            ======================================================================

            """
            appendUnchecked(banner)
        }
    }

    /// Ensures the log file exists before Help → Open / Finder (synchronous).
    static func ensureLogFileExistsForUser() {
        queue.sync {
            ensureDirectoryExists()
            let path = logFileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
                appendUnchecked("QuickPreview debug log created. New entries appear as you use the app.\n")
            }
        }
    }
}
