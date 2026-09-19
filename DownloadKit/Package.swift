// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloadKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
    ],
    targets: [
        // User-facing messages live in Resources/Localizable.xcstrings (English and Turkish).
        .target(name: "DownloadKit", resources: [.process("Resources")]),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
    ],
    swiftLanguageModes: [.v6]
)
