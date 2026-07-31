import Foundation

enum WriterError: LocalizedError {
    case cancelled
    case isoNotFound(String)
    case mountFailed(String)
    case eraseFailed(String)
    case usbPartitionMissing
    case usbDidNotMount
    case wimToolMissing
    case wimSplitFailed(Int32)
    case copyFailed(String)
    case notBootable

    var errorDescription: String? {
        switch self {
        case .cancelled:            return "Cancelled."
        case .isoNotFound(let p):   return "ISO file not found:\n\(p)"
        case .mountFailed(let m):   return "Could not mount the ISO:\n\(m)"
        case .eraseFailed(let m):
            return "Failed to format the USB drive:\n\(m)\n\nMake sure it isn't write-protected and no Finder window is showing it."
        case .usbPartitionMissing:  return "Could not locate the formatted USB partition."
        case .usbDidNotMount:       return "The formatted USB partition did not mount."
        case .wimToolMissing:
            return "install.wim is larger than 4 GiB, which FAT32 can't store.\n\n"
                + "Install the splitter, then try again:\n    brew install wimlib"
        case .wimSplitFailed(let c): return "Splitting install.wim failed (wimlib exit \(c))."
        case .copyFailed(let m):    return "Copying files failed: \(m)"
        case .notBootable:
            return "Copy finished but the UEFI boot file (efi/boot/bootx64.efi) is missing — the drive would not boot. Please try again."
        }
    }
}

/// Writes a bootable Windows installer to a USB drive: format FAT32/MBR, copy
/// the ISO contents, and split install.wim if it exceeds FAT32's 4 GiB limit.
final class USBWriter {

    static let defaultFat32Limit: Int64 = 4 * 1024 * 1024 * 1024 - 1
    /// Instance-level so tests can force the split path with a small file.
    var fat32Limit: Int64 = USBWriter.defaultFat32Limit
    static let volName = "WININSTALL"
    static let diskutil = "/usr/sbin/diskutil"
    static let hdiutil  = "/usr/bin/hdiutil"

    private let disk: String         // /dev/diskN
    private let iso: URL
    private let cancel: CancelFlag
    private let bypassWin11: Bool     // write autounattend.xml with the bypasses
    /// progress reported as fraction 0…1 of the *write* phase + status text
    private let onProgress: (Double, String) -> Void
    private let onLog: (String) -> Void
    /// Coarse stage changes, for the progress checklist. Purely observational —
    /// nothing here influences what gets written.
    private let onPhase: (WritePhase) -> Void

    private var isoMount: String?
    private var usbMount: String?
    private var copiedBytes: Int64 = 0
    private var lastPct = -1

    init(disk: String, isoPath: String, cancel: CancelFlag,
         bypassWin11: Bool = false,
         onProgress: @escaping (Double, String) -> Void,
         onLog: @escaping (String) -> Void,
         onPhase: @escaping (WritePhase) -> Void = { _ in }) {
        self.disk = disk
        self.iso = URL(fileURLWithPath: isoPath)
        self.cancel = cancel
        self.bypassWin11 = bypassWin11
        self.onProgress = onProgress
        self.onLog = onLog
        self.onPhase = onPhase
    }

    /// Test hook: run only the copy / split / verify stages against
    /// already-mounted paths (skips real disk erase/mount). Used by --writetest.
    func runCopyStagesForTest(isoMount: String, usbMount: String) throws {
        self.isoMount = isoMount
        self.usbMount = usbMount
        try copyBase()
        try handleWIM()
        try verify()
    }

    func write() throws {
        defer { detachISO() }
        onPhase(.preparing)
        try check(); try mountISO()
        try check(); try erase()
        try check(); suppressSpotlight()
        onPhase(.copying)
        try check(); try copyBase()
        try check(); try handleWIM()
        onPhase(.finalising)
        try check(); if bypassWin11 { writeAutounattend() }
        try check(); cleanMacMetadata()
        try check(); try verify()
        onProgress(1.0, "Done")
        onLog("✅  USB drive is ready.")
    }

