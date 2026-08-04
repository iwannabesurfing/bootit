import Foundation

/// One selectable item (an edition or a language) in the catalogue.
struct CatalogItem: Identifiable, Hashable {
    let id: String     // edition id, or SKU id for a language
    let name: String
}

enum CatalogError: LocalizedError {
    case sentinelRejected
    case api(String)
    case noLanguages
    case noLinks
    case network(String)

    var errorDescription: String? {
        switch self {
        case .sentinelRejected:
            return """
            Microsoft declined the request (anti-bot check).

            This usually means your IP has been rate-limited or flagged — \
            common on VPNs and shared/office networks.

            • Wait 10–15 minutes and try again
            • Turn off any VPN, then retry
            • Or download the ISO manually from microsoft.com and choose \
            “Use an existing ISO file”.
            """
        case .api(let m):       return "Microsoft API error: \(m)"
        case .noLanguages:      return "Microsoft returned no languages for this edition."
        case .noLinks:          return "Microsoft returned no download links (the link expires quickly — try again, or use a local ISO)."
        case .network(let m):   return "Network error talking to Microsoft: \(m)"
        }
    }
}

/// Resolves a direct Windows ISO download URL via Microsoft's current
/// software-download-connector API — the same flow Rufus/Fido use.
final class MicrosoftCatalog {

    static let orgID      = "y6jn8c31"
    static let profile    = "606624d44113"
    static let instanceID = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let locale     = "en-US"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    static let pages = [
        "windows11": "https://www.microsoft.com/en-us/software-download/windows11",
        "windows10": "https://www.microsoft.com/en-us/software-download/windows10ISO"
    ]
    static let referers = [
        "windows11": "https://www.microsoft.com/software-download/windows11",
        "windows10": "https://www.microsoft.com/software-download/windows10ISO"
    ]
    static let fallbackEdition = ["windows11": "3321", "windows10": "2618"]

    static let skuAPI  = "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition"
    static let linkAPI = "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku"

