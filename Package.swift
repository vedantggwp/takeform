// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Takeform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TakeformSupport", targets: ["TakeformSupport"]),
        .executable(name: "Takeform", targets: ["TakeformApp"]),
        .executable(name: "TakeformDoctor", targets: ["TakeformDoctor"])
    ],
    targets: [
        .target(name: "TakeformSupport"),
        .executableTarget(name: "TakeformApp", dependencies: ["TakeformSupport"]),
        .executableTarget(name: "TakeformDoctor", dependencies: ["TakeformSupport"]),
        .testTarget(name: "TakeformSupportTests", dependencies: ["TakeformSupport"])
    ]
)
