import Foundation

/// The two decisions a run makes about how it is *presented*, as pure functions
/// of what the run knows.
///
/// Extracted from `AppModel.runPipeline` / `runWindows` / `runMac` for the same
/// reason `CopyRing` and `CopyProgressModel` were: the rules were tangled up
/// inside the private methods that also do the work, so the only way to reach
/// them was a forty-minute write to a real drive. Neither had a single test.
/// The plumbing they were extracted from stayed exactly where it is — see the
/// note at the bottom of this file for why.
enum RunPlan {

    // MARK: - Where the write lands on the ring

    /// The share of the progress ring already spent by the time the write
    /// begins. The write is then scaled into `1 - base`, so the bar advances
    /// once across the whole run rather than resetting between phases.
    ///
    /// The two platforms differ because their downloads differ in weight.
    /// Windows fetches an ISO and then writes it, and the write is the shorter
    /// half — 0.55. macOS fetches a ~14 GB installer app and `createinstallmedia`
    /// then takes longer than the fetch did, so the halves are even.
    ///
    /// **A download that did not happen owns none of the ring.** When the exact
    /// installer is already in `/Applications` nothing is fetched, and starting
    /// the write at 0.5 would put the bar half-way along before any byte had
    /// reached the drive. The checklist says "Skipped" for that stage precisely
    /// so a bar at 2% is not contradicted by a completed stage above it, and
    /// this is the other half of that fix.
    static func writeBase(platform: AppModel.Platform,
                          source: AppModel.SourceMode,
                          installerWasReused: Bool) -> Double {
        // A local ISO or a local installer app: there was never a download to
        // charge for, whichever platform asked.
        guard source == .download else { return 0 }
        switch platform {
        case .windows: return 0.55
        case .macos:   return installerWasReused ? 0 : 0.5
        }
    }

    /// What is left of the ring for the write itself.
    static func writeSpan(platform: AppModel.Platform,
                          source: AppModel.SourceMode,
                          installerWasReused: Bool) -> Double {
        1 - writeBase(platform: platform, source: source, installerWasReused: installerWasReused)
    }

    // MARK: - How a run that stopped early is reported

    /// Everything the screen changes when a run does not reach the end.
    struct Outcome: Equatable {
        let wasCancelled: Bool
        let statusText: String
        /// What the failure banner says.
        let message: String
        /// Whether the technical log is opened for the user.
        let showsLogDetails: Bool
        /// What is appended to the log itself.
        let logLine: String
    }

    /// Stopping on request is an outcome, not a fault, and the two must not
    /// present the same way.
    ///
    /// The tool's own message is discarded for a cancellation on purpose:
    /// "createinstallmedia exited 15" is the SIGTERM *we* sent it, and
    /// reporting that as "Something went wrong" — with diagnostics to copy and
    /// a hint about what to try — blames the user for pressing the button we
    /// offered them.
    ///
    /// The log opens itself on a failure and stays shut on a cancellation for
    /// the same reason. A failure is exactly the moment technical detail stops
    /// being noise and becomes the thing you need; nothing in the log needs
    /// reading after a button the user pressed did what they asked.
    static func outcome(cancelled: Bool, describedError: String) -> Outcome {
        guard cancelled else {
            return Outcome(wasCancelled: false,
                           statusText: "Error",
                           message: describedError,
                           showsLogDetails: true,
                           logLine: "\n❌  \(describedError)")
        }
        return Outcome(
            wasCancelled: true,
            statusText: "Cancelled",
            message: "Stopped before the installer was finished, so the drive is not "
                   + "bootable. Start over to make one.",
            showsLogDetails: false,
            logLine: "\nCancelled.")
    }
}

// MARK: - What was deliberately NOT extracted, and why
//
// `runPipeline`, `runWindows` and `runMac` themselves stay on `AppModel`.
//
// The previous session queued "the write pipeline is the next coherent slice"
// as a second decomposition pass, on the basis that `AppModel` owns navigation,
// disks, the pipeline and progress at once. Measured rather than assumed, the
// line-count case for that has gone: the class sits comfortably inside its
// budget, and the earlier pass already noted that its last extraction was
// shaving to hit a number. Doing it again for the same reason would be the
// same mistake with more risk attached.
//
// The case that would have justified it anyway is coverage — extracting
// `CatalogModel` is what made the supersede logic reachable, and two mutations
// then survived the whole suite. That argument does not transfer here. Those
// three methods are almost entirely sequencing of five concrete collaborators
// (`MicrosoftCatalog`, `ISODownloader`, `USBWriter`, `MacInstaller`,
// `CopyTraceWriter`), each already tested in its own right. Making the
// sequencing testable means injecting all five into the one code path that
// erases a drive — a large, load-bearing change whose entire yield would be
// asserting that mocks are called in order.
//
// What was genuinely untested in there was not the sequencing. It was the two
// value-returning decisions above, both of which have shipped wrong before and
// neither of which needed the pipeline moved to become testable.
