import Foundation

enum DownloadError: LocalizedError {
    case cancelled
    case http(Int)
    case other(String)
    var errorDescription: String? {
        switch self {
        case .cancelled:     return "Download cancelled."
        case .http(let c):   return "Download failed (HTTP \(c))."
        case .other(let m):  return m
        }
    }
}

/// Streams an ISO to disk with progress + cancellation. Synchronous (blocks
/// the calling background thread until the download finishes or fails).
final class ISODownloader: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let dest: URL
    private let isCancelled: () -> Bool
    /// (fraction 0…1, speed text, eta text)
    private let onProgress: (Double, String, String) -> Void
    private let onLog: (String) -> Void

    private var handle: FileHandle?
    private var total: Int64 = 0
    private var received: Int64 = 0
    private var startTime = Date()
    private var lastTick = Date.distantPast
    private let sem = DispatchSemaphore(value: 0)
    private var failure: Error?
    private weak var task: URLSessionTask?

    init(url: URL,
         dest: URL,
         isCancelled: @escaping () -> Bool,
         onProgress: @escaping (Double, String, String) -> Void,
         onLog: @escaping (String) -> Void) {
        self.url = url
        self.dest = dest
        self.isCancelled = isCancelled
        self.onProgress = onProgress
        self.onLog = onLog
    }

    func download() throws {
        onLog("Downloading ISO…\n\(url.absoluteString)")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        handle = try FileHandle(forWritingTo: dest)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.httpAdditionalHeaders = ["User-Agent": MicrosoftCatalog.userAgent]
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        startTime = Date()
        let t = session.dataTask(with: URLRequest(url: url))
        task = t
        t.resume()
        sem.wait()
        try? handle?.close()
        session.invalidateAndCancel()

        if let failure {
            try? FileManager.default.removeItem(at: dest)
            throw failure
        }
        onLog("Download complete → \(dest.lastPathComponent)")
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            failure = DownloadError.http(http.statusCode)
            completionHandler(.cancel)
            return
        }
        total = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isCancelled() {
            failure = DownloadError.cancelled
            task?.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = DownloadError.other(error.localizedDescription)
            task?.cancel()
            return
        }
        received += Int64(data.count)
        let now = Date()
        guard now.timeIntervalSince(lastTick) >= 0.2 else { return }
        lastTick = now
        let elapsed = max(now.timeIntervalSince(startTime), 0.001)
        let speed = Double(received) / elapsed
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        let eta = (speed > 0 && total > 0) ? Double(total - received) / speed : 0
        onProgress(fraction,
                   "\(bytesHuman(Int64(speed)))/s",
                   String(format: "%dm%02ds", Int(eta) / 60, Int(eta) % 60))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as NSError).code
            if failure == nil && code != NSURLErrorCancelled {
                failure = DownloadError.other(error.localizedDescription)
            }
        }
        sem.signal()
    }
}
