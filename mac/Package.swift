// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BootIt",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BootIt",
            path: "Sources/BootIt"
        ),
        .testTarget(
            name: "BootItTests",
            dependencies: ["BootIt"],
            path: "Tests/BootItTests"
        )
    ]
)
