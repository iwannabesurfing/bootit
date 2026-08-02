// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BootIt",
    platforms: [.macOS(.v13)],
    targets: [
        // The XPC contract, shared so the app and the daemon cannot drift apart.
        .target(
            name: "BootItShared",
            path: "Sources/BootItShared"
        ),
        .executableTarget(
            name: "BootIt",
            dependencies: ["BootItShared"],
            path: "Sources/BootIt"
        ),
        // The privileged LaunchDaemon. Embedded in the app bundle at
        // Contents/MacOS/ and registered with SMAppService.
        .executableTarget(
            name: "BootItHelper",
            dependencies: ["BootItShared"],
            path: "Sources/BootItHelper"
        ),
        .testTarget(
            name: "BootItTests",
            dependencies: ["BootIt", "BootItShared"],
            path: "Tests/BootItTests"
        )
    ]
)
