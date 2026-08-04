#if DEBUG
import BootItShared
import Foundation

/// Deterministic models for SwiftUI previews.
///
/// Everything here is fabricated in memory. Nothing enumerates a disk, contacts
/// Microsoft or Apple, or writes anything — a preview must never be able to
/// reach real hardware. Excluded from release builds.
/// Hands back a different number each time it is asked, so a preview can stage
/// something that is only visible as a *change* between two readings.
private final class Counter {
    private var value: UInt64 = 0
    func next() -> UInt64 {
        value += 1
        return value
    }
}

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
        model.catalog.isLoading = loading
        model.catalog.error = error
        if !loading && error == nil {
            model.catalog.editions = [CatalogItem(id: "3321", name: "Windows 11 Home/Pro")]
            model.catalog.languages = [
                CatalogItem(id: "1", name: "English (United States)"),
                CatalogItem(id: "2", name: "English (United Kingdom)")
            ]
        }
        return model
    }

    static func macOptions() -> AppModel {
        let model = AppModel()
        model.platform = .macos
        model.step = .options
        model.catalog.macInstallers = sampleMacInstallers
        model.catalog.selectedMacGroupTitle = "macOS Tahoe"
        model.catalog.selectedMacBuild = "25C61"
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

    /// The drive step as it looks when a pre-flight check has something to say.
    ///
    /// Both warnings are macOS-only — the Windows path never goes near the
    /// privileged helper — so this fixes the platform rather than taking it.
    static func preflightWarning(replaced: Bool = false,
                                 access: AccessDiagnostics.Report? = nil) -> AppModel {
        // The reading has to *change* between the one taken at init and the one
        // taken by the check — a constant closure returns the same identity both
        // times and nothing would ever look replaced.
        let readings = Counter()
        let model = AppModel(
            preflight: InstallPreflight(
                bundleIdentity: {
                    AppBundleWatch.Identity(inode: replaced ? readings.next() : 0, device: 0)
                },
                usbAccessProbe: { access }))
        model.platform = .macos
        model.step = .usb
        model.disks = sampleDrives
        model.diskIndex = 0
        if replaced {
            // A second reading that disagrees with the one taken at init.
            model.checkWhetherAppWasReplaced()
        }
        if let access {
            // Through the real decision rather than by setting the field: a
            // preview that bypasses `acceptProbe` would happily render a state
            // the app cannot actually reach — an inconclusive report shown as a
            // warning, for one, which is the exact bug this feature guards.
            // `checkUSBAccess` is asynchronous and would not have landed by the
            // time the preview renders.
            let id = model.preflight.beginProbe()
            model.preflight.acceptProbe(access, id: id)
        }
        return model
    }

    static let blockedByFullDiskAccess = AccessDiagnostics.Report(
        volume: "/Volumes/Install macOS Tahoe",
        appCanWrite: true,
        helperDenial: "Operation not permitted",
        helperNeedsFullDiskAccess: true)

    static let blockedByAReadOnlyVolume = AccessDiagnostics.Report(
        volume: "/Volumes/Install macOS Tahoe",
        appCanWrite: true,
        helperDenial: "Read-only file system",
        helperNeedsFullDiskAccess: false)

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

    /// The opaque macOS copy — the 33 minutes that had nothing honest to show.
    ///
    /// The wording comes from the model's own `status`/`detail`, not from
    /// strings typed here, so a preview cannot show copy the app would never
    /// produce. Byte and elapsed figures are the 2026-08-03 run at its midpoint.
    static func copying(_ activity: CopyActivity) -> AppModel {
        let model = writing(progress: InstallMediaProgress.eraseCeiling, phase: .creatingInstaller)
        model.platform = .macos
        let state = CopyProgressState(
            activity: activity,
            bytesWritten: 12_400_000_000,
            elapsed: 1_390,
            fraction: nil,
            status: CopyProgressModel.status(for: activity),
            detail: CopyProgressModel.detail(for: activity, bytesWritten: 12_400_000_000))
        model.copyState = state
        model.statusText = state.status
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
            model.catalog.macInstallers = sampleMacInstallers
            model.catalog.selectedMacGroupTitle = "macOS Tahoe"
            model.catalog.selectedMacBuild = "25C61"
        } else {
            model.catalog.editions = [CatalogItem(id: "3321", name: "Windows 11 Home/Pro")]
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
