import UIKit

/// Downloaded source archives remain available after installing or disabling a mod.
final class ModDownloadFilesController: UITableViewController {
    var onInstall: ((URL) -> Void)?
    var onBrowse: (() -> Void)?

    private var files = [ModInbox.Download]()
    private var refreshID = UUID()
    private var message: String?
    private lazy var emptyView: UIView = makeEmptyView()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("MOD 文件")
        view.tintColor = LauncherInterface.accent
        tableView.accessibilityIdentifier = "mods.files.list"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "GameBanana", style: .plain, target: self, action: #selector(browse))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "mods.files.browse"
        navigationItem.rightBarButtonItem?.accessibilityLabel = L("浏览／下载 MOD（GameBanana）")
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadFiles), for: .valueChanged)
        refreshControl = refresh
        NotificationCenter.default.addObserver(self, selector: #selector(reloadFiles), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadFiles()
    }

    @objc private func browse() { onBrowse?() }

    @objc private func reloadFiles() {
        let request = UUID()
        refreshID = request
        let root = ResourceLibrary.appDataRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ModInbox.downloads(under: root) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshID == request else { return }
                self.refreshControl?.endRefreshing()
                switch result {
                case .success(let downloads):
                    self.files = downloads
                    self.message = nil
                case .failure(let error):
                    self.message = L(error.localizedDescription)
                }
                self.tableView.backgroundView = self.files.isEmpty && self.message == nil ? self.emptyView : nil
                self.tableView.reloadData()
            }
        }
    }

    private func makeEmptyView() -> UIView {
        let background = UIView()
        let icon = UIImageView(image: UIImage(systemName: "tray", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)))
        icon.tintColor = LauncherInterface.accent
        icon.contentMode = .center
        icon.isAccessibilityElement = false
        let text = UILabel()
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = .secondaryLabel
        text.textAlignment = .center
        text.numberOfLines = 0
        text.text = L("暂无下载文件。打开 GameBanana 下载 MOD 后，可在这里安装和管理。")
        let content = UIStackView(arrangedSubviews: [icon, text])
        content.axis = .vertical
        content.spacing = 14
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            content.widthAnchor.constraint(lessThanOrEqualTo: background.layoutMarginsGuide.widthAnchor),
            text.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        return background
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { files.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        files.isEmpty ? nil : L("已下载的压缩包")
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let message { return message }
        guard !files.isEmpty else { return nil }
        return L("轻点 ZIP 或 RAR 安装。更多操作可导出或删除下载文件。")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let file = files[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: "archivebox")
        content.imageProperties.tintColor = LauncherInterface.accent
        content.text = file.url.lastPathComponent
        content.textProperties.numberOfLines = 0
        let size = ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
        let date = DateFormatter.localizedString(from: file.date, dateStyle: .short, timeStyle: .short)
        let ext = file.url.pathExtension.uppercased()
        content.secondaryText = [ext, size, date].joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "mods.files.archive." + file.url.lastPathComponent
        cell.accessibilityHint = L(ext == "7Z" ? "7z 请先解压，再添加 MOD 文件夹。" : "轻点安装")
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        more.frame.size = CGSize(width: 44, height: 44)
        more.accessibilityLabel = LF("%@ 的更多操作", file.url.lastPathComponent)
        more.accessibilityIdentifier = "mods.files.actions." + file.url.lastPathComponent
        var actions = [UIAction]()
        if ext != "7Z" {
            actions.append(UIAction(title: L("安装 MOD"), image: UIImage(systemName: "shippingbox")) { [weak self] _ in self?.install(file) })
        }
        actions.append(UIAction(title: L("导出文件"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.export(file) })
        actions.append(UIAction(title: L("删除下载文件"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmRemoval(file) })
        more.menu = UIMenu(children: actions)
        more.showsMenuAsPrimaryAction = true
        cell.accessoryView = more
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let file = files[indexPath.row]
        if file.url.pathExtension.lowercased() == "7z" {
            let alert = UIAlertController(title: file.url.lastPathComponent, message: L("7z 请先解压，再添加 MOD 文件夹。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("导出文件"), style: .default) { [weak self] _ in self?.export(file) })
            present(alert, animated: true)
        } else { install(file) }
    }

    private func install(_ file: ModInbox.Download) {
        do {
            try ModInbox.validateDownload(file.url, under: ResourceLibrary.appDataRoot)
            onInstall?(file.url)
        } catch { showError(error) }
    }

    private func export(_ file: ModInbox.Download) {
        do {
            try ModInbox.validateDownload(file.url, under: ResourceLibrary.appDataRoot)
            let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
            present(picker, animated: true)
        } catch { showError(error) }
    }

    private func confirmRemoval(_ file: ModInbox.Download) {
        let alert = UIAlertController(title: L("删除下载文件？"), message: LF("将删除“%@”的下载原档。已安装的 MOD 可以继续使用。", file.url.lastPathComponent), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除下载文件"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try ModInbox.removeDownload(file.url, under: ResourceLibrary.appDataRoot)
                self.reloadFiles()
            } catch { self.showError(error) }
        })
        present(alert, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: L("MOD 文件"), message: L(error.localizedDescription), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("确定"), style: .default))
        present(alert, animated: true)
        reloadFiles()
    }
}
