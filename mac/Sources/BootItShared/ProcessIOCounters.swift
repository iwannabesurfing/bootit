import Darwin
import Foundation

/// Bytes a process has written, from `proc_pid_rusage`.
///
/// **Recorded, never displayed.** Two of the three tri-model legs argued this
/// counts writes into the kernel's unified buffer cache rather than bytes
/// reaching the device — in which case it races ahead and then freezes, which is
/// the `df` failure one layer up, and it is the counter most likely to look
/// authoritative while being wrong in exactly the way that has already shipped
/// three times.
///
/// So it goes in the trace beside the device counter and nowhere else. One
/// instrumented run comparing the two columns settles it; until then, using it
/// would be assuming the answer to the question the trace exists to ask.
public enum ProcessIOCounters {

    /// Cumulative bytes written by `pid`, or nil if it has exited or cannot be
    /// inspected.
    public static func bytesWritten(pid: pid_t) -> Int64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return Int64(bitPattern: info.ri_diskio_byteswritten)
    }
}
