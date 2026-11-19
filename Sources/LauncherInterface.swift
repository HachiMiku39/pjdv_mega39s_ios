import UIKit

/// Shared launcher shell. Keep content opaque and reserve system materials for
/// navigation/controls. All actions are supplied by HostLaunchController.
final class LauncherInterface: UIView {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.25, green: 0.79, blue: 0.73, alpha: 1)
            : UIColor(red: 0.0, green: 0.43, blue: 0.40, alpha: 1)
    }
    private let sidebar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let scroll = UIScrollView()
    private let navigation = UIStackView()
    private let compactActions = UIStackView()
    private let content = UIStackView()
    private let preferences = UIStackView()
    private let hero = UIStackView()
    private let artwork = UIImageView(image: UIImage(named: "LauncherArtwork"))
    private let title = UILabel()
    private let resourceIcon = UIImageView(image: UIImage(systemName: "ellipsis.circle"))
    private let resourceStatus: UILabel
    private let resourceActions: [UIButton]
    private var wideConstraints = [NSLayoutConstraint]()
    private var narrowConstraints = [NSLayoutConstraint]()
    private var artworkSize: NSLayoutConstraint!
    private var wide: Bool?

    init(message: String, start: UIButton, resources: UIButton, mods: UIButton,
         quality: UIButton, language: UIButton, sticks: UIButton, autoplay: UIButton,
         experiments: UIButton, resourceStatus: UILabel, inboxStatus: UILabel, updates: UIButton) {
        self.resourceStatus = resourceStatus; resourceActions = [resources, mods]
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground; tintColor = Self.accent
        accessibilityIdentifier = "launcher.interface"

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)
        let identityImage = UIImageView(image: UIImage(named: "LauncherArtwork"))
        identityImage.layer.cornerRadius = 10; identityImage.clipsToBounds = true
        identityImage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([identityImage.widthAnchor.constraint(equalToConstant: 36), identityImage.heightAnchor.constraint(equalToConstant: 36)])
        let name = Self.label("PJDV M39", size: 17, weight: .semibold)
        let subtitle = Self.label("PROJECT DIVA", size: 10, color: .secondaryLabel)
        let brandText = UIStackView(arrangedSubviews: [name, subtitle]); brandText.axis = .vertical; brandText.spacing = 3
        let identity = UIStackView(arrangedSubviews: [identityImage, brandText]); identity.spacing = 10; identity.alignment = .center
        let home = UIButton(type: .system); home.setTitle(L("游戏主页"), for: .normal)
        Self.style(home, symbol: "play.square.stack.fill")
        home.backgroundColor = Self.accent.withAlphaComponent(0.12); home.layer.cornerRadius = 12
        home.accessibilityIdentifier = "launcher.home"
        home.addAction(UIAction { [weak self] _ in self?.scroll.setContentOffset(.zero, animated: !UIAccessibility.isReduceMotionEnabled) }, for: .touchUpInside)
        navigation.axis = .vertical; navigation.spacing = 6
        navigation.addArrangedSubview(home)
        let sidebarTitle = Self.label(L("资料库"), size: 11, weight: .semibold, color: .secondaryLabel)
        let sidebarContent = UIStackView(arrangedSubviews: [identity, sidebarTitle, navigation, UIView()])
        sidebarContent.axis = .vertical; sidebarContent.spacing = 20; sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        sidebar.contentView.addSubview(sidebarContent)
        NSLayoutConstraint.activate([
            sidebarContent.leadingAnchor.constraint(equalTo: sidebar.contentView.leadingAnchor, constant: 16),
            sidebarContent.trailingAnchor.constraint(equalTo: sidebar.contentView.trailingAnchor, constant: -16),
            sidebarContent.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 28),
            sidebarContent.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .onDrag
        addSubview(scroll)
        let body = UIView(); body.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(body)
        content.axis = .vertical; content.spacing = 20; content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        let maxWidth = content.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -64); maxWidth.priority = UILayoutPriority(999)
        let fitHeight = body.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor); fitHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), body.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            content.centerXAnchor.constraint(equalTo: body.centerXAnchor), content.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: body.topAnchor, constant: 28), content.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 920), content.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40), maxWidth, fitHeight
        ])

        let eyebrow = Self.label("PROJECT DIVA MEGA39’s", size: 11, weight: .semibold, color: .secondaryLabel)
        title.text = "PJDV M39"; title.textColor = .label
        title.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 40, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        let tagline = Self.label(L("属于你的节奏舞台。"), size: 16, color: .secondaryLabel)
        resourceStatus.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13))
        resourceStatus.adjustsFontForContentSizeCategory = true
        resourceStatus.textAlignment = .natural; resourceStatus.textColor = .secondaryLabel; resourceStatus.numberOfLines = 0
        resourceIcon.tintColor = .secondaryLabel; resourceIcon.contentMode = .scaleAspectFit
        resourceIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([resourceIcon.widthAnchor.constraint(equalToConstant: 17), resourceIcon.heightAnchor.constraint(equalToConstant: 17)])
        let statusRow = UIStackView(arrangedSubviews: [resourceIcon, resourceStatus]); statusRow.spacing = 7; statusRow.alignment = .top
        let intro = UIStackView(arrangedSubviews: [eyebrow, title, tagline, statusRow]); intro.axis = .vertical; intro.spacing = 8
        intro.setCustomSpacing(16, after: tagline)
        if !message.isEmpty { intro.addArrangedSubview(Self.label(message, size: 13, color: .secondaryLabel)) }
        Self.style(start, symbol: "play.fill", primary: true)
        start.accessibilityHint = L("使用当前资源与设置启动游戏")
        intro.addArrangedSubview(start); intro.setCustomSpacing(20, after: statusRow)
        artwork.layer.cornerRadius = 26; artwork.clipsToBounds = true; artwork.contentMode = .scaleAspectFill
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artworkSize = artwork.widthAnchor.constraint(equalToConstant: 152)
        NSLayoutConstraint.activate([artworkSize, artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor)])
        hero.addArrangedSubview(intro); hero.addArrangedSubview(artwork)
        hero.spacing = 32; hero.alignment = .center
        let heroCard = Self.panel(hero, inset: 28)
        content.addArrangedSubview(heroCard)

        resources.setTitle(L("游戏资源"), for: .normal); resources.accessibilityHint = L("导入 XCI／资源管理")
        mods.setTitle(L("MOD 管理（实验）"), for: .normal)
        Self.style(resources, symbol: "externaldrive.fill"); Self.style(mods, symbol: "square.stack.3d.up.fill")
        compactActions.axis = .horizontal; compactActions.distribution = .fillEqually; compactActions.spacing = 10
        content.addArrangedSubview(compactActions)

        Self.style(quality, symbol: "slider.horizontal.3")
        Self.style(language, symbol: "globe")
        Self.style(sticks, symbol: "gamecontroller")
        Self.style(autoplay, symbol: "play.circle")
        experiments.setTitle(L("图形实验"), for: .normal)
        Self.style(experiments, symbol: "sparkles")
        let settings = Self.group(title: L("游戏设置"), buttons: [quality, language, sticks])
        let labs = Self.group(title: L("实验功能"), buttons: [autoplay, experiments])
        preferences.axis = .horizontal; preferences.alignment = .fill; preferences.distribution = .fillEqually; preferences.spacing = 16
        preferences.addArrangedSubview(settings); preferences.addArrangedSubview(labs)
        content.addArrangedSubview(preferences)

        inboxStatus.font = .preferredFont(forTextStyle: .caption1); inboxStatus.textColor = .secondaryLabel
        inboxStatus.adjustsFontForContentSizeCategory = true; inboxStatus.numberOfLines = 0; inboxStatus.textAlignment = .natural
        content.addArrangedSubview(inboxStatus)
        let version = Self.label(AppReleaseVersion.current.label, size: 11, color: .tertiaryLabel)
        version.setContentHuggingPriority(.required, for: .horizontal)
        updates.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        updates.titleLabel?.numberOfLines = 0; updates.titleLabel?.textAlignment = .right; updates.contentHorizontalAlignment = .right
        updates.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = UIStackView(arrangedSubviews: [version, updates]); footer.spacing = 20; footer.alignment = .center
        content.addArrangedSubview(footer)

        wideConstraints = [scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)]
        narrowConstraints = [scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)]
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo: leadingAnchor), sidebar.topAnchor.constraint(equalTo: topAnchor), sidebar.bottomAnchor.constraint(equalTo: bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 224), scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor), scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)])
        updateLayout(wide: false)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    override func layoutSubviews() {
        let useSidebar = bounds.width >= 980 && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if wide != useSidebar { updateLayout(wide: useSidebar) }
        let compact = bounds.width < 620 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        preferences.axis = compact ? .vertical : .horizontal
        hero.axis = compact ? .vertical : .horizontal
        artworkSize.constant = compact ? 96 : (useSidebar ? 136 : 152)
        super.layoutSubviews()
    }
    private func updateLayout(wide: Bool) {
        NSLayoutConstraint.deactivate(wide ? narrowConstraints : wideConstraints)
        NSLayoutConstraint.activate(wide ? wideConstraints : narrowConstraints)
        sidebar.isHidden = !wide; compactActions.isHidden = wide
        for button in resourceActions {
            (button.superview as? UIStackView)?.removeArrangedSubview(button); button.removeFromSuperview()
            (wide ? navigation : compactActions).addArrangedSubview(button)
        }
        self.wide = wide
    }
    func resourceState(ready: Bool?, error: Bool = false) {
        resourceIcon.image = UIImage(systemName: ready == true ? "checkmark.circle.fill" : error ? "exclamationmark.circle.fill" : "ellipsis.circle")
        resourceIcon.tintColor = ready == true ? Self.accent : error ? .systemOrange : .secondaryLabel
        resourceStatus.textColor = error ? .secondaryLabel : ready == true ? Self.accent : .secondaryLabel
    }
    private static func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel {
        let label = UILabel(); label.text = text; label.textColor = color; label.numberOfLines = 0
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true; return label
    }
    private static func panel(_ child: UIView, inset: CGFloat) -> UIView {
        let panel = UIView(); panel.backgroundColor = .secondarySystemGroupedBackground
        panel.layer.cornerRadius = 24; panel.layer.cornerCurve = .continuous
        child.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -inset)])
        return panel
    }
    private static func group(title: String, buttons: [UIButton]) -> UIView {
        let heading = label(title, size: 12, weight: .semibold, color: .secondaryLabel)
        let stack = UIStackView(arrangedSubviews: [heading] + buttons); stack.axis = .vertical; stack.spacing = 4
        stack.setCustomSpacing(8, after: heading)
        return panel(stack, inset: 16)
    }
    private static func style(_ button: UIButton, symbol: String, primary: Bool = false) {
        button.tintColor = accent; button.contentHorizontalAlignment = primary ? .center : .leading
        button.titleLabel?.font = .systemFont(ofSize: primary ? 17 : 14, weight: primary ? .semibold : .medium)
        button.titleLabel?.numberOfLines = 0; button.titleLabel?.lineBreakMode = .byWordWrapping
        button.isPointerInteractionEnabled = true
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            var config: UIButton.Configuration
            if #available(iOS 26.0, macCatalyst 26.0, *), primary { config = .prominentGlass() }
            else { config = primary ? .filled() : .plain() }
            config.image = UIImage(systemName: symbol); config.imagePadding = 10
            config.titleLineBreakMode = .byWordWrapping
            config.titleAlignment = primary ? .center : .leading
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var text = incoming
                text.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: primary ? 17 : 14, weight: primary ? .semibold : .medium))
                return text
            }
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: primary ? 15 : 17, weight: .medium)
            config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)
            config.cornerStyle = primary ? .capsule : .medium
            config.baseForegroundColor = primary ? .white : .label
            config.baseBackgroundColor = primary ? UIColor(red: 0, green: 0.43, blue: 0.40, alpha: 1) : nil
            button.configuration = config
        } else {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            if primary { button.backgroundColor = UIColor(red: 0, green: 0.43, blue: 0.40, alpha: 1); button.setTitleColor(.white, for: .normal); button.layer.cornerRadius = 22 }
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: primary ? 48 : 44).isActive = true
    }
}
