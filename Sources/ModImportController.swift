import UIKit
import UniformTypeIdentifiers

extension RuntimeModCatalog {
    static var current: RuntimeModCatalog {
        RuntimeModCatalog(root: ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Ready", isDirectory: true), defaults: .standard)
    }
}

// Launcher-only downloads/imports. Resource installation is separate from
// runtime compatibility: importing never executes a PC DLL or unknown patch.
final class ModImportController: UITableViewController, UIDocumentPickerDelegate {
    var onClose: (() -> Void)?
    private let registry = ModRegistry(root: ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Registrations", isDirectory: true))
    private var records = [ModRegistration]()
    private var downloads = [URL]()
    private var ready = [RuntimeMod]()
    private var unavailable = [RuntimeModCatalog.Unavailable]()
    private var pendingIDs=[UUID]()
    private var operation: Progress?
    private var selecting = false
    private var statusTimer:Timer?
    private var fraction:Float=0
    private var status = L("ZIP／文件夹可导入；7z、RAR 请先解压。")
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override func viewDidLoad() {
        super.viewDidLoad()
        title=L("MOD 管理")
        pendingIDs=RuntimeModCatalog.current.selectedIDs
        preferredContentSize=CGSize(width:720,height:600)
        tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=64
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:L("加载"),style:.done,target:self,action:#selector(closePanel))
        reloadRecords()
    }
    private func reloadRecords() {
        do { records=try registry.records() }
        catch { status=L(error.localizedDescription) }
        do { let inventory=try RuntimeModCatalog.current.inventory();ready=inventory.ready;unavailable=inventory.unavailable }
        catch { ready=[];unavailable=[];status=Self.userMessage(error) }
        let root=ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Downloads",isDirectory:true)
        let fm=FileManager.default
        downloads=[]
        for folder in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [] {
            guard UUID(uuidString:folder.lastPathComponent) != nil else {continue}
            for file in (try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:.skipsHiddenFiles)) ?? [] {
                let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                if values?.isRegularFile==true && values?.isSymbolicLink != true && ["zip","7z","rar"].contains(file.pathExtension.lowercased()) {downloads.append(file)}
                if downloads.count>=100 {break}
            }
            if downloads.count>=100 {break}
        }
        downloads.sort{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
        tableView.reloadData()
    }
    override func numberOfSections(in tableView:UITableView)->Int { 5 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {
        section == 0 ? 5 : section == 1 ? ready.count+unavailable.count+1 : section == 2 ? max(1,records.count) : section == 3 ? max(1,downloads.count) : 1
    }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {
        L(section == 0 ? "添加 MOD" : section == 1 ? "启用 MOD" : section == 2 ? "暂不能加载" : section == 3 ? "已下载的压缩包" : "状态")
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int)->String? {
        section == 0 ? L("原始 PC 包目前支持 Leo/need 1.0.2；其他包请使用已适配版本。") : section == 1 ? L("可同时启用多个 MOD，加载时自动处理组合。") : section == 3 ? L("下载文件会保留，轻点可重新导入；7z／RAR 需先解压。") : nil
    }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
        let cell=UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        cell.textLabel?.numberOfLines=0;cell.detailTextLabel?.numberOfLines=0
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                cell.textLabel?.text=L("ZIP／文件夹可导入；7z、RAR 请先解压。")
                cell.textLabel?.font = .systemFont(ofSize:15)
            } else {
                cell.textLabel?.text=L(indexPath.row == 1 ? "浏览／下载 MOD（GameBanana）" : indexPath.row == 2 ? "添加 ZIP 包" : indexPath.row == 3 ? "添加 MOD 文件夹" : "重新完整校验")
                cell.accessibilityIdentifier=indexPath.row == 1 ? "mods.browse" : indexPath.row == 2 ? "mods.addZIP" : indexPath.row == 3 ? "mods.addFolder" : "mods.verify"
                cell.textLabel?.textColor=operation == nil && !selecting ? .systemBlue : .secondaryLabel
                cell.selectionStyle = .default
            }
        } else if indexPath.section == 2 {
            if records.isEmpty { cell.textLabel?.text=L("尚未登记 MOD。");cell.accessibilityIdentifier="mods.empty" }
            else {
                let record=records[indexPath.row]
                cell.textLabel?.text=record.name;cell.detailTextLabel?.text=L("此包目前不能加载。")
                cell.accessibilityIdentifier="mods.record."+record.id.uuidString
                cell.accessoryType = .disclosureIndicator;cell.selectionStyle = .default
            }
        } else if indexPath.section == 3 {
            if downloads.isEmpty {cell.textLabel?.text=L("暂无已下载的 MOD 压缩包。")}
            else {
                let file=downloads[indexPath.row];cell.textLabel?.text=file.lastPathComponent
                cell.detailTextLabel?.text=L("重新导入");cell.textLabel?.textColor = .systemBlue
                cell.accessibilityIdentifier="mods.download."+file.deletingLastPathComponent().lastPathComponent
                cell.accessoryType = .disclosureIndicator;cell.selectionStyle = .default
            }
        } else if indexPath.section == 1 {
            if indexPath.row>ready.count {
                let item=unavailable[indexPath.row-ready.count-1]
                cell.textLabel?.text=item.name;cell.textLabel?.textColor = .systemRed
                cell.detailTextLabel?.text=L("文件损坏，无法加载。")
                cell.accessoryType=pendingIDs.contains(item.id) ? .checkmark:.none
                cell.accessibilityIdentifier="mods.unavailable."+item.id.uuidString;cell.selectionStyle = .default
                return cell
            }
            let item=indexPath.row == 0 ? nil : ready[indexPath.row-1]
            cell.textLabel?.text=item?.name ?? L("停用 MOD（原版游戏）")
            cell.detailTextLabel?.text=nil
            cell.accessoryType = (item.map{pendingIDs.contains($0.id)} ?? pendingIDs.isEmpty) ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityIdentifier="mods.ready."+(item?.id.uuidString ?? "off")
        } else {
            cell.textLabel?.text=status;cell.accessibilityIdentifier="mods.status"
            cell.detailTextLabel?.text=nil
            if operation != nil {
                let bar=UIProgressView(progressViewStyle:.default);bar.progress=fraction
                bar.frame=CGRect(x:0,y:0,width:100,height:8);bar.accessibilityIdentifier="mods.installProgress"
                cell.accessoryView=bar
            }
        }
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        guard operation == nil && !selecting else { return }
        if indexPath.section == 0 && indexPath.row == 1 {browse()}
        else if indexPath.section == 0 && indexPath.row == 4 {verifyPackages()}
        else if indexPath.section == 0 && indexPath.row > 1 { pick(directory:indexPath.row == 3) }
        else if indexPath.section == 2 && !records.isEmpty { showRecord(records[indexPath.row]) }
        else if indexPath.section == 3 && !downloads.isEmpty {inspect(ResourceAccess(downloads[indexPath.row]))}
        else if indexPath.section == 1 {
            do {
                if indexPath.row==0 {pendingIDs=[]}
                else if indexPath.row<=ready.count {
                    let id=ready[indexPath.row-1].id
                    if let i=pendingIDs.firstIndex(of:id){pendingIDs.remove(at:i)}else{guard pendingIDs.count<16 else {throw ModPackageError.limitExceeded};pendingIDs.append(id)}
                }
                else {
                    let item=unavailable[indexPath.row-ready.count-1]
                    pendingIDs.removeAll{$0==item.id}
                    status=L("文件损坏，无法加载。");tableView.reloadData();return
                }
                status=LF("已选择 %d 个 MOD",pendingIDs.count)
            } catch {status=Self.userMessage(error)}
            tableView.reloadSections(IndexSet(integer:1),with:.none)
            tableView.reloadSections(IndexSet(integer:4),with:.none)
        }
    }
    private func browse() {
        let browser=ModDownloadBrowser()
        browser.onImport={ [weak self] url in self?.inspect(ResourceAccess(url)) }
        let panel=UINavigationController(rootViewController:browser);panel.modalPresentationStyle = .fullScreen
        present(panel,animated:true)
    }
    private func updateBusyState() {
        let busy=operation != nil || selecting
        navigationItem.prompt=operation == nil ? nil : status.components(separatedBy:"\n").first
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        navigationItem.leftBarButtonItem = operation == nil ? nil : UIBarButtonItem(title:L("取消"),style:.plain,target:self,action:#selector(cancelInspection))
        isModalInPresentation=busy;navigationController?.isModalInPresentation=busy
        tableView.reloadData()
    }
    private func verifyPackages() {
        let items=ready+unavailable.compactMap(\.item)
        let unreadable=unavailable.filter{$0.item==nil}.map(\.name)
        guard !items.isEmpty else {status=unreadable.isEmpty ? L("没有可校验的 MOD。") : LF("这些 MOD 无法加载：%@",unreadable.joined(separator:"、"));tableView.reloadData();return}
        let catalog=RuntimeModCatalog.current,progress=Progress(totalUnitCount:1)
        operation=progress;fraction=0;status=L("正在校验 MOD…");updateBusyState()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var failures=unreadable
            for item in items {
                if progress.isCancelled {break}
                do {
                    try catalog.verifyFully(item,progress:progress) {completed,total in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else{return}
                            self.status=L("正在校验 MOD…")+"\n"+item.name
                            self.fraction=total>0 ? Float(Double(completed)/Double(total)):0
                            self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                        }
                    }
                } catch {if !progress.isCancelled {failures.append(item.name)}}
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else{return};self.operation=nil
                self.status=progress.isCancelled ? L("已取消校验。") : failures.isEmpty ? L("文件校验通过。") : LF("这些 MOD 无法加载：%@",failures.joined(separator:"、"))
                self.updateBusyState();self.reloadRecords()
            }
        }
    }
    static func userMessage(_ error:Error)->String {
        if let e=error as? ModLoadError {
            if case .conflict(let names)=e {return LF("这些 MOD 不能同时加载：%@",names)}
            return L(e.localizedDescription)
        }
        if let e=error as? ModPackageError {return L(e.localizedDescription)}
        return L("MOD 加载失败，请重新导入或减少启用数量。")
    }
    @objc private func closePanel() {
        guard operation == nil && !selecting else{return}
        let catalog=RuntimeModCatalog.current
        let selection=pendingIDs
        if selection.isEmpty {catalog.select(nil);dismiss(animated:true,completion:onClose);return}
        let progress=Progress(totalUnitCount:8);operation=progress;status=L("正在加载 MOD…");fraction=0;updateBusyState()
        statusTimer=Timer.scheduledTimer(withTimeInterval:0.15,repeats:true){[weak self] _ in
            guard let self else{return};self.fraction=Float(progress.fractionCompleted);self.tableView.reloadSections(IndexSet(integer:4),with:.none)
        }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=Result<Void,Error> {
                let access=try ResourceLibrary.open();let layout=try ResourceLayout.locate(access.root)
                _=try ModComposition.prepare(catalog.resolve(selection),catalog:catalog,base:layout.rom,dlc:layout.dlc,
                    root:ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Compositions",isDirectory:true),progress:progress)
                withExtendedLifetime(access){}
            }
            DispatchQueue.main.async {
                guard let self else{return};self.statusTimer?.invalidate();self.statusTimer=nil;self.operation=nil;self.updateBusyState()
                switch result {
                case .success:catalog.select(values:selection);self.dismiss(animated:true,completion:self.onClose)
                case .failure(let error):
                    self.status=Self.userMessage(error);self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                    let alert=UIAlertController(title:L("无法加载 MOD"),message:self.status,preferredStyle:.alert)
                    alert.addAction(UIAlertAction(title:L("确定"),style:.default));self.present(alert,animated:true)
                }
            }
        }
    }
    @objc private func cancelInspection() { operation?.cancel();navigationItem.leftBarButtonItem?.isEnabled=false }
    private func pick(directory:Bool) {
        selecting=true;updateBusyState()
        #if targetEnvironment(macCatalyst)
        guard let url=Bundle.main.builtInPlugInsURL?.appendingPathComponent("PJDVMacLifecycle.bundle"),
              let bundle=Bundle(url:url),bundle.load(),let entry=bundle.principalClass as? MacFileSelectionPlugin.Type else {
            selecting=false;status=L("Mac 文件选择组件不可用，请重新安装完整的 App。");updateBusyState();return
        }
        entry.chooseLocalItem(withTitle:L(directory ? "添加 MOD 文件夹" : "添加 ZIP 包"),directory:directory) { [weak self] url in
            self?.selected(url)
        }
        #else
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:directory ? [.folder] : [.zip,.item],asCopy:false)
        picker.allowsMultipleSelection=false;picker.shouldShowFileExtensions=true;picker.delegate=self
        picker.modalPresentationStyle = .fullScreen;present(picker,animated:true)
        #endif
    }
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) { finishPicker(controller,url:nil) }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) { finishPicker(controller,url:urls.first) }
    private func finishPicker(_ controller:UIDocumentPickerViewController,url:URL?) {
        let access=url.map{ResourceAccess($0)}
        controller.dismiss(animated:true) { [weak self,access] in self?.selected(access?.root,retaining:access) }
    }
    private func selected(_ url:URL?,retaining access:ResourceAccess?=nil) {
        selecting=false
        guard let url else { status=L("已取消选择；没有开始检查。");updateBusyState();return }
        inspect(access ?? ResourceAccess(url))
    }
    private func inspect(_ access:ResourceAccess) {
        let progress=Progress(totalUnitCount:1);operation=progress;fraction=0
        status=L("正在检查 MOD 结构…");updateBusyState()
        let registry=self.registry
        let started=Date()
        DispatchQueue.global(qos:.utility).async { [weak self,access] in
            let result=Result<Bool,Error> {
                let coordinator=NSFileCoordinator(filePresenter:nil)
                var coordinationError:NSError?, installed:Result<InstalledMod,Error>?
                coordinator.coordinate(readingItemAt:access.root,options:.withoutChanges,error:&coordinationError) { url in
                    installed=Result {try ModInstaller.install(url,under:ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Installed",isDirectory:true),progress:progress) {update in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else{return}
                            let bytes=ByteCountFormatter.string(fromByteCount:Int64(update.completed),countStyle:.file)
                            let total=ByteCountFormatter.string(fromByteCount:Int64(update.total),countStyle:.file)
                            let speed=ByteCountFormatter.string(fromByteCount:Int64(Double(update.completed)/max(1,Date().timeIntervalSince(started))),countStyle:.file)
                            self.status=L(update.phase)+"\n"+update.file+"\n"+bytes+" / "+total+" · "+speed+"/s"
                            self.fraction=update.total>0 ? Float(Double(update.completed)/Double(update.total)) : 0
                            self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                        }
                    }}
                }
                if let error=coordinationError { throw error }
                guard let installed else { throw ModPackageError.invalidZIP }
                let package=try installed.get()
                do {
                    if progress.isCancelled {throw ModPackageError.cancelled}
                    if try RuntimeModCatalog.current.adoptPrepared(from:package.root,progress:progress,report:{ completed,total in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.status=L("正在校验已适配包…")+"\n"+ByteCountFormatter.string(fromByteCount:Int64(completed),countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:Int64(total),countStyle:.file)
                            self.fraction=total>0 ? Float(Double(completed)/Double(total)) : 0
                            self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                        }
                    }) != nil { return true }
                    let profileURL=Bundle.main.url(forResource:"PCModelProfiles",withExtension:"json")
                    if let profileURL,let candidate=try PCModelConverter.recognize(package.root,profiles:PCModelConverter.profiles(profileURL),progress:progress,report:{update in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else{return};self.status=L(update.phase)
                            self.fraction=update.total>0 ? Float(Double(update.completed)/Double(update.total)):0
                            self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                        }
                    }) {
                        let resources=try ResourceLibrary.open(),layout=try ResourceLayout.locate(resources.root)
                        _=try PCModelConverter.convert(candidate,base:layout.rom,dlc:layout.dlc,catalog:RuntimeModCatalog.current,progress:progress) {update in
                            DispatchQueue.main.async { [weak self] in
                                guard let self else{return};self.status=L(update.phase)
                                self.fraction=update.total>0 ? Float(Double(update.completed)/Double(update.total)):0
                                self.tableView.reloadSections(IndexSet(integer:4),with:.none)
                            }
                        }
                        withExtendedLifetime(resources){}
                        // Only this importer's private copy is removed. The
                        // selected ZIP/folder, installed MODs and saves survive.
                        try? FileManager.default.removeItem(at:package.root)
                        return true
                    }
                    try registry.register(package.root,inspection:package.inspection,name:package.name)
                    return false
                } catch {try? FileManager.default.removeItem(at:package.root);throw error}
            }
            DispatchQueue.main.async { [weak self,access] in
                guard let self else { return }
                self.operation=nil
                switch result {
                case .success(let prepared):self.status=L(prepared ? "MOD 已导入。" : "此包目前不能加载。")
                case .failure(let error):self.status=L(error.localizedDescription)
                }
                self.updateBusyState();self.reloadRecords()
                withExtendedLifetime(access) {}
            }
        }
    }
    private func showRecord(_ record:ModRegistration) {
        let alert=UIAlertController(title:record.name,message:L("此包目前不能加载。"),preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:L("重新导入"),style:.default) { [weak self] _ in
            guard let self else{return}
            do { self.inspect(ResourceAccess(try self.registry.source(record))) }
            catch { self.status=L("MOD 源位置不可用，请重新添加。");self.tableView.reloadData() }
        })
        alert.addAction(UIAlertAction(title:L("移除登记（保留原文件）"),style:.destructive) { [weak self] _ in
            guard let self else{return}
            do { try self.registry.remove(record);self.status=L("已移除登记，原文件保持不变。");self.reloadRecords() }
            catch { self.status=L(error.localizedDescription);self.tableView.reloadData() }
        })
        alert.addAction(UIAlertAction(title:L("取消"),style:.cancel));present(alert,animated:true)
    }
}
