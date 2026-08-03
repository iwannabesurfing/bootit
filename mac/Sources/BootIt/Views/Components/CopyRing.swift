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
    /// A copy in flight has no defensible percentage, so it gets no number. Once
    /// the tool announces the bless step there is a real end in sight again and
    /// the determinate bar returns for the last stretch.
    static func value(_ copy: CopyProgressState?, progress: Double) -> Double? {
        guard let copy else { return progress }
        if case .finishing = copy.activity { return progress }
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
