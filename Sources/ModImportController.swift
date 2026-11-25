import UIKit
import UniformTypeIdentifiers

extension RuntimeModCatalog {
    static var current: RuntimeModCatalog {
        let root=ModInbox.managedRoot(under:ResourceLibrary.appDataRoot).appendingPathComponent("Ready",isDirectory:true)
        #if targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.environment["PJDV_APP_DATA_TEST_ROOT"] != nil {
            // Developer trials may keep large packages on another volume while
            // transactional saves remain on APFS. Anchor validation at the
            // resolved catalog root; links inside individual packages stay rejected.
            let resolved=root.resolvingSymlinksInPath()
            if let defaults=UserDefaults(suiteName:"PJDV.ModTrial."+ModFormats.sha(Data(resolved.path.utf8))) {
                return RuntimeModCatalog(root:resolved,defaults:defaults)
            }
        }
        #endif
        return RuntimeModCatalog(root:root,defaults:.standard)
    }
}

// Launcher-only downloads/imports. Resource installation is separate from
// runtime compatibility: importing never executes a PC DLL or unknown patch.
final class ModImportController: UITableViewController, UIDocumentPickerDelegate {
    var onClose: (() -> Void)?
    private let registry = ModRegistry(root: ModInbox.managedRoot(under:ResourceLibrary.appDataRoot).appendingPathComponent("Registrations", isDirectory: true))
    private var records = [ModRegistration]()
    private var sources = [ModInbox.Entry]()
    private var ready = [RuntimeMod]()
    private var unavailable = [RuntimeModCatalog.Unavailable]()
    private var pendingIDs=[UUID]()
    private var operation: Progress?
    private var selecting = false
    private var statusTimer:Timer?
    private var fraction:Float=0
    private var status = ""
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override func viewDidLoad() {
        super.viewDidLoad()
        title=L("MOD 管理")
        pendingIDs=RuntimeModCatalog.current.selectedIDs
        preferredContentSize=CGSize(width:720,height:600)
        tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=64
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:L("加载"),style:.done,target:self,action:#selector(closePanel))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "mods.load"
        view.tintColor = LauncherInterface.accent
        navigationController?.navigationBar.tintColor = LauncherInterface.accent
        tableView.backgroundColor = .systemGroupedBackground
        configureActions()
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action:#selector(refreshSources), for:.valueChanged)
        refreshControl = refresh
        NotificationCenter.default.addObserver(self, selector:#selector(refreshSources), name:UIApplication.didBecomeActiveNotification, object:nil)
        updateBusyState()
        reloadRecords()
    }
    @objc private func refreshSources() {
        defer { refreshControl?.endRefreshing() }
        guard operation == nil && !selecting else { return }
        reloadRecords()
    }
    private func reloadRecords() {
        do { records=try registry.records() }
        catch { status=L(error.localizedDescription) }
        do {
            let inventory = try RuntimeModCatalog.current.inventory()
            ready = inventory.ready
            unavailable = inventory.unavailable
            let blocked = Set(unavailable.filter { $0.windowsRequirement != nil }.map(\.id))
            pendingIDs.removeAll { blocked.contains($0) }
        }
        catch { ready=[];unavailable=[];status=Self.userMessage(error) }
        do { sources = try ModInbox.sources(under:ResourceLibrary.appDataRoot, includingDownloads:false) }
        catch { status=L(error.localizedDescription) }
        updateSelection()
    }
    private enum Section: Int, CaseIterable {
        case add, status, ready, inbox, unavailable, verify
    }

    private var busy: Bool { operation != nil || selecting }
    private var actionAxis: NSLayoutConstraint.Axis {
        tableView.bounds.width >= 570 && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .horizontal : .vertical
    }
    private let actions = UIStackView()

    private func configureActions() {
        actions.spacing = 8
        let archive = actionButton(L("添加 ZIP 或 RAR 包"), symbol: "archivebox.fill", id: "mods.addZIP", primary: true) { [weak self] in
            self?.pick(directory: false)
        }
        let folder = actionButton(L("添加 MOD 文件夹"), symbol: "folder", id: "mods.addFolder") { [weak self] in
            self?.pick(directory: true)
        }
        let browser = actionButton("GameBanana", symbol: "safari", id: "mods.browse") { [weak self] in self?.browse() }
        browser.accessibilityLabel = L("浏览／下载 MOD（GameBanana）")
        for button in [archive, folder, browser] { actions.addArrangedSubview(button) }
        updateActionLayout()
    }

    private func actionButton(_ title: String, symbol: String, id: String, primary: Bool = false,
                              handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        LauncherInterface.style(button, symbol: symbol, primary: primary)
        if !primary {
            button.backgroundColor = .tertiarySystemGroupedBackground
            button.layer.cornerCurve = .continuous
            button.layer.cornerRadius = 12
        }
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateActionLayout()
    }

    private func updateActionLayout() {
        let axis = actionAxis
        actions.axis = axis
        actions.distribution = axis == .horizontal ? .fillEqually : .fill
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .add: return 2
        case .status: return status.isEmpty ? 0 : 1
        case .ready: return ready.count + 1
        case .inbox: return sources.count
        case .unavailable: return unavailable.count + records.count
        case .verify: return ready.isEmpty && unavailable.isEmpty ? 0 : 1
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard self.tableView(tableView, numberOfRowsInSection: section) > 0 else { return nil }
        switch Section(rawValue: section) {
        case .add: return L("添加 MOD")
        case .ready: return L("启用 MOD")
        case .inbox: return L("待导入的 MOD")
        case .unavailable: return L("暂不能加载")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .add: return L("支持资源型模型包和常规视频歌曲包；特殊玩法及插件需适配。")
        case .ready: return ready.isEmpty ? nil : L("可同时启用多个 MOD，加载时自动处理组合。")
        case .inbox where !sources.isEmpty: return L("将压缩包或解压后的单个 MOD 文件夹放入 mods，再轻点列表中的名称导入。")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        self.tableView(tableView, numberOfRowsInSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        self.tableView(tableView, numberOfRowsInSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == Section.add.rawValue && indexPath.row == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            cell.contentView.addSubview(actions)
            actions.translatesAutoresizingMaskIntoConstraints = false
            let guide = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                actions.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                actions.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                actions.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
                actions.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -4)
            ])
            return cell
        }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.tintColor = LauncherInterface.accent
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.imageProperties.tintColor = LauncherInterface.accent
        content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
        switch Section(rawValue: indexPath.section) {
        case .add:
            content.text = L("MOD 文件")
            content.image = UIImage(systemName: "folder.fill")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "mods.files"
        case .ready:
            let item = indexPath.row == 0 ? nil : ready[indexPath.row - 1]
            let selected = item.map { pendingIDs.contains($0.id) } ?? pendingIDs.isEmpty
            content.text = item?.name ?? L("停用 MOD（原版游戏）")
            content.image = UIImage(systemName: item == nil ? "gamecontroller" : "shippingbox")
            if selected {
                cell.accessoryType = .checkmark
                cell.accessibilityTraits.insert(.selected)
                cell.backgroundColor = LauncherInterface.accent.withAlphaComponent(0.10)
            }
            cell.accessibilityIdentifier = "mods.ready." + (item?.id.uuidString ?? "off")
        case .inbox:
            let source = sources[indexPath.row]
            let file = source.url
            content.text = file.lastPathComponent
            content.image = UIImage(systemName: source.isDirectory ? "folder" : "archivebox")
            cell.accessibilityIdentifier = "mods.inbox." + file.lastPathComponent
            content.secondaryText = L(source.isDirectory ? "文件夹 · 轻点导入" : "压缩包 · 轻点导入")
            cell.accessoryType = .disclosureIndicator
        case .unavailable:
            content.image = UIImage(systemName: "exclamationmark.circle")
            content.imageProperties.tintColor = .systemOrange
            if indexPath.row < unavailable.count {
                let item = unavailable[indexPath.row]
                content.text = item.name
                content.secondaryText = item.windowsRequirement.map(Self.windowsMessage) ?? L("文件损坏，无法加载。")
                cell.accessibilityIdentifier = "mods.unavailable." + item.id.uuidString
                cell.accessoryType = pendingIDs.contains(item.id) ? .checkmark : .none
            } else {
                let record = records[indexPath.row - unavailable.count]
                content.text = record.name
                content.secondaryText = record.windowsRequirement.map(Self.windowsMessage) ?? L("已登记，当前版本不能加载此包。")
                cell.accessibilityIdentifier = "mods.record." + record.id.uuidString
                cell.accessoryType = .disclosureIndicator
            }
        case .status:
            cell.accessibilityIdentifier = "mods.status"
            cell.selectionStyle = .none
            content.text = status
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.image = UIImage(systemName: operation == nil ? "info.circle" : "arrow.triangle.2.circlepath")
            if operation != nil {
                let progress = UIProgressView(progressViewStyle: .default)
                progress.frame.size.width = min(100, tableView.bounds.width * 0.16)
                progress.progress = fraction
                progress.accessibilityIdentifier = "mods.installProgress"
                cell.accessoryView = progress
            }
        case .verify:
            content.text = L("重新完整校验")
            content.image = UIImage(systemName: "checkmark.shield")
            cell.accessibilityIdentifier = "mods.verify"
            cell.accessoryType = .disclosureIndicator
        default: break
        }
        if busy && indexPath.section != Section.status.rawValue {
            cell.isUserInteractionEnabled = false
            cell.accessibilityTraits.insert(.notEnabled)
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        switch Section(rawValue: indexPath.section) {
        case .add:
            if indexPath.row == 1 { showFiles() }
        case .verify: verifyPackages()
        case .inbox:
            inspect(ResourceAccess(sources[indexPath.row].url))
        case .unavailable:
            if indexPath.row < unavailable.count {
                let item = unavailable[indexPath.row]
                pendingIDs.removeAll { $0 == item.id }
                presentImportNotice(item.windowsRequirement.map(Self.windowsMessage) ?? L("文件损坏，无法加载。"))
                updateSelection()
            } else { showRecord(records[indexPath.row - unavailable.count]) }
        case .ready:
            if indexPath.row == 0 { pendingIDs.removeAll() }
            else {
                let id = ready[indexPath.row - 1].id
                if let index = pendingIDs.firstIndex(of: id) { pendingIDs.remove(at: index) }
                else if pendingIDs.count < 16 { pendingIDs.append(id) }
                else { presentImportNotice(Self.userMessage(ModPackageError.limitExceeded)); return }
            }
            status = ""
            updateSelection()
        default: break
        }
    }

    private func updateSelection() {
        let apply = navigationItem.rightBarButtonItem
        apply?.title = pendingIDs.isEmpty ? L("加载") : L("加载") + " (\(pendingIDs.count))"
        apply?.accessibilityValue = LF("已选择 %d 个 MOD", pendingIDs.count)
        tableView.reloadData()
    }

    private func showFiles() {
        let files = ModDownloadFilesController(style: .insetGrouped)
        files.onInstall = { [weak self] url in self?.installDownload(url) }
        files.onBrowse = { [weak self] in self?.browse() }
        navigationController?.pushViewController(files, animated: true)
    }

    private func browse() {
        guard let navigationController, !busy, navigationController.presentedViewController == nil else { return }
        let browser = ModDownloadBrowser()
        browser.onImport = { [weak self] url in self?.installDownload(url) }
        let panel = UINavigationController(rootViewController: browser)
        panel.modalPresentationStyle = .fullScreen
        navigationController.present(panel, animated: true)
    }

    private func installDownload(_ url: URL) {
        guard !busy else { return }
        inspect(ResourceAccess(url))
    }
    private func presentImportNotice(_ message:String) {
        status=message
        tableView.reloadSections(IndexSet(integer: Section.status.rawValue),with:.none)
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert=UIAlertController(title:L("无法加载 MOD"),message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:L("确定"),style:.default));present(alert,animated:true)
    }
    private func updateBusyState() {
        let busy=operation != nil || selecting
        actions.arrangedSubviews.compactMap { $0 as? UIButton }.forEach { $0.isEnabled = !busy }
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        if operation == nil {
            let refresh=UIBarButtonItem(barButtonSystemItem:.refresh,target:self,action:#selector(refreshSources))
            refresh.accessibilityLabel=L("刷新 MOD 列表")
            refresh.accessibilityIdentifier="mods.refresh"
            refresh.isEnabled = !selecting
            navigationItem.leftBarButtonItem=refresh
        } else {
            navigationItem.leftBarButtonItem=UIBarButtonItem(title:L("取消"),style:.plain,target:self,action:#selector(cancelInspection))
        }
        isModalInPresentation=busy;navigationController?.isModalInPresentation=busy
        tableView.reloadData()
    }
    private func verifyPackages() {
        let items=ready+unavailable.compactMap(\.item)
        let unreadable=unavailable.filter{$0.item==nil && $0.windowsRequirement==nil}.map(\.name)
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
                            self.tableView.reloadSections(IndexSet(integer: Section.status.rawValue),with:.none)
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
    private static func windowsMessage(_ reason:ModWindowsRequirement)->String {
        switch reason {
        case .declaredPlugin(let name): return LF("此 MOD 需要 Windows 插件“%@”，无法加载。",name)
        case .executableOnly(let name): return LF("此 MOD 仅提供 Windows 程序“%@”，无法加载。",name)
        }
    }
    static func userMessage(_ error:Error)->String {
        if let reason=error as? ModWindowsRequirement { return windowsMessage(reason) }
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
            guard let self else{return};self.fraction=Float(progress.fractionCompleted);self.tableView.reloadSections(IndexSet(integer: Section.status.rawValue),with:.none)
        }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=Result<Void,Error> {
                let access=try ResourceLibrary.open();let layout=try ResourceLayout.locate(access.root)
                _=try ModComposition.prepare(catalog.resolve(selection),catalog:catalog,base:layout.rom,dlc:layout.dlc,
                    root:ModInbox.managedRoot(under:ResourceLibrary.appDataRoot).appendingPathComponent("Compositions",isDirectory:true),progress:progress)
                withExtendedLifetime(access){}
            }
            DispatchQueue.main.async {
                guard let self else{return};self.statusTimer?.invalidate();self.statusTimer=nil;self.operation=nil;self.updateBusyState()
                switch result {
                case .success:catalog.select(values:selection);self.dismiss(animated:true,completion:self.onClose)
                case .failure(let error):
                    self.status=Self.userMessage(error);self.tableView.reloadSections(IndexSet(integer: Section.status.rawValue),with:.none)
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
        entry.chooseLocalItem(withTitle:L(directory ? "添加 MOD 文件夹" : "添加 ZIP 或 RAR 包"),directory:directory) { [weak self] url in
            self?.selected(url)
        }
        #else
        let rar=UTType(filenameExtension:"rar") ?? UTType(importedAs:"com.rarlab.rar-archive")
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:directory ? [.folder] : [.zip,rar,.data],asCopy:false)
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
    private func inspect(_ access:ResourceAccess, retrying record:ModRegistration? = nil) {
        guard operation == nil else { return }
        let presenter = navigationController?.topViewController ?? self
        // A retry starts from a dismissing alert. Wait for that transition so
        // UIKit can attach the installation sheet to the visible controller.
        if let closing = presenter.presentedViewController, closing.isBeingDismissed,
           let transition = closing.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.inspect(access, retrying: record)
            }
            return
        }
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
        let progress = Progress(totalUnitCount: 1)
        let sheet = ModInstallationController(source: access.root.lastPathComponent, progress: progress)
        let panel = UINavigationController(rootViewController: sheet)
        panel.modalPresentationStyle = .formSheet
        panel.preferredContentSize = CGSize(width: 640, height: 460)
        panel.isModalInPresentation = true
        presenter.present(panel, animated: true)
        operation = progress
        fraction = 0
        status = L("正在检查 MOD 结构…")
        updateBusyState()
        let registry = self.registry
        let delivery = ModInstallDelivery(sheet)
        let report: (ModInstallUpdate) -> Void = delivery.submit
        DispatchQueue.global(qos:.utility).async { [weak self, weak sheet, access] in
            let result = Result<RuntimeMod?, Error> {
                if access.root.pathExtension.lowercased() == "7z",
                   (try? access.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                    throw ImportFailure.invalid(L("7z 请先解压，再添加 MOD 文件夹。"))
                }
                // DLC belongs to the base XCI import. MOD installation is a
                // separate workflow and must not write packages before a
                // complete, usable base has been selected.
                let baseAccess:ResourceAccess,baseLayout:ResourceLayout
                do {baseAccess=try ResourceLibrary.open();baseLayout=try ResourceLayout.locate(baseAccess.root)}
                catch {throw ImportFailure.invalid(L("请先使用 XCI 和 prod.keys 完成本体导入，再添加 MOD。"))}
                defer {withExtendedLifetime(baseAccess){}}
                let coordinator=NSFileCoordinator(filePresenter:nil)
                var coordinationError:NSError?, installed:Result<InstalledMod,Error>?
                coordinator.coordinate(readingItemAt:access.root,options:.withoutChanges,error:&coordinationError) { url in
                    installed = Result {
                        try ModInstaller.install(url, under: ModInbox.managedRoot(under: ResourceLibrary.appDataRoot)
                            .appendingPathComponent("Installed", isDirectory: true), progress: progress, report: report)
                    }
                }
                if let error=coordinationError { throw error }
                guard let installed else { throw ModPackageError.invalidZIP }
                let package=try installed.get()
                do {
                    if progress.isCancelled {throw ModPackageError.cancelled}
                    let catalog = RuntimeModCatalog.current
                    if let item = try catalog.adoptPrepared(from: package.root, progress: progress, activity: report) {
                        return item
                    }
                    if let item = try ModSwitchOverlay.adopt(package, base: baseLayout.rom, catalog: catalog,
                                                             progress: progress, activity: report) {
                        try? FileManager.default.removeItem(at: package.root)
                        return item
                    }
                    func registerUnsupported() throws -> RuntimeMod? {
                        // Retain the user's original source for retry. In particular, do not keep a second
                        // expanded copy of an archive that the runtime cannot use.
                        if record == nil {
                            try registry.register(access.root,inspection:package.inspection,name:package.name)
                        }
                        try FileManager.default.removeItem(at:package.root)
                        return nil
                    }
                    guard [.pluginAssets, .mixedAssets].contains(package.inspection.kind) else { return try registerUnsupported() }
                    let profileURL=Bundle.main.url(forResource:"PCModelProfiles",withExtension:"json")
                    let knownProfiles=try profileURL.map{try PCModelConverter.profiles($0)} ?? []
                    if let candidate = try PCModelConverter.recognize(package.root, profiles: knownProfiles, progress: progress, report: report)
                        ?? PCModelConverter.recognizeResourceModel(package.root, progress: progress, report: report) {
                        let converted = try PCModelConverter.convert(candidate, base: baseLayout.rom, dlc: baseLayout.dlc,
                            catalog: catalog, progress: progress, report: report)
                        try? FileManager.default.removeItem(at: package.root)
                        return converted.item
                    }
                    if let candidate = try PCSongConverter.recognize(package.root, progress: progress, report: report) {
                        let converted = try PCSongConverter.convert(candidate, base: baseLayout.rom, dlc: baseLayout.dlc,
                            catalog: catalog, progress: progress, report: report)
                        try? FileManager.default.removeItem(at: package.root)
                        return converted.item
                    }
                    return try registerUnsupported()
                } catch {try? FileManager.default.removeItem(at:package.root);throw error}
            }
            if let record {
                switch result {
                case .failure(let error as ModWindowsRequirement): try? registry.setWindowsRequirement(error,for:record)
                case .success(.some): try? registry.remove(record)
                case .success(nil): try? registry.setWindowsRequirement(nil,for:record)
                default: break
                }
            }
            DispatchQueue.main.async { [weak self, weak sheet, access] in
                guard let self, self.operation === progress else { return }
                delivery.flush()
                self.operation = nil
                switch result {
                case .success(let item?):
                    self.status = L("MOD 已导入。")
                    sheet?.finish(title: L("安装完成"), message: L("可在 MOD 管理中勾选并加载。"),
                                  installed: item, symbol: "checkmark.circle.fill", color: .systemGreen)
                case .success(nil):
                    self.status = L("已登记，当前版本不能加载此包。")
                    sheet?.finish(title: L("无法加载 MOD"), message: self.status,
                                  symbol: "exclamationmark.circle", color: .systemOrange)
                case .failure(let error):
                    let cancelled = progress.isCancelled
                    self.status = cancelled ? L("已取消安装") : Self.importMessage(error)
                    sheet?.finish(title: cancelled ? self.status : L("安装失败"), message: cancelled ? nil : self.status,
                                  symbol: cancelled ? "minus.circle" : "exclamationmark.triangle", color: .systemOrange)
                }
                self.updateBusyState()
                self.reloadRecords()
                withExtendedLifetime(access) {}
            }
        }
    }

    private static func importMessage(_ error: Error) -> String {
        if let reason = error as? ModWindowsRequirement { return windowsMessage(reason) }
        if let known = error as? LocalizedError, let message = known.errorDescription { return L(message) }
        let problem = error as NSError
        if problem.domain == NSCocoaErrorDomain && problem.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return L(ModInstallError.storage.localizedDescription)
        }
        return L("MOD 文件无法读取，请重新导入。")
    }

    private func showRecord(_ record:ModRegistration) {
        let message=record.windowsRequirement.map(Self.windowsMessage) ?? L("已登记，当前版本不能加载此包。")
        let alert=UIAlertController(title:record.name,message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title: L("重新导入"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let retry = { [weak self] in
                guard let self else { return }
                do { self.inspect(ResourceAccess(try self.registry.source(record)), retrying: record) }
                catch { self.status = L("MOD 源位置不可用，请重新添加。"); self.tableView.reloadData() }
            }
            if let alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true, completion: retry)
            } else { retry() }
        })
        alert.addAction(UIAlertAction(title:L("移除登记（保留原文件）"),style:.destructive) { [weak self] _ in
            guard let self else{return}
            do { try self.registry.remove(record);self.status=L("已移除登记，原文件保持不变。");self.reloadRecords() }
            catch { self.status=L(error.localizedDescription);self.tableView.reloadData() }
        })
        alert.addAction(UIAlertAction(title:L("取消"),style:.cancel));present(alert,animated:true)
    }
}

