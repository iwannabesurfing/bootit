import Foundation

/// What can be installed, and what the user has picked from it.
///
/// Pulled out of `AppModel`, which had grown to do navigation, catalogue
/// loading, disk listing, the write pipeline, progress reporting and pre-flight
/// checks in one 400-line class — and had four lines of headroom under the lint
/// ceiling, so any feature that touched it broke the build. This is the largest
/// coherent slice: everything about *what to install*, none of it about how.
///
/// A value type in a single `@Published` property, the same shape as
/// `InstallPreflight`. SwiftUI republishes on any mutation with no nested
/// observable subscription, and every decision below is drivable from a test
/// with no network and no `AppModel`.
///
/// `AppModel` keeps the three loaders, because they own the queue hop. Nothing
/// in here dispatches: a value type that owns a queue is how a reducer ends up
/// being written from two threads at once, which this project has already
/// shipped once.
struct CatalogModel {

    // Shared
    var isLoading = false
    var error: String?

    // Windows
    var editions: [CatalogItem] = []
    var languages: [CatalogItem] = []
    var editionIndex = 0
    var languageIndex = 0

    // macOS
    var macInstallers: [MacOSInstaller] = []
    var selectedMacGroupTitle = ""
    var selectedMacBuild = ""
    var showOlderMacBuilds = false
    var macInstalledApps: [URL] = []
    var macAppPath = ""

    /// Bumped on every load; a completion whose id no longer matches has been
    /// superseded — the user switched Windows version mid-fetch — and must not
    /// write its stale results.
    private var loadID = 0

    // MARK: - Derived

    var macOSGroups: [MacOSGroup] { MacOSGroup.group(macInstallers) }
    var selectedMacGroup: MacOSGroup? { MacOSGroup.selected(macOSGroups, titled: selectedMacGroupTitle) }
    var selectedMacInstaller: MacOSInstaller? { MacOSGroup.selected(selectedMacGroup, build: selectedMacBuild) }

    /// Whether the options step has enough loaded to continue.
    func isReady(for platform: AppModel.Platform?) -> Bool {
        guard !isLoading else { return false }
        return platform == .macos ? !macInstallers.isEmpty : !languages.isEmpty
    }

    // MARK: - Transitions

    mutating func beginLoad(clearingWindowsResults: Bool = false) -> Int {
        isLoading = true
        error = nil
        if clearingWindowsResults {
            // Immediately, so the previous version's edition and language do not
            // linger on screen while the new ones fetch.
            editions = []
            languages = []
        }
        loadID += 1
        return loadID
    }

    /// True when this reply still belongs to the question being asked.
    func isCurrent(_ id: Int) -> Bool { id == loadID }

    mutating func acceptWindows(editions: [CatalogItem], languages: [CatalogItem], id: Int) {
        guard isCurrent(id) else { return }
        self.editions = editions
        self.languages = languages
        editionIndex = 0
        languageIndex = languages.firstIndex { $0.name.lowercased().hasPrefix("english") } ?? 0
        isLoading = false
    }

    mutating func acceptMac(_ list: [MacOSInstaller], id: Int) {
        guard isCurrent(id) else { return }
        macInstallers = list
        selectedMacGroupTitle = list.first?.title ?? ""
        selectedMacBuild = list.first?.build ?? ""
        showOlderMacBuilds = false
        isLoading = false
        if list.isEmpty {
            error = "Couldn't get the macOS installer list from Apple. "
                  + "Check your connection and try again."
        }
    }

    mutating func fail(_ message: String, id: Int) {
        guard isCurrent(id) else { return }
        isLoading = false
        error = message
    }

    mutating func acceptInstalledApps(_ apps: [URL]) {
        macInstalledApps = apps
        if macAppPath.isEmpty, let first = apps.first { macAppPath = first.path }
    }

    mutating func reset() {
        let carriedLoadID = loadID
        self = CatalogModel()
        // Not restarted from zero: a fetch already in flight when the user
        // starts over must still be recognised as superseded when it lands.
        loadID = carriedLoadID + 1
    }
}
