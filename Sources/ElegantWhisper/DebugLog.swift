import Foundation

enum DebugLog {
    static func event(_ name: String) {
        #if DEBUG
        print("\(AppConstants.logPrefix) \(name) \(Date().timeIntervalSince1970)")
        #endif
    }
}
