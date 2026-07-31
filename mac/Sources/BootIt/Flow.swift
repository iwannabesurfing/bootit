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

extension AppModel {

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
        return platform == .windows ? !localISOPath.isEmpty : !macAppPath.isEmpty
    }

    /// The primary button's title for the current step.
    var primaryActionTitle: String {
        switch step {
        case .platform, .source, .options: return "Continue"
        case .usb:      return "Erase and Create Installer"
        case .progress: return "Cancel"
        case .done:     return "Quit"
        }
    }

    /// Whether the primary button is enabled. It stays *visible* when disabled,
    /// so the next action is always discoverable even before it's available.
    var isPrimaryActionEnabled: Bool {
        switch step {
        case .platform: return platform != nil
        case .source:   return isSourceValid
        case .options:  return optionsReady
        case .usb:      return canStart
        case .progress: return running
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
            let path = platform == .windows ? localISOPath : macAppPath
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
            catalogError = nil
            if destination == .source, platform == .macos { loadInstalledMacApps() }
            step = destination
            if refreshing { refreshDisks() }
        case .block(let message):
            catalogError = message
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
        case .progress: cancel()
        case .done:     break
        default:        apply(flowDecision())
        }
    }

    func goBack() {
        guard let destination = backDestination else { return }
        catalogError = nil
        step = destination
    }
}
