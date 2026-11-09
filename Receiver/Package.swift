// swift-tools-version:5.9
// iMac Display – Empfänger: native App für den iMac (macOS 12 Monterey, Intel + Apple Silicon).
// Zeigt das H.264-Bild des MacBooks selbst an (VideoToolbox/AVSampleBufferDisplayLayer) – kein Browser nötig.
// Bauen:   swift build -c release --arch arm64 --arch x86_64
// Paket:   ./build-dmg.sh  (erzeugt dist/…app + dist/iMac-Display-Empfaenger.dmg; Abkürzung: scripts/make-imac-package.sh)
import PackageDescription

let package = Package(
    name: "Receiver",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "iMacDisplayReceiver",
            path: "Sources/iMacDisplayReceiver",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