// The importer can report many files while UIKit is presenting the sheet.
// Keep the delivery queue bounded even if the main thread is temporarily busy.
private final class ModInstallDelivery {
    private let lock = NSLock()
    private var pending = [ModInstallUpdate]()
    private var scheduled = false
    private weak var sheet: ModInstallationController?

    init(_ sheet: ModInstallationController) { self.sheet = sheet }

    func submit(_ event: ModInstallUpdate) {
        lock.lock()
        if let last = pending.last, last.phase == event.phase,
           last.file == event.file, last.destination == event.destination {
            pending[pending.count - 1] = event
        } else {
            if pending.count == 48 { pending.removeFirst() }
            pending.append(event)
        }
        let notify = !scheduled
        scheduled = true
        lock.unlock()
        if notify { DispatchQueue.main.async { [weak self] in self?.flush() } }
    }

    @MainActor func flush() {
        lock.lock()
        let events = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        sheet?.receive(events)
    }
}

private final class ModInstallationController: UIViewController {
    private let source: String
    private let operation: Progress
    private let nameLabel = UILabel()
    private let phaseLabel = UILabel()
    private let amountLabel = UILabel()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let meter = UIProgressView(progressViewStyle: .default)
    private let console = UITextView()
    private var lines = [String]()
    private var stage = ""
    private var route = ""
    private var firstCount: UInt64 = 0
    private var phaseStart = ProcessInfo.processInfo.systemUptime
    private var finished = false

