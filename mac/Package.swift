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
            path: "Tests/BootItTests",
            // A real recorded run. The reason the trace format exists is that a
            // wrong answer about copy progress could previously only be
            // falsified by a 40-minute human-gated write, which is why three
            // wrong answers shipped. Carrying one real run as a fixture makes
            // that falsifiable in milliseconds.
            resources: [.copy("Fixtures")]
        )
    ]
)
