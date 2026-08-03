import BootItShared
import Foundation

/// Appends a run's samples to a `.jsonl` trace under `~/Library/Logs/BootIt/`.
///
/// Always on, not behind a debug flag. The percentage this design declines to
/// show can only be re-approved by evidence from a device matrix — slow flash,
/// fast flash, external SSD, through a hub — and evidence that requires a
/// special build is evidence nobody collects. A trace of a 40-minute run is
/// about 100 KB.
///
/// App-side rather than daemon-side deliberately: the daemon runs as root, so
/// anything it wrote would land outside the user's own Logs folder and need
/// privileges to read or delete. The user owns their traces.
final class CopyTraceWriter {

    /// Where traces go. `~/Library/Logs/BootIt/` — the folder Console.app shows
    /// and the one people are told to look in when asked for diagnostics.
    ///
    /// Neither the writer nor the pruner checks that this resolves to a real
    /// directory rather than a symlink, and that is a deliberate stopping point
    /// rather than an oversight. Planting one requires code already running as
    /// this user, and the ceiling on the damage is that BootIt creates and
    /// deletes JSON files somewhere that attacker already owns outright.
    ///
    /// The version of this bug that *would* matter is a root-owned writer
    /// following a symlink a user planted, which is exactly why the trace is
    /// written here by the app and not by the daemon that has the privileges.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BootIt", isDirectory: true)
    }

    private let url: URL
    private var handle: FileHandle?
    /// Latched, so `close()` means closed. `append` opens the file lazily, so
    /// without this a sample arriving after the run ended would reopen a trace
    /// that had already been finished and add a line to it — and a sample
    /// arriving after the run ends is the tail of every run.
    private var isClosed = false
    /// Serial: samples arrive on the XPC delivery queue, and a trace interleaved
    /// by two threads is not a trace.
    private let queue = DispatchQueue(label: "bootit.copy-trace", qos: .utility)

    /// - Parameter stamp: the run's identifier, used in the filename. Passed in
    ///   rather than read from the clock so a test can name its own file.
    init(stamp: String) {
        url = Self.directory.appendingPathComponent("copy-trace-\(stamp).jsonl")
    }

    /// Filename-safe UTC stamp: `2026-08-04T093012Z`.
    static func stamp(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    var fileURL: URL { url }

    /// Best-effort throughout. A trace that cannot be written is worth nothing
    /// and worth breaking nothing: no error from here may reach a run that is
    /// otherwise going fine.
    func append(_ sample: CopySample) {
        queue.async { [self] in
            guard !isClosed else { return }
            guard let line = try? sample.traceLine(), let data = line.data(using: .utf8) else { return }
            if handle == nil { handle = openFile() }
            try? handle?.write(contentsOf: data)
        }
    }

    func close() {
        queue.async { [self] in
            isClosed = true
            try? handle?.close()
            handle = nil
        }
    }

    private func openFile() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        try? handle.seekToEnd()
        return handle
    }

    /// Delete traces older than `days`, so this cannot grow without bound on a
    /// machine that makes a lot of installers.
    ///
    /// Runs on a background queue at launch: a folder scan is cheap, but it is
    /// still I/O, and nothing about it needs to happen before the window appears.
    static func pruneOldTraces(olderThan days: Int = 30,
                               now: Date = Date(),
                               fileManager: FileManager = .default) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in contents ?? [] where file.lastPathComponent.hasPrefix("copy-trace-") {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
        }
    }
}
