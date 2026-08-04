import Foundation

/// What pressing the primary action should do, expressed as data rather than
/// performed inline. Navigation used to live in `ContentView`, where nothing
/// could reach it without a window; as a value it can be asserted directly.
enum FlowDecision: Equatable {
    /// Move to `step`. `refreshingDisks` asks for a disk rescan on arrival.
    case advance(to: AppModel.Step, refreshingDisks: Bool)
    /// Stay put and surface `message` to the user.
    case block(message: String)
    /// Hand off to the destructive confirmation before anything is erased.
    case confirmErase
    /// This step's primary action isn't navigation (progress cancels, done resets).
    case noop

    static func advance(to step: AppModel.Step) -> FlowDecision {
        .advance(to: step, refreshingDisks: false)
    }
}

extension AppModel.Step {
    /// Short label for the setup progress indicator.
    var stageTitle: String {
        switch self {
        case .platform: return "Platform"
        case .source:   return "Source"
        case .options:  return "Options"
        case .usb:      return "USB Drive"
        case .progress: return "Writing"
        case .done:     return "Done"
        }
    }
}

extension AppModel {

    // MARK: - Page furniture

    /// The stages the indicator shows for the *current route*. A local source
    /// never visits `.options`, so listing it would promise a step that never
    /// arrives and make the flow look longer than it is.
    var setupStages: [Step] {
        source == .local
            ? [.platform, .source, .usb]
            : [.platform, .source, .options, .usb]
    }

    /// Writing and completion replace setup navigation rather than extending it.
    var showsSetupProgress: Bool { step != .progress && step != .done }

    /// The Windows 11 bypass normally lives on the options step, which the local
    /// route skips entirely — so on that route the drive step carries it instead.
    /// Without this it would simply be unavailable to anyone using their own ISO.
    var showsBypassOptionOnDriveStep: Bool {
        platform == .windows && source == .local
    }

    private var platformName: String { platform == .macos ? "macOS" : "Windows" }

    var pageTitle: String {
        switch step {
        case .platform: return "Create a bootable installer"
        case .source:   return "Choose installer source"
        case .options:  return platform == .macos ? "Choose macOS version" : "Choose Windows options"
        case .usb:      return "Choose the USB drive to erase"
        case .progress:
            if wasCancelled { return "Build cancelled" }
            return runError == nil ? "Creating \(platformName) installer" : "Something went wrong"
        case .done:     return "Your \(platformName) installer is ready"
        }
    }

    var pageSubtitle: String? {
        switch step {
        case .platform: return "Choose the operating system you want to install."
        case .source:   return "Where would you like to get your \(platformName) installer from?"
        case .options:  return platform == .macos
            ? "Downloaded directly from Apple."
            : "Select the edition and language for your installer."
        case .usb:      return "Only external drives are shown."
        case .progress, .done: return nil
        }
    }

    // MARK: - Derived navigation state

    /// Where Back leads from the current step, or nil when there's nowhere to go.
    var backDestination: Step? {
        switch step {
        case .source:  return .platform
        case .options: return .source
        // Local sources never visit `.options`, so Back has to skip it too.
        case .usb:     return source == .download ? .options : .source
        case .platform, .progress, .done: return nil
        }
    }

    var showsBack: Bool { backDestination != nil }

    /// Whether the source step has everything it needs to continue.
    var isSourceValid: Bool {
        guard source == .local else { return true }   // download is always valid
        return platform == .windows ? !localISOPath.isEmpty : !catalog.macAppPath.isEmpty
    }

    /// The primary button's title for the current step.
    var primaryActionTitle: String {
        switch step {
        case .platform, .source, .options: return "Continue"
        case .usb:      return "Erase and Create Installer"
        // Once a build has stopped there is nothing left to cancel, and leaving
        // a dead Cancel button as the only action strands the user.
        case .progress: return runError == nil ? "Cancel" : "Start Over"
        // Quit is not what someone wants next — the drive is still mounted and
        // pulling it out unejected risks the thing they just spent 15 minutes
        // making. Offer the real next action, and only then a way to leave.
        case .done:     return driveEjected ? "Done" : "Eject Drive"
        }
    }

    /// Plain-language guidance for the failures worth recognising. Nil when the
    /// underlying message already says everything useful — a generic "try again"
    /// is worse than no hint at all.
    var recoveryHint: String? {
        guard let error = runError?.lowercased() else { return nil }

        if error.contains("-69850") || error.contains("chosen size is not valid") {
            return "That drive still carries a bootable partition layout from a previous use, "
                 + "which macOS won't erase in place. BootIt now rewrites the whole partition "
                 + "scheme automatically, so try again. If it fails a second time, erase the "
                 + "drive once in Disk Utility using GUID Partition Map, then retry."
        }
        if error.contains("rate") || error.contains("anti-bot") || error.contains("rejected") {
            return "Microsoft rate-limits download links per IP address. Wait 10–15 minutes, "
                 + "turn off any VPN, or switch to “Use an existing ISO file”, which never "
                 + "touches their servers."
        }
        if error.contains("authorisation") || error.contains("authorization") {
            return "Creating a macOS installer needs an administrator password. Try again and "
                 + "approve the prompt when it appears."
        }
        if error.contains("no space") || error.contains("not enough") {
            return "The drive is too small for this installer. Windows needs 8 GB or more, "
                 + "macOS 16 GB or more."
        }
        return nil
    }

    /// Whether the primary button is enabled. It stays *visible* when disabled,
    /// so the next action is always discoverable even before it's available.
    var isPrimaryActionEnabled: Bool {
        switch step {
        case .platform: return platform != nil
        case .source:   return isSourceValid
        case .options:  return optionsReady
        case .usb:      return canStart
        case .progress: return running || runError != nil
        case .done:     return true
        }
    }

    // MARK: - Decisions

    /// What pressing the primary action should do. Pure — `fileExists` is
    /// injected so tests never touch the filesystem.
    func flowDecision(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> FlowDecision {
        switch step {
        case .platform:
            return platform == nil ? .noop : .advance(to: .source)

        case .source:
            guard source == .local else { return .advance(to: .options) }
            let path = platform == .windows ? localISOPath : catalog.macAppPath
            guard !path.isEmpty, fileExists(path) else {
                return .block(message: platform == .windows
                              ? "Choose a valid .iso file first."
                              : "Choose a macOS installer first.")
            }
            // Straight to the drive: a local source has nothing to configure.
            return .advance(to: .usb, refreshingDisks: true)

        case .options:
            return .advance(to: .usb, refreshingDisks: true)

        case .usb:
            return .confirmErase

        case .progress, .done:
            return .noop
        }
    }

    /// Applies a decision. `.confirmErase` becomes state rather than an action
    /// so SwiftUI can present a system confirmation over the top of it.
    func apply(_ decision: FlowDecision) {
        switch decision {
        case .advance(let destination, let refreshing):
            catalog.error = nil
            if destination == .source, platform == .macos { loadInstalledMacApps() }
            step = destination
            if refreshing { refreshDisks() }
        case .block(let message):
            catalog.error = message
        case .confirmErase:
            isConfirmingErase = true
        case .noop:
            break
        }
    }

    /// The primary button's action for the current step. `.done` is the view's
    /// to handle — quitting is an AppKit call this layer deliberately avoids.
    func primaryAction() {
        switch step {
        case .progress:
            if runError == nil { cancel() } else { reset() }
        case .done:     break
        default:        apply(flowDecision())
        }
    }

    func goBack() {
        guard let destination = backDestination else { return }
        catalog.error = nil
        step = destination
    }
}
