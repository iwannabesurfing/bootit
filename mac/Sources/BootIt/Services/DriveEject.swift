import Foundation

/// Ejecting the finished drive, and saying what happened if it did not work.
///
/// Both halves together on purpose. The failure message is only worth anything
/// if it repeats what the tool that failed actually said, so the code that runs
/// the command and the code that explains it should not be able to drift apart.
enum DriveEject {

    static func perform(_ drive: USBDisk) -> Shell.Result {
        Shell.run(DiskLister.diskutil, ["eject", drive.id])
    }

    /// What to say when the drive would not eject.
    ///
    /// `diskutil`'s own sentence, because it is the only thing that knows. This
    /// used to read "a file on it may still be open" for *every* failure — a
    /// guess written in the grammar of a diagnosis. On 2026-08-04 it was a wrong
    /// one: `lsof` showed nothing open on the volume, and the same eject
    /// succeeded from a shell moments later.
    ///
    /// The discarded output was the useful part. When something really does hold
    /// the disk, `diskutil` names it — "Dissenter PID=442 (mds)" — which is the
    /// difference between closing the right window and hunting for a file the
    /// user never had open.
    ///
    /// Third time this project has made this mistake: `20e1874` stopped guessing
    /// at the helper's reason for refusing, and `AccessDiagnostics` stopped
    /// rendering every daemon refusal as "enable Full Disk Access".
    ///
    /// Advice still follows, because a dissenter PID is not actionable on its
    /// own — but it is offered as a next step, not asserted as the cause.
    /// `diskutil` writes some failures to stdout rather than stderr, so both are
    /// considered.
    static func failureMessage(_ drive: USBDisk, _ result: Shell.Result) -> String {
        let reported = [result.err, result.out]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let reported else {
            return "Couldn't eject \(drive.name), and diskutil gave no reason. "
                 + "You can eject it from Finder, or unplug it once the Mac has finished writing."
        }
        return "Couldn't eject \(drive.name). \(reported)\n\n"
             + "Close anything using the drive and try again, or eject it from Finder."
    }
}
