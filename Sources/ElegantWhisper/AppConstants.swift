import Foundation

enum AppConstants {
    static let productName = "ElegantWhisper"
    static let bundleIdentifier = "com.aetherallan.ElegantWhisper"
    static let userDefaultsSuiteName = bundleIdentifier
    static let keychainServiceName = bundleIdentifier
    static let logPrefix = "[ElegantWhisper]"

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(productName, isDirectory: true)
    }

    static func ensureApplicationDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
    }

    static func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureApplicationDirectories()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        // User history, dictionary terms, and prompts can contain private text. Keep these JSON
        // files readable only by the current user instead of inheriting broader directory modes.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
