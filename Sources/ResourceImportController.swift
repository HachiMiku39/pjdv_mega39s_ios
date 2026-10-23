import UIKit
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
@objc(PJDVMacFileSelection) private protocol MacFileSelectionPlugin {
    static func chooseLocalItem(withTitle title:String,directory:Bool,completion:@escaping(URL?)->Void)
}
#endif

final class ResourceImportController:UIViewController,UIDocumentPickerDelegate {
    private enum Purpose {case xci,keys,folder,destination}
    private var purpose=Purpose.xci
    private var source:ResourceAccess?
    private var destination:ResourceAccess?
    private var operation:Progress?
    private var selecting=false
    private var backgroundTask=UIBackgroundTaskIdentifier.invalid
    private let detail=UILabel(),bar=UIProgressView(progressViewStyle:.default)
    private let cancel=UIButton(type:.system)
    private let activity=UIActivityIndicatorView(style:.medium)
    private var actions=[UIButton]()
    var onClose:(()->Void)?
    override var supportedInterfaceOrientations:UIInterfaceOrientationMask {.landscape}
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .systemBackground
        preferredContentSize=CGSize(width:720,height:500)
        let title=UILabel();title.text=L("游戏资源");title.font = .boldSystemFont(ofSize:26)
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
        let stack=UIStackView(arrangedSubviews:[title,info,row1,row2,detail,activity,bar,cancel,help,close]);stack.axis = .vertical;stack.spacing=18
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll);stack.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor),scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor),stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:24),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-48)])
    }
    private func picker(_ purpose:Purpose) {
        guard operation==nil && !selecting else{return};self.purpose=purpose
        selecting=true;isModalInPresentation=true;bar.isHidden=true
        detail.text=purpose == .destination ? L("已选择 XCI，接下来选择资源保存位置。") : L("请选择文件或文件夹；取消不会开始导入。")
        let title=purpose == .destination ? L("选择资源保存位置（可选外置 SSD）"):L("选择本地文件")
        #if targetEnvironment(macCatalyst)
        guard let url=Bundle.main.builtInPlugInsURL?.appendingPathComponent("PJDVMacLifecycle.bundle"),
              let plugin=Bundle(url:url),plugin.load(),
              let entry=plugin.principalClass as? MacFileSelectionPlugin.Type else {
            finishSelection(nil,purpose:purpose)
            show(ImportFailure.invalid(L("Mac 文件选择组件不可用，请重新安装完整的 App。")))
            return
        }
        entry.chooseLocalItem(withTitle:title,directory:purpose == .folder || purpose == .destination) {[weak self] url in
            self?.finishSelection(url,purpose:purpose)
        }
        #else
        let types:[UTType]=(purpose == .folder || purpose == .destination) ? [.folder]:[.item]
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:types,asCopy:false)
        picker.delegate=self;picker.allowsMultipleSelection=false
        picker.title=title
        present(picker,animated:true)
        #endif
    }
    @objc private func pickXCI(){picker(.xci)}
    @objc private func pickFolder(){picker(.folder)}
    @objc private func pickKeys(){picker(.keys)}
    @objc private func closePanel(){guard operation==nil && !selecting else{return};dismiss(animated:true,completion:onClose)}
    @objc private func cancelWork(){operation?.cancel();cancel.isEnabled=false;detail.text=L("正在安全停止，源 XCI 与现有存档保留…")}
    @objc private func useLocal(){do{try ResourceLibrary.useLocal();detail.text=L("已使用本机 GameResources。");onClose?()}catch{show(error)}}
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {finishSelection(nil,purpose:purpose)}
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        finishSelection(urls.first,purpose:purpose)
    }
    private func finishSelection(_ url:URL?,purpose:Purpose) {
        selecting=false;isModalInPresentation=false
        guard let url else {
            if purpose == .xci || purpose == .destination {source=nil;destination=nil}
            detail.text=L("已取消选择；没有开始导入，原文件保持不变。")
            return
        }
        detail.text=L("已选择：")+url.lastPathComponent
        switch purpose {
        case .xci:
            guard url.pathExtension.lowercased()=="xci" else {show(ImportFailure.invalid(L("请选择 .xci 文件；ZIP／7z 请先解压。")));return}
            source=ResourceAccess(url)
            #if targetEnvironment(macCatalyst)
            // Present after the source picker has completed its dismissal.
            DispatchQueue.main.async {[weak self] in self?.picker(.destination)}
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
        case .keys:
            let access=ResourceAccess(url)
            do{try ResourceLibrary.storeKeys(access.root);detail.text=L("密钥已保存在本机，仅用于本地导入。")}catch{show(error)}
        }
    }
    private func show(_ error:Error){detail.text=L("操作未完成：")+error.localizedDescription}
    private func beginImport(root:URL) {
        guard let source else{return}
        let keys:URL
        do{keys=try ResourceLibrary.keysURL()}catch{show(error);self.source=nil;destination=nil;return}
        let progress=Progress(totalUnitCount:100);operation=progress
        let destination=self.destination
        actions.forEach{$0.isEnabled=false};cancel.isHidden=false;cancel.isEnabled=true;isModalInPresentation=true;bar.progress=0;bar.isHidden=true;activity.startAnimating()
        detail.text=L("检查 XCI、密钥与更新映射…")
        UIApplication.shared.isIdleTimerDisabled=true
        backgroundTask=UIApplication.shared.beginBackgroundTask(withName:"PJDV resource import"){progress.cancel()}
        DispatchQueue.global(qos:.userInitiated).async {[weak self] in
            var coordinationError:NSError?,result:Result<Void,Error>?
            NSFileCoordinator().coordinate(readingItemAt:source.root,options:.withoutChanges,error:&coordinationError){url in
                result=Result {
                    let plan=try XCIImportPlan(xci:url,keys:keys,checkCancelled:{progress.isCancelled},report:{message in
                        DispatchQueue.main.async {[weak self] in self?.detail.text=message.components(separatedBy:"\n").map{L($0)}.joined(separator:"\n")}
                    })
                    try XCIResourceImporter(plan:plan,root:root,cancel:{progress.isCancelled},report:{value in
                        DispatchQueue.main.async {[weak self] in
                            self?.activity.stopAnimating();self?.bar.isHidden=false
                            self?.bar.progress=Float(value.completed)/Float(max(1,value.total))
                            self?.detail.text=L(value.message)+"\n"+ByteCountFormatter.string(fromByteCount:Int64(value.completed),countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:Int64(value.total),countStyle:.file)
                        }
                    }).run()
                    _=try ResourceLayout.locate(root);try ResourceLibrary.select(root)
                }
            }
            withExtendedLifetime(destination){}
            let final=result ?? .failure(coordinationError ?? ImportFailure.invalid(L("无法协调读取 XCI")) as NSError)
            DispatchQueue.main.async {[weak self] in
                guard let self else{return}
                self.operation=nil;self.source=nil;self.destination=nil;self.actions.forEach{$0.isEnabled=true};self.cancel.isHidden=true;self.isModalInPresentation=false;self.activity.stopAnimating()
                UIApplication.shared.isIdleTimerDisabled=false
                if self.backgroundTask != .invalid {UIApplication.shared.endBackgroundTask(self.backgroundTask);self.backgroundTask = .invalid}
                switch final {case .success:self.bar.isHidden=false;self.bar.progress=1;self.detail.text=L("导入完成，包内曲库、DLC 与语言已识别。可以启动游戏测试。");self.onClose?();case .failure(let error):self.show(error)}
            }
        }
    }
}
