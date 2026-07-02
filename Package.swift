// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ElegantWhisper",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ElegantWhisper", targets: ["ElegantWhisper"])
    ],
    targets: [
        .executableTarget(
            name: "ElegantWhisper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("Speech")
            ]
        ),
        .testTarget(
            name: "ElegantWhisperTests",
            dependencies: ["ElegantWhisper"]
        )
    ]
)
