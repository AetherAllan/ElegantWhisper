import Foundation

enum DebugLog {
    private static let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.debug-log")
    private static let maxBytes = 128 * 1024

    static func event(_ name: String) {
        // Keep release diagnostics local and content-free. These events are used for timing and
        // failure-path debugging only; transcript text, API keys, and prompt bodies must never be
        // written here because the log is intentionally easy for the user to inspect.
        let safeName = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        #if DEBUG
        print("\(AppConstants.logPrefix) \(safeName) \(Date().timeIntervalSince1970)")
        #endif

        queue.async {
            append(safeName)
        }
    }

    private static func append(_ name: String) {
        do {
            try AppConstants.ensureApplicationDirectories()
            let url = AppConstants.applicationSupportDirectory.appendingPathComponent("debug.log")
            rotateIfNeeded(url)
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(name)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            #if DEBUG
            print("\(AppConstants.logPrefix) debugLogWriteFailed \(error.localizedDescription)")
            #endif
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue > maxBytes
        else {
            return
        }
        let backup = url.deletingPathExtension().appendingPathExtension("log.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
