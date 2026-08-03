import Foundation

/// The filesystem and partition scheme an installer drive gets formatted to.
///
/// BootIt erases a USB stick from two places — the app for the Windows path,
/// the root daemon for the macOS path — and the two differ in nothing else.
public struct EraseFormat: Equatable {

    public let filesystem: String
    public let scheme: String

    public init(filesystem: String, scheme: String) {
        self.filesystem = filesystem
        self.scheme = scheme
    }

    /// What `createinstallmedia` expects to be handed. It erases and reformats
    /// the drive itself afterwards; this is only what it will accept as a start.
    public static let macOSInstaller = EraseFormat(filesystem: "JHFS+", scheme: "GPT")

    /// MBR — **not** GPT, and not an arbitrary choice.
    ///
    /// A GPT format makes macOS add a small empty EFI System Partition alongside
    /// the data partition. Windows Setup detects that ESP and writes its boot
    /// loader (bootmgfw + BCD) onto the USB instead of the target SSD — so
    /// pulling the USB after the install leaves the SSD unbootable, "No OS
    /// found". MBR yields a single FAT32 partition with no ESP for Setup to
    /// hijack, and is still UEFI-bootable for removable install media via the
    /// \EFI\BOOT\BOOTX64.EFI fallback path.
    public static let windowsInstaller = EraseFormat(filesystem: "MS-DOS", scheme: "MBR")
}

/// Erasing a USB stick with `diskutil`, in one place.
///
/// This was written out twice — once in the app, once in the daemon — including
/// both argument vectors, the retry, and the way the two failures get combined
/// into one message. The argument vectors are the reason it is worth having one
/// home: `eraseDisk` and `partitionDisk` take the *same four values in different
/// orders*, and getting one wrong produces a command that still parses and fails
/// only against a real drive.
///
/// It builds arguments and decides the retry; it does not run anything. Each
/// caller keeps its own runner, because the daemon streams output line by line
/// through a cancellable `ToolRunner` while the app uses a blocking `Shell.run`.
public enum DiskErase {

    /// What one `diskutil` invocation reported back.
    public struct StepResult {
        public let ok: Bool
        public let output: String

        public init(ok: Bool, output: String) {
            self.ok = ok
            self.output = output
        }
    }

    public enum Outcome: Equatable {
        case formatted
        /// Both the erase and the repartition failed; the text is what they said.
        case failed(String)
    }

    /// `diskutil unmountDisk force <device>` — a mounted disk cannot be erased.
    public static func unmountArguments(device: String) -> [String] {
        ["unmountDisk", "force", device]
    }

    /// `diskutil eraseDisk <filesystem> <name> <scheme> <device>`
    public static func eraseArguments(device: String,
                                      volumeName: String,
                                      format: EraseFormat) -> [String] {
        ["eraseDisk", format.filesystem, volumeName, format.scheme, device]
    }

    /// `diskutil partitionDisk <device> <scheme> <filesystem> <name> 100%`
    ///
    /// Note this is not `eraseArguments` reordered by accident: `partitionDisk`
    /// genuinely takes the device first and the scheme before the filesystem,
    /// where `eraseDisk` takes the filesystem first and the device last.
    public static func repartitionArguments(device: String,
                                            volumeName: String,
                                            format: EraseFormat) -> [String] {
        ["partitionDisk", device, format.scheme, format.filesystem, volumeName, "100%"]
    }

    /// Unmount, erase, and — if that fails — replace the partition scheme.
    ///
    /// The retry is not a hopeful second attempt at the same thing. `eraseDisk`
    /// reuses the partition scheme already on the drive, which fails with -69850
    /// on anything already carrying a bootable or cloned layout — including a
    /// drive BootIt itself wrote earlier. `partitionDisk` replaces the scheme
    /// outright, which is the case a plain retry can never reach.
    ///
    /// - Parameters:
    ///   - onRetry: called before the second attempt, so each caller can log it
    ///     in its own voice.
    ///   - run: invokes `diskutil` with the given arguments.
    public static func perform(device: String,
                               volumeName: String,
                               format: EraseFormat,
                               onRetry: () -> Void = {},
                               run: (_ arguments: [String]) -> StepResult) -> Outcome {
        _ = run(unmountArguments(device: device))

        let erased = run(eraseArguments(device: device, volumeName: volumeName, format: format))
        if erased.ok { return .formatted }

        onRetry()
        _ = run(unmountArguments(device: device))

        let repartitioned = run(
            repartitionArguments(device: device, volumeName: volumeName, format: format))
        if repartitioned.ok { return .formatted }

        return .failed([erased.output, repartitioned.output]
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))
    }
}
