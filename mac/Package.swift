// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BootIt",
    platforms: [.macOS(.v13)],
    // `BootItKit` is declared as a library product so Xcode offers a scheme
    // containing *no* executable. Previews resolve their host from the scheme,
    // and any scheme with an executable in it makes that executable the host —
    // which cannot carry ENABLE_PREVIEWS, so every `#Preview` in the package
    // failed naming the executable target, even for files in a library. All
    // three arrangements were measured on Xcode 26.6: executable target ✗,
    // library target under the package scheme ✗, library target under this
    // scheme ✓.
    //
    // The executables are listed too — naming any product suppresses the
    // implicit ones, and `build.sh` copies both binaries out of the bin path.
    products: [
        .library(name: "BootItKit", targets: ["BootItKit"]),
        .library(name: "BootItShared", targets: ["BootItShared"]),
        .executable(name: "BootIt", targets: ["BootIt"]),
        .executable(name: "BootItHelper", targets: ["BootItHelper"])
    ],
    targets: [
        // The XPC contract, shared so the app and the daemon cannot drift apart.
        .target(
            name: "BootItShared",
            path: "Sources/BootItShared"
        ),
        // Everything the app is. A library rather than the executable so its
        // `#Preview` blocks can render — see `products` above.
        .target(
            name: "BootItKit",
            dependencies: ["BootItShared"],
            path: "Sources/BootItKit"
        ),
        // A thin `@main` over BootItKit, and nothing else. Anything added here
        // is unpreviewable and untestable by construction.
        .executableTarget(
            name: "BootIt",
            dependencies: ["BootItKit"],
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
            dependencies: ["BootItKit", "BootItShared"],
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
