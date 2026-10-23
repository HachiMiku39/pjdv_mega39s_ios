import UIKit
import MetalKit
import GameController
import AVFAudio

@_silgen_name("pjdv_set_upscale_mode")
private func setUpscaleMode(_ mode: Int32)
@_silgen_name("pjdv_metalfx_supported")
private func metalFXSupported(_ device: UnsafeMutableRawPointer) -> Int32
@_silgen_name("pjdv_upscale_status")
private func upscaleStatus() -> Int32
@_silgen_name("pjdv_set_rt_stage_mode")
private func setRTStageMode(_ mode: Int32)
@_silgen_name("pjdv_rt_stage_mode")
private func rtStageMode() -> Int32
@_silgen_name("pjdv_rt_stage_status")
private func rtStageStatus() -> Int32
@_silgen_name("pjdv_rt_stage_supported")
private func rtStageSupported(_ device: UnsafeMutableRawPointer) -> Int32

@_silgen_name("pjdv_set_hdr_mode") private func setHDRMode(_ mode: Int32, _ headroom: Float)
@_silgen_name("pjdv_hdr_status") private func hdrStatus() -> Int32

@_silgen_name("pjdv_set_game_frame_generation") private func setGameFG(_ mode: Int32)
@_silgen_name("pjdv_game_frame_generation_mode") private func gameFGMode() -> Int32

// GPU family is separate from operating-system and feature availability.
private enum DeviceGraphicsProfile {
    static let policy: GameHardwarePolicy = {
        let detected: Int
        #if targetEnvironment(simulator)
        detected = 9 // Simulator reports a synthetic GPU; never a hardware qualification.
        #else
        let d = MTLCreateSystemDefaultDevice()
        detected = d?.supportsFamily(.apple9) == true ? 9 : d?.supportsFamily(.apple8) == true ? 8 : d?.supportsFamily(.apple7) == true ? 7 : 0
        #endif
        let cap = ProcessInfo.processInfo.environment["PJDV_GPU_FAMILY_CAP"].flatMap(Int.init)
        return GameHardwarePolicy(family: GameHardwarePolicy.cappedFamily(detected: detected, requested: cap))
    }()
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        window?.rootViewController?.supportedInterfaceOrientations ?? .landscape
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Main", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HostLaunchController()
        self.window = window
        window.makeKeyAndVisible()
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                NSLog("PJDV M39 landscape request: %@", error.localizedDescription)
            }
        }
    }
}

