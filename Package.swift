// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Takeform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TakeformSupport", targets: ["TakeformSupport"]),
        .library(name: "TakeformMedia", targets: ["TakeformMedia"]),
        .executable(name: "Takeform", targets: ["TakeformApp"]),
        .executable(name: "TakeformDoctor", targets: ["TakeformDoctor"])
    ],
    targets: [
        .target(name: "TakeformSupport"),
        .target(name: "TakeformMedia"),
        .executableTarget(name: "TakeformApp", dependencies: ["TakeformSupport"]),
        .executableTarget(name: "TakeformDoctor", dependencies: ["TakeformSupport"]),
        .testTarget(name: "TakeformSupportTests", dependencies: ["TakeformSupport"]),
        .testTarget(name: "TakeformMediaTests", dependencies: ["TakeformMedia"])
    ]
)
