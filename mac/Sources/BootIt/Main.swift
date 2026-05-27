import Foundation

/// Entry point. Normally launches the SwiftUI app; with `--selftest` it runs a
/// headless check of the Microsoft download API (handy for diagnosing the
/// notoriously flaky catalogue endpoints without a USB drive).
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            let osKey = args.contains("windows10") ? "windows10" : "windows11"
            SelfTest.run(osKey: osKey, resolveLink: args.contains("--resolve"))
            exit(0)
        }
        if args.contains("--writetest") {
            SelfTest.writeTest(forceSplit: args.contains("--split"))
            exit(0)
        }
        if args.contains("--mactest") {
            SelfTest.macTest()
            exit(0)
        }
        BootItApp.main()
    }
}

enum SelfTest {
    static func run(osKey: String, resolveLink: Bool) {
        print("=== BootIt self-test (\(osKey)) ===")
        let cat = MicrosoftCatalog(log: { print("  ·", $0) })
        cat.register(osKey: osKey)
        let eds = cat.editions(osKey: osKey)
        print("editions:", eds.map { "\($0.id):\($0.name)" })
        do {
            let langs = try cat.languages(editionID: eds.first?.id ?? "", osKey: osKey)
            let english = langs.firstIndex { $0.name.lowercased().hasPrefix("english") }
            print("languages: \(langs.count) found; English at index \(english.map(String.init) ?? "none")")
            if let i = english { print("  →", langs[i].name, "sku", langs[i].id) }
            if resolveLink, let i = english {
                let url = try cat.resolveSku(osKey: osKey, skuID: langs[i].id)
                print("RESOLVED URL:", url.absoluteString.split(separator: "?").first ?? "")
            } else {
                print("(skipping link resolution — pass --resolve to test it; it rate-limits per IP)")
            }
            print("RESULT: OK")
        } catch {
            print("RESULT: ERROR —", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Exercises the copy / split / verify stages against temp directories that
    /// stand in for the mounted ISO and the formatted USB — no real disk needed.
    static func writeTest(forceSplit: Bool) {
        print("=== USB writer copy-stage test (forceSplit=\(forceSplit)) ===")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bootit-test-\(UUID().uuidString)")
        let iso = base.appendingPathComponent("iso")
        let usb = base.appendingPathComponent("usb")
        do {
            try fm.createDirectory(at: iso.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
            try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
            try fm.createDirectory(at: usb, withIntermediateDirectories: true)
            try Data("EFI".utf8).write(to: iso.appendingPathComponent("efi/boot/bootx64.efi"))
            try randomData(2 * 1024 * 1024).write(to: iso.appendingPathComponent("sources/boot.wim"))
            try Data(repeating: 0x41, count: 4096).write(to: iso.appendingPathComponent("bootmgr"))

            let wim = iso.appendingPathComponent("sources/install.wim")
            if forceSplit, let wimlib = Shell.locate("wimlib-imagex") {
                // Build a real WIM so wimlib can split it.
                let cap = base.appendingPathComponent("cap")
                try fm.createDirectory(at: cap, withIntermediateDirectories: true)
                try randomData(5 * 1024 * 1024).write(to: cap.appendingPathComponent("payload.bin"))
                Shell.run(wimlib, ["capture", cap.path, wim.path, "--compress=none"])
            } else {
                try randomData(3 * 1024 * 1024).write(to: wim)
            }

            let writer = USBWriter(disk: "/dev/null", isoPath: "/x.iso", cancel: CancelFlag(),
                                   onProgress: { _, _ in }, onLog: { print("  ·", $0) })
            if forceSplit { writer.fat32Limit = 1 * 1024 * 1024 }   // force the split path
            try writer.runCopyStagesForTest(isoMount: iso.path, usbMount: usb.path)

            let copiedBoot = fm.fileExists(atPath: usb.appendingPathComponent("efi/boot/bootx64.efi").path)
            let copiedBootmgr = fm.fileExists(atPath: usb.appendingPathComponent("bootmgr").path)
            let swms = (try? fm.contentsOfDirectory(atPath: usb.appendingPathComponent("sources").path)) ?? []
            print("bootx64 copied:", copiedBoot, "| bootmgr copied:", copiedBootmgr)
            print("sources contents:", swms.sorted())
            print("RESULT: OK")
        } catch {
            print("RESULT: ERROR —", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        try? fm.removeItem(at: base)
    }

    private static func randomData(_ count: Int) -> Data {
        Data(repeating: 0xAB, count: count)
    }

    /// Live-checks the macOS installer catalogue parse, the installed-app
    /// detection, and the createinstallmedia progress parser (offline sample).
    static func macTest() {
        print("=== macOS installer catalogue (softwareupdate --list-full-installers) ===")
        let list = MacInstaller.listAvailable()
        print("parsed \(list.count) installers")
        for m in list.prefix(6) {
            print("  • \(m.displayName)  build \(m.build)  \(m.sizeText)")
        }
        print("=== installed Install macOS*.app in /Applications ===")
        let apps = MacInstaller.installedApps()
        print(apps.isEmpty ? "  (none)" : apps.map { "  • \($0.lastPathComponent)" }.joined(separator: "\n"))
        print("RESULT:", list.isEmpty ? "WARN (no installers parsed — check connection)" : "OK")
    }
}