    init(source: String, progress: Progress) {
        self.source = source
        operation = progress
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("安装 MOD")
        view.accessibilityIdentifier = "mods.install.sheet"
        view.accessibilityViewIsModal = true
        view.backgroundColor = .systemGroupedBackground
        navigationController?.navigationBar.tintColor = LauncherInterface.accent
        let cancel = UIBarButtonItem(title: L("取消"), style: .plain, target: self, action: #selector(requestCancel))
        cancel.accessibilityIdentifier = "mods.install.cancel"
        navigationItem.leftBarButtonItem = cancel

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.text = Self.display(source)
        nameLabel.accessibilityIdentifier = "mods.install.package"
        phaseLabel.font = .preferredFont(forTextStyle: .body)
        phaseLabel.adjustsFontForContentSizeCategory = true
        phaseLabel.numberOfLines = 2
        phaseLabel.accessibilityIdentifier = "mods.install.phase"
        amountLabel.font = .preferredFont(forTextStyle: .footnote)
        amountLabel.adjustsFontForContentSizeCategory = true
        amountLabel.numberOfLines = 2
        amountLabel.textColor = .secondaryLabel
        amountLabel.isHidden = true
        icon.isHidden = true
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        spinner.color = LauncherInterface.accent
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        let status = UIStackView(arrangedSubviews: [spinner, icon, phaseLabel])
        status.alignment = .center
        status.spacing = 8
        meter.progressTintColor = LauncherInterface.accent
        meter.accessibilityIdentifier = "mods.install.progress"
        meter.isHidden = true

        console.backgroundColor = UIColor(red: 0.06, green: 0.08, blue: 0.10, alpha: 1)
        console.textColor = UIColor(white: 0.94, alpha: 1)
        console.layer.cornerRadius = 12
        console.layer.cornerCurve = .continuous
        console.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        console.adjustsFontForContentSizeCategory = true
        console.isEditable = false
        console.isSelectable = false
        console.isAccessibilityElement = true
        console.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        console.accessibilityLabel = L("安装记录")
        console.accessibilityIdentifier = "mods.install.log"
        let contents = UIStackView(arrangedSubviews: [nameLabel, status, meter, amountLabel, console])
        contents.axis = .vertical
        contents.spacing = 7
        contents.translatesAutoresizingMaskIntoConstraints = false
        console.setContentHuggingPriority(.defaultLow, for: .vertical)
        console.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for label in [nameLabel, phaseLabel, amountLabel] {
            label.setContentHuggingPriority(.required, for: .vertical)
        }
        view.addSubview(contents)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            contents.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            contents.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            contents.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12)
        ])
        stage = "正在检查 MOD 结构…"
        phaseLabel.text = L(stage)
        append(L(stage))
        renderLog()
    }

    private static func display(_ value: String) -> String {
        var clean = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        // Routes supplied by importers are relative and may include long archive names.
        // Fall back to the leaf if a file provider supplies an absolute display name.
        if clean.hasPrefix("/") { clean = (clean as NSString).lastPathComponent }
        return clean.count <= 240 ? clean : "…" + String(clean.suffix(239))
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        if lines.count >= 64 { lines.removeFirst() }
        lines.append(text)
    }

    private func renderLog() {
        let follow = console.contentOffset.y + console.bounds.height >= console.contentSize.height - 20
        console.text = lines.joined(separator: "\n")
        console.accessibilityValue = console.text
        if follow && !console.isDragging && !console.isDecelerating {
            let count = (console.text as NSString).length
            if count > 0 { console.scrollRangeToVisible(NSRange(location: count - 1, length: 1)) }
        }
    }

    func receive(_ events: [ModInstallUpdate]) {
        guard !events.isEmpty, !finished, !operation.isCancelled else { return }
        loadViewIfNeeded()
        var changed = false
        for update in events {
            if stage != update.phase {
                stage = update.phase
                route = ""
                firstCount = update.completed
                phaseStart = ProcessInfo.processInfo.systemUptime
                phaseLabel.text = L(stage)
                append(L(stage))
                changed = true
            }
            let from = Self.display(update.file)
            let to = Self.display(update.destination ?? "")
            let entry = [from, to].filter { !$0.isEmpty }.joined(separator: " → ")
            if !entry.isEmpty && route != entry {
                route = entry
                append("  " + entry)
                changed = true
            }
        }
        if changed { renderLog() }
        guard let update = events.last else { return }
        let measured = update.total > 0
        meter.isHidden = !measured
        amountLabel.isHidden = !measured
        guard measured else { return }
        let fraction = min(1, Double(update.completed) / Double(update.total))
        meter.progress = Float(fraction)
        if ["复制／校验 MOD", "解压／校验 MOD", "正在校验已适配包…", "正在校验 MOD…"].contains(update.phase) {
            func size(_ value: UInt64) -> String {
                ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
            }
            var amount = size(update.completed) + " / " + size(update.total)
            let elapsed = ProcessInfo.processInfo.systemUptime - phaseStart
            if elapsed >= 1 && update.completed > firstCount {
                amount += " · " + size(UInt64(Double(update.completed - firstCount) / elapsed)) + "/s"
            }
            amountLabel.text = amount
        } else {
            amountLabel.text = NumberFormatter.localizedString(from: NSNumber(value: fraction), number: .percent)
        }
    }

    @objc private func requestCancel() {
        guard !finished, !operation.isCancelled else { return }
        operation.cancel()
        navigationItem.leftBarButtonItem?.isEnabled = false
        phaseLabel.text = L("正在取消…")
    }

    func finish(title: String, message: String?, installed: RuntimeMod? = nil, symbol: String, color: UIColor) {
        loadViewIfNeeded()
        finished = true
        if let installed {
            let path = RuntimeModCatalog.current.directory(installed)
            let location = path.pathComponents.suffix(3).joined(separator: "/")
            append("  " + Self.display(source) + " → " + Self.display(location))
        }
        phaseLabel.text = title
        amountLabel.text = message
        amountLabel.isHidden = message == nil
        spinner.stopAnimating()
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = color
        icon.isHidden = false
        meter.isHidden = true
        append(title)
        if let message { append(message) }
        renderLog()
        navigationItem.leftBarButtonItem = nil
        let back = UIBarButtonItem(title: L("返回"), style: .done, target: self, action: #selector(close))
        back.accessibilityIdentifier = "mods.install.back"
        navigationItem.rightBarButtonItem = back
        navigationController?.isModalInPresentation = false
        UIAccessibility.post(notification: .layoutChanged, argument: phaseLabel)
    }

    @objc private func close() { dismiss(animated: true) }
}
