import UIKit

final class StickLayoutController: UIViewController {
    private var profile: String
    private var drafts: [String: StickLayout] = [:]
    private let pad = VirtualPad(input: InputStore())
    private let preview = UIView(), hitLayer = UIView()
    private let profileButton = UIButton(type: .system)
    private let controlButton = UIButton(type: .system)
    private var selected = PadControl.leftStick
    private var dragging: PadControl?
    private var grabOffset = CGPoint.zero
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
        let title = UILabel(); title.text = L("虚拟按键大小与位置"); title.font = .boldSystemFont(ofSize: 22)
        profileButton.showsMenuAsPrimaryAction = true; profileButton.accessibilityIdentifier = "padEditor.profile"
        controlButton.showsMenuAsPrimaryAction = true
        controlButton.accessibilityIdentifier = "padEditor.control"
        slider.minimumValue = 0.4; slider.maximumValue = 1.5
        slider.accessibilityIdentifier = "padEditor.size"; slider.addTarget(self, action: #selector(resize), for: .valueChanged)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        positionLabel.accessibilityIdentifier = "padEditor.position"
        let help = UILabel(); help.text = L("点选或拖动任意摇杆／按键，使用滑块调整大小。"); help.font = .systemFont(ofSize: 12); help.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [profileButton, controlButton]); row.distribution = .fillEqually; row.spacing = 16
        func stepButton(_ delta: Int) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(delta < 0 ? "−" : "+", for: .normal); button.tag = delta
            button.accessibilityLabel = L(delta < 0 ? "缩小所选按键" : "放大所选按键")
            button.accessibilityIdentifier = delta < 0 ? "padEditor.smaller" : "padEditor.larger"
            button.addTarget(self, action: #selector(stepSize(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        let sizes = UIStackView(arrangedSubviews: [sizeLabel, stepButton(-1), slider, stepButton(1), positionLabel]); sizes.spacing = 8
        let header = UIStackView(arrangedSubviews: [title, row, sizes, help]); header.axis = .vertical; header.spacing = 8
        preview.backgroundColor = UIColor(white: 0.07, alpha: 1); preview.layer.cornerRadius = 12
        preview.addSubview(pad); preview.addSubview(hitLayer)
        hitLayer.accessibilityIdentifier = "padEditor.dragArea"
        hitLayer.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveControl(_:))))
        hitLayer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectControl(_:))))
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
        let config = layout, p = config.placement(for: selected)
        controlButton.setTitle(L("控件：") + L(selected.title), for: .normal)
        controlButton.menu = UIMenu(children: PadControl.allCases.map { control in
            UIAction(title: L(control.title), state: selected == control ? .on : .off) { [weak self] _ in
                self?.selected = control; self?.refresh()
            }
        })
        slider.value = Float(p.scale); sizeLabel.text = LF("大小：%d%%", Int((p.scale * 100).rounded()))
        positionLabel.text = p.x.flatMap { x in p.y.map { y in String(format: "x %.0f%% · y %.0f%%", x * 100, y * 100) } } ?? "x — · y —"
        profileButton.setTitle(L(StickLayout.profiles.first { $0.0 == profile }?.1 ?? "普通手机"), for: .normal)
        profileButton.menu = UIMenu(children: StickLayout.profiles.map { key, label in
            UIAction(title: L(label), state: profile == key ? .on : .off) { [weak self] _ in self?.profile = key; self?.refresh() }
        })
        pad.layoutProfile = profile; pad.configurationOverride = config; pad.highlightedControl = selected; pad.setNeedsLayout()
    }
    @objc private func resize() {
        var config = layout, p = layout.placement(for: selected)
        p.scale = Double(slider.value); config.setPlacement(p, for: selected)
        layout = config; refresh()
    }
    @objc private func stepSize(_ sender: UIButton) {
        slider.value = min(slider.maximumValue, max(slider.minimumValue, slider.value + Float(sender.tag) * 0.05))
        resize()
    }
    @objc private func selectControl(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: pad)
        if let control = pad.control(at: point) { selected = control }
        else if pad.bounds.contains(point), pad.bounds.width > 0, pad.bounds.height > 0 {
            var config = layout, p = config.placement(for: selected)
            p.x = point.x / pad.bounds.width; p.y = point.y / pad.bounds.height
            config.setPlacement(p, for: selected); layout = config
        }
        refresh()
    }
    @objc private func moveControl(_ gesture: UIPanGestureRecognizer) {
        guard pad.bounds.width > 0, pad.bounds.height > 0 else { return }
        let point = gesture.location(in: pad)
        if gesture.state == .began {
            let translation = gesture.translation(in: pad)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            dragging = pad.control(at: start)
            guard let dragging else { return }
            selected = dragging
            let frame = pad.controlFrame(dragging)
            grabOffset = CGPoint(x: start.x - frame.midX, y: start.y - frame.midY)
        }
        guard let dragging else { return }
        if gesture.state == .cancelled || gesture.state == .failed { self.dragging = nil; return }
        var config = layout, p = layout.placement(for: dragging)
        p.x = (point.x - grabOffset.x) / pad.bounds.width
        p.y = (point.y - grabOffset.y) / pad.bounds.height
        config.setPlacement(p, for: dragging); layout = config; refresh()
        if gesture.state == .ended { self.dragging = nil }
    }
    @objc private func reset() { layout = .defaults(profile); refresh() }
    @objc private func cancel() { dismiss(animated: true) }
    @objc private func save() { for (key, value) in drafts { value.save(key) }; dismiss(animated: true) }
}