final class LabController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { duoPose == .tabletop ? .portrait : .landscape }
    override var shouldAutorotate: Bool { true }

    private let status = UILabel()
    private let input = InputStore()
    private var controllers: ControllerBridge?
    private var virtualPad: VirtualPad?
    private var duoPose = GameDisplayPolicy.DuoPose.ordinary
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var renderer: LabRenderer?
    private var metalView: MTKView?
    private var lastUpdate = 0.0
    private var sessionTimer: Timer?
    private var sessionHasStarted = false
    private var exitAlertVisible = false
    private var pendingExitError: Int32 = 0
    private var backgroundObserver: NSObjectProtocol?
    private let performance = PerformanceWindow(frame: .zero)
    private let padToggle = UIButton(type: .system)
    private let outputToggle = UIButton(type: .system)
    private var outputPreferenceKey: String { DeviceGraphicsProfile.policy.conservative ? "entryOutputResolution" : "outputResolution" }
    private var outputMode = UserDefaults.standard.string(forKey: DeviceGraphicsProfile.policy.conservative ? "entryOutputResolution" : "outputResolution") ?? "1080p"
    private var hdrEnabled = ProcessInfo.processInfo.environment["PJDV_GAME_HDR"] == "1" || UserDefaults.standard.bool(forKey: "gameHDREnabled")
    private var supportsHDR: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard DeviceGraphicsProfile.policy.allowsHDR else { return false }
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            return (view.window?.screen ?? UIScreen.main).potentialEDRHeadroom > 1
        }
        return false
        #endif
    }
    private var currentEDRHeadroom: Float {
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            return Float((view.window?.screen ?? UIScreen.main).currentEDRHeadroom)
        }
        return 1
    }
    private var supportsMetalFX = false
    private var supportsRTStage = false
    private var connectedControllers = 0
    private var virtualEnabled = UserDefaults.standard.object(forKey: "virtualPadEnabled") as? Bool ?? true
    private var guestStatus = "Guest image mapping pending"

    // The same fixed keyboard layout works on iPad hardware, Catalyst and Simulator.
    private var keyboardGeneration: [String: Int] = [:]
    private var heldKeyboardKeys = Set<String>()
    override var canBecomeFirstResponder: Bool { true }
    #if !targetEnvironment(macCatalyst)
    // This responder handles game controls, never text entry. UIKit may restore
    // it after a context menu closes; use a zero-height custom input view so
    // restoring hardware-keyboard focus cannot summon the software keyboard.
    private lazy var hardwareKeyboardInputView: UIView = UIView(frame: .zero)
    override var inputView: UIView? { hardwareKeyboardInputView }
    #endif
    private var keyboardDeleteToken: String {
        if #available(iOS 15.0, macCatalyst 15.0, *) { return UIKeyCommand.inputDelete }
        return "\u{7f}"
    }
    override var keyCommands: [UIKeyCommand]? {
        ["\r", "\u{8}", "\u{7f}", keyboardDeleteToken, " ", "a", "w", "s", "d", "q", "e", "p", "m", "i", "k", "j", "l", UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
         UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(simulatorKey(_:)))
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    private func keyboardButton(_ key: String) -> PadButtons? {
        // UIKit arrow tokens are case-sensitive identifiers, not letters.
        switch key {
        case UIKeyCommand.inputUpArrow: return .up
        case UIKeyCommand.inputDownArrow: return .down
        case UIKeyCommand.inputLeftArrow: return .left
        case UIKeyCommand.inputRightArrow: return .right
        default: break
        }
        switch key.lowercased() {
        case "d": return .a // Xbox B: east face button.
        case "s": return .b       // Xbox A: south face button.
        case "w": return .x       // Xbox Y: north face button.
        case "a": return .y       // Xbox X: west face button.
        case " ": return [.x, .y, .a, .b] // One chord source; release preserves separately held face keys.
        case "q": return .l
        case "e": return .r
        case "i": return .up
        case "k": return .down
        case "j": return .left
        case "l": return .right
        case "p", "\u{8}", "\u{7f}", keyboardDeleteToken: return .plus
        case "m", "\r", "\n": return .minus
        default: return nil
        }
    }
    @objc private func simulatorKey(_ command: UIKeyCommand) {
        guard let key = command.input, let button = keyboardButton(key), !heldKeyboardKeys.contains(key) else { return }
        let generation = (keyboardGeneration[key] ?? 0) + 1
        keyboardGeneration[key] = generation
        var state = PadState(); state.buttons = button
        input.update(source: "simulator-keyboard-" + key, state: state)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.keyboardGeneration[key] == generation, !self.heldKeyboardKeys.contains(key) else { return }
            self.input.remove(source: "simulator-keyboard-" + key)
        }
    }
    private func keyboardKey(_ press: UIPress) -> String? {
        guard let key = press.key else { return nil }
        switch key.keyCode {
        // Physical QWERTY positions keep Chinese IMEs and Caps Lock from
        // changing the bindings. ZL/ZR and both sticks have no keyboard binding.
        case .keyboardA: return "a"
        case .keyboardW: return "w"
        case .keyboardS: return "s"
        case .keyboardD: return "d"
        case .keyboardQ: return "q"
        case .keyboardE: return "e"
        case .keyboardP: return "p"
        case .keyboardM: return "m"
        case .keyboardI: return "i"
        case .keyboardK: return "k"
        case .keyboardJ: return "j"
        case .keyboardL: return "l"
        case .keyboardSpacebar: return " "
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward: return "\u{8}"
        case .keyboardReturnOrEnter, .keypadEnter: return "\r"
        case .keyboardUpArrow: return UIKeyCommand.inputUpArrow
        case .keyboardDownArrow: return UIKeyCommand.inputDownArrow
        case .keyboardLeftArrow: return UIKeyCommand.inputLeftArrow
        case .keyboardRightArrow: return UIKeyCommand.inputRightArrow
        default: return key.charactersIgnoringModifiers.lowercased()
        }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let modifiers = press.key?.modifierFlags,
               !modifiers.intersection([.command, .control, .alternate]).isEmpty {
                unhandled.insert(press); continue
            }
            guard let key = keyboardKey(press), let button = keyboardButton(key) else { unhandled.insert(press); continue }
            heldKeyboardKeys.insert(key)
            keyboardGeneration[key] = (keyboardGeneration[key] ?? 0) + 1
            var state = PadState(); state.buttons = button
            input.update(source: "simulator-keyboard-" + key, state: state)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    private func releaseKeyboardPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = keyboardKey(press), keyboardButton(key) != nil else { unhandled.insert(press); continue }
            heldKeyboardKeys.remove(key)
            keyboardGeneration[key] = (keyboardGeneration[key] ?? 0) + 1
            input.remove(source: "simulator-keyboard-" + key)
        }
        return unhandled
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeyboardPresses(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeyboardPresses(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.input.clear()
            self?.heldKeyboardKeys.removeAll()
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            status.text = "Metal device unavailable"
            showStatus()
            return
        }
        #if !targetEnvironment(simulator)
        guard DeviceGraphicsProfile.policy.supported else {
            status.text = "需要 Apple GPU family 7 或更新设备\niPhone A14 起；iPad／Mac M1 同代 GPU 起\n当前设备：\(device.name)"
            showStatus()
            return
        }
        #endif
        if ProcessInfo.processInfo.environment["PJDV_GAME_FG"] == "1" {
            hdrEnabled = false; outputMode = "1080p"; setGameFG(1)
        } else { setGameFG(0) }
        supportsMetalFX = metalFXSupported(Unmanaged.passUnretained(device as AnyObject).toOpaque()) != 0
        if UserDefaults.standard.string(forKey: outputPreferenceKey) == nil {
            outputMode = DeviceGraphicsProfile.policy.defaultOutput(phone: isPhone, metalFX: supportsMetalFX)
        }
        outputMode = GameDisplayPolicy.outputMode(outputMode, phone: isPhone, conservative: DeviceGraphicsProfile.policy.conservative)
        NSLog("PJDV GPU policy family=%d conservative=%d HDR=%d RT=%d output=%@", DeviceGraphicsProfile.policy.family,
              DeviceGraphicsProfile.policy.conservative ? 1 : 0, DeviceGraphicsProfile.policy.allowsHDR ? 1 : 0,
              DeviceGraphicsProfile.policy.allowsRayTracing ? 1 : 0, outputMode)
        NSLog("PJDV MetalFX available=%d", supportsMetalFX ? 1 : 0)
        supportsRTStage = DeviceGraphicsProfile.policy.allowsRayTracing && rtStageSupported(Unmanaged.passUnretained(device as AnyObject).toOpaque()) != 0
        let rtEnabled = ProcessInfo.processInfo.environment["PJDV_RT_STAGE"] == "1" || UserDefaults.standard.bool(forKey: "rtStageShadowEnabled")
        setRTStageMode(supportsRTStage && rtEnabled ? 1 : 0)
        input.onChange = { [weak input] in if let input { publishGuestInput(input.snapshot()) } }
        let canvas = TouchMetalView(device: device, input: input)
        controllers = ControllerBridge(input: input) { [weak self] count in
            self?.connectedControllers = count
            self?.updatePadVisibility()
        }
        canvas.preferredFramesPerSecond = 60
        canvas.colorPixelFormat = .bgra8Unorm
        canvas.clearColor = MTLClearColorMake(0.025, 0.04, 0.07, 1)
        view.addSubview(canvas)
        metalView = canvas
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self, self.isPhone else { return }
                let next: GameDisplayPolicy.DuoPose
                switch update.hinge?.status {
                case .closed: next = .folded
                case .partiallyOpen: next = .tabletop
                case .fullyOpen: next = .expanded
                default: next = .ordinary
                }
                guard next != self.duoPose else { return }
                self.input.clear(); self.virtualPad?.releaseButtons(); self.duoPose = next
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                self.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: next == .tabletop ? .portrait : .landscape))
                self.view.setNeedsLayout()
                NSLog("PJDV Duo pose=%@", next.rawValue)
            })
        }
        #endif
        attachGuestMetalLayer(Unmanaged.passUnretained(canvas.layer).toOpaque())
        do {
            renderer = try LabRenderer(device: device, view: canvas)
            renderer?.onFrame = { [weak self] frames, elapsed in
                guard let self, elapsed - self.lastUpdate >= 1 else { return }
                self.lastUpdate = elapsed
                self.updateOutputLabel()
                #if targetEnvironment(simulator)
                let platform = "Simulator — performance requires a physical device"
                #else
                #if targetEnvironment(macCatalyst)
                let platform = "macOS · Apple GPU family 7+"
                #else
                let platform = self.isPhone ? "iOS 17+ · Apple GPU family 7+" : "iPadOS 17+ · Apple GPU family 7+"
                #endif
                #endif
                let frame = self.input.snapshot()
                self.status.text = "PJDV M39 • Metal host\n\(platform)\n\(device.name)\nDrawable: \(Int(canvas.drawableSize.width)) × \(Int(canvas.drawableSize.height))\nFrames submitted: \(frames) • Controllers: \(GCController.controllers().count)\nButtons: \(String(frame.pad.buttons.rawValue, radix: 16)) • Touches: \(frame.touches.count)\n\(self.guestStatus)\n\(GuestRuntime.currentStatus())"
            }
            canvas.delegate = renderer
            status.text = "Metal host initializing…"
        } catch {
            status.text = "Metal initialization failed: \(error.localizedDescription)"
        }
        showStatus()
        let pad = VirtualPad(input: input)
        view.addSubview(pad)
        virtualPad = pad
        padToggle.accessibilityIdentifier = "controls.virtualPadToggle"
        padToggle.setTitleColor(.white, for: .normal)
        padToggle.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        padToggle.layer.cornerRadius = 12
        padToggle.addTarget(self, action: #selector(toggleVirtualPad), for: .touchUpInside)
        view.addSubview(padToggle)
        outputToggle.accessibilityIdentifier = "display.outputResolution"
        outputToggle.setTitleColor(.white, for: .normal)
        outputToggle.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        outputToggle.layer.cornerRadius = 12
        outputToggle.showsMenuAsPrimaryAction = true
        view.addSubview(outputToggle)
        applyOutputMode()
        view.addSubview(performance)
        updatePadVisibility()
        AppLanguage.prepareSession()
        GameRenderProfile.prepareSession()
        GuestRuntime.validateMapping { [weak self] message in self?.guestStatus = message }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollSession() }
        sessionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let layout = GameDisplayPolicy.layout(bounds: view.bounds, safe: safe, phone: isPhone, pose: duoPose)
        metalView?.frame = layout.game
        virtualPad?.layoutProfile = isPhone ? (duoPose == .ordinary ? "phone" : "duo." + duoPose.rawValue) : "tablet"
        virtualPad?.frame = layout.pad
        let controls = layout.controls
        let padToggleWidth = min(controls.width - 16, isPhone ? 250.0 : 330.0)
        padToggle.frame = CGRect(x: controls.midX - padToggleWidth / 2, y: controls.minY + 6, width: padToggleWidth, height: 30)
        outputToggle.frame = CGRect(x: controls.midX - 126, y: controls.minY + 38, width: 252, height: 30)
        padToggle.titleLabel?.font = .systemFont(ofSize: isPhone ? 12 : 16)
        padToggle.titleLabel?.adjustsFontSizeToFitWidth = true
        padToggle.titleLabel?.minimumScaleFactor = 0.7
        outputToggle.titleLabel?.adjustsFontSizeToFitWidth = true
        outputToggle.titleLabel?.minimumScaleFactor = 0.55
        outputToggle.titleLabel?.font = .systemFont(ofSize: isPhone ? 12 : 16)
        status.isHidden = isPhone && gameGraphicsActive() != 0
        if ["screen", "screenfx"].contains(outputMode), let canvas = metalView {
            canvas.drawableSize = GameDisplayPolicy.drawableSize(mode: outputMode, bounds: canvas.bounds, scale: displayScale)
        }
        performance.place(in: layout.metrics, controlsExpanded: !(virtualPad?.isHidden ?? true) && duoPose != .tabletop, compact: isPhone)
    }

    deinit {
        sessionTimer?.invalidate()
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func pollSession() {
        let phase = guestSessionPhase()
        if phase != 0 { sessionHasStarted = true }
        let error = guestExitError()
        if error != 0 { pendingExitError = error }
        if guestExitPrompt() != 0, !exitAlertVisible, presentedViewController == nil {
            exitAlertVisible = true
            input.clear()
            let alert = UIAlertController(title: SessionText.exit, message: SessionText.confirm, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SessionText.cancel, style: .cancel) { [weak self] _ in
                self?.input.clear(); self?.exitAlertVisible = false; answerGuestExit(0)
            })
            alert.addAction(UIAlertAction(title: SessionText.exit, style: .destructive) { [weak self] _ in
                self?.input.clear(); self?.exitAlertVisible = false; answerGuestExit(1)
            })
            alert.preferredAction = alert.actions.first
            present(alert, animated: true)
        }
        if phase == 4 || phase == 5 {
            view.isUserInteractionEnabled = false
            status.text = SessionText.saving
        } else if phase == 2 {
            view.isUserInteractionEnabled = true
        }
        if pendingExitError != 0, !exitAlertVisible, presentedViewController == nil {
            let error = pendingExitError; pendingExitError = 0
            let message = phase == 6 ? SessionText.stopFailed : SessionText.saveFailed
            let alert = UIAlertController(title: SessionText.exitFailed,
                message: message + " (\(error))", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SessionText.ok, style: .default))
            present(alert, animated: true)
        }
        guard phase == 0, sessionHasStarted else { return }
        sessionTimer?.invalidate();sessionTimer = nil
        input.clear();virtualPad?.releaseButtons();controllers = nil
        metalView?.isPaused = true;metalView?.delegate = nil;renderer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        GuestRuntime.releaseResourceAccess()
        #if targetEnvironment(macCatalyst)
        if MacHostTermination.terminate() { return }
        #endif
        view.window?.rootViewController = HostLaunchController(message: SessionText.saved)
    }

    private func showStatus() {
        status.numberOfLines = 0
        status.textColor = .white
        status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        status.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.accessibilityIdentifier = "lab.status"
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    private func updatePadVisibility() {
        let show = GameDisplayPolicy.showVirtualPad(enabled: virtualEnabled, controllerCount: connectedControllers)
        if !show { virtualPad?.releaseButtons() }
        virtualPad?.isHidden = !show
        view.setNeedsLayout()
        let state = virtualEnabled ? L("开") : L("关")
        padToggle.setTitle(connectedControllers > 0 ? LF("虚拟手柄：%@ · 已自动隐藏", state) : LF("虚拟手柄：%@", state), for: .normal)
        padToggle.accessibilityValue = connectedControllers > 0 ? L("已连接手柄；触屏可用") : L("触屏可用")
    }

    @objc private func toggleVirtualPad() {
        virtualEnabled.toggle()
        UserDefaults.standard.set(virtualEnabled, forKey: "virtualPadEnabled")
        updatePadVisibility()
    }

    // MTKView's own scale can follow an explicitly sized drawable. Match the
    // window's display backing scale, independent of the previous output mode.
    private var displayScale: CGFloat { view.window?.screen.scale ?? view.contentScaleFactor }

    private func applyOutputMode() {
        guard let canvas = metalView else { return }
        canvas.autoResizeDrawable = false
        if !DeviceGraphicsProfile.policy.allowsRayTracing { setRTStageMode(0) }
        let edr = hdrEnabled && supportsHDR
        canvas.colorPixelFormat = edr ? .rgba16Float : .bgra8Unorm
        if let layer = canvas.layer as? CAMetalLayer {
            layer.colorspace = edr ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB) : CGColorSpace(name: CGColorSpace.sRGB)
            if #available(iOS 16.0, macCatalyst 16.0, *) { layer.wantsExtendedDynamicRangeContent = edr }
        }
        setHDRMode(edr ? 1 : 0, currentEDRHeadroom)
        outputMode = GameDisplayPolicy.outputMode(outputMode, phone: isPhone, conservative: DeviceGraphicsProfile.policy.conservative)
        let modes = [("720p", "720p"), ("1080p", L("1080p（普通放大）")),
                     ("1080fx", L("1080p（MetalFX 超分）")), ("1440fx", L("1440p（MetalFX 超分）")),
                     ("screenfx", L("匹配屏幕（MetalFX 超分）")), ("screen", L("匹配屏幕（普通放大）"))].filter { !DeviceGraphicsProfile.policy.cappedTo1080(phone: isPhone) || ["720p", "1080p", "1080fx"].contains($0.0) }.filter { gameFGMode() == 0 || ["720p", "1080p"].contains($0.0) }
        if !modes.contains(where: { $0.0 == outputMode }) { outputMode = "1080p" }
        canvas.drawableSize = GameDisplayPolicy.drawableSize(mode: outputMode, bounds: canvas.bounds, scale: displayScale)
        NSLog("PJDV output mode=%@ bounds=%.1fx%.1f displayScale=%.2f canvasScale=%.2f drawable=%.0fx%.0f", outputMode,
              canvas.bounds.width, canvas.bounds.height, displayScale, canvas.contentScaleFactor,
              canvas.drawableSize.width, canvas.drawableSize.height)
        setUpscaleMode(GameDisplayPolicy.usesMetalFX(mode: outputMode) && supportsMetalFX ? 1 : 0)
        updateOutputLabel()
        let resolutionActions = modes.map { key, title in
            UIAction(title: L(title), attributes: GameDisplayPolicy.usesMetalFX(mode: key) && !supportsMetalFX ? [.disabled] : [], state: key == outputMode ? .on : .off) { [weak self] _ in
                self?.outputMode = key
                if !["720p", "1080p"].contains(key) { setGameFG(0) }
                UserDefaults.standard.set(key, forKey: self?.outputPreferenceKey ?? "outputResolution")
                self?.applyOutputMode()
            }
        }
        let shadowActions = [(Int32(0), L("原版阴影")), (Int32(1), L("光追舞台阴影（试验）"))].map { mode, title in
            UIAction(title: L(title), attributes: mode == 1 && !supportsRTStage ? [.disabled] : [], state: rtStageMode() == mode ? .on : .off) { [weak self] _ in
                setRTStageMode(DeviceGraphicsProfile.policy.allowsRayTracing && mode == 1 ? 1 : 0)
                UserDefaults.standard.set(mode == 1, forKey: "rtStageShadowEnabled")
                self?.applyOutputMode()
            }
        }
        // Keep the unqualified algorithm behind an explicit research launch.
        // Real PV captures show hair/outline artifacts; a 60Hz counter alone
        // must not promote this prototype into a usable performance preset.
        let fgResearch = ProcessInfo.processInfo.environment["PJDV_GAME_FG"] == "1"
        let fgActions = [(Int32(0), L("原生 60 FPS")), (Int32(1), L(fgResearch ? "省电 30→60（实验，增加显示延迟）" : "省电 30→60（画质验证中）"))].map { mode, title in
            UIAction(title: title, attributes: mode == 1 && !fgResearch ? [.disabled] : [], state: gameFGMode() == mode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                if mode == 1 {
                    self.hdrEnabled = false; setHDRMode(0, 1)
                    self.outputMode = "1080p"
                }
                setGameFG(mode); self.applyOutputMode()
            }
        }
        let hdrActions = [(false, L("SDR（原版色调映射）")), (true, L("HDR 高光映射（实验）"))].map { enabled, title in
            UIAction(title: L(title), attributes: enabled && (!supportsHDR || gameFGMode() == 1) ? [.disabled] : [], state: (hdrEnabled && supportsHDR) == enabled ? .on : .off) { [weak self] _ in
                self?.hdrEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: "gameHDREnabled")
                self?.applyOutputMode()
            }
        }
        outputToggle.menu = UIMenu(children: [UIMenu(title: L("游戏插帧（实验）"), options: .displayInline, children: fgActions), UIMenu(title: L("输出分辨率"), options: .displayInline, children: resolutionActions), UIMenu(title: L("舞台光照"), options: .displayInline, children: shadowActions), UIMenu(title: L("动态范围"), options: .displayInline, children: hdrActions)])
    }

    private func updateOutputLabel() {
        let label: String
        switch outputMode {
        case "720p": label = "720p"
        case "screen": label = L("屏幕分辨率（放大）")
        case "1080fx", "1440fx", "screenfx":
            let name = outputMode == "screenfx" ? L("屏幕") : outputMode == "1440fx" ? "1440p" : "1080p"
            switch upscaleStatus() {
            case 1: label = "\(name) · MetalFX"
            case 3, 4: label = "\(name) · 普通放大（超分回退）"
            default: label = supportsMetalFX ? "\(name) · MetalFX 准备中" : "\(name) · 普通放大（超分不可用）"
            }
        default: label = L("1080p（普通放大）")
        }
        var shadow = ""
        if rtStageMode() == 1 {
            switch rtStageStatus() {
            case 1: shadow = L(" · RT 舞台")
            case 3: shadow = L(" · RT 回退")
            default: shadow = L(" · RT 待场景")
            }
        }
        if hdrEnabled && supportsHDR {
            setHDRMode(1, currentEDRHeadroom)
            shadow += hdrStatus() == 1 ? " · HDR" : hdrStatus() == 4 ? L(" · HDR 错误") : L(" · HDR 待3D")
        }
        outputToggle.setTitle(L("输出：") + label + shadow + (gameFGMode() == 1 ? L(" · 30→60 图像插帧") : ""), for: .normal)
    }

    @objc private func toggleFrameRate() {
        guard let canvas = metalView else { return }
        canvas.preferredFramesPerSecond = canvas.preferredFramesPerSecond == 60 ? 30 : 60
    }
}

