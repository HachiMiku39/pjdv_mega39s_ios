import UIKit
import UniformTypeIdentifiers

// Launcher-only downloads/imports. Resource installation is separate from
// runtime compatibility: importing never executes a PC DLL or unknown patch.
final class ModImportController: UITableViewController, UIDocumentPickerDelegate {
    private let registry = ModRegistry(root: ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Registrations", isDirectory: true))
    private var records = [ModRegistration]()
    private var downloads = [URL]()
    private var operation: Progress?
    private var selecting = false
    private var fraction:Float=0
    private var status = L("ZIP／文件夹可导入；7z、RAR 请先解压。")
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override func viewDidLoad() {
        super.viewDidLoad()
        title=L("MOD 管理（实验）")
        preferredContentSize=CGSize(width:720,height:600)
        tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=64
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:L("完成"),style:.done,target:self,action:#selector(closePanel))
        reloadRecords()
    }
    private func reloadRecords() {
        do { records=try registry.records() }
        catch { status=L(error.localizedDescription) }
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
    override func numberOfSections(in tableView:UITableView)->Int { 4 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {
        section == 0 ? 4 : section == 1 ? max(1,records.count) : section == 2 ? max(1,downloads.count) : 1
    }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {
        L(section == 0 ? "添加 MOD" : section == 1 ? "已登记（未启用）" : section == 2 ? "已下载的压缩包" : "检查结果")
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int)->String? {
        section == 0 ? L("目前仅测试过模型和歌曲两类 MOD，不保证所有同类包兼容。") : section == 1 ? L("导入与游戏内适配分开处理；含新增数据库或程序插件的包不会自动启用。") : section == 2 ? L("下载文件会保留，轻点可重新导入；7z／RAR 需先解压。") : nil
    }
    private func kind(_ result:ModInspection)->String {
        switch result.kind {
        case .layeredFS:return L("Switch RomFS 资源覆盖")
        case .pluginAssets:return L("MikuMikuSwitchPlugin／DML 包")
        case .mixedAssets:return L("资源覆盖＋插件包")
        case .codeOnly:return L("仅代码补丁")
        }
    }
    private func summary(_ result:ModInspection)->String {
        let bytes=ByteCountFormatter.string(fromByteCount:Int64(result.expandedBytes),countStyle:.file)
        var lines=[kind(result),LF("未启用 · %d 个文件 · %@",result.fileCount,bytes)]
        if result.contentIntegrityChecked {lines.append(L("ZIP 内容 CRC 校验通过。"))}
        if result.containsCode { lines.append(L("包含程序补丁或插件，当前不支持执行。")) }
        if result.declaredTitleIDs.contains(where:{$0 != "0100F3100DA46000"}) { lines.append(L("其他地区的资源，运行兼容性待验证。")) }
        if result.containsDatabases { lines.append(L("含新增内容数据库，仍需游戏内适配。")) }
        if result.unusualCompression { lines.append(L("特殊 ZIP 压缩方式，使用前需先解压。")) }
        return lines.joined(separator:"\n")
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
                cell.textLabel?.text=L(indexPath.row == 1 ? "浏览／下载 MOD（GameBanana）" : indexPath.row == 2 ? "添加 ZIP 包" : "添加 MOD 文件夹")
                cell.accessibilityIdentifier=indexPath.row == 1 ? "mods.browse" : indexPath.row == 2 ? "mods.addZIP" : "mods.addFolder"
                cell.textLabel?.textColor=operation == nil && !selecting ? .systemBlue : .secondaryLabel
                cell.selectionStyle = .default
            }
        } else if indexPath.section == 1 {
            if records.isEmpty { cell.textLabel?.text=L("尚未登记 MOD。");cell.accessibilityIdentifier="mods.empty" }
            else {
                let record=records[indexPath.row]
                cell.textLabel?.text=record.name;cell.detailTextLabel?.text=summary(record.inspection)
                cell.accessibilityIdentifier="mods.record."+record.id.uuidString
                cell.accessoryType = .disclosureIndicator;cell.selectionStyle = .default
            }
        } else if indexPath.section == 2 {
            if downloads.isEmpty {cell.textLabel?.text=L("暂无已下载的 MOD 压缩包。")}
            else {
                let file=downloads[indexPath.row];cell.textLabel?.text=file.lastPathComponent
                cell.detailTextLabel?.text=L("重新导入");cell.textLabel?.textColor = .systemBlue
                cell.accessibilityIdentifier="mods.download."+file.deletingLastPathComponent().lastPathComponent
                cell.accessoryType = .disclosureIndicator;cell.selectionStyle = .default
            }
        } else {
            cell.textLabel?.text=status;cell.accessibilityIdentifier="mods.status"
            cell.detailTextLabel?.text=L("采用分块解压和独立安装目录，不改动原游戏资源。运行兼容性需另行验证。")
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
        else if indexPath.section == 0 && indexPath.row > 1 { pick(directory:indexPath.row == 3) }
        else if indexPath.section == 1 && !records.isEmpty { showRecord(records[indexPath.row]) }
        else if indexPath.section == 2 && !downloads.isEmpty {inspect(ResourceAccess(downloads[indexPath.row]))}
    }
    private func browse() {
        let browser=ModDownloadBrowser()
        browser.onImport={ [weak self] url in self?.inspect(ResourceAccess(url)) }
        let panel=UINavigationController(rootViewController:browser);panel.modalPresentationStyle = .fullScreen
        present(panel,animated:true)
    }
    private func updateBusyState() {
        let busy=operation != nil || selecting
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        navigationItem.leftBarButtonItem = operation == nil ? nil : UIBarButtonItem(title:L("取消检查"),style:.plain,target:self,action:#selector(cancelInspection))
        isModalInPresentation=busy;navigationController?.isModalInPresentation=busy
        tableView.reloadData()
    }
    @objc private func closePanel() { guard operation == nil && !selecting else{return};dismiss(animated:true) }
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
            let result=Result<Void,Error> {
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
                            self.tableView.reloadSections(IndexSet(integer:3),with:.none)
                        }
                    }}
                }
                if let error=coordinationError { throw error }
                guard let installed else { throw ModPackageError.invalidZIP }
                let package=try installed.get()
                do {
                    if progress.isCancelled {throw ModPackageError.cancelled}
                    try registry.register(package.root,inspection:package.inspection,name:package.name)
                } catch {try? FileManager.default.removeItem(at:package.root);throw error}
            }
            DispatchQueue.main.async { [weak self,access] in
                guard let self else { return }
                self.operation=nil
                switch result {
                case .success:self.status=L("MOD 已导入独立目录；游戏内适配与启用尚需验证。")
                case .failure(let error):self.status=L(error.localizedDescription)
                }
                self.updateBusyState();self.reloadRecords()
                withExtendedLifetime(access) {}
            }
        }
    }
    private func showRecord(_ record:ModRegistration) {
        let alert=UIAlertController(title:record.name,message:summary(record.inspection)+"\n\n"+L("导入与游戏内适配分开处理；含新增数据库或程序插件的包不会自动启用。"),preferredStyle:.alert)
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
