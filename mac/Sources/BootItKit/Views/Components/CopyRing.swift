import BootItShared
import Foundation

/// How the copy phase is drawn, as a pure function of what is known about it.
///
/// Separated from `AppModel` for the same reason `CopyProgressModel` was: these
/// are the rules that decide whether the app *claims a percentage*, and three
/// wrong answers shipped when they were tangled up with the thing that owns
/// them. Here they can be read, and falsified, on their own.
enum CopyRing {

    /// The ring's value, or nil for an indeterminate one.
    ///
    /// A copy in flight has no defensible percentage, so it gets no number —
    /// synthesis §3.2, "animated, not a frozen number", and #8, "100% only on
    /// exit code 0". No copy state is exempt.
    ///
    /// `.finishing` returned `progress` until 2026-08-05, which made the ring
    /// determinate again for the tail. That was survivable only because
    /// `InstallMediaProgress` fed `progress` a fabricated 0.95 at the same
    /// moment. With the 0.95 deleted, `progress` still holds the erase ceiling
    /// during the copy, so honouring `.finishing` here would have drawn ~15% at
    /// 90% through the run — an under-claim replacing an over-claim, and the
    /// same category of error.
    ///
    /// `copy == nil` still yields `progress`: the download, the erase and the
    /// whole Windows path are genuinely measured, and this only ever governed
    /// the opaque macOS copy.
    static func value(_ copy: CopyProgressState?, progress: Double) -> Double? {
        guard let copy else { return progress }
        return copy.fraction
    }

    static func symbol(_ copy: CopyProgressState?) -> String {
        switch copy?.activity {
        case .idle:        return "exclamationmark.triangle.fill"
        case .unmeasured:  return "questionmark.circle.fill"
        default:           return "arrow.down.circle.fill"
        }
    }

    /// Only a genuinely quiet drive is drawn as a warning. "Can't be measured"
    /// is a limitation of the drive, not a fault in the run, and colouring it
    /// like one would send people hunting for a problem that is not there.
    static func isWarning(_ copy: CopyProgressState?) -> Bool {
        if case .idle = copy?.activity { return true }
        return false
    }
}
