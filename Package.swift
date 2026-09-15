// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Takeform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TakeformSupport", targets: ["TakeformSupport"]),
        .library(name: "TakeformCore", targets: ["TakeformCore"]),
        .library(name: "TakeformWorkspace", targets: ["TakeformWorkspace"]),
        .library(name: "TakeformAppAuthorityWire", targets: ["TakeformAppAuthorityWire"]),
        .library(name: "TakeformMedia", targets: ["TakeformMedia"]),
        .library(name: "TakeformRenderedPreview", targets: ["TakeformRenderedPreview"]),
        .executable(name: "TakeformAuthorityAppService", targets: ["TakeformAuthorityAppService"]),
        // Keep the native app executable distinct from the lowercase CLI on
        // case-insensitive volumes, where Takeform/takeform are one path.
        .executable(name: "TakeformApp", targets: ["TakeformApp"]),
        .executable(name: "TakeformDoctor", targets: ["TakeformDoctor"]),
        .executable(name: "takeform", targets: ["TakeformCLI"]),
        .executable(name: "TakeformAuthorityService", targets: ["TakeformAuthorityService"])
    ],
    targets: [
        .target(name: "CSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "TakeformSupport"),
        .target(name: "TakeformCore"),
        .target(name: "TakeformAuthorityEngine", dependencies: ["CSQLite", "TakeformCore"], path: "Sources/TakeformAuthority"),
        .target(name: "TakeformAuthorityAppServiceCore", dependencies: ["TakeformAuthorityEngine", "TakeformCore", "TakeformWorkspace", "TakeformAppAuthorityWire", "TakeformMedia"]),
        .target(name: "TakeformWorkspace", dependencies: ["TakeformCore"]),
        .target(name: "TakeformAppAuthorityWire", dependencies: ["TakeformCore", "TakeformWorkspace"]),
        .target(name: "TakeformMedia"),
        .target(name: "TakeformRenderedPreview", dependencies: ["TakeformCore", "TakeformAppAuthorityWire"]),
        .target(name: "TakeformAppServiceClient", dependencies: ["TakeformCore", "TakeformWorkspace", "TakeformAppAuthorityWire"]),
        .executableTarget(name: "TakeformApp", dependencies: ["TakeformSupport", "TakeformCore", "TakeformWorkspace", "TakeformAppAuthorityWire", "TakeformAppServiceClient", "TakeformRenderedPreview"]),
        .executableTarget(name: "TakeformAuthorityAppService", dependencies: ["TakeformAuthorityAppServiceCore", "TakeformCore", "TakeformWorkspace", "TakeformAppAuthorityWire"]),
        .executableTarget(name: "TakeformDoctor", dependencies: ["TakeformSupport"]),
        .executableTarget(name: "TakeformCLI", dependencies: ["TakeformCore", "TakeformAppAuthorityWire"]),
        .executableTarget(name: "TakeformAuthorityService", dependencies: ["TakeformAuthorityAppServiceCore", "TakeformCore"]),
        .executableTarget(name: "TakeformAuthorityHarness", dependencies: ["TakeformAuthorityAppServiceCore", "TakeformCore"]),
        .executableTarget(name: "TakeformAuthorityFaultHarness", dependencies: ["TakeformAuthorityAppServiceCore", "TakeformCore"]),
        .testTarget(name: "TakeformSupportTests", dependencies: ["TakeformSupport"]),
        .testTarget(name: "TakeformAuthorityTests", dependencies: ["TakeformAuthorityAppServiceCore", "TakeformAppAuthorityWire", "TakeformCore"]),
        .testTarget(name: "TakeformWorkspaceTests", dependencies: ["TakeformWorkspace", "TakeformCore", "TakeformAppServiceClient", "TakeformAppAuthorityWire", "TakeformAuthorityAppServiceCore", "TakeformApp", "TakeformRenderedPreview"]),
        .testTarget(name: "TakeformMediaTests", dependencies: ["TakeformMedia"]),
        .testTarget(name: "TakeformRenderedPreviewTests", dependencies: ["TakeformRenderedPreview", "TakeformCore", "TakeformAppAuthorityWire"])
    ]
)
