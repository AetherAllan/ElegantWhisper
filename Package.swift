// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElegantWhisper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ElegantWhisper", targets: ["ElegantWhisper"])
    ],
    targets: [
        .executableTarget(
            name: "ElegantWhisper",
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
