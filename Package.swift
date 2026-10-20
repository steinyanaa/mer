// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MerCore", targets: ["MerCore"]),
        .executable(name: "mer", targets: ["mer"]),
        .executable(name: "MerApp", targets: ["MerApp"]),
    ],
    targets: [
        .target(name: "MerCore"),
        .executableTarget(name: "mer", dependencies: ["MerCore"]),
        .executableTarget(name: "MerApp", dependencies: ["MerCore"]),
    ]
)