final class LabRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let started = CACurrentMediaTime()
    private var frames = 0
    var onFrame: ((Int, Double) -> Void)?

    init(device: MTLDevice, view: MTKView) throws {
        guard let queue = device.makeCommandQueue(),
              let shaderURL = Bundle.main.url(forResource: "Shaders", withExtension: "msl") else {
            throw NSError(domain: "PJDVM39", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing Metal queue or demo shader source"])
        }
        let shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "lab_vertex"),
              let fragment = library.makeFunction(name: "lab_fragment") else {
            throw NSError(domain: "PJDVM39", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing Metal queue or shaders"])
        }
        self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if gameGraphicsActive() != 0 {
            onFrame?(Int(guestSubmittedFrames()), CACurrentMediaTime() - started)
            return
        }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let elapsed = CACurrentMediaTime() - started
        var uniforms = SIMD2<Float>(Float(elapsed), Float(view.drawableSize.width / view.drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        #if targetEnvironment(simulator)
        command.addCompletedHandler { command in
            if command.status == .completed && gameGraphicsActive() == 0 {
                pjdvFramePresented(command.gpuEndTime > 0 ? command.gpuEndTime : CACurrentMediaTime())
            }
        }
        #else
        drawable.addPresentedHandler { drawable in if gameGraphicsActive() == 0 { pjdvFramePresented(drawable.presentedTime) } }
        #endif
        command.present(drawable)
        command.commit()
        frames += 1
        onFrame?(frames, elapsed)
    }
}


// The game chooses its original render profile during guest initialization.
// Offer the choice only while idle; never reconfigure targets mid-song.
private enum GameRenderProfile {
    private static var preferenceKey: String { DeviceGraphicsProfile.policy.conservative ? "entryHighRenderQuality" : "highRenderQuality" }
    static var high: Bool {
        if let value = getenv("PJDV_GAME_DOCKED") { return String(cString: value) == "1" }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }
    static func select(high: Bool) {
        UserDefaults.standard.set(high, forKey: preferenceKey)
        setenv("PJDV_GAME_DOCKED", high ? "1" : "0", 1)
    }
    static func prepareSession() { setenv("PJDV_GAME_DOCKED", high ? "1" : "0", 1) }
}

// iPadOS keeps the host alive and launches a completely new guest session.
final class HostLaunchController: UIViewController {
    private let message: String
    private let quality = UIButton(type: .system)
    private let resourceStatus = UILabel()
    private let start = UIButton(type: .system)
    private let language = UIButton(type: .system)
    private var startedExperiment = false
    private var launchDuoProfile = "phone"
    private let inbox=AppImportInbox()
    private var inboxTimer:Timer?
    private let inboxStatus=UILabel()
    init(message: String = "") { self.message = message; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = UIColor(red: 0.025, green: 0.04, blue: 0.07, alpha: 1)
        if let access=try? ResourceLibrary.open(),let layout=try? ResourceLayout.locate(access.root) {
            AppLanguage.configure(available:layout.languages)
        } else {AppLanguage.configure(available:["ja"])}
        let title = UILabel();title.text = "PJDV M39";title.font = .boldSystemFont(ofSize: 44);title.textColor = .white
        let detail = UILabel();detail.text = message;detail.textColor = .lightGray;detail.numberOfLines = 0;detail.textAlignment = .center
        start.setTitle(SessionText.start, for: .normal);start.titleLabel?.font = .boldSystemFont(ofSize: 24)
        start.accessibilityIdentifier = "launcher.startGame"
        start.addTarget(self, action: #selector(startGame), for: .touchUpInside)
        quality.accessibilityIdentifier = "launcher.renderQuality"
        quality.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        quality.showsMenuAsPrimaryAction = true
        updateQualityMenu()
        resourceStatus.font = .systemFont(ofSize: 15)
        resourceStatus.textColor = .lightGray;resourceStatus.numberOfLines = 0;resourceStatus.textAlignment = .center
        resourceStatus.accessibilityIdentifier = "launcher.resourceStatus"
        let resources = UIButton(type: .system);resources.setTitle(L("导入 XCI／资源管理"), for: .normal)
        resources.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        resources.accessibilityIdentifier = "launcher.resources"
        resources.addTarget(self, action: #selector(manageResources), for: .touchUpInside)
        let experiments = UIButton(type: .system);experiments.setTitle(L(DeviceGraphicsProfile.policy.conservative ? "实验功能" : "实验功能：HDR／帧生成显示链测试"), for: .normal)
        experiments.accessibilityIdentifier = "launcher.graphicsExperiments"
        experiments.showsMenuAsPrimaryAction = true
        #if targetEnvironment(simulator)
        let fg60Title = L("30→60 模拟器插帧实验")
        #else
        let fg60Title = L("30→60 MetalFX 测试场景")
        #endif
        experiments.menu = UIMenu(children: [(GraphicsExperimentMode.hdr, L("HDR / EDR 测试图")), (.fg60, fg60Title), (.fg120, L("60→120 MetalFX 测试场景"))].filter { item in
            if item.0 == .hdr { return DeviceGraphicsProfile.policy.allowsHDR }
            if item.0 == .fg120 { return DeviceGraphicsProfile.policy.allows120(phone: UIDevice.current.userInterfaceIdiom == .phone) }
            return true
        }.map { mode, name in
            UIAction(title: L(name)) { [weak self] _ in self?.showExperiment(mode) }
        })
        language.accessibilityIdentifier = "launcher.language"; language.showsMenuAsPrimaryAction = true
        updateLanguageMenu()
        let sticks = UIButton(type: .system); sticks.setTitle(L("摇杆布局"), for: .normal); sticks.accessibilityIdentifier = "launcher.stickLayout"
        sticks.addTarget(self, action: #selector(editSticks), for: .touchUpInside)
        let settings = UIStackView(arrangedSubviews: [language, sticks]); settings.spacing = 20
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak self] _, update in
                switch update.hinge?.status {
                case .closed: self?.launchDuoProfile = "duo.folded"
                case .partiallyOpen: self?.launchDuoProfile = "duo.tabletop"
                case .fullyOpen: self?.launchDuoProfile = "duo.expanded"
                default: self?.launchDuoProfile = "phone"
                }
            })
        }
        #endif
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        title.font = .boldSystemFont(ofSize: phone ? 32 : 44)
        inboxStatus.font = .systemFont(ofSize:13);inboxStatus.textColor = .lightGray;inboxStatus.numberOfLines=0;inboxStatus.textAlignment = .center;inboxStatus.accessibilityIdentifier="launcher.inboxStatus"
        let stack = UIStackView(arrangedSubviews: [title, detail, resourceStatus, resources,inboxStatus, quality, start, settings, experiments]);stack.axis = .vertical;stack.spacing = phone ? 8 : 18;stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),start.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated);refreshResources()
        inboxTimer?.invalidate()
        let timer=Timer(timeInterval:2,repeats:true){[weak self] _ in self?.checkImportInbox()}
        inboxTimer=timer;RunLoop.main.add(timer,forMode:.common);checkImportInbox()
        if !startedExperiment, let key = ProcessInfo.processInfo.environment["PJDV_GRAPHICS_EXPERIMENT"],
           let mode = GraphicsExperimentMode(rawValue: key) { startedExperiment = true;showExperiment(mode) }
    }

    override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated);inboxTimer?.invalidate();inboxTimer=nil
    }
    private func checkImportInbox() {
        guard viewIfLoaded?.window != nil,presentedViewController==nil,UIApplication.shared.applicationState == .active else{return}
        do {
            let root=ResourceLibrary.appDataRoot
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let snapshot=try AppImportInbox.Snapshot.read(root)
            inboxStatus.text=snapshot.isEmpty ? L("将 XCI 和密钥拷入 PJDVM39 根目录，可自动识别导入。") : inbox.isHandled(snapshot.signature) ? L("根目录文件已检测；可在资源管理查看或重试。") : L("已检测到根目录文件，等待复制稳定后自动导入。")
            guard inbox.ready(snapshot) else{return}
            inbox.markAttempted(snapshot.signature)
            let panel=ResourceImportController();panel.automaticInbox=snapshot;panel.modalPresentationStyle = .formSheet
            panel.onClose={[weak self] in self?.refreshResources()};present(panel,animated:true)
        } catch {inboxStatus.text=L("自动检测：")+error.localizedDescription}
    }
    deinit {inboxTimer?.invalidate()}
    @objc private func editSticks() {
        let editor = StickLayoutController(profile: UIDevice.current.userInterfaceIdiom == .phone ? launchDuoProfile : "tablet")
        editor.modalPresentationStyle = .fullScreen; present(editor, animated: true)
    }
    private func showExperiment(_ mode: GraphicsExperimentMode) {
        guard mode != .hdr || DeviceGraphicsProfile.policy.allowsHDR,
              mode != .fg120 || DeviceGraphicsProfile.policy.allows120(phone: UIDevice.current.userInterfaceIdiom == .phone) else { return }
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            let panel = GraphicsExperimentController(mode: mode); panel.modalPresentationStyle = .fullScreen
            present(panel, animated: true)
        } else {
            let alert = UIAlertController(title: L("实验功能"), message: L("帧生成实验需要 iOS 26 或更新系统；游戏仍可正常运行。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SessionText.ok, style: .default)); present(alert, animated: true)
        }
    }
    private func refreshResources() {
        do {
            let access = try ResourceLibrary.open();let layout = try ResourceLayout.locate(access.root)
            try GameRenderingAssets.validate(layout)
            let oldLanguage=AppLanguage.current
            AppLanguage.configure(available:layout.languages)
            if oldLanguage != AppLanguage.current,let window=view.window {
                window.rootViewController=HostLaunchController();return
            }
            updateLanguageMenu()
            let version=layout.content?.display_version ?? (layout.content==nil ? "1.0.9" : L("包内版本未标注"))
            resourceStatus.text = LF("资源就绪 · %@ · %d DLC",version,layout.dlcContents.count)
            if !layout.resourceVersionVerified {resourceStatus.text! += "\n"+L("资源版本待验证，使用已适配的运行程序")}
            start.isEnabled = true
        } catch {resourceStatus.text = error.localizedDescription;start.isEnabled = false}
    }
    private func updateLanguageMenu() {
        language.setTitle(L("语言")+" / "+(AppLanguage.available.first{$0.0==AppLanguage.current}?.1 ?? "日本語"),for:.normal)
        language.menu=UIMenu(children:AppLanguage.available.map {key,label in
            UIAction(title:label,state:AppLanguage.current==key ? .on:.off) {[weak self] _ in
                AppLanguage.select(key);self?.view.window?.rootViewController=HostLaunchController()
            }
        })
    }
    @objc private func manageResources() {
        let panel = ResourceImportController();panel.modalPresentationStyle = .formSheet
        panel.onClose = { [weak self] in self?.refreshResources() }
        present(panel, animated: true)
    }
    private func updateQualityMenu() {
        quality.setTitle(SessionText.quality + "：" + (GameRenderProfile.high ? SessionText.highQuality : SessionText.standardQuality), for: .normal)
        quality.menu = UIMenu(children: [false, true].map { high in
            UIAction(title: high ? SessionText.highQuality : SessionText.standardQuality, state: GameRenderProfile.high == high ? .on : .off) { [weak self] _ in
                GameRenderProfile.select(high: high)
                self?.updateQualityMenu()
            }
        })
    }
    @objc private func startGame() {
        guard guestSessionPhase() == 0 else { return }
        do {let access = try ResourceLibrary.open();let layout = try ResourceLayout.locate(access.root);try GameRenderingAssets.validate(layout)}
        catch {resourceStatus.text = error.localizedDescription;return}
        AppLanguage.prepareSession()
        GameRenderProfile.prepareSession()
        view.window?.rootViewController = LabController()
    }
}

