import XCTest
@testable import BootItKit
@testable import BootItShared

/// Erasing the stick was written out twice — app and daemon — and the copies
/// differed only in filesystem and scheme. What made that worth collapsing is
/// not the line count: it is that each copy hand-wrote two `diskutil` argument
/// vectors that take the *same four values in different orders*, where getting
/// one wrong yields a command that still parses and fails only against a real
/// drive somebody has already agreed to erase.
final class DiskEraseArgumentTests: XCTestCase {

    private let device = "/dev/disk4"
    private let volume = "MACINSTALL"

    /// `diskutil eraseDisk <filesystem> <name> <scheme> <device>`
    func testEraseTakesFilesystemFirstAndDeviceLast() {
        XCTAssertEqual(
            DiskErase.eraseArguments(device: device, volumeName: volume, format: .macOSInstaller),
            ["eraseDisk", "JHFS+", "MACINSTALL", "GPT", "/dev/disk4"])
    }

    /// `diskutil partitionDisk <device> <scheme> <filesystem> <name> 100%`
    ///
    /// Device first, and scheme *before* filesystem — the opposite of eraseDisk
    /// on both counts.
    func testRepartitionTakesDeviceFirstAndSchemeBeforeFilesystem() {
        XCTAssertEqual(
            DiskErase.repartitionArguments(device: device, volumeName: volume, format: .macOSInstaller),
            ["partitionDisk", "/dev/disk4", "GPT", "JHFS+", "MACINSTALL", "100%"])
    }

    func testTheTwoOrderingsAreGenuinelyDifferent() {
        // Guards against someone "tidying" one into the other's shape.
        let erase = DiskErase.eraseArguments(device: device, volumeName: volume, format: .macOSInstaller)
        let repartition = DiskErase.repartitionArguments(device: device, volumeName: volume,
                                                         format: .macOSInstaller)
        XCTAssertEqual(erase.firstIndex(of: "JHFS+"), 1)
        XCTAssertEqual(repartition.firstIndex(of: "JHFS+"), 3)
        XCTAssertEqual(erase.firstIndex(of: device), 4)
        XCTAssertEqual(repartition.firstIndex(of: device), 1)
    }

    func testAMountedDiskIsUnmountedByForce() {
        XCTAssertEqual(DiskErase.unmountArguments(device: device),
                       ["unmountDisk", "force", "/dev/disk4"])
    }
}

/// The two formats are the only thing that ever differed between the copies, and
/// one of them is load-bearing in a way that is invisible at the call site.
final class EraseFormatTests: XCTestCase {

    func testTheMacOSInstallerIsWhatCreateinstallmediaAccepts() {
        XCTAssertEqual(EraseFormat.macOSInstaller.filesystem, "JHFS+")
        XCTAssertEqual(EraseFormat.macOSInstaller.scheme, "GPT")
    }

    /// Not a preference. GPT makes macOS add an empty EFI System Partition, and
    /// Windows Setup writes its boot loader onto *that* instead of the target
    /// SSD — so the machine won't boot once the stick is pulled. The drive still
    /// formats, still installs, and the damage only shows up at the end.
    func testTheWindowsInstallerIsMBRAndNotGPT() {
        XCTAssertEqual(EraseFormat.windowsInstaller.scheme, "MBR")
        XCTAssertNotEqual(EraseFormat.windowsInstaller.scheme, "GPT")
        XCTAssertEqual(EraseFormat.windowsInstaller.filesystem, "MS-DOS")
    }

    func testTheTwoPathsHaveNotDriftedIntoEachOther() {
        XCTAssertNotEqual(EraseFormat.macOSInstaller, EraseFormat.windowsInstaller)
    }
}

/// The retry is the part with actual policy in it, and neither copy had a test.
final class DiskErasePolicyTests: XCTestCase {

    private let device = "/dev/disk4"
    private let volume = "MACINSTALL"