    /// Write an autounattend.xml to the USB root that (1) bypasses the Win11
    /// TPM / Secure Boot / RAM / Storage / CPU checks (LabConfig keys in the
    /// windowsPE pass) and (2) sets BypassNRO so the "I don't have internet"
    /// option appears during OOBE. Setup stays interactive otherwise.
    private func writeAutounattend() {
        guard let usb = usbMount else { return }
        onLog("Adding autounattend.xml (bypass TPM/Secure Boot/RAM + offline-account option)…")
        try? Self.autounattendXML.write(toFile: "\(usb)/autounattend.xml",
                                        atomically: true, encoding: .utf8)
    }

    // Verbatim Windows answer-file XML; the long <RunSynchronousCommand> lines are intentional.
    // swiftlint:disable line_length
    static let autounattendXML = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """#
    // swiftlint:enable line_length

    /// Stop macOS from indexing and littering the FAT32 USB during the copy
    /// (otherwise it scatters .Spotlight-V100 / .fseventsd and ._* files).
    private func suppressSpotlight() {
        guard let usb = usbMount else { return }
        Shell.run("/usr/bin/mdutil", ["-i", "off", usb])
        FileManager.default.createFile(atPath: "\(usb)/.metadata_never_index", contents: nil)
    }

    /// Strip the AppleDouble ._* files and macOS metadata folders so the drive
    /// is clean (Rufus-style). Harmless to Windows, but unprofessional to leave.
    private func cleanMacMetadata() {
        guard let usb = usbMount else { return }
        onLog("Cleaning up macOS metadata…")
        onProgress(0.99, "Cleaning up…")
        Shell.run("/usr/sbin/dot_clean", ["-m", usb])   // delete every ._* file
        for junk in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DS_Store"] {
            try? FileManager.default.removeItem(atPath: "\(usb)/\(junk)")
        }
    }

    // MARK: ISO mount

    private func mountISO() throws {
        guard FileManager.default.fileExists(atPath: iso.path) else {
            throw WriterError.isoNotFound(iso.path)
        }
        onLog("Mounting \(iso.lastPathComponent)…")
        onProgress(0.03, "Mounting ISO…")
        let r = Shell.run(Self.hdiutil, ["attach", "-nobrowse", "-readonly", "-noverify", iso.path])
        guard r.ok else { throw WriterError.mountFailed(r.err.isEmpty ? r.out : r.err) }
        for line in r.out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            if let last = parts.last?.trimmingCharacters(in: .whitespaces),
               last.hasPrefix("/Volumes/") {
                isoMount = last
            }
        }
        guard let mount = isoMount,
              FileManager.default.fileExists(atPath: mount) else {
            throw WriterError.mountFailed("could not determine ISO mount point")
        }
        if !dirExists("\(mount)/sources") {
            onLog("⚠️  No 'sources' folder on the ISO — is this a Windows ISO?")
        }
        onLog("Mounted at \(mount)")
        onProgress(0.06, "ISO mounted")
    }

    // MARK: Format USB

    private func erase() throws {
        onLog("Erasing \(disk) → FAT32 / MBR…")
        onProgress(0.08, "Erasing USB…")
        Shell.run(Self.diskutil, ["unmountDisk", "force", disk])
        // MBR — NOT GPT. A GPT format makes macOS add a small empty EFI System
        // Partition alongside the data partition. Windows Setup detects that ESP
        // and writes the boot loader (bootmgfw + BCD) onto the USB instead of the
        // target SSD — so pulling the USB after install leaves the SSD unbootable
        // ("No OS found"). MBR yields a single FAT32 partition with no ESP for
        // Setup to hijack, and is still UEFI-bootable for removable install media
        // via the \EFI\BOOT\BOOTX64.EFI fallback path.
        let erase = Shell.run(Self.diskutil, ["eraseDisk", "MS-DOS", Self.volName, "MBR", disk])
        if !erase.ok {
            // Same failure mode as the macOS path: `eraseDisk` reuses the existing
            // partition scheme and fails with -69850 on a drive that already holds
            // a bootable layout. `partitionDisk` replaces the scheme, keeping MBR
            // for the reason above.
            onLog("Erase failed; rewriting the partition scheme and retrying…")
            Shell.run(Self.diskutil, ["unmountDisk", "force", disk])
            let repartition = Shell.run(
                Self.diskutil, ["partitionDisk", disk, "MBR", "MS-DOS", Self.volName, "100%"])
            guard repartition.ok else {
                let detail = [erase.err.isEmpty ? erase.out : erase.err,
                              repartition.err.isEmpty ? repartition.out : repartition.err]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                throw WriterError.eraseFailed(detail)
            }
        }
        let mount = try findUSBMount()
        usbMount = mount
        onLog("Formatted. USB mounted at \(mount)")
        onProgress(0.12, "USB formatted")
    }

    /// Locate the FAT32 partition we just created on `disk` and return its
    /// mount point — never assume /Volumes/WININSTALL (a stale volume of the
    /// same name would shadow it).
    private func findUSBMount() throws -> String {
        let listed = Shell.run(Self.diskutil, ["list", "-plist", disk])
        var ident: String?
        if let data = listed.out.data(using: .utf8),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let allDisks = root["AllDisksAndPartitions"] as? [[String: Any]] {
            var partitions: [[String: Any]] = []
            for d in allDisks { partitions += (d["Partitions"] as? [[String: Any]]) ?? [] }
            if let named = partitions.first(where: { ($0["VolumeName"] as? String) == Self.volName }) {
                ident = named["DeviceIdentifier"] as? String
            } else if let largest = partitions.max(by: {
                (($0["Size"] as? NSNumber)?.int64Value ?? 0) < (($1["Size"] as? NSNumber)?.int64Value ?? 0)
            }) {
                ident = largest["DeviceIdentifier"] as? String
            }
        }
        guard let ident else { throw WriterError.usbPartitionMissing }
        Shell.run(Self.diskutil, ["mount", ident])
        for _ in 0..<5 {
            let info = Shell.run(Self.diskutil, ["info", "-plist", ident])
            if let data = info.out.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let mp = plist["MountPoint"] as? String, !mp.isEmpty,
               FileManager.default.fileExists(atPath: mp) {
                return mp
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw WriterError.usbDidNotMount
    }

    // MARK: Copy everything except install.wim

    private func copyBase() throws {
        guard let src = isoMount, let usb = usbMount else { throw WriterError.copyFailed("no mounts") }
        onLog("Copying installer files to \(usb)…")
        onProgress(0.14, "Scanning ISO…")
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: src)
        // Resolve symlinks on both sides so relative paths compute correctly
        // regardless of /var vs /private/var style differences.
        let rootComponents = srcURL.resolvingSymlinksInPath().pathComponents

        func relativeComponents(_ url: URL) -> [String]? {
            let comps = url.resolvingSymlinksInPath().pathComponents
            guard comps.count > rootComponents.count,
                  Array(comps.prefix(rootComponents.count)) == rootComponents else { return nil }
            return Array(comps[rootComponents.count...])
        }

        // Gather files (excluding install.wim) and total size.
        var files: [(path: String, rel: [String])] = []
        var total: Int64 = 0
        if let en = fm.enumerator(at: srcURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in en {
                let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard vals?.isRegularFile == true, let rel = relativeComponents(url) else { continue }
                if rel == ["sources", "install.wim"] { continue }
                files.append((url.path, rel))
                total += Int64(vals?.fileSize ?? 0)
            }
        }
        let totalBytes = max(total, 1)
        copiedBytes = 0
        lastPct = -1
        for file in files {
            try check()
            let dst = ([usb] + file.rel).joined(separator: "/")
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try copyTracked(from: file.path, to: dst, total: totalBytes,
                            into: ProgressSegment(base: 0.14, span: 0.56, label: "Copying files"))
        }
        onLog("Installer files copied (\(files.count) files).")
        onProgress(0.70, "Files copied")
    }

    /// A sub-range of the overall progress bar that a copy maps its 0–100% onto.
    private struct ProgressSegment {
        let base: Double
        let span: Double
        let label: String
    }

    /// Copy one file in chunks, advancing the cumulative byte counter so
    /// progress stays smooth even through large files.
    private func copyTracked(from src: String, to dst: String,
                             total: Int64, into segment: ProgressSegment) throws {
        guard let input = FileHandle(forReadingAtPath: src) else {
            throw WriterError.copyFailed(src)
        }
        FileManager.default.createFile(atPath: dst, contents: nil)
        guard let output = FileHandle(forWritingAtPath: dst) else {
            try? input.close(); throw WriterError.copyFailed(dst)
        }
        defer { try? input.close(); try? output.close() }
        while true {
            try check()
            let chunk = input.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            let pct = Int(Double(copiedBytes) / Double(total) * 100)
            if pct != lastPct {
                lastPct = pct
                onProgress(segment.base + segment.span * Double(pct) / 100, "\(segment.label)… \(pct)%")
            }
        }
    }

    // MARK: install.wim (copy if ≤4 GiB, else split)

    private func handleWIM() throws {
        guard let src = isoMount, let usb = usbMount else { return }
        let wim = "\(src)/sources/install.wim"
        let fm = FileManager.default
        guard fm.fileExists(atPath: wim) else {
            onLog("No install.wim (install.esd?) — nothing to split.")
            return
        }
        let dstDir = "\(usb)/sources"
        try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
        let attrs = try? fm.attributesOfItem(atPath: wim)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onLog("install.wim is \(bytesHuman(size)).")
        if size <= fat32Limit {
            onLog("Copying install.wim…")
            lastPct = -1
            copiedBytes = 0
            try copyTracked(from: wim, to: "\(dstDir)/install.wim", total: max(size, 1),
                            into: ProgressSegment(base: 0.70, span: 0.28, label: "Copying install.wim"))
        } else {
            onLog("install.wim exceeds FAT32's 4 GiB limit — splitting with wimlib…")
            onProgress(0.72, "Splitting install.wim…")
            try splitWIM(src: wim, dst: "\(dstDir)/install.swm")
        }
        onProgress(0.98, "Finalising…")
    }

    private func splitWIM(src: String, dst: String) throws {
        // Prefer the wimlib bundled inside the app; fall back to a Homebrew one.
        guard let wimlib = Shell.bundledTool("wimlib-imagex") ?? Shell.locate("wimlib-imagex") else {
            throw WriterError.wimToolMissing
        }
        onLog("Using wimlib: \(wimlib)")
        let code = Shell.runStreaming(wimlib, ["split", src, dst, "3800"],
                                      isCancelled: { self.cancel.isCancelled },
                                      onLine: { line in
            if let pct = Self.percent(in: line) {
                self.onProgress(0.72 + Double(pct) * 0.0026, "Splitting install.wim… \(pct)%")
            }
        })
        if cancel.isCancelled { throw WriterError.cancelled }
        if code != 0 { throw WriterError.wimSplitFailed(code) }
        onLog("install.wim split into .swm parts.")
    }

    // MARK: Verify

    private func verify() throws {
        guard let usb = usbMount else { throw WriterError.notBootable }
        // FAT32 is case-insensitive, so this resolves regardless of case.
        guard FileManager.default.fileExists(atPath: "\(usb)/efi/boot/bootx64.efi") else {
            throw WriterError.notBootable
        }
        Shell.run("/bin/sync", [])
        onLog("Verified: UEFI boot files present.")
    }

    // MARK: Helpers

    private func detachISO() {
        if let m = isoMount {
            Shell.run(Self.hdiutil, ["detach", m, "-force"])
            isoMount = nil
        }
    }

    private func check() throws {
        if cancel.isCancelled { throw WriterError.cancelled }
    }

    private func dirExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func percent(in line: String) -> Int? {
        RegexCache.firstCapture(line, #"(\d+)\s*%"#).flatMap { Int($0) }
    }
}
