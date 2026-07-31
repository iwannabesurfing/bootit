import Foundation

/// Thin wrapper around `Process` for the command-line tools we drive
/// (diskutil, hdiutil, wimlib-imagex, sync). All calls are synchronous and
/// must run off the main thread.
enum Shell {

    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
    }

    /// Run a tool to completion, capturing stdout/stderr.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(code: -1, out: "", err: "\(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Run a tool while streaming its output line-by-line. Treats both `\r`
    /// and `\n` as line breaks (tools like wimlib update a progress line in
    /// place with `\r`). Returns the exit code.
    @discardableResult
    static func runStreaming(_ launchPath: String,
                             _ args: [String],
                             isCancelled: () -> Bool,
                             onLine: (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            onLine("Failed to launch \(launchPath): \(error.localizedDescription)")
            return -1
        }
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            if isCancelled() {
                p.terminate()
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            // Split on \n or \r.
            while let idx = buffer.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                let lineData = buffer[buffer.startIndex..<idx]
                if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                    onLine(line)
                }
                buffer.removeSubrange(buffer.startIndex...idx)
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            onLine(line)
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Path to a binary bundled inside the app at Contents/Resources/<subdir>/,
    /// if present and executable. Returns nil when running outside an .app
    /// bundle (e.g. the SPM dev binary), so callers fall back to `locate`.
    static func bundledTool(_ name: String, subdir: String = "wimlib") -> String? {
        guard let path = Bundle.main.resourceURL?
                .appendingPathComponent(subdir)
                .appendingPathComponent(name).path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Locate a Homebrew-installed tool (arm64 and Intel prefixes), or fall
    /// back to whatever is on PATH.
    static func locate(_ tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let which = run("/usr/bin/which", [tool])
        let path = which.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (which.ok && !path.isEmpty) ? path : nil
    }
}

/// A tiny thread-safe boolean used as a cancellation flag shared between the
/// UI (writer) and the background worker.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Format a byte count like "5.3 GB".
/// Formats a byte count the way macOS does — base 1000, so "GB" means what
/// Disk Utility, Finder and the drive's own packaging mean by it.
///
/// This used to divide by 1024 while still labelling the result GB, which made
/// a 61.5 GB stick read as "57.3 GB" here and 61.5 GB everywhere else. On the
/// screen where someone is identifying which drive to erase, disagreeing with
/// the rest of the system about its size is the last thing this should do.
func bytesHuman(_ n: Int64) -> String {
    var v = Double(n)
    for unit in ["B", "KB", "MB", "GB"] {
        if v < 1000 { return String(format: "%.1f %@", v, unit) }
        v /= 1000
    }
    return String(format: "%.1f TB", v)
}
