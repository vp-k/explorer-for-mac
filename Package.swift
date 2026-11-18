// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Explorer", targets: ["Explorer"]),
        .library(name: "ExplorerCore", targets: ["ExplorerCore"]),
    ],
    targets: [
        .target(name: "ExplorerCore"),
        .executableTarget(name: "Explorer", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
    ]
)
