import XCTest
@testable import BootItKit

/// Exercises the USB writer's copy / split / verify stages against temp
/// directories standing in for the mounted ISO and formatted USB — no real
/// disk required. These cover the most consequential logic in the app.
final class USBWriterTests: XCTestCase {

    private var base: URL!
    private var iso: URL!
    private var usb: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("bootit-xctest-\(UUID().uuidString)")
        iso = base.appendingPathComponent("iso")
        usb = base.appendingPathComponent("usb")
        try fm.createDirectory(at: iso.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: usb, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeWriter() -> USBWriter {
        USBWriter(disk: "/dev/null", isoPath: "/unused.iso", cancel: CancelFlag(),
                  onProgress: { _, _ in }, onLog: { _ in })
    }

    private func writeBootFile() throws {
        try fm.createDirectory(at: iso.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data("EFI".utf8).write(to: iso.appendingPathComponent("efi/boot/bootx64.efi"))
    }

    func testCopyStageCopiesFilesAndVerifies() throws {
        try writeBootFile()
        try Data(repeating: 0x41, count: 256).write(to: iso.appendingPathComponent("bootmgr"))
        try Data(repeating: 0xAB, count: 4096).write(to: iso.appendingPathComponent("sources/install.wim"))

        try makeWriter().runCopyStagesForTest(isoMount: iso.path, usbMount: usb.path)

        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("efi/boot/bootx64.efi").path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("bootmgr").path))
        XCTAssertTrue(fm.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
    }

    func testVerifyFailsWhenBootFileMissing() throws {
        // No efi/boot/bootx64.efi on the source → verify must reject it.
        try Data(repeating: 0x41, count: 256).write(to: iso.appendingPathComponent("bootmgr"))
        XCTAssertThrowsError(try makeWriter().runCopyStagesForTest(isoMount: iso.path, usbMount: usb.path)) { error in
            XCTAssertTrue(error is WriterError)
        }
    }

    func testSplitPathProducesSWMParts() throws {
        guard Shell.locate("wimlib-imagex") != nil else {
            throw XCTSkip("wimlib-imagex not installed; the split path is also covered by `BootIt --writetest --split`")
        }
        try writeBootFile()

        // Build a real (uncompressed) WIM so wimlib can split it.
        let cap = base.appendingPathComponent("cap")
        try fm.createDirectory(at: cap, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 5 * 1024 * 1024).write(to: cap.appendingPathComponent("payload.bin"))
        let wim = iso.appendingPathComponent("sources/install.wim")
        Shell.run(Shell.locate("wimlib-imagex")!, ["capture", cap.path, wim.path, "--compress=none"])

        let writer = makeWriter()
        writer.fat32Limit = 1 * 1024 * 1024   // force the split path
        try writer.runCopyStagesForTest(isoMount: iso.path, usbMount: usb.path)

        let sources = (try? fm.contentsOfDirectory(atPath: usb.appendingPathComponent("sources").path)) ?? []
        XCTAssertTrue(sources.contains { $0.hasSuffix(".swm") }, "expected split .swm parts, got \(sources)")
        XCTAssertFalse(sources.contains("install.wim"), "the oversized .wim should not be copied whole")
    }
}