    let sessionID = UUID().uuidString
    private let session: URLSession
    private var registered = false
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": MicrosoftCatalog.userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        self.session = URLSession(configuration: cfg)
        self.log = log
    }

    // MARK: - Synchronous GET (worker runs off the main thread)

    private func get(_ urlString: String, referer: String? = nil) throws -> Data {
        guard let url = URL(string: urlString) else { throw CatalogError.network("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var failure: Error?
        session.dataTask(with: req) { d, _, e in
            data = d; failure = e; sem.signal()
        }.resume()
        sem.wait()
        if let failure { throw CatalogError.network(failure.localizedDescription) }
        guard let data else { throw CatalogError.network("no response") }
        return data
    }

    // MARK: - Session / anti-bot registration

    /// Register the session so the download-links call isn't rejected.
    /// Idempotent. Best-effort: failures here don't throw because the SKU
    /// call still works without them.
    func register(osKey: String) {
        if registered { return }
        log("Connecting to Microsoft…")
        _ = try? get("https://vlscppe.microsoft.com/tags?org_id=\(Self.orgID)&session_id=\(sessionID)")
        // Clear the "Sentinel" anti-bot gate via the ov-df fingerprint.
        if let data = try? get("https://ov-df.microsoft.com/mdt.js?instanceId=\(Self.instanceID)&PageId=si&session_id=\(sessionID)"),
           let body = String(data: data, encoding: .utf8),
           let dfp = RegexCache.firstCapture(body, #"url:"([^"]+)""#) {
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            _ = try? get(dfp + "&mdt=\(ms)")
        }
        registered = true
    }

    // MARK: - Catalogue queries

    /// Scrape product-edition id(s) from the live download page; fall back to
    /// the last-known id if the layout changes.
    func editions(osKey: String) -> [CatalogItem] {
        log("Fetching editions…")
        if let page = Self.pages[osKey],
           let data = try? get(page),
           let html = String(data: data, encoding: .utf8) {
            let matches = RegexCache.allGroups(html, #"<option[^>]+value="(\d+)"[^>]*>\s*([^<]+)</option>"#)
            let eds = matches.compactMap { groups -> CatalogItem? in
                let name = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : CatalogItem(id: groups[1], name: name)
            }
            if !eds.isEmpty { return eds }
            log("No editions on page — using fallback id.")
        } else {
            log("Edition page lookup failed; using fallback id.")
        }
        let fallbackID = Self.fallbackEdition[osKey] ?? "3321"
        return [CatalogItem(id: fallbackID, name: "Windows (multi-edition ISO)")]
    }

    /// Languages = one SKU per language for the chosen edition.
    func languages(editionID: String, osKey: String) throws -> [CatalogItem] {
        register(osKey: osKey)
        log("Fetching languages…")
        let url = "\(Self.skuAPI)?profile=\(Self.profile)&productEditionId=\(editionID)"
            + "&SKU=undefined&friendlyFileName=undefined&Locale=\(Self.locale)&sessionID=\(sessionID)"
        let data = try get(url, referer: Self.referers[osKey])
        let decoded = try JSONDecoder().decode(SkuResponse.self, from: data)
        try Self.checkErrors(decoded.Errors)
        let skus = decoded.Skus ?? []
        return skus.map { CatalogItem(id: $0.Id, name: $0.LocalizedLanguage ?? $0.Language ?? "Unknown") }
    }

    /// Download options for a SKU. DownloadType: 0 = x86, 1 = x64, 2 = ARM64.
    private func links(skuID: String, osKey: String) throws -> [LinkResponse.Option] {
        register(osKey: osKey)
        log("Getting download link…")
        let url = "\(Self.linkAPI)?profile=\(Self.profile)&productEditionId=undefined"
            + "&SKU=\(skuID)&friendlyFileName=undefined&Locale=\(Self.locale)&sessionID=\(sessionID)"
        let data = try get(url, referer: Self.referers[osKey])
        let decoded = try JSONDecoder().decode(LinkResponse.self, from: data)
        try Self.checkErrors(decoded.Errors)
        return (decoded.ProductDownloadOptions ?? []).filter { !($0.Uri ?? "").isEmpty }
    }

    /// Resolve a direct ISO URL for a known SKU id, preferring 64-bit.
    func resolveSku(osKey: String, skuID: String) throws -> URL {
        // `links` already drops options with an empty URI; pick the best,
        // preferring native 64-bit, then any x64-tagged build, then the first.
        let options = try links(skuID: skuID, osKey: osKey)
        let best = options.first { $0.DownloadType == 1 }
            ?? options.first { ($0.Uri ?? "").lowercased().contains("x64") }
            ?? options.first
        guard let uri = best?.Uri, let url = URL(string: uri) else { throw CatalogError.noLinks }
        return url
    }

    // MARK: - Helpers

    private static func checkErrors(_ errors: [APIError]?) throws {
        guard let first = errors?.first else { return }
        if first.type == 9 { throw CatalogError.sentinelRejected }
        throw CatalogError.api(first.Value ?? first.Key ?? "unknown")
    }
}

// MARK: - JSON shapes

// These structs decode Microsoft's connector-API responses, so their members
// intentionally keep the wire format's PascalCase names verbatim.
// swiftlint:disable identifier_name
private struct SkuResponse: Decodable {
    struct Sku: Decodable {
        let Id: String
        let Language: String?
        let LocalizedLanguage: String?
    }
    let Skus: [Sku]?
    let Errors: [APIError]?
}

private struct LinkResponse: Decodable {
    struct Option: Decodable {
        let Name: String?
        let Uri: String?
        let DownloadType: Int?
    }
    let ProductDownloadOptions: [Option]?
    let Errors: [APIError]?
}

private struct APIError: Decodable {
    let Key: String?
    let Value: String?
    let type: Int?
    enum CodingKeys: String, CodingKey {
        case Key, Value
        case type = "Type"
    }
}
// swiftlint:enable identifier_name
