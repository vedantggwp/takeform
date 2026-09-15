// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Takeform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TakeformSupport", targets: ["TakeformSupport"]),
        .library(name: "TakeformCore", targets: ["TakeformCore"]),
        .library(name: "TakeformWorkspace", targets: ["TakeformWorkspace"]),
        .executable(name: "Takeform", targets: ["TakeformApp"]),
        .executable(name: "TakeformDoctor", targets: ["TakeformDoctor"]),
        .executable(name: "takeform", targets: ["TakeformCLI"]),
        .executable(name: "TakeformAuthorityService", targets: ["TakeformAuthorityService"])
    ],
    targets: [
        .target(name: "CSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "TakeformSupport"),
        .target(name: "TakeformCore"),
        .target(name: "TakeformAuthority", dependencies: ["CSQLite", "TakeformCore"]),
        .target(name: "TakeformWorkspace", dependencies: ["TakeformCore"]),
        .executableTarget(name: "TakeformApp", dependencies: ["TakeformSupport", "TakeformCore", "TakeformWorkspace"]),
        .executableTarget(name: "TakeformDoctor", dependencies: ["TakeformSupport"]),
        .executableTarget(name: "TakeformCLI", dependencies: ["TakeformAuthority", "TakeformCore"]),
        .executableTarget(name: "TakeformAuthorityService", dependencies: ["TakeformAuthority", "TakeformCore"]),
        .executableTarget(name: "TakeformAuthorityHarness", dependencies: ["TakeformAuthority", "TakeformCore"]),
        .executableTarget(name: "TakeformAuthorityFaultHarness", dependencies: ["TakeformAuthority", "TakeformCore"]),
        .testTarget(name: "TakeformSupportTests", dependencies: ["TakeformSupport"]),
        .testTarget(name: "TakeformAuthorityTests", dependencies: ["TakeformAuthority", "TakeformCore"]),
        .testTarget(name: "TakeformWorkspaceTests", dependencies: ["TakeformWorkspace", "TakeformCore"])
    ]
)