@_silgen_name("pjdv_session_phase") private func guestSessionPhase() -> Int32
@_silgen_name("pjdv_exit_prompt_pending") private func guestExitPrompt() -> Int32
@_silgen_name("pjdv_exit_answer") private func answerGuestExit(_ yes: Int32)
@_silgen_name("pjdv_exit_last_error") private func guestExitError() -> Int32

// Follow the game language; do not use the Mac's language for a Chinese game.
private enum SessionText {
    static var language: String { AppLanguage.current }
    static func pick(_ cn: String, _ tw: String, _ en: String, _ jp: String, _ kr: String) -> String {
        let l = language.lowercased()
        if l.contains("hant") || l == "tw" { return tw }
        if l.hasPrefix("zh") || l == "cn" { return cn }
        if l.hasPrefix("ja") || l == "jp" { return jp }
        if l.hasPrefix("ko") || l == "kr" { return kr }
        return en
    }
    static var exit: String { pick("退出游戏", "結束遊戲", "Exit Game", "ゲームを終了", "게임 종료") }
    static var cancel: String { pick("取消", "取消", "Cancel", "キャンセル", "취소") }
    static var ok: String { pick("好", "好", "OK", "OK", "확인") }
    static var quality: String { pick("画质", "畫質", "Quality", "画質", "화질") }
    static var standardQuality: String { pick("标准", "標準", "Standard", "標準", "표준") }
    static var highQuality: String { pick("高画质（试验）", "高畫質（試驗）", "High (Experimental)", "高画質（試験）", "고화질 (실험)") }
    static var start: String { pick("启动游戏", "啟動遊戲", "Start Game", "ゲームを開始", "게임 시작") }
    static var confirm: String { pick("保存进度并退出游戏？", "儲存進度並結束遊戲？", "Save your progress and exit the game?", "進行状況を保存してゲームを終了しますか？", "진행 상황을 저장하고 게임을 종료하시겠습니까?") }
    static var saving: String { pick("正在保存并结束游戏…", "正在儲存並結束遊戲…", "Saving and closing the game…", "保存して終了しています…", "저장하고 종료하는 중…") }
    static var saved: String { pick("进度已保存，游戏会话已结束", "進度已儲存，遊戲已結束", "Progress saved. Game session closed.", "保存してゲームを終了しました", "저장 후 게임을 종료했습니다") }
    static var exitFailed: String { pick("未能退出游戏", "未能結束遊戲", "Unable to Exit", "終了できませんでした", "종료할 수 없습니다") }
    static var saveFailed: String { pick("存档或暂停检查未完成，已恢复游戏。请稍后重试。", "存檔或暫停檢查未完成，已恢復遊戲。請稍後重試。", "The save or pause check did not finish. The game has resumed; please try again.", "保存または停止の確認が完了しませんでした。ゲームに戻りました。", "저장 또는 일시 정지 확인이 완료되지 않아 게임을 재개했습니다.") }
    static var stopFailed: String { pick("会话清理未能完成。为保护存档，暂时无法重新启动；请关闭并重新打开 App。", "遊戲清理未能完成，請關閉並重新開啟 App。", "Session cleanup did not finish. Please close and reopen the app.", "終了処理が完了しませんでした。アプリを開き直してください。", "종료 처리가 완료되지 않았습니다. 앱을 다시 열어 주세요.") }
}

#if targetEnvironment(macCatalyst)
@objc(PJDVMacTermination) private protocol MacTerminationPlugin { static func terminateApplication() }
private enum MacHostTermination {
    static func terminate() -> Bool {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PJDVMacLifecycle.bundle"),
              let plugin = Bundle(url: url), plugin.load(),
              let entry = plugin.principalClass as? MacTerminationPlugin.Type else {
            NSLog("PJDV normal Mac termination helper unavailable");return false
        }
        entry.terminateApplication();return true
    }
}
#endif
