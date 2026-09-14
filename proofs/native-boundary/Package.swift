// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "native-boundary",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProofWire"),
        .executableTarget(name: "ProofService", dependencies: ["ProofWire"]),
        .executableTarget(name: "ProofHelper", dependencies: ["ProofWire"]),
        .executableTarget(name: "proofctl", dependencies: ["ProofWire"]),
        .executableTarget(name: "ProofApp", dependencies: ["ProofWire"]),
    ]
)
