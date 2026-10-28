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
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .systemBackground
        preferredContentSize=CGSize(width:720,height:640)
        let title=UILabel();title.text=L("游戏资源");title.font = .boldSystemFont(ofSize:26)
        let version=UILabel();version.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        version.text="PJDV M39 "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")+" ("+(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "")+")"
        version.accessibilityIdentifier="resources.version"
        let info=UILabel();info.numberOfLines=0;info.text=L("导入 MEGA39’s XCI。自动识别包内更新、DLC 与完整语言资源。导入时请保持 App 在前台。");info.font = .systemFont(ofSize:15)
        detail.numberOfLines=0;detail.text=L("按包内实际内容计算所需空间。外置 XCI 可直接读取，不会先复制整个源文件。");detail.font = .systemFont(ofSize:14);detail.accessibilityIdentifier="resources.status"
        func button(_ text:String,_ id:String,_ selector:Selector)->UIButton {
            let b=UIButton(type:.system);b.setTitle(text,for:.normal);b.titleLabel?.font = .systemFont(ofSize:18,weight:.medium);b.accessibilityIdentifier=id;b.addTarget(self,action:selector,for:.touchUpInside);actions.append(b);return b
        }
        let xci=button(L("导入 XCI"),"resources.importXCI",#selector(pickXCI))
        let folder=button(L("连接已提取资源文件夹"),"resources.connectFolder",#selector(pickFolder))
        let keys=button(L("选择／更换 prod.keys"),"resources.chooseKeys",#selector(pickKeys))
        let local=button(L("使用已拷入本机的资源"),"resources.useLocal",#selector(useLocal))
        let close=button(L("完成"),"resources.done",#selector(closePanel))
        cancel.setTitle(L("取消导入（保留已完成部分）"),for:.normal);cancel.addTarget(self,action:#selector(cancelWork),for:.touchUpInside);cancel.isHidden=true
        let row1=UIStackView(arrangedSubviews:[xci,folder]);row1.distribution = .fillEqually;row1.spacing=16
        let row2=UIStackView(arrangedSubviews:[keys,local]);row2.distribution = .fillEqually;row2.spacing=16
        let help=UILabel();help.numberOfLines=0;help.font = .systemFont(ofSize:13);help.text=L("iPad：也可用访达 → iPad → 文件 → PJDV M39，拷入整份 GameResources。\nMac：导入时可选择外置 SSD 为目标。完整资源版可直接启动。")
        activity.hidesWhenStopped=true;bar.isHidden=true
        transfer.numberOfLines=0;transfer.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular);transfer.isHidden=true;transfer.accessibilityIdentifier="resources.transferRates"
        var rows:[UIView]=[title,version,info,row1,row2]
        #if !targetEnvironment(macCatalyst)
        let folderXCI=button(L("备用：从文件夹选择 XCI"),"resources.xciFolder",#selector(pickXCIFolder))
        let folderKeys=button(L("备用：从文件夹选择密钥"),"resources.keysFolder",#selector(pickKeysFolder))
        let fallback=UIStackView(arrangedSubviews:[folderXCI,folderKeys]);fallback.distribution = .fillEqually;fallback.spacing=16
        rows.append(fallback)
        #endif
        let inbox=button(L("检测 App 根目录中的 XCI／密钥"),"resources.scanInbox",#selector(scanInbox))
        let mods=button(L("MOD 管理／下载（实验）"),"resources.mods",#selector(openMods))
        rows += [inbox,mods,detail,activity,bar,transfer,cancel,help,close]
        let stack=UIStackView(arrangedSubviews:rows);stack.axis = .vertical;stack.spacing=14
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll);stack.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:24),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-48)])
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
            guard !snapshot.isEmpty else {detail.text=L("请将 .xci 和 .keys 拷入“文件”App 中的 PJDVM39 根目录。");return}
            importInbox(snapshot)
        } catch {show(error)}
    }
    private func importInbox(_ snapshot:AppImportInbox.Snapshot) {
        inboxSignature=snapshot.signature;pendingInboxXCI=snapshot.xcis
        if snapshot.keys.count>1 {showFolderFiles(ResourceAccess(ResourceLibrary.appDataRoot),purpose:.keys);return}
        if let keys=snapshot.keys.first {
            do {try ResourceLibrary.storeKeys(keys);detail.text=L("密钥已保存在本机，仅用于本地导入。")}
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
        detail.text=purpose == .xciFolder || purpose == .keysFolder ? L("选择文件所在的文件夹并点“打开”，再在 App 内点选文件。") : purpose == .destination ? L("已选择 XCI，接下来选择资源保存位置。") : L("请选择文件或文件夹；取消不会开始导入。")
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
    @objc private func cancelWork(){operation?.cancel();cancel.isEnabled=false;detail.text=L("正在安全停止，源 XCI 与现有存档保留…")}
    @objc private func useLocal(){do{try ResourceLibrary.useLocal();detail.text=L("已使用本机 GameResources。");onClose?()}catch{show(error)}}
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
            detail.text=L("已取消选择；没有开始导入，原文件保持不变。")
            return
        }
        detail.text=L("已选择：")+url.lastPathComponent
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
            do{_=try ResourceLayout.locate(access.root);try ResourceLibrary.select(access.root);detail.text=L("已连接：")+url.lastPathComponent+L("。外置盘需保持连接。");onClose?()}catch{show(error)}
        case .xciFolder,.keysFolder:
            showFolderFiles(ResourceAccess(url),purpose:purpose == .xciFolder ? .xci:.keys)
        case .keys:
            let access=ResourceAccess(url,retaining:containingFolder)
            do{try ResourceLibrary.storeKeys(access.root);detail.text=L("密钥已保存在本机，仅用于本地导入。");continueInboxImport()}catch{pendingInboxXCI=nil;show(error)}
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
    private func show(_ error:Error){detail.text=L("操作未完成：")+error.localizedDescription}
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
        detail.text=L("检查 XCI、密钥与更新映射…")
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
                switch final {case .success:if let signature=self.inboxSignature {AppImportInbox.markCompleted(signature)};self.bar.isHidden=false;self.bar.progress=1;self.detail.text=L("导入完成，包内曲库、DLC 与语言已识别。可以启动游戏测试。");self.onClose?();case .failure(let error):self.show(error)}
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
