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

    static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static func ensureApplicationDirectories() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
}
