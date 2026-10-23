import UIKit

final class StickLayoutController: UIViewController {
    private var profile: String
    private var drafts: [String: StickLayout] = [:]
    private let pad = VirtualPad(input: InputStore())
    private let preview = UIView(), hitLayer = UIView()
    private let profileButton = UIButton(type: .system)
    private let side = UISegmentedControl(items: [L("左摇杆"), L("右摇杆")])
    private let slider = UISlider(), sizeLabel = UILabel(), positionLabel = UILabel()
    init(profile: String) { self.profile = profile; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic controller") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    private var layout: StickLayout {
        get { drafts[profile] ?? StickLayout.load(profile) }
        set { drafts[profile] = newValue.sanitized }
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = L("摇杆大小与位置"); title.font = .boldSystemFont(ofSize: 22)
        profileButton.showsMenuAsPrimaryAction = true; profileButton.accessibilityIdentifier = "padEditor.profile"
        side.selectedSegmentIndex = 0; side.addTarget(self, action: #selector(refresh), for: .valueChanged)
        slider.minimumValue = 0.4; slider.maximumValue = 1.5
        slider.accessibilityIdentifier = "padEditor.size"; slider.addTarget(self, action: #selector(resize), for: .valueChanged)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        positionLabel.accessibilityIdentifier = "padEditor.position"
        let help = UILabel(); help.text = L("拖动预览区调整所选摇杆的位置。"); help.font = .systemFont(ofSize: 12); help.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [profileButton, side]); row.distribution = .fillEqually; row.spacing = 16
        let sizes = UIStackView(arrangedSubviews: [sizeLabel, slider, positionLabel]); sizes.spacing = 12
        let header = UIStackView(arrangedSubviews: [title, row, sizes, help]); header.axis = .vertical; header.spacing = 8
        preview.backgroundColor = UIColor(white: 0.07, alpha: 1); preview.layer.cornerRadius = 12
        preview.addSubview(pad); preview.addSubview(hitLayer)
        hitLayer.accessibilityIdentifier = "padEditor.dragArea"
        hitLayer.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveStick(_:))))
        func button(_ title: String, _ id: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system); b.setTitle(L(title), for: .normal); b.accessibilityIdentifier = id
            b.addTarget(self, action: action, for: .touchUpInside); return b
        }
        let actions = UIStackView(arrangedSubviews: [button("取消", "padEditor.cancel", #selector(cancel)), button("恢复默认", "padEditor.reset", #selector(reset)), button("保存", "padEditor.save", #selector(save))]); actions.distribution = .fillEqually
        [header, preview, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: header.leadingAnchor), preview.trailingAnchor.constraint(equalTo: header.trailingAnchor), preview.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), preview.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor), actions.trailingAnchor.constraint(equalTo: header.trailingAnchor), actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8), actions.heightAnchor.constraint(equalToConstant: 36)])
        refresh()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); pad.frame = preview.bounds.insetBy(dx: 12, dy: 8); hitLayer.frame = preview.bounds }
    @objc private func refresh() {
        let config = layout, p = side.selectedSegmentIndex == 0 ? config.left : config.right
        slider.value = Float(p.scale); sizeLabel.text = LF("大小：%d%%", Int((p.scale * 100).rounded()))
        positionLabel.text = p.x.flatMap { x in p.y.map { y in String(format: "x %.0f%% · y %.0f%%", x * 100, y * 100) } } ?? "x — · y —"
        profileButton.setTitle(L(StickLayout.profiles.first { $0.0 == profile }?.1 ?? "普通手机"), for: .normal)
        profileButton.menu = UIMenu(children: StickLayout.profiles.map { key, label in
            UIAction(title: L(label), state: profile == key ? .on : .off) { [weak self] _ in self?.profile = key; self?.refresh() }
        })
        pad.layoutProfile = profile; pad.configurationOverride = config; pad.setNeedsLayout()
    }
    @objc private func resize() {
        var config = layout
        if side.selectedSegmentIndex == 0 { config.left.scale = Double(slider.value) } else { config.right.scale = Double(slider.value) }
        layout = config; refresh()
    }
    @objc private func moveStick(_ gesture: UIPanGestureRecognizer) {
        guard pad.bounds.width > 0, pad.bounds.height > 0 else { return }
        let point = gesture.location(in: pad); var config = layout
        if side.selectedSegmentIndex == 0 { config.left.x = point.x / pad.bounds.width; config.left.y = point.y / pad.bounds.height }
        else { config.right.x = point.x / pad.bounds.width; config.right.y = point.y / pad.bounds.height }
        layout = config; refresh()
    }
    @objc private func reset() { layout = .defaults(profile); refresh() }
    @objc private func cancel() { dismiss(animated: true) }
    @objc private func save() { for (key, value) in drafts { value.save(key) }; dismiss(animated: true) }
}
