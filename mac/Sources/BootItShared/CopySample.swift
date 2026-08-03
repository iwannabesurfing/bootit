import Foundation

/// One observation of a copy in flight.
///
/// Four columns and a timestamp, sampled every couple of seconds by the daemon
/// and sent to the app, which both drives the UI from it and appends it to a
/// trace file. That second use is the point: every real run now produces
/// evidence, so the device matrix the percentage decision needs fills itself
/// instead of requiring a special instrumented build.
///
/// `elapsed` is seconds since the copy phase started, not a wall clock, so a
/// recorded trace replays identically forever.
public struct CopySample: Codable, Equatable {

    /// Seconds since the copy phase began.
    public var elapsed: Double

    /// Cumulative bytes the *block device* has been asked to write, from
    /// `IOBlockStorageDriver`'s `Statistics`. The one counter measured to track
    /// the physical write rather than the buffer cache. Nil when unreadable.
    public var deviceBytes: Int64?

    /// Cumulative bytes written by the `createinstallmedia` process, from
    /// `proc_pid_rusage`. Recorded to settle whether it measures the cache layer
    /// — in which case it races ahead and freezes exactly as `df` does. **Never
    /// drives the UI**: it is here to be observed, not trusted.
    public var processBytes: Int64?

    /// Bytes the filesystem reports in use on the target volume — the signal the
    /// three shipped attempts were driven from. Kept as the control column: a
    /// trace can be replayed through the old implementation to prove it
    /// reproduces the frozen bar, which is what makes a fixture evidence rather
    /// than decoration.
    public var volumeUsedBytes: Int64?

    /// The tool's own output at this moment, if it said anything.
    public var line: String?

    public init(elapsed: Double,
                deviceBytes: Int64? = nil,
                processBytes: Int64? = nil,
                volumeUsedBytes: Int64? = nil,
                line: String? = nil) {
        self.elapsed = elapsed
        self.deviceBytes = deviceBytes
        self.processBytes = processBytes
        self.volumeUsedBytes = volumeUsedBytes
        self.line = line
    }
}

extension CopySample {

    /// One JSON object per line, so a trace can be appended to while a run is in
    /// flight and still parses if the run is killed partway through. A single
    /// JSON array would be truncated and unreadable — which is precisely the run
    /// worth having a trace of.
    public func traceLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    /// Parse a `.jsonl` trace, skipping anything unreadable.
    ///
    /// Lenient on purpose: a trace from an interrupted run ends in a partial
    /// line, and that trace is more interesting than a clean one, not less.
    public static func parseTrace(_ text: String) -> [CopySample] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(CopySample.self, from: data)
        }
    }
}
