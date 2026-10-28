import UIKit
import WebKit

// Public MOD catalog in an isolated web session. Download tasks write to disk;
// the page never receives access to GameResources, saves or local keys.
final class ModDownloadBrowser:UIViewController,WKNavigationDelegate,WKUIDelegate,URLSessionDownloadDelegate {
    var onImport:((URL)->Void)?
    private let web=WKWebView(frame:.zero,configuration:{let c=WKWebViewConfiguration();c.websiteDataStore = .nonPersistent();return c}())
    private let label=UILabel(),bar=UIProgressView(progressViewStyle:.default)
    private var session:URLSession?,task:URLSessionDownloadTask?
    private var start=Date(),lastUI=Date.distantPast
    private var closed=false,preparing=false
    private static let maximumDownload:Int64=16*1024*1024*1024
    override func viewDidLoad() {
        super.viewDidLoad();title="GameBanana";view.backgroundColor = .systemBackground
        web.navigationDelegate=self;web.uiDelegate=self;web.accessibilityIdentifier="mods.browser"
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:L("完成"),style:.done,target:self,action:#selector(close))
        navigationItem.leftBarButtonItem=UIBarButtonItem(title:L("返回"),style:.plain,target:self,action:#selector(back))
        label.numberOfLines=2;label.font = .systemFont(ofSize:13);label.text="gamebanana.com/games/16522";label.accessibilityIdentifier="mods.downloadStatus"
        let hint=UILabel();hint.text=L("目前仅测试过模型和歌曲两类 MOD，不保证所有同类包兼容。");hint.numberOfLines=0;hint.font = .systemFont(ofSize:13)
        let stack=UIStackView(arrangedSubviews:[hint,label,bar,web]);stack.axis = .vertical;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),stack.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor)])
        bar.isHidden=true;web.load(URLRequest(url:URL(string:"https://gamebanana.com/games/16522")!))
    }
    @objc private func back(){if web.canGoBack && task==nil && !preparing {web.goBack()}}
    @objc private func close(){closed=true;task?.cancel();session?.invalidateAndCancel();session=nil;dismiss(animated:true)}
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        if navigationAction.targetFrame==nil {webView.load(navigationAction.request)};return nil
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let scheme=navigationAction.request.url?.scheme?.lowercased(),["https","http","about","blob"].contains(scheme) else {decisionHandler(.cancel);return}
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,decidePolicyFor response:WKNavigationResponse,decisionHandler:@escaping(WKNavigationResponsePolicy)->Void) {
        let mime=response.response.mimeType?.lowercased() ?? "",ext=response.response.url?.pathExtension.lowercased() ?? ""
        if !response.canShowMIMEType || ["zip","7z","rar"].contains(ext) || ["application/zip","application/x-zip-compressed","application/x-7z-compressed","application/vnd.rar"].contains(mime) {
            decisionHandler(.cancel)
            guard task==nil,!preparing,let url=response.response.url,["http","https"].contains(url.scheme?.lowercased() ?? "") else {return}
            beginDownload(url)
        } else {decisionHandler(.allow)}
    }
    private func beginDownload(_ url:URL) {
        preparing=true
        label.text=L("正在准备 MOD 下载…");bar.isHidden=false;bar.progress=0;isModalInPresentation=true;navigationController?.isModalInPresentation=true
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self,!self.closed else {return}
            self.preparing=false
            let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=6*60*60
            config.httpCookieStorage?.setCookies(cookies,for:url,mainDocumentURL:self.web.url)
            self.session=URLSession(configuration:config,delegate:self,delegateQueue:.main)
            var request=URLRequest(url:url);request.setValue(self.web.url?.absoluteString,forHTTPHeaderField:"Referer")
            self.task=self.session?.downloadTask(with:request);self.start=Date();self.task?.resume()
        }
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
        if totalBytesWritten>Self.maximumDownload || totalBytesExpectedToWrite>Self.maximumDownload {
            label.text=L("下载超过单包上限（16 GB），已停止。");downloadTask.cancel();return
        }
        guard Date().timeIntervalSince(lastUI)>0.2 else {return};lastUI=Date()
        let done=ByteCountFormatter.string(fromByteCount:totalBytesWritten,countStyle:.file)
        let speed=ByteCountFormatter.string(fromByteCount:Int64(Double(totalBytesWritten)/max(1,Date().timeIntervalSince(start))),countStyle:.file)
        label.text=LF("下载 MOD：%@ · %@/s",done,speed)
        if totalBytesExpectedToWrite>0 {bar.progress=Float(Double(totalBytesWritten)/Double(totalBytesExpectedToWrite))}
        let root=ResourceLibrary.appDataRoot
        if let attr=try? FileManager.default.attributesOfFileSystem(forPath:root.path),let free=attr[.systemFreeSize] as? NSNumber,free.int64Value<128*1024*1024 {
            label.text=L("可用空间不足，MOD 安装已安全停止。");downloadTask.cancel()
        }
    }
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
        do {
            if let http=downloadTask.response as? HTTPURLResponse,!(200...299).contains(http.statusCode) {throw ModPackageError.invalidZIP}
            let fm=FileManager.default,folder=ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Downloads/"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            var name=((downloadTask.response?.suggestedFilename ?? "mod.zip") as NSString).lastPathComponent
            if !["zip","7z","rar"].contains((name as NSString).pathExtension.lowercased()) {name="mod.zip"}
            let target=folder.appendingPathComponent(name)
            try fm.moveItem(at:location,to:target)
            task=nil;self.session=nil;session.finishTasksAndInvalidate()
            isModalInPresentation=false;navigationController?.isModalInPresentation=false
            let callback=onImport;dismiss(animated:true){callback?(target)}
        } catch {label.text=L(error.localizedDescription);task=nil;self.session=nil;session.invalidateAndCancel();isModalInPresentation=false;navigationController?.isModalInPresentation=false}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        guard let error else {return};self.task=nil;self.session=nil;session.invalidateAndCancel()
        label.text=L(error.localizedDescription);bar.isHidden=true;isModalInPresentation=false;navigationController?.isModalInPresentation=false
    }
}
