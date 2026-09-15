// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativePreviewHost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NativePreviewHost", targets: ["NativePreviewHost"])],
    targets: [
        .executableTarget(
            name: "NativePreviewHost",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NativePreviewHostTests", dependencies: ["NativePreviewHost"])
    ]
)
