import Foundation

struct AppReleaseVersion: Comparable, Codable, Equatable {
    let major: Int, minor: Int, patch: Int, build: Int
    init?(tag: String) {
        let pattern = #"^v?(\d+)\.(\d+)\.(\d+)(?:b(\d+))?$"#
        guard let match = tag.range(of: pattern, options: .regularExpression), match == tag.startIndex..<tag.endIndex else { return nil }
        let pieces = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: "b", omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard core.count == 3, let build = pieces.count == 2 ? Int(pieces[1]) : 0 else { return nil }
        self.major = core[0]; self.minor = core[1]; self.patch = core[2]; self.build = build
    }
    static func < (a: Self, b: Self) -> Bool {
        [a.major,a.minor,a.patch,a.build].lexicographicallyPrecedes([b.major,b.minor,b.patch,b.build])
    }
    static var current: Self {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Self(tag: base + "b" + build) ?? Self(tag: "0.0.0")!
    }
    var label: String { "\(major).\(minor).\(patch)b\(build)" }
}

struct AvailableRelease: Codable, Equatable {
    let tag: String
    let version: AppReleaseVersion
    let page: URL
}

enum ReleaseUpdateResult {
    case available(AvailableRelease), current, unavailable, rateLimited
}

enum ReleaseUpdatePolicy {
    static let repository = "HachiMiku39/pjdv_mega39s_ios"
    static let endpoint = URL(string: "https://api.github.com/repos/" + repository + "/releases?per_page=100")!
    static let maximumBytes = 2 * 1024 * 1024
    static func releasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.user == nil && url.password == nil && url.port == nil &&
        url.path.hasPrefix("/" + repository + "/releases/tag/")
    }
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let state: String }
        let tag_name: String, html_url: URL, draft: Bool
        let assets: [Asset]
    }
    static func newest(_ data: Data, assetExtension: String) throws -> AvailableRelease? {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        // Our public builds are prereleases. /latest would omit them. Ignore
        // source-only drafts/experiments and compare numeric versions, not dates.
        return releases.compactMap { row -> AvailableRelease? in
            guard !row.draft, let version = AppReleaseVersion(tag: row.tag_name), releasePage(row.html_url),
                  row.assets.contains(where: { $0.state == "uploaded" && $0.name.hasPrefix("PJDVM39-") && $0.name.hasSuffix(assetExtension) }) else { return nil }
            return AvailableRelease(tag: row.tag_name, version: version, page: row.html_url)
        }.max { $0.version < $1.version }
    }
}

// A bounded response reader: no release assets are downloaded or installed.
// It uses public HTTPS without credentials, cookies or user/device telemetry.
private final class ReleaseResponse: NSObject, URLSessionDataDelegate {
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var oversized = false
    private var session: URLSession?
    private let completion: (Data, HTTPURLResponse?, Error?) -> Void
    init(request: URLRequest, configuration: URLSessionConfiguration, completion: @escaping (Data, HTTPURLResponse?, Error?) -> Void) {
        self.completion = completion; super.init()
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session; session.dataTask(with: request).resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        oversized = response.expectedContentLength > ReleaseUpdatePolicy.maximumBytes
        completionHandler(oversized ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count <= ReleaseUpdatePolicy.maximumBytes - data.count else { oversized = true; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion(bytes, response, oversized ? URLError(.dataLengthExceedsMaximum) : error)
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

final class ReleaseUpdateChecker {
    static let shared = ReleaseUpdateChecker()
    static var promptedTags = Set<String>() // main thread, once per app process
    private let queue = DispatchQueue(label: "PJDV.releaseCheck")
    private let defaults: UserDefaults
    private let configuration: URLSessionConfiguration
    private let current: AppReleaseVersion
    private let assetExtension: String
    private let cacheKey: String
    private var result: ReleaseUpdateResult?
    private var waiters = [(ReleaseUpdateResult) -> Void]()
    private var request: ReleaseResponse?
    private struct Cache: Codable { let etag: String?; let newest: AvailableRelease? }
    init(defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral,
         current: AppReleaseVersion = .current, assetExtension: String? = nil) {
        self.defaults = defaults; self.configuration = configuration; self.current = current
        #if targetEnvironment(macCatalyst)
        self.assetExtension = assetExtension ?? ".dmg"
        #else
        self.assetExtension = assetExtension ?? ".ipa"
        #endif
        cacheKey = "pjdv.releaseCheck.v1" + self.assetExtension
    }
    func check(force: Bool = false, completion: @escaping (ReleaseUpdateResult) -> Void) {
        queue.async {
            if !self.waiters.isEmpty { self.waiters.append(completion); return }
            if !force, let result = self.result { DispatchQueue.main.async { completion(result) }; return }
            self.waiters = [completion]
            if self.defaults.double(forKey: self.cacheKey + ".retryAfter") > Date().timeIntervalSince1970 { self.finish(.rateLimited); return }
            let cached = self.defaults.data(forKey: self.cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            var request = URLRequest(url: ReleaseUpdatePolicy.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("PJDVM39-update-check", forHTTPHeaderField: "User-Agent")
            if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let config = self.configuration
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
            self.request = ReleaseResponse(request: request, configuration: config) { data, response, error in
                self.queue.async {
                    self.request = nil
                    guard error == nil, let response else { self.finish(.unavailable); return }
                    if response.statusCode == 403 || response.statusCode == 429 {
                        let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                        let reset = Double(response.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "") ?? 0
                        self.defaults.set(max(Date().timeIntervalSince1970 + max(60,seconds),reset), forKey: self.cacheKey + ".retryAfter")
                        self.finish(.rateLimited); return
                    }
                    let newest: AvailableRelease?
                    if response.statusCode == 304, let cached { newest = cached.newest }
                    else if response.statusCode == 200 {
                        do {
                            newest = try ReleaseUpdatePolicy.newest(data, assetExtension: self.assetExtension)
                            let cache = Cache(etag: response.value(forHTTPHeaderField: "ETag"), newest: newest)
                            self.defaults.set(try JSONEncoder().encode(cache), forKey: self.cacheKey)
                        } catch { self.finish(.unavailable); return }
                    } else { self.finish(.unavailable); return }
                    if let newest, ReleaseUpdatePolicy.releasePage(newest.page), newest.version > self.current { self.finish(.available(newest)) }
                    else { self.finish(.current) }
                }
            }
        }
    }
    private func finish(_ value: ReleaseUpdateResult) {
        result = value; let callbacks = waiters; waiters = []
        DispatchQueue.main.async { callbacks.forEach { $0(value) } }
    }
}
