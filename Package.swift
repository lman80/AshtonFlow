// swift-tools-version: 5.9
import PackageDescription

// AshtonFlow builds as a SwiftPM executable so it can depend on WhisperKit
// (added below) for on-device/offline transcription. The Makefile still drives
// the build and assembles the .app bundle (Info.plist, icon, codesign).
let package = Package(
    name: "AshtonFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AshtonFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources"
        )
    ]
)