    /// Records what diskutil was asked to do, and answers however the test says.
    private final class FakeDiskutil {
        private(set) var commands: [[String]] = []
        var results: [DiskErase.StepResult] = []
        private var next = 0

        /// Anything not scripted succeeds silently — the unmounts, mostly.
        func run(_ arguments: [String]) -> DiskErase.StepResult {
            commands.append(arguments)
            defer { next += 1 }
            guard next < results.count else { return DiskErase.StepResult(ok: true, output: "") }
            return results[next]
        }

        var verbs: [String] { commands.compactMap(\.first) }
    }

    func testACleanEraseNeverTouchesThePartitionScheme() {
        let diskutil = FakeDiskutil()
        var retried = false

        let outcome = DiskErase.perform(device: device, volumeName: volume, format: .macOSInstaller,
                                        onRetry: { retried = true }, run: diskutil.run)

        XCTAssertEqual(outcome, .formatted)
        XCTAssertEqual(diskutil.verbs, ["unmountDisk", "eraseDisk"])
        XCTAssertFalse(retried, "nothing failed — the user should see no retry line")
    }

    /// -69850: `eraseDisk` reuses the scheme already on the drive, so a drive
    /// BootIt itself wrote earlier fails until the scheme is replaced outright.
    func testAFailedEraseIsRetriedByReplacingThePartitionScheme() {
        let diskutil = FakeDiskutil()
        diskutil.results = [
            .init(ok: true, output: ""),                              // unmount
            .init(ok: false, output: "Error: -69850")                 // eraseDisk
        ]
        var retried = false

        let outcome = DiskErase.perform(device: device, volumeName: volume, format: .macOSInstaller,
                                        onRetry: { retried = true }, run: diskutil.run)

        XCTAssertEqual(outcome, .formatted)
        XCTAssertTrue(retried)
        // Unmounted again before the second attempt: eraseDisk remounts on success
        // and can leave the volume mounted on failure.
        XCTAssertEqual(diskutil.verbs, ["unmountDisk", "eraseDisk", "unmountDisk", "partitionDisk"])
    }

    func testBothFailuresAreReportedTogether() {
        let diskutil = FakeDiskutil()
        diskutil.results = [
            .init(ok: true, output: ""),
            .init(ok: false, output: "Error: -69850"),
            .init(ok: true, output: ""),
            .init(ok: false, output: "Error: could not modify partition map")
        ]

        let outcome = DiskErase.perform(device: device, volumeName: volume,
                                        format: .macOSInstaller, run: diskutil.run)

        XCTAssertEqual(outcome,
                       .failed("Error: -69850\nError: could not modify partition map"))
    }

    /// A tool that fails silently must not produce a message that is just a
    /// newline — the app shows this text to the user verbatim.
    func testASilentFailureDoesNotProduceBlankLines() {
        let diskutil = FakeDiskutil()
        diskutil.results = [
            .init(ok: true, output: ""),
            .init(ok: false, output: ""),
            .init(ok: true, output: ""),
            .init(ok: false, output: "the only thing it said")
        ]

        let outcome = DiskErase.perform(device: device, volumeName: volume,
                                        format: .macOSInstaller, run: diskutil.run)

        XCTAssertEqual(outcome, .failed("the only thing it said"))
    }

    /// The Windows path runs the identical policy — that is the whole point of
    /// there being one of these now.
    func testTheWindowsPathRunsTheSamePolicyWithItsOwnFormat() {
        let diskutil = FakeDiskutil()
        diskutil.results = [
            .init(ok: true, output: ""),
            .init(ok: false, output: "Error: -69850")
        ]

        let outcome = DiskErase.perform(device: "disk4", volumeName: "WININSTALL",
                                        format: .windowsInstaller, run: diskutil.run)

        XCTAssertEqual(outcome, .formatted)
        XCTAssertEqual(diskutil.commands.last,
                       ["partitionDisk", "disk4", "MBR", "MS-DOS", "WININSTALL", "100%"])
    }
}
