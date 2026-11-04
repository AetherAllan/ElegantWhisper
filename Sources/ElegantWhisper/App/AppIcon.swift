import AppKit

/// The icon that matches the app's look. The Dock, the app switcher and About show it; Finder
/// and Launchpad show the bundle icon (Prism), which cannot change without breaking the code
/// signature. Drawn by scripts/render-logo.swift.
enum AppIconVariant: String, CaseIterable, Sendable {
    /// Ink bars on white: the Standard theme in light mode.
    case paper
    /// White bars on graphite: the Standard theme in dark mode.
    case pulse
    /// Spectrum bars on black: the Prism theme, in either mode.
    case prism

    init(theme: AppTheme, isDark: Bool) {
        switch theme {
        case .prism: self = .prism
        case .standard: self = isDark ? .pulse : .paper
        }
    }

    var resourceName: String {
        switch self {
        case .paper: "AppIcon-Paper"
        case .pulse: "AppIcon-Pulse"
        case .prism: "AppIcon-Prism"
        }
    }

    /// Nil when the image is not in the bundle, as in a bare `swift run` build.
    @MainActor var image: NSImage? {
        if let cached = Self.cache[self] { return cached }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        Self.cache[self] = image
        return image
    }

    @MainActor private static var cache: [AppIconVariant: NSImage] = [:]
}

/// Keeps the Dock icon in step with the theme and the system's light or dark mode.
@MainActor
final class AppIconSwitcher {
    private var theme: AppTheme = .standard
    private var started = false
    private var appearanceObservation: NSKeyValueObservation?
    private(set) var current: AppIconVariant?

    func start(theme: AppTheme) {
        self.theme = theme
        started = true
        // Fires when the system switches mode, and when the Prism window's forced dark
        // appearance comes and goes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    /// Before start() this only records the theme, so models built in tests never touch NSApp.
    func setTheme(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        apply()
    }

    private func apply() {
        guard started else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let variant = AppIconVariant(theme: theme, isDark: isDark)
        guard variant != current, let image = variant.image else { return }
        current = variant
        NSApp.applicationIconImage = image
        DebugLog.event("appIcon variant=\(variant.rawValue)")
    }
}
