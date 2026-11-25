import UIKit
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
@objc(PJDVMacFileSelection) protocol MacFileSelectionPlugin {
    static func chooseLocalItem(withTitle title:String,directory:Bool,completion:@escaping(URL?)->Void)
}
#endif

final class ResourceImportController:UIViewController,UIDocumentPickerDelegate {
    private enum Purpose {case xci,keys,folder,destination,xciFolder,keysFolder
        var directory:Bool {switch self {case .folder,.destination,.xciFolder,.keysFolder:return true;default:return false}}
    }
    private var purpose=Purpose.xci
    private var source:ResourceAccess?
    private var destination:ResourceAccess?
    private var operation:Progress?
    private var selecting=false
    private var backgroundTask=UIBackgroundTaskIdentifier.invalid
    private let detail=UILabel(),bar=UIProgressView(progressViewStyle:.default)
    private let cancel=UIButton(type:.system)
    private let activity=UIActivityIndicatorView(style:.medium)
    private let transfer=UILabel()
    private var io:ImportIOMeter?
    private var transferTimer:Timer?
    private var memoryLog:FileHandle?
    private var memoryPeak:UInt64=0
    private var memoryLogTime:TimeInterval=0
    private var actions=[UIButton]()
    var automaticInbox:AppImportInbox.Snapshot?
    private var startedInbox=false
    private var pendingInboxXCI:[URL]?
    private var inboxSignature:String?
    var onClose:(()->Void)?
    override var supportedInterfaceOrientations:UIInterfaceOrientationMask {.landscape}
    private let scroll = UIScrollView()
    private let statusPanel = UIStackView()
    private var actionRows = [UIStackView]()

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 720, height: 640)
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = LauncherInterface.accent

        let title = label(L("游戏资源"), style: .title1)
        title.accessibilityTraits.insert(.header)
        let version = label("PJDV M39 · " + AppReleaseVersion.current.label, style: .caption1, color: .secondaryLabel)
        version.accessibilityIdentifier = "resources.version"
        let heading = UIStackView(arrangedSubviews: [title, version])
        heading.axis = .vertical
        heading.spacing = 2
        let close = action(L("完成"), id: "resources.done", symbol: "checkmark", selector: #selector(closePanel))
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [heading, close])
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let xci = action(L("导入 XCI"), id: "resources.importXCI", symbol: "square.and.arrow.down",
                         selector: #selector(pickXCI), primary: true)
        let keys = action(L("选择／更换 prod.keys"), id: "resources.chooseKeys", symbol: "key",
                          selector: #selector(pickKeys))
        let inbox = action(L("检测 App 根目录中的 XCI／密钥"), id: "resources.scanInbox",
                           symbol: "tray.and.arrow.down", selector: #selector(scanInbox))
        let intro = label(L("从本地选择 prod.keys 和 MEGA39’s 的 XCI。包内更新与 DLC 会一并导入。导入时请保持 App 在前台。"),
                          style: .subheadline, color: .secondaryLabel)
        let fromXCI = panel(title: L("游戏本体"), contents: [intro, pair(xci, keys), inbox])

        let folder = action(L("连接已提取资源文件夹"), id: "resources.connectFolder",
                            symbol: "folder", selector: #selector(pickFolder))
        let local = action(L("使用已拷入本机的资源"), id: "resources.useLocal",
                           symbol: "internaldrive", selector: #selector(useLocal))
        let existingHelp = label(L("选择已成功导入的完整 GameResources 文件夹，可直接使用其中的游戏数据。"),
                                 style: .subheadline, color: .secondaryLabel)
        let existing = panel(title: L("已有游戏数据"), contents: [existingHelp, pair(folder, local)])

        detail.numberOfLines = 0
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.accessibilityIdentifier = "resources.status"
        transfer.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        transfer.adjustsFontForContentSizeCategory = true
        transfer.numberOfLines = 0
        transfer.textColor = .secondaryLabel
        transfer.isHidden = true
        transfer.accessibilityIdentifier = "resources.transferRates"
        bar.progressTintColor = LauncherInterface.accent
        bar.isHidden = true
        bar.accessibilityLabel = L("导入状态")
        activity.hidesWhenStopped = true
        activity.color = LauncherInterface.accent
        activity.setContentHuggingPriority(.required, for: .horizontal)
        let feedback = UIStackView(arrangedSubviews: [activity, detail])
        feedback.alignment = .top
        feedback.spacing = 8
        cancel.setTitle(L("取消导入（保留已完成部分）"), for: .normal)
        LauncherInterface.style(cancel, symbol: "stop.circle")
        cancel.addTarget(self, action: #selector(cancelWork), for: .touchUpInside)
        cancel.isHidden = true
        cancel.accessibilityIdentifier = "resources.cancel"
        configurePanel(statusPanel, title: L("导入状态"), contents: [feedback, bar, transfer, cancel])
        statusPanel.isHidden = true

        let content = UIStackView(arrangedSubviews: [statusPanel, fromXCI, existing])
        content.axis = .vertical
        content.spacing = 12
        #if !targetEnvironment(macCatalyst)
        let folderXCI = action(L("备用：从文件夹选择 XCI"), id: "resources.xciFolder",
                               symbol: "folder", selector: #selector(pickXCIFolder))
        let folderKeys = action(L("备用：从文件夹选择密钥"), id: "resources.keysFolder",
                                symbol: "key", selector: #selector(pickKeysFolder))
        content.addArrangedSubview(panel(title: L("文件选择备选方式"), contents: [pair(folderXCI, folderKeys)]))
        #endif
        let mods = action(L("MOD 管理／下载（实验）"), id: "resources.mods",
                          symbol: "square.stack.3d.up", selector: #selector(openMods))
        content.addArrangedSubview(mods)
        scroll.keyboardDismissMode = .onDrag
        scroll.accessibilityIdentifier = "resources.scroll"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let narrow = view.safeAreaLayoutGuide.layoutFrame.width < 560 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in actionRows {
            row.axis = narrow ? .vertical : .horizontal
            row.distribution = narrow ? .fill : .fillEqually
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let result = UILabel()
        result.text = text
        result.font = .preferredFont(forTextStyle: style)
        result.adjustsFontForContentSizeCategory = true
        result.textColor = color
        result.numberOfLines = 0
        return result
    }

    private func action(_ title: String, id: String, symbol: String, selector: Selector, primary: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        LauncherInterface.style(button, symbol: symbol, primary: primary)
        button.addTarget(self, action: selector, for: .touchUpInside)
        actions.append(button)
        return button
    }

    private func pair(_ first: UIView, _ second: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [first, second])
        row.spacing = 8
        actionRows.append(row)
        return row
    }

    private func panel(title: String, contents: [UIView]) -> UIStackView {
        let panel = UIStackView()
        configurePanel(panel, title: title, contents: contents)
        return panel
    }

    private func configurePanel(_ panel: UIStackView, title: String, contents: [UIView]) {
        panel.axis = .vertical
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        panel.backgroundColor = .secondarySystemGroupedBackground
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        let heading = label(title, style: .headline)
        heading.accessibilityTraits.insert(.header)
        panel.addArrangedSubview(heading)
        contents.forEach(panel.addArrangedSubview)
    }

    private func setStatus(_ text: String?, error: Bool = false, reveal: Bool = false) {
        detail.text = text
        detail.textColor = error ? .systemRed : .label
        let show = statusPanel.isHidden || reveal || error
        statusPanel.isHidden = false
        if show {
            view.layoutIfNeeded()
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        }
        if error { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    @objc private func openMods() {
        guard operation==nil && !selecting else{return}
        let panel=UINavigationController(rootViewController:ModImportController(style:.insetGrouped))
        panel.modalPresentationStyle = .formSheet;present(panel,animated:true)
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        if !startedInbox,let snapshot=automaticInbox {startedInbox=true;importInbox(snapshot)}
    }
    @objc private func scanInbox() {
        guard operation==nil && !selecting else{return}
        do {
            let snapshot=try AppImportInbox.Snapshot.read(ResourceLibrary.appDataRoot)
            guard !snapshot.isEmpty else {setStatus(L("请将 .xci 和 .keys 拷入“文件”App 中的 PJDVM39 根目录。"), reveal: true);return}
            importInbox(snapshot)
        } catch {show(error)}
    }
    private func importInbox(_ snapshot:AppImportInbox.Snapshot) {
        inboxSignature=snapshot.signature;pendingInboxXCI=snapshot.xcis
        if snapshot.keys.count>1 {showFolderFiles(ResourceAccess(ResourceLibrary.appDataRoot),purpose:.keys);return}
        if let keys=snapshot.keys.first {
            do {try ResourceLibrary.storeKeys(keys);setStatus(L("密钥已保存在本机，仅用于本地导入。"), reveal: true)}
            catch {pendingInboxXCI=nil;show(error);return}
        }
        continueInboxImport()
    }
    private func continueInboxImport() {
        guard let xcis=pendingInboxXCI else{return};pendingInboxXCI=nil
        if xcis.count>1 {showFolderFiles(ResourceAccess(ResourceLibrary.appDataRoot),purpose:.xci)}
        else if let xci=xcis.first {finishSelection(xci,purpose:.xci)}
        else if let inboxSignature {AppImportInbox.markCompleted(inboxSignature)}
    }
    private func picker(_ purpose:Purpose) {
        guard operation==nil && !selecting else{return};self.purpose=purpose
        if purpose != .destination {pendingInboxXCI=nil;inboxSignature=nil}
        selecting=true;isModalInPresentation=true;bar.isHidden=true
        transfer.isHidden=true
        setStatus(purpose == .xciFolder || purpose == .keysFolder ? L("选择文件所在的文件夹并点“打开”，再在 App 内点选文件。") : purpose == .destination ? L("已选择 XCI，接下来选择资源保存位置。") : L("请选择文件或文件夹；取消不会开始导入。"), reveal: true)
        let title=purpose == .destination ? L("选择资源保存位置（可选外置 SSD）"):L("选择本地文件")
        #if targetEnvironment(macCatalyst)
        guard let url=Bundle.main.builtInPlugInsURL?.appendingPathComponent("PJDVMacLifecycle.bundle"),
              let plugin=Bundle(url:url),plugin.load(),
              let entry=plugin.principalClass as? MacFileSelectionPlugin.Type else {
            finishSelection(nil,purpose:purpose)
            show(ImportFailure.invalid(L("Mac 文件选择组件不可用，请重新安装完整的 App。")))
            return
        }
        entry.chooseLocalItem(withTitle:title,directory:purpose.directory) {[weak self] url in
            self?.finishSelection(url,purpose:purpose)
        }
        #else
        let types:[UTType]
        switch purpose {
        case .folder,.destination,.xciFolder,.keysFolder:types=[.folder]
        case .xci:types=[UTType(importedAs:"com.hachimiku39.pjdv.xci",conformingTo:.data),.item]
        case .keys:types=[UTType(importedAs:"com.hachimiku39.pjdv.keys",conformingTo:.plainText),.item]
        }
        // Some Files providers return a dynamic/unknown type. Keep .item as a
        // fallback and validate the extension and contents after selection.
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:types,asCopy:false)
        picker.delegate=self;picker.allowsMultipleSelection=false;picker.shouldShowFileExtensions=true
        picker.title=title;picker.modalPresentationStyle = .fullScreen
        present(picker,animated:true)
        #endif
    }
    @objc private func pickXCI(){picker(.xci)}
    @objc private func pickFolder(){picker(.folder)}
    @objc private func pickXCIFolder(){picker(.xciFolder)}
    @objc private func pickKeysFolder(){picker(.keysFolder)}
    @objc private func pickKeys(){picker(.keys)}
    @objc private func closePanel(){guard operation==nil && !selecting else{return};dismiss(animated:true,completion:onClose)}
    @objc private func cancelWork(){operation?.cancel();cancel.isEnabled=false;setStatus(L("正在安全停止，源 XCI 与现有存档保留…"))}
    @objc private func useLocal(){do{try ResourceLibrary.useLocal();setStatus(L("已使用本机 GameResources。"), reveal: true);onClose?()}catch{show(error)}}
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {
        completeDocumentSelection(controller,url:nil)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        completeDocumentSelection(controller,url:urls.first)
    }
    private func completeDocumentSelection(_ controller:UIDocumentPickerViewController,url:URL?) {
        guard selecting else{return}
        let selectedPurpose=purpose
        // Acquire the provider's security scope before dismissing Files; keep it
        // alive until finishSelection has handed it to the background importer.
        let access=url.map{ResourceAccess($0)}
        controller.dismiss(animated:true) {[weak self,access] in
            self?.finishSelection(access?.root,purpose:selectedPurpose)
            withExtendedLifetime(access){}
        }
    }
    private func finishSelection(_ url:URL?,purpose:Purpose,containingFolder:ResourceAccess?=nil) {
        selecting=false;isModalInPresentation=false
        guard let url else {
            if purpose == .xci || purpose == .destination {source=nil;destination=nil}
            pendingInboxXCI=nil;inboxSignature=nil
            setStatus(L("已取消选择；没有开始导入，原文件保持不变。"))
            return
        }
        setStatus(L("已选择：") + url.lastPathComponent)
        switch purpose {
        case .xci:
            guard url.pathExtension.lowercased()=="xci" else {show(ImportFailure.invalid(L("请选择 .xci 文件；ZIP／7z 请先解压。")));return}
            source=ResourceAccess(url,retaining:containingFolder)
            #if targetEnvironment(macCatalyst)
            // Present after the source picker has completed its dismissal.
            if inboxSignature != nil {beginImport(root:ResourceLibrary.localRoot)}
            else {DispatchQueue.main.async {[weak self] in self?.picker(.destination)}}
            #else
            beginImport(root:ResourceLibrary.localRoot)
            #endif
        case .destination:
            destination=ResourceAccess(url)
            let existing=(try?ResourceLayout.locate(url,requireComplete:false)) != nil
            beginImport(root:existing ? url:url.appendingPathComponent("PJDVM39-Resources",isDirectory:true))
        case .folder:
            let access=ResourceAccess(url)
            do{_=try ResourceLayout.locate(access.root);try ResourceLibrary.select(access.root);setStatus(L("已连接：") + url.lastPathComponent + L("。外置盘需保持连接。"), reveal: true);onClose?()}catch{show(error)}
        case .xciFolder,.keysFolder:
            showFolderFiles(ResourceAccess(url),purpose:purpose == .xciFolder ? .xci:.keys)
        case .keys:
            let access=ResourceAccess(url,retaining:containingFolder)
            do{try ResourceLibrary.storeKeys(access.root);setStatus(L("密钥已保存在本机，仅用于本地导入。"), reveal: true);continueInboxImport()}catch{pendingInboxXCI=nil;show(error)}
        }
    }
    private func showFolderFiles(_ folder:ResourceAccess,purpose:Purpose) {
        selecting=true;isModalInPresentation=true
        let list=ImportFileListController(folder:folder,fileExtension:purpose == .xci ? "xci":"keys")
        let navigation=UINavigationController(rootViewController:list)
        navigation.modalPresentationStyle = .fullScreen
        list.onPick={[weak self,weak navigation] url in
            navigation?.dismiss(animated:true) {
                self?.finishSelection(url,purpose:purpose,containingFolder:folder)
            }
        }
        list.onCancel={[weak self,weak navigation] in
            navigation?.dismiss(animated:true) {self?.finishSelection(nil,purpose:purpose)}
        }
        present(navigation,animated:true)
    }
    private func importMessage(_ message:String)->String {
        message.components(separatedBy:"\n").map { line in
            for prefix in ["导入：","校验已有资源：","校验未完成记录："] where line.hasPrefix(prefix) {return L(prefix)+line.dropFirst(prefix.count)}
            return L(line)
        }.joined(separator:"\n")
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        recordImportMemory(event:"memory_warning",force:true)
    }
    // Small, local-only log: no source paths, filenames, keys or save data.
    // A killed process cannot write a final record, so persist every five seconds.
    private func startMemoryLog() {
        let url=ResourceLibrary.appDataRoot.appendingPathComponent("PJDV-import-diagnostics.jsonl")
        memoryPeak=0;memoryLogTime=0
        // Preserve the preceding session before an automatic retry can truncate
        // it, including the last samples left by a jetsam-terminated process.
        if let size=try?FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber,
           size.intValue<=8*1024*1024,let previous=try?Data(contentsOf:url) {
            try?previous.write(to:ResourceLibrary.appDataRoot.appendingPathComponent("PJDV-import-diagnostics.previous.jsonl"),options:.atomic)
        }
        do {
            try Data().write(to:url,options:.atomic)
            memoryLog=try FileHandle(forWritingTo:url)
            let header:[String:Any]=["event":"start","build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "", "physical_memory_bytes":ProcessInfo.processInfo.physicalMemory,"system":UIDevice.current.systemVersion]
            try memoryLog?.write(contentsOf:JSONSerialization.data(withJSONObject:header,options:[.sortedKeys])+Data([10]))
        } catch {try?memoryLog?.close();memoryLog=nil}
    }
    private func recordImportMemory(event:String,force:Bool=false,sample:ImportIOMeter.Sample?=nil) {
        let now=ProcessInfo.processInfo.systemUptime
        let memory=PerformanceMonitor.memoryBytes()
        if let memory {memoryPeak=max(memoryPeak,memory)}
        guard memoryLog != nil,(force || now-memoryLogTime>=5) else{return}
        memoryLogTime=now
        var row:[String:Any]=["event":event,"uptime":now,"peak_memory_bytes":memoryPeak]
        if let memory {row["memory_bytes"]=memory}
        if let sample {row["elapsed_seconds"]=sample.elapsed;row["read_bytes"]=sample.readBytes;row["written_bytes"]=sample.writtenBytes}
        do {
            try memoryLog?.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
            try memoryLog?.synchronize()
        } catch {try?memoryLog?.close();memoryLog=nil}
    }
    private func refreshTransfer(final:Bool=false) {
        guard let sample=io?.sample() else{return}
        func bytes(_ n:Int64)->String {ByteCountFormatter.string(fromByteCount:n,countStyle:.file)}
        func rate(_ n:Double)->String {bytes(Int64(max(0,min(n,Double(Int64.max/2)))))+"/s"}
        let readRate=final ? 0:sample.readBytesPerSecond,writeRate=final ? 0:sample.writtenBytesPerSecond
        let elapsed=Int(sample.elapsed)
        recordImportMemory(event:final ? "finished":"sample",force:final,sample:sample)
        let memory=PerformanceMonitor.memoryBytes().map{L("内存")+" "+bytes(Int64($0))+"  ·  "+L("峰值")+" "+bytes(Int64(memoryPeak))} ?? ""
        transfer.text=L("读取")+" "+rate(readRate)+"  ·  "+L("写入")+" "+rate(writeRate)+"\n"+L("累计读取")+" "+bytes(sample.readBytes)+"  ·  "+L("累计写入")+" "+bytes(sample.writtenBytes)+"  ·  "+L("已耗时")+String(format:" %02d:%02d",elapsed/60,elapsed%60)+"\n"+memory+"\n"+L("应用层读写量，含缓存；不是物理硬盘测速。")
    }
    private func show(_ error:Error){setStatus(L("操作未完成：") + error.localizedDescription, error: true)}
    deinit {transferTimer?.invalidate();try?memoryLog?.close()}
    private func beginImport(root:URL) {
        guard let source else{return}
        let keys:URL
        do{keys=try ResourceLibrary.keysURL()}catch{show(error);self.source=nil;destination=nil;return}
        let progress=Progress(totalUnitCount:100);operation=progress
        let io=ImportIOMeter();self.io=io;startMemoryLog();transfer.isHidden=false;refreshTransfer()
        let timer=Timer(timeInterval:0.5,repeats:true){[weak self] _ in self?.refreshTransfer()}
        transferTimer=timer;RunLoop.main.add(timer,forMode:.common)
        let destination=self.destination
        actions.forEach{$0.isEnabled=false};cancel.isHidden=false;cancel.isEnabled=true;isModalInPresentation=true;bar.progress=0;bar.isHidden=true;activity.startAnimating()
        setStatus(L("检查 XCI、密钥与更新映射…"), reveal: true)
        UIApplication.shared.isIdleTimerDisabled=true
        backgroundTask=UIApplication.shared.beginBackgroundTask(withName:"PJDV resource import"){progress.cancel()}
        DispatchQueue.global(qos:.userInitiated).async {[weak self] in
            var coordinationError:NSError?,result:Result<Void,Error>?
            NSFileCoordinator().coordinate(readingItemAt:source.root,options:.withoutChanges,error:&coordinationError){url in
                result=Result {
                    let plan=try XCIImportPlan(xci:url,keys:keys,checkCancelled:{progress.isCancelled},io:io,report:{message in
                        DispatchQueue.main.async {[weak self] in self?.detail.text=self?.importMessage(message)}
                    })
                    try XCIResourceImporter(plan:plan,root:root,cancel:{progress.isCancelled},report:{value in
                        DispatchQueue.main.async {[weak self] in
                            self?.activity.stopAnimating();self?.bar.isHidden=false
                            let fraction=Double(value.completed)/Double(max(1,value.total))
                            self?.bar.progress=Float(min(0.999,fraction))
                            self?.detail.text=(self?.importMessage(value.message) ?? value.message)+String(format:"\n%.1f%% · ",min(99.9,fraction*100))+ByteCountFormatter.string(fromByteCount:Int64(value.completed),countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:Int64(value.total),countStyle:.file)
                        }
                    }).run()
                    _=try ResourceLayout.locate(root);try ResourceLibrary.select(root)
                }
            }
            withExtendedLifetime(destination){}
            let final=result ?? .failure(coordinationError ?? ImportFailure.invalid(L("无法协调读取 XCI")) as NSError)
            DispatchQueue.main.async {[weak self] in
                guard let self else{return}
                self.transferTimer?.invalidate();self.transferTimer=nil;self.refreshTransfer(final:true)
                switch final {case .success:self.recordImportMemory(event:"success",force:true);case .failure:self.recordImportMemory(event:"failure",force:true)}
                try?self.memoryLog?.close();self.memoryLog=nil
                self.operation=nil;self.source=nil;self.destination=nil;self.actions.forEach{$0.isEnabled=true};self.cancel.isHidden=true;self.isModalInPresentation=false;self.activity.stopAnimating()
                UIApplication.shared.isIdleTimerDisabled=false
                if self.backgroundTask != .invalid {UIApplication.shared.endBackgroundTask(self.backgroundTask);self.backgroundTask = .invalid}
                switch final {case .success:if let signature=self.inboxSignature {AppImportInbox.markCompleted(signature)};self.bar.isHidden=false;self.bar.progress=1;self.setStatus(L("导入完成，包内曲库、DLC 与语言已识别。可以启动游戏测试。"), reveal: true);self.onClose?();case .failure(let error):self.show(error)}
            }
        }
    }
}

// Select a directory with the system picker, then use ordinary UIKit cells.
// Keeps the directory grant alive while listing and throughout a selected import.
private final class ImportFileListController:UITableViewController {
    private struct File {let url:URL;let size:Int64}
    private let folder:ResourceAccess,fileExtension:String
    private var files=[File]()
    var onPick:((URL)->Void)?
    var onCancel:(()->Void)?
    override var supportedInterfaceOrientations:UIInterfaceOrientationMask {.landscape}
    init(folder:ResourceAccess,fileExtension:String) {
        self.folder=folder;self.fileExtension=fileExtension
        super.init(style:.insetGrouped)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func viewDidLoad() {
        super.viewDidLoad();title=fileExtension == "xci" ? L("选择 XCI"):L("选择密钥")
        navigationItem.leftBarButtonItem=UIBarButtonItem(title:L("取消"),style:.plain,target:self,action:#selector(cancelSelection))
        tableView.accessibilityIdentifier="resources.folderFiles"
        let status=UILabel();status.numberOfLines=0;status.textAlignment = .center;status.text=L("正在读取文件夹…");tableView.backgroundView=status
        let folder=self.folder,ext=fileExtension
        DispatchQueue.global(qos:.userInitiated).async {[weak self] in
            var coordinationError:NSError?,result:Result<[File],Error>?
            NSFileCoordinator().coordinate(readingItemAt:folder.root,options:.withoutChanges,error:&coordinationError){url in
                result=Result {
                    let entries=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey],options:.skipsHiddenFiles)
                    guard entries.count<=10000 else{throw ImportFailure.invalid(L("文件过多，请选择更小的文件夹。"))}
                    return try entries.filter{$0.pathExtension.lowercased()==ext}.compactMap { file in
                        let value=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                        guard value.isRegularFile==true else{return nil}
                        return File(url:folder.root.appendingPathComponent(file.lastPathComponent),size:Int64(value.fileSize ?? 0))
                    }.sorted{$0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending}
                }
            }
            let final=result ?? .failure(coordinationError ?? ImportFailure.invalid(L("无法读取文件夹")) as NSError)
            DispatchQueue.main.async {[weak self] in
                guard let self else{return}
                switch final {
                case .success(let files):
                    self.files=files;status.text=files.isEmpty ? L("这个文件夹没有对应文件，请返回重选所在文件夹。"):nil
                    if !files.isEmpty {self.tableView.backgroundView=nil}
                    self.tableView.reloadData()
                case .failure(let error):status.text=L("操作未完成：")+error.localizedDescription
                }
            }
        }
    }
    @objc private func cancelSelection(){onCancel?()}
    override func numberOfSections(in tableView:UITableView)->Int {1}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {files.count}
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {folder.root.lastPathComponent}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
        let cell=UITableViewCell(style:.subtitle,reuseIdentifier:nil),file=files[indexPath.row]
        cell.textLabel?.text=file.url.lastPathComponent;cell.textLabel?.numberOfLines=0
        cell.detailTextLabel?.text=ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file)
        cell.accessoryType = .disclosureIndicator;cell.accessibilityIdentifier="resources.file."+file.url.lastPathComponent
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.isUserInteractionEnabled=false;navigationItem.leftBarButtonItem?.isEnabled=false
        onPick?(files[indexPath.row].url)
    }
}
