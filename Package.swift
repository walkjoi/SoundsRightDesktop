// swift-tools-version: 5.9
// SwiftPM manifest used by Scripts/build-app.sh to build the app with only
// Command Line Tools (no full Xcode). The canonical Xcode setup remains
// project.yml + XcodeGen.
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
        // stripped: the SwiftUI previews macro plugin ships only with full
        // Xcode, so the upstream package cannot compile under Command Line
        // Tools alone. Xcode builds (project.yml) still use upstream.
        .package(path: "Vendor/KeyboardShortcuts")
    ],
    targets: [
        .executableTarget(
            name: "SoundsRight",
            dependencies: ["KeyboardShortcuts"],
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
