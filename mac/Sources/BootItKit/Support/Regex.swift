import Foundation

/// Cached `NSRegularExpression` helpers. The services parse tool output
/// line-by-line during long operations, so compiling a fresh expression per
/// call is wasteful; patterns are literal constants, so compilation only ever
/// has to happen once. Thread-safe (parsers run on the background worker).
enum RegexCache {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = re
        return re
    }

    /// The given capture group of the first match, or nil.
    static func firstCapture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let re = compiled(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              group < m.numberOfRanges, m.range(at: group).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// The given capture group of the last match, or nil.
    static func lastCapture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let re = compiled(pattern) else { return nil }
        let ns = text as NSString
        let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = all.last, group < m.numberOfRanges,
              m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// Every match as an array of capture groups (index 0 = whole match).
    static func allGroups(_ text: String, _ pattern: String) -> [[String]] {
        guard let re = compiled(pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
