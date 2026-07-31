#if DEBUG
import Foundation

/// Deterministic models for SwiftUI previews.
///
/// Everything here is fabricated in memory. Nothing enumerates a disk, contacts
/// Microsoft or Apple, or writes anything — a preview must never be able to
/// reach real hardware. Excluded from release builds.
enum PreviewModel {

    static let sampleDrives = [
        USBDisk(id: "/dev/disk4", name: "SanDisk Ultra", sizeText: "31.9 GB"),
        USBDisk(id: "/dev/disk5", name: "Kingston DataTraveler 3.0", sizeText: "64.0 GB"),
        USBDisk(id: "/dev/disk6", name: "WD Elements", sizeText: "2.0 TB")
    ]

    static let sampleMacInstallers = [
        MacOSInstaller(title: "macOS Tahoe", version: "26.2", build: "25C61", sizeKiB: 15_800_000),
        MacOSInstaller(title: "macOS Tahoe", version: "26.1", build: "25B45", sizeKiB: 15_700_000),
        MacOSInstaller(title: "macOS Sequoia", version: "15.7", build: "24H120", sizeKiB: 14_900_000),
        MacOSInstaller(title: "macOS Sonoma", version: "14.8", build: "23J40", sizeKiB: 13_400_000)
    ]

    /// Base model — nothing chosen yet.
    static func fresh() -> AppModel { AppModel() }

    static func platform(_ platform: AppModel.Platform?) -> AppModel {
        let model = AppModel()
        model.platform = platform
        return model
    }

    static func windowsOptions(loading: Bool = false, error: String? = nil) -> AppModel {
        let model = AppModel()
        model.platform = .windows
        model.step = .options
        model.loadingCatalog = loading
        model.catalogError = error
        if !loading && error == nil {
            model.editions = [CatalogItem(id: "3321", name: "Windows 11 Home/Pro")]
            model.languages = [CatalogItem(id: "1", name: "English (United States)"),
                               CatalogItem(id: "2", name: "English (United Kingdom)")]
        }
        return model
    }

    static func macOptions() -> AppModel {
        let model = AppModel()
        model.platform = .macos
        model.step = .options
        model.macInstallers = sampleMacInstallers
        model.selectedMacGroupTitle = "macOS Tahoe"
        model.selectedMacBuild = "25C61"
        return model
    }

    static func drives(_ disks: [USBDisk] = sampleDrives,
                       selected: Int? = nil,
                       acknowledged: Bool = false,
                       platform: AppModel.Platform = .windows,
                       source: AppModel.SourceMode = .download) -> AppModel {
        let model = AppModel()
        model.platform = platform
        model.source = source
        model.step = .usb
        model.disks = disks
        model.diskIndex = selected
        model.hasAcknowledgedErase = acknowledged
        return model
    }

    static func writing(progress: Double,
                        phase: WritePhase,
                        showingLog: Bool = false) -> AppModel {
        let model = drives(selected: 0, acknowledged: true)
        model.step = .progress
        model.running = true
        model.progress = progress
        model.currentPhase = phase
        model.statusText = "Copying installer files — 29.6 GB of 71.3 GB"
        model.showsLogDetails = showingLog
        model.logText = sampleLog
        return model
    }

    static func failed() -> AppModel {
        let model = writing(progress: 0.42, phase: .copying, showingLog: true)
        model.running = false
        model.runError = "Splitting install.wim failed (wimlib exit 2)."
        return model
    }

    static func completed(platform: AppModel.Platform = .windows) -> AppModel {
        let model = drives(selected: 0, acknowledged: true, platform: platform)
        model.step = .done
        model.progress = 1
        if platform == .macos {
            model.macInstallers = sampleMacInstallers
            model.selectedMacGroupTitle = "macOS Tahoe"
            model.selectedMacBuild = "25C61"
        } else {
            model.editions = [CatalogItem(id: "3321", name: "Windows 11 Home/Pro")]
        }
        return model
    }

    private static let sampleLog = """
    10:42:31  Starting write process to /dev/disk4
    10:42:31  Mounting installer image…
    10:42:32  Copying files from /Volumes/CCCOMA_X64FRE_EN-US_DV9
    10:45:18  Copied 2145 of 5112 files
    10:45:18  29.6 GB of 71.3 GB (42%)
    """
}
#endif
