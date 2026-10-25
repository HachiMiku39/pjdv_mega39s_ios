import UIKit
import UniformTypeIdentifiers

// Launcher-only package registration. There is deliberately no enable/load action.
final class ModImportController: UITableViewController, UIDocumentPickerDelegate {
    private let registry = ModRegistry(root: ResourceLibrary.appDataRoot.appendingPathComponent("Mods/Registrations", isDirectory: true))
    private var records = [ModRegistration]()
    private var operation: Progress?
    private var selecting = false
    private var status = L("ZIP／文件夹可检查登记；7z、RAR 请先解压。")
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
        tableView.reloadData()
    }
    override func numberOfSections(in tableView:UITableView)->Int { 3 }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {
        section == 0 ? 3 : section == 1 ? max(1,records.count) : 1
    }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {
        L(section == 0 ? "添加 MOD" : section == 1 ? "已登记（未启用）" : "检查结果")
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int)->String? {
        section == 1 ? L("当前只登记文件位置与检查结果，不复制、不解压、不加载 MOD。") : nil
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
                cell.textLabel?.text=L("ZIP／文件夹可检查登记；7z、RAR 请先解压。")
                cell.textLabel?.font = .systemFont(ofSize:15)
            } else {
                cell.textLabel?.text=L(indexPath.row == 1 ? "添加 ZIP 包" : "添加 MOD 文件夹")
                cell.accessibilityIdentifier=indexPath.row == 1 ? "mods.addZIP" : "mods.addFolder"
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
        } else {
            cell.textLabel?.text=status;cell.accessibilityIdentifier="mods.status"
            cell.detailTextLabel?.text=L("仅检查目录结构，未校验文件内容或运行兼容性。")
            if operation != nil {let spinner=UIActivityIndicatorView(style:.medium);spinner.startAnimating();cell.accessoryView=spinner}
        }
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        guard operation == nil && !selecting else { return }
        if indexPath.section == 0 && indexPath.row > 0 { pick(directory:indexPath.row == 2) }
        else if indexPath.section == 1 && !records.isEmpty { showRecord(records[indexPath.row]) }
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
        let progress=Progress(totalUnitCount:1);operation=progress
        status=L("正在检查 MOD 结构…");updateBusyState()
        let registry=self.registry
        DispatchQueue.global(qos:.userInitiated).async { [weak self,access] in
            let result=Result<Void,Error> {
                let coordinator=NSFileCoordinator(filePresenter:nil)
                var coordinationError:NSError?, inspected:Result<ModInspection,Error>?
                coordinator.coordinate(readingItemAt:access.root,options:.withoutChanges,error:&coordinationError) { url in
                    inspected=Result { try ModPackageInspector.inspect(url,progress:progress) }
                }
                if let error=coordinationError { throw error }
                guard let inspected else { throw ModPackageError.invalidZIP }
                let report=try inspected.get()
                if progress.isCancelled { throw ModPackageError.cancelled }
                try registry.register(access.root,inspection:report)
            }
            DispatchQueue.main.async { [weak self,access] in
                guard let self else { return }
                self.operation=nil
                switch result {
                case .success:self.status=L("结构已识别，已登记；加载未启用。")
                case .failure(let error):self.status=L(error.localizedDescription)
                }
                self.updateBusyState();self.reloadRecords()
                withExtendedLifetime(access) {}
            }
        }
    }
    private func showRecord(_ record:ModRegistration) {
        let alert=UIAlertController(title:record.name,message:summary(record.inspection)+"\n\n"+L("仅检查目录结构，未校验文件内容或运行兼容性。"),preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:L("重新检查"),style:.default) { [weak self] _ in
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
