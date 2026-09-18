// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloadKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
    ],
    targets: [
        .target(name: "DownloadKit"),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
    ],
    swiftLanguageModes: [.v6]
)
