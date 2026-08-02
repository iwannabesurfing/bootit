import Foundation

/// A coarse stage of a build, reported by the writers so the progress screen can
/// show what has happened and what is left rather than one anonymous bar.
///
/// Deliberately coarser than the writers' internal steps: splitting `install.wim`
/// only happens for images over 4 GB, so listing it as a planned stage would
/// promise work that often never runs. It shows in the status line and the log
/// instead, where being conditional costs nothing.
enum WritePhase: String, CaseIterable, Identifiable {
    case downloading
    case preparing
    case copying
    case creatingInstaller
    case finalising

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .downloading:       return "arrow.down.circle"
        case .preparing:         return "externaldrive"
        case .copying:           return "doc.on.doc"
        case .creatingInstaller: return "gearshape"
        case .finalising:        return "checkmark.seal"
        }
    }

    /// Fallback wording; `AppModel.title(for:)` names the actual OS where it can.
    var genericTitle: String {
        switch self {
        case .downloading:       return "Downloading installer"
        case .preparing:         return "Preparing drive"
        case .copying:           return "Copying installer files"
        case .creatingInstaller: return "Creating installer"
        case .finalising:        return "Finalising"
        }
    }
}

/// Where a phase sits relative to the one running now.
enum PhaseState: Equatable {
    case done
    case active
    /// The phase that was running when the build stopped. Without this the
    /// checklist shows a failed stage as still in progress.
    case failed
    /// Planned, but there turned out to be nothing to do — the installer was
    /// already on the Mac, so no download happened.
    ///
    /// Distinct from `.done` on purpose. Ticking a skipped stage green makes the
    /// progress ring look broken: the user sees a completed stage sitting above
    /// a bar reading 2%, and reasonably concludes the bar reset.
    case skipped
    case pending
}
