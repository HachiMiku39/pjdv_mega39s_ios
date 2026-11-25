import UIKit
import WebKit

/// The catalog has its own web session. Archives only become visible to the MOD
/// library after the response has finished and its file signature is checked.
final class ModDownloadBrowser: UIViewController, WKNavigationDelegate, WKUIDelegate, URLSessionDownloadDelegate {
    var onImport: ((URL) -> Void)?
    var catalogURL = URL(string: "https://gamebanana.com/games/16522")!

    // Some WebKit versions discard unknown app schemes before notifying the
    // navigation delegate. Capture the catalog's one-click anchor before its
    // default action. The isolated world exposes no native bridge to page JS.
    private final class QuickInstallLink: NSObject, WKScriptMessageHandler {
        weak var browser: ModDownloadBrowser?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, origin.protocol == "https", let browser,
                  !browser.closed, !browser.downloading, let text = message.body as? String,
                  let link = URL(string: text), let file = ModDownloadBrowser.gameBananaQuickInstallURL(link, from: origin.host) else { return }
            browser.web.load(URLRequest(url: file))
        }
    }

    private let web: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    // WKDownload is unavailable on the first supported version of Mac Catalyst.
    private var nativeDownload: NSObject?
    private var partial: URL?
    private var temporaryFolder: URL?
    private var suggestedName: String?
    private var poll: Timer?
    private var preparingID: UUID?
    private var saving = false
    private var closed = false
    private var started = Date()
    private var lastUI = Date.distantPast
    private static let maximumDownload: Int64 = 16 * 1024 * 1024 * 1024
    private var downloading: Bool { saving || preparingID != nil || nativeDownload != nil || task != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GameBanana"
        view.backgroundColor = .systemBackground
        let content = web.configuration.userContentController
        let receiver = QuickInstallLink()
        receiver.browser = self
        let world = WKContentWorld.world(name: "pjdv.gamebanana")
        content.add(receiver, contentWorld: world, name: "modLink")
        content.addUserScript(WKUserScript(source: """
            if (location.protocol === "https:" && ["gamebanana.com", "www.gamebanana.com"].includes(location.hostname)) {
                window.addEventListener("click", event => {
                    const anchor = event.composedPath().find(n => n instanceof HTMLAnchorElement);
                    const href = anchor?.getAttribute("href");
                    if (!href || !href.toLowerCase().startsWith("divamodmanager:")) return;
                    event.preventDefault();
                    event.stopImmediatePropagation();
                    window.webkit.messageHandlers.modLink.postMessage(href);
                }, true);
            }
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        web.navigationDelegate = self
        web.uiDelegate = self
        web.accessibilityIdentifier = "mods.browser"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("完成"), style: .done, target: self, action: #selector(close))
        label.numberOfLines = 2
        label.font = .preferredFont(forTextStyle: .footnote)
        label.text = catalogURL.host
        label.accessibilityIdentifier = "mods.downloadStatus"
        let hint = UILabel()
        hint.text = L("目前仅测试过模型和歌曲两类 MOD，不保证所有同类包兼容。")
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .footnote)
        let stack = UIStackView(arrangedSubviews: [hint, label, bar, web])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        ])
        setDownloading(false)
        web.load(URLRequest(url: catalogURL))
    }

    private func setDownloading(_ active: Bool) {
        isModalInPresentation = active
        navigationController?.isModalInPresentation = active
        bar.isHidden = !active
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: active ? L("取消") : L("返回"), style: .plain, target: self, action: #selector(backOrCancel))
        if active {
            started = Date()
            lastUI = .distantPast
            label.text = L("正在准备 MOD 下载…")
            bar.progress = 0
        }
    }

    @objc private func backOrCancel() {
        if downloading {
            stopTransfer()
            label.text = L("已取消下载。")
        } else if web.canGoBack {
            web.goBack()
        }
    }

    @objc private func close() {
        closed = true
        stopTransfer()
        dismiss(animated: true)
    }

    private func stopTransfer() {
        preparingID = nil
        if #available(iOS 14.5, macCatalyst 14.5, *), let native = nativeDownload as? WKDownload {
            native.cancel(nil)
        }
        nativeDownload = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        poll?.invalidate()
        poll = nil
        if let partial { try? FileManager.default.removeItem(at: partial) }
        partial = nil
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
        temporaryFolder = nil
        suggestedName = nil
        setDownloading(false)
    }

    private func fail(_ message: String) {
        stopTransfer()
        if !closed { label.text = message }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, !downloading, !closed {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private static func isDirectFile(_ url: URL) -> Bool {
        guard ["gamebanana.com", "www.gamebanana.com"].contains(url.host?.lowercased()) else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 2 && parts[0] == "dl" && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// GameBanana also advertises the Windows Diva Mod Manager next to its normal
    /// Download button. Only translate the site's own canonical file reference.
    static func gameBananaQuickInstallURL(_ link: URL, from origin: String) -> URL? {
        let hosts = ["gamebanana.com", "www.gamebanana.com"]
        guard hosts.contains(origin.lowercased()), link.scheme?.lowercased() == "divamodmanager",
              let colon = link.absoluteString.firstIndex(of: ":") else { return nil }
        let fields = link.absoluteString[link.absoluteString.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[1].lowercased() == "mod", !fields[2].isEmpty,
              fields[2].allSatisfy({ $0.isASCII && $0.isNumber }),
              let source = URLComponents(string: String(fields[0])), source.scheme?.lowercased() == "https",
              hosts.contains(source.host?.lowercased() ?? ""), source.user == nil, source.password == nil,
              source.port == nil, source.query == nil, source.fragment == nil else { return nil }
        let parts = source.percentEncodedPath.split(separator: "/")
        guard parts.count == 2, parts[0] == "mmdl", parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://gamebanana.com/dl/" + parts[1])
    }

    private static func isArchiveResponse(_ response: WKNavigationResponse) -> Bool {
        let file = response.response
        let archives = ["zip", "rar", "7z"]
        let disposition = (file as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if disposition.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "attachment" { return true }
        if let name = file.suggestedFilename, archives.contains((name as NSString).pathExtension.lowercased()) { return true }
        if let url = file.url, archives.contains(url.pathExtension.lowercased()) { return true }
        let mime = file.mimeType?.lowercased() ?? ""
        return ["application/zip", "application/x-zip-compressed", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar", "application/x-rar-compressed", "application/octet-stream"].contains(mime) || (response.isForMainFrame && !response.canShowMIMEType)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let origin = action.sourceFrame.securityOrigin
        if !closed, !downloading, origin.protocol == "https", let link = action.request.url,
           let file = Self.gameBananaQuickInstallURL(link, from: origin.host) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: file))
            return
        }
        guard !closed, let url = action.request.url, let scheme = url.scheme?.lowercased(), ["https", "http", "about", "blob"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        if #available(iOS 14.5, macCatalyst 14.5, *), action.shouldPerformDownload || Self.isDirectFile(url) {
            decisionHandler(downloading ? .cancel : .download)
        } else if Self.isDirectFile(url) {
            decisionHandler(.cancel)
            if !downloading { beginLegacyDownload(action.request) }
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard Self.isArchiveResponse(response) else { decisionHandler(.allow); return }
        guard !closed, !downloading else { decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            decisionHandler(.cancel)
            label.text = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            return
        }
        if #available(iOS 14.5, macCatalyst 14.5, *) {
            // Consume WebKit's current response, including any cookies or a single-use CDN redirect.
            decisionHandler(.download)
        } else {
            decisionHandler(.cancel)
            if let url = response.response.url, ["https", "http"].contains(url.scheme?.lowercased()) {
                beginLegacyDownload(URLRequest(url: url))
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !closed, !downloading, ns.code != NSURLErrorCancelled,
              !(["WebKitErrorDomain", WKError.errorDomain].contains(ns.domain) && ns.code == 102) else { return }
        label.text = ns.localizedDescription
    }

    private func beginLegacyDownload(_ request: URLRequest) {
        let id = UUID()
        preparingID = id
        setDownloading(true)
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, self.preparingID == id, !self.closed else { return }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 6 * 60 * 60
            for cookie in cookies { config.httpCookieStorage?.setCookie(cookie) }
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            var outgoing = request
            outgoing.setValue(nil, forHTTPHeaderField: "Cookie")
            if outgoing.value(forHTTPHeaderField: "Referer") == nil {
                outgoing.setValue(self.web.url?.absoluteString, forHTTPHeaderField: "Referer")
            }
            self.task = self.session?.downloadTask(with: outgoing)
            self.preparingID = nil
            self.task?.resume()
        }
    }

    private func updateProgress(_ bytes: Int64, expected: Int64) {
        guard bytes <= Self.maximumDownload, expected <= Self.maximumDownload else {
            fail(L("下载超过单包上限（16 GB），已停止。"))
            return
        }
        guard Date().timeIntervalSince(lastUI) >= 0.25 else { return }
        lastUI = Date()
        let done = ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
        let rate = Int64(Double(max(0, bytes)) / max(1, Date().timeIntervalSince(started)))
        let speed = ByteCountFormatter.string(fromByteCount: rate, countStyle: .file)
        label.text = LF("下载 MOD：%@ · %@/s", done, speed)
        if expected > 0 { bar.progress = Float(Double(bytes) / Double(expected)) }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: (temporaryFolder ?? FileManager.default.temporaryDirectory).path),
           let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < 128 * 1024 * 1024 {
            fail(L("可用空间不足，MOD 安装已安全停止。"))
        }
    }

    /// Both transports keep the payload on disk; promotion consumes only a completed file.
    private func finish(_ file: URL, name: String?, needsOwnership: Bool = false) {
        do {
            let fm = FileManager.default
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ModPackageError.unsupportedArchive }
            guard size <= Self.maximumDownload else {
                fail(L("下载超过单包上限（16 GB），已停止。"))
                return
            }
            // URLSession reclaims its file when this delegate callback returns.
            let owned: URL
            if needsOwnership {
                owned = fm.temporaryDirectory.appendingPathComponent("pjdv-download-" + UUID().uuidString)
                try fm.moveItem(at: file, to: owned)
            } else {
                owned = file
            }
            poll?.invalidate()
            poll = nil
            nativeDownload = nil
            partial = nil
            task = nil
            session?.finishTasksAndInvalidate()
            session = nil
            saving = true
            bar.progress = 1
            navigationItem.leftBarButtonItem?.isEnabled = false
            navigationItem.rightBarButtonItem?.isEnabled = false
            let root = ResourceLibrary.appDataRoot
            let folder = temporaryFolder
            temporaryFolder = nil
            DispatchQueue.global(qos: .userInitiated).async {
                // The library may live on another volume. A cross-volume copy
                // must finish before offering the archive, without freezing UI.
                let result = Result { try ModInbox.storeDownload(from: owned, suggestedName: name, under: root) }
                try? fm.removeItem(at: owned)
                if let folder { try? fm.removeItem(at: folder) }
                DispatchQueue.main.async {
                    self.saving = false
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    self.stopTransfer()
                    switch result {
                    case .success(let stored):
                        self.closed = true
                        let callback = self.onImport
                        self.dismiss(animated: true) { callback?(stored) }
                    case .failure(let error):
                        self.label.text = L(error.localizedDescription)
                    }
                }
            }
        } catch {
            fail(L(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard self.task === downloadTask else { return }
        updateProgress(totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard self.task === downloadTask, !closed else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            fail(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            return
        }
        finish(location, name: downloadTask.response?.suggestedFilename, needsOwnership: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task, let error else { return }
        fail(error.localizedDescription)
    }
}

@available(iOS 14.5, macCatalyst 14.5, *)
extension ModDownloadBrowser: WKDownloadDelegate {
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        accept(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        accept(download)
    }

    private func accept(_ download: WKDownload) {
        guard !closed, !downloading else { download.cancel(nil); return }
        nativeDownload = download
        download.delegate = self
        setDownloading(true)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard nativeDownload === download, !closed else { completionHandler(nil); return }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(nil)
            fail(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            return
        }
        if response.expectedContentLength > Self.maximumDownload {
            completionHandler(nil)
            fail(L("下载超过单包上限（16 GB），已停止。"))
            return
        }
        // Ask Foundation for a private temporary directory on the library's
        // volume. After a crash the system can reclaim this directory; the
        // file manager enumerates only committed entries under Downloads.
        let fm = FileManager.default
        temporaryFolder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: ResourceLibrary.appDataRoot, create: true)
        let file = (temporaryFolder ?? fm.temporaryDirectory).appendingPathComponent("pjdv-download-" + UUID().uuidString)
        partial = file
        suggestedName = suggestedFilename
        completionHandler(file)
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak download] _ in
            guard let self, let download, self.nativeDownload === download else { return }
            self.updateProgress(download.progress.completedUnitCount, expected: download.progress.totalUnitCount)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard nativeDownload === download, let partial, !closed else { return }
        finish(partial, name: suggestedName)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard nativeDownload === download, !closed else { return }
        fail(error.localizedDescription)
    }
}
