// swift-tools-version: 5.9
// SwiftPM manifest used by Scripts/build-app.sh to build the app without an
// Apple Developer account (it still needs Xcode's toolchain for SwiftUI's
// macro plugins). The canonical Xcode setup remains project.yml + XcodeGen.
import PackageDescription

let package = Package(
    name: "SoundsRight",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SoundsRight", targets: ["SoundsRight"])
    ],
    dependencies: [
        // Vendored copy of KeyboardShortcuts 2.4.0 with its #Preview blocks
        // and unused globalKeyboardShortcut(_:) modifier stripped. Xcode
        // builds (project.yml) use upstream.
        .package(path: "Vendor/KeyboardShortcuts"),
        // Pure-Swift Core ML runtime for Whisper — no C++ toolchain, CMake or
        // Metal compiler, so it builds with plain `swift build`.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0")
    ],
    targets: [
        .executableTarget(
            name: "SoundsRight",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "SoundsRight",
            exclude: [
                "Info.plist",
                "SoundsRight.entitlements",
                "Resources"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
