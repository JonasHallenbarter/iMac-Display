// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "imac-display",
    platforms: [.macOS(.v13)],
    targets: [
        // Header-only declarations of Apple's private CGVirtualDisplay API (CoreGraphics).
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "imac-display",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/imac-display",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
