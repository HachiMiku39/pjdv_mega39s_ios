import UIKit
import MetalKit
import GameController
import CoreHaptics

// The guest callback may run on any game thread. Only its tiny mailbox uses a
// lock; engine creation and parameter updates stay on a dedicated serial queue.
private enum GuestRumble {
    static let lock = NSLock()
    static weak var target: ControllerRumble?
}
@_cdecl("pjdv_host_vibration_send")
func pjdvHostVibrationSend(_ side: Int32, _ low: Float, _ lowHz: Float, _ high: Float, _ highHz: Float) {
    GuestRumble.lock.lock(); let target = GuestRumble.target; GuestRumble.lock.unlock()
    target?.submit(side: Int(side), low: low, lowHz: lowHz, high: high, highHz: highHz)
}

/// Ordinary controller rumble, not bit-accurate Switch HD or PS5 waveform haptics.
private final class ControllerRumble {
    private struct Value {
        var intensity: Float = 0
        var sharpness: Float = 0
    }
    private final class Channel {
        let engine: CHHapticEngine
        var player: CHHapticPatternPlayer?
        var running = false
        init(_ engine: CHHapticEngine) { self.engine = engine }
        func stop() {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
        }
        func apply(_ value: Value) throws {
            if value.intensity <= 0 { stop(); return }
            if !running { try engine.start(); running = true }
            let parameters = [
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value.intensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: value.sharpness, relativeTime: 0)
            ]
            if let player { try player.sendParameters(parameters, atTime: CHHapticTimeImmediate) }
            else {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0)
                ], relativeTime: 0, duration: Double(GCHapticDurationInfinite))
                let pattern = try CHHapticPattern(events: [event], parameters: parameters)
                let next = try engine.makePlayer(with: pattern)
                try next.start(atTime: CHHapticTimeImmediate)
                player = next
            }
        }
        func close() { stop(); engine.stoppedHandler = { _ in }; engine.resetHandler = {}; engine.stop(completionHandler: nil); running = false }
    }
    private let queue = DispatchQueue(label: "PJDV.controller-rumble", qos: .userInteractive)
    private let mailbox = NSLock()
    private var accepting = true
    private var pending: [Value?] = [nil, nil]
    private var scheduled = false
    private var submitTrace = 0
    // Everything below is confined to queue.
    private var devices: [(ObjectIdentifier, GCDeviceHaptics, String)] = []
    private var selected: ObjectIdentifier?
    private var channels: [Channel] = []
    private var values = [Value(), Value()]
    private var generation = 0
    private var errorCount = 0
    private var outputCount = 0

    init() {
        GuestRumble.lock.lock(); GuestRumble.target = self; GuestRumble.lock.unlock()
    }
    deinit {
        let retiring = channels
        queue.async { retiring.forEach { $0.close() } }
    }
    func connect(_ controller: GCController) {
        guard !controller.isSnapshot, controller.extendedGamepad != nil else { return }
        guard let haptics = controller.haptics else {
            NSLog("PJDV rumble unavailable vendor=%@ (no GCDeviceHaptics)", controller.vendorName ?? "unknown"); return
        }
        let id = ObjectIdentifier(controller), vendor = controller.vendorName ?? "unknown"
        queue.async { [weak self] in
            guard let self, !self.devices.contains(where: { $0.0 == id }) else { return }
            self.devices.append((id, haptics, vendor)); self.selectDevice()
        }
    }
    func disconnect(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        queue.async { [weak self] in
            guard let self else { return }
            self.devices.removeAll { $0.0 == id }
            if self.selected == id { self.closeChannels(); self.selectDevice() }
        }
    }
    private func closeChannels() {
        generation += 1; channels.forEach { $0.close() }; channels = []
        selected = nil; values = [Value(), Value()]
        mailbox.lock(); pending = [nil, nil]; mailbox.unlock()
    }
    private func selectDevice() {
        guard selected == nil else { return }
        for (id, haptics, vendor) in devices {
            let localities = haptics.supportedLocalities
            let split = localities.contains(.leftHandle) && localities.contains(.rightHandle)
            let wanted: [GCHapticsLocality] = split ? [.leftHandle, .rightHandle] : [.default]
            var next: [Channel] = []
            for locality in wanted {
                guard let engine = haptics.createEngine(withLocality: locality) else { break }
                engine.playsHapticsOnly = true; engine.isMutedForAudio = true
                let channel = Channel(engine)
                engine.stoppedHandler = { [weak self, weak channel] reason in
                    self?.queue.async { [weak channel] in
                        channel?.player = nil; channel?.running = false
                    }
                    NSLog("PJDV rumble engine stopped reason=%ld", reason.rawValue)
                }
                engine.resetHandler = { [weak self, weak channel] in
                    self?.queue.async { [weak channel] in channel?.player = nil; channel?.running = false }
                }
                next.append(channel)
            }
            guard next.count == wanted.count else { next.forEach { $0.close() }; continue }
            channels = next; selected = id
            NSLog("PJDV rumble configured vendor=%@ channels=%d localities=%@", vendor, next.count, String(describing: localities))
            if ProcessInfo.processInfo.environment["PJDV_HAPTICS_PROBE"] == "1" { probe() }
            return
        }
    }
    func suspend() {
        mailbox.lock(); accepting = false; pending = [nil, nil]; mailbox.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1; self.values = [Value(), Value()]
            self.channels.forEach { $0.stop() }
        }
    }
    func resume() { mailbox.lock(); accepting = true; mailbox.unlock() }
    func submit(side: Int, low: Float, lowHz: Float, high: Float, highHz: Float) {
        guard (0..<2).contains(side) else { return }
        let l = low.isFinite ? min(1, max(0, low)) : 0
        let h = high.isFinite ? min(1, max(0, high)) : 0
        let sum = l + h
        let hz = sum > 0 ? (l * (lowHz.isFinite ? lowHz : 160) + h * (highHz.isFinite ? highHz : 320)) / sum : 0
        let value = Value(intensity: max(l, h), sharpness: min(1, max(0, hz / 640)))
        mailbox.lock()
        if value.intensity > 0, submitTrace < 24 {
            submitTrace += 1
            NSLog("PJDV rumble received side=%d intensity=%.3f accepting=%d", side, value.intensity, accepting ? 1 : 0)
        }
        guard accepting else { mailbox.unlock(); return }
        pending[side] = value
        if scheduled { mailbox.unlock(); return }
        scheduled = true; mailbox.unlock()
        queue.async { [weak self] in self?.drain() }
    }
    private func drain() {
        mailbox.lock(); let updates = pending; pending = [nil, nil]; scheduled = false; mailbox.unlock()
        guard !channels.isEmpty else { return }
        for i in 0..<2 { if let value = updates[i] { values[i] = value } }
        do {
            if channels.count == 2 {
                for i in 0..<2 where updates[i] != nil { try channels[i].apply(values[i]) }
            } else {
                let sum = values[0].intensity + values[1].intensity
                let sharpness = sum > 0 ? (values[0].intensity * values[0].sharpness + values[1].intensity * values[1].sharpness) / sum : 0
                try channels[0].apply(Value(intensity: max(values[0].intensity, values[1].intensity), sharpness: sharpness))
            }
            if values.contains(where: { $0.intensity > 0 }), outputCount < 24 {
                outputCount += 1
                NSLog("PJDV rumble output left=%.3f right=%.3f", values[0].intensity, values[1].intensity)
            }
        } catch {
            channels.forEach { $0.stop() }
            if errorCount < 8 { NSLog("PJDV rumble output failed: %@", String(describing: error)); errorCount += 1 }
        }
    }
    // Explicit diagnostic launch only. Two short, modest pulses, never a
    // replacement for proof that the game itself sends nonzero vibration.
    private func probe() {
        let epoch = generation
        for side in 0..<2 {
            queue.asyncAfter(deadline: .now() + 0.5 + Double(side) * 0.5) { [weak self] in
                guard let self, self.generation == epoch else { return }
                NSLog("PJDV rumble diagnostic pulse side=%d", side)
                self.submit(side: side, low: 0.45, lowHz: 160, high: 0, highHz: 320)
            }
            queue.asyncAfter(deadline: .now() + 0.7 + Double(side) * 0.5) { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.submit(side: side, low: 0, lowHz: 160, high: 0, highHz: 320)
            }
        }
    }
}

final class TouchMetalView: MTKView {
    let input: InputStore
    private var touchIDs: [ObjectIdentifier: Int] = [:]

    init(device: MTLDevice, input: InputStore) {
        self.input = input
        super.init(frame: .zero, device: device)
        isMultipleTouchEnabled = true
    }
    required init(coder: NSCoder) { fatalError("Use programmatic initialization") }

    private func update(_ touches: Set<UITouch>) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if touchIDs[key] == nil {
                let used = Set(touchIDs.values)
                guard let slot = (0..<10).first(where: { !used.contains($0) }) else { continue }
                touchIDs[key] = slot
            }
            let position = touch.location(in: self)
            input.touch(id: touchIDs[key]!, x: Float(position.x / bounds.width),
                        y: Float(position.y / bounds.height))
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    func resetTouchTracking() { touchIDs.removeAll() }
    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            if let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) { input.endTouch(id: id) }
        }
    }
}

/// GameController handles supported DualSense and Xbox controllers. Mapping is
/// by physical face-button position: south -> Switch B, east -> Switch A.
@_silgen_name("pjdv_set_controller_glyphs")
private func setControllerGlyphs(_ family: Int32)

final class ControllerBridge {
    private let input: InputStore
    private let rumble = ControllerRumble()
    private var observers: [NSObjectProtocol] = []
    private var active = Set<ObjectIdentifier>()
    private var glyphFamilies: [ObjectIdentifier: ControllerGlyphFamily] = [:]
    private var connectionOrder: [ObjectIdentifier] = []
    private var glyphController: ObjectIdentifier?
    private let onControllersChanged: (Int) -> Void
    init(input: InputStore, onControllersChanged: @escaping (Int) -> Void) {
        self.input = input
        self.onControllersChanged = onControllersChanged
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect,
                         object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.connect(controller) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect,
                         object: nil, queue: .main) { [weak self] note in
            if let self, let controller = note.object as? GCController {
                self.input.remove(source: self.key(controller))
                let id = ObjectIdentifier(controller)
                self.active.remove(id)
                self.glyphFamilies.removeValue(forKey: id)
                self.connectionOrder.removeAll { $0 == id }
                if self.glyphController == id { self.glyphController = self.connectionOrder.last }
                self.publishGlyphs()
                self.rumble.disconnect(controller)
                self.onControllersChanged(self.active.count)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                         object: nil, queue: .main) { [weak self] _ in self?.rumble.suspend() })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                         object: nil, queue: .main) { [weak self] _ in self?.rumble.resume() })
        GCController.controllers().forEach(connect)
        publishGlyphs()
    }
    deinit { rumble.suspend(); observers.forEach(NotificationCenter.default.removeObserver); setControllerGlyphs(0) }
    private func publishGlyphs() {
        let family = glyphController.flatMap { glyphFamilies[$0] } ?? .nintendo
        // Ephemeral launch diagnostic, used to verify the Xbox/PS atlas paths
        // in a simulator without fabricating a connected physical controller.
        let override = ProcessInfo.processInfo.environment["PJDV_GLYPH_FAMILY"]
        let value: ControllerGlyphFamily = override == "xbox" ? .xbox : override == "ps" ? .playStation : override == "switch" ? .nintendo : family
        setControllerGlyphs(value.rawValue)
    }
    private func key(_ controller: GCController) -> String { "controller-\(ObjectIdentifier(controller))" }
    private func connect(_ controller: GCController) {
        NSLog("PJDV controller vendor=%@ category=%@ snapshot=%d", controller.vendorName ?? "unknown", controller.productCategory, controller.isSnapshot ? 1 : 0)
        // Device Hub's simulator Gamepad was confirmed as virtual input. Keep
        // its input bridge, but do not let it hide the on-screen controls.
        #if targetEnvironment(simulator)
        let simulatorVirtual = controller.vendorName == "Gamepad" && controller.productCategory == "MFi"
        #else
        let simulatorVirtual = false
        #endif
        let id = ObjectIdentifier(controller)
        if !controller.isSnapshot && !simulatorVirtual {
            active.insert(id)
            connectionOrder.removeAll { $0 == id }; connectionOrder.append(id)
            let pad = controller.extendedGamepad
            glyphFamilies[id] = .identify(category: controller.productCategory, vendor: controller.vendorName,
                                          xboxProfile: pad is GCXboxGamepad,
                                          psProfile: pad is GCDualSenseGamepad || pad is GCDualShockGamepad)
            if glyphController == nil { glyphController = id }
            publishGlyphs()
        }
        if !simulatorVirtual { rumble.connect(controller) }
        onControllersChanged(active.count)
        guard let pad = controller.extendedGamepad else { return }
        let source = key(controller)
        pad.valueChangedHandler = { [weak self] pad, _ in self?.sample(pad, source: source, controller: id) }
        sample(pad, source: source, controller: id)
    }
    private func sample(_ pad: GCExtendedGamepad, source: String, controller: ObjectIdentifier) {
        var value = PadState()
        let pairs: [(GCControllerButtonInput?, PadButtons)] = [
            (pad.buttonA, .b), (pad.buttonB, .a), (pad.buttonX, .y), (pad.buttonY, .x),
            (pad.leftShoulder, .l), (pad.rightShoulder, .r),
            (pad.leftTrigger, .zl), (pad.rightTrigger, .zr),
            (pad.leftThumbstickButton, .l3), (pad.rightThumbstickButton, .r3),
            (pad.buttonMenu, .plus), (pad.buttonOptions, .minus),
            (pad.dpad.left, .left), (pad.dpad.right, .right),
            (pad.dpad.up, .up), (pad.dpad.down, .down)
        ]
        for (button, mask) in pairs where button?.isPressed == true { value.buttons.formUnion(mask) }
        value.leftStick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
        value.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        input.update(source: source, state: value)
        if !value.buttons.isEmpty || abs(value.leftStick.x) > 0.2 || abs(value.leftStick.y) > 0.2 || abs(value.rightStick.x) > 0.2 || abs(value.rightStick.y) > 0.2 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active.contains(controller), self.glyphController != controller else { return }
                self.glyphController = controller; self.publishGlyphs()
            }
        }
    }
}

final class StickView: UIView {
    private let input: InputStore
    private let right: Bool
    private let knob = UIView()
    private var tracked: UITouch?
    init(input: InputStore, right: Bool) {
        self.input = input; self.right = right
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.15)
        layer.cornerRadius = 36
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.6)
        knob.layer.cornerRadius = 12
        addSubview(knob)
        accessibilityLabel = right ? "Right stick" : "Left stick"
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    private var knobSize: CGFloat { bounds.width * (24 / 76) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = knobSize
        knob.layer.cornerRadius = size / 2
        if tracked == nil { knob.frame = CGRect(x: bounds.midX-size/2, y: bounds.midY-size/2, width: size, height: size) }
    }
    private func update(_ touch: UITouch) {
        let p = touch.location(in: self)
        let radius = max(1, bounds.width / 2)
        var vector = SIMD2(Float((p.x - bounds.midX) / radius), Float((bounds.midY - p.y) / radius))
        let length = sqrt(vector.x * vector.x + vector.y * vector.y)
        if length > 1 { vector /= length }
        var state = PadState()
        if right { state.rightStick = vector } else { state.leftStick = vector }
        input.update(source: right ? "virtual-right-stick" : "virtual-left-stick", state: state)
        let size = knobSize, travel = max(1, radius - size / 2)
        knob.frame = CGRect(x: bounds.midX + CGFloat(vector.x)*travel - size/2,
                            y: bounds.midY - CGFloat(vector.y)*travel - size/2, width: size, height: size)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if tracked == nil, let touch = touches.first { tracked = touch; update(touch) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = tracked, touches.contains(touch) { update(touch) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        if let touch = tracked, touches.contains(touch) {
            releaseInput()
        }
    }
    func releaseInput() {
        tracked = nil
        input.remove(source: right ? "virtual-right-stick" : "virtual-left-stick")
        setNeedsLayout()
    }
}

/// VoiceOver / accessibility activation has no touch-down phase. Keep it a
/// momentary button too, so the game receives both press and release.
private final class PadButton: UIButton {
    private var activation = 0
    override func accessibilityActivate() -> Bool {
        guard isEnabled, !isHidden, window != nil else { return false }
        activation += 1
        let token = activation
        sendActions(for: .touchDown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.activation == token else { return }
            self.sendActions(for: .touchUpInside)
        }
        return true
    }
}

/// Complete Switch controls; original HID labels and physical positions.
/// Only actual controls capture touches; the gaps pass through to Touch Play.
final class VirtualPad: UIView {
    static let preferredScale: CGFloat = 2.0
    var layoutProfile = "tablet"
    var configurationOverride: StickLayout?
    var highlightedControl: PadControl? { didSet { setNeedsLayout() } }
    static let baselineHeight: CGFloat = 286
    private let input: InputStore
    private var buttons: [UIButton: PadButtons] = [:]
    private var named: [String: UIButton] = [:]
    private let leftStick: StickView
    private let rightStick: StickView
    init(input: InputStore) {
        self.input = input
        leftStick = StickView(input: input, right: false)
        rightStick = StickView(input: input, right: true)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        leftStick.accessibilityIdentifier = "pad.leftStick"
        rightStick.accessibilityIdentifier = "pad.rightStick"
        addSubview(leftStick); addSubview(rightStick)
        let mapping: [(String, PadButtons, String)] = [
            ("X", .x, "Switch X"), ("Y", .y, "Switch Y"),
            ("A", .a, "Switch A，确认"), ("B", .b, "Switch B，返回"),
            ("L", .l, "Switch L"), ("R", .r, "Switch R"),
            ("ZL", .zl, "Switch ZL"), ("ZR", .zr, "Switch ZR"),
            ("L3", .l3, "左摇杆按压"), ("R3", .r3, "右摇杆按压"),
            ("−", .minus, "Switch 减号"), ("+", .plus, "Switch 加号，暂停"),
            ("↑", .up, "方向上"), ("←", .left, "方向左"),
            ("→", .right, "方向右"), ("↓", .down, "方向下")
        ]
        // Keep the Switch diamond and use Xbox's familiar letter colors.
        let colors: [String: UIColor] = ["X": .systemBlue, "Y": .systemYellow,
                                         "A": .systemGreen, "B": .systemRed]
        for (title, mask, meaning) in mapping {
            let button = PadButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.setTitleColor(colors[title] ?? .white, for: .normal)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
            button.layer.borderWidth = 1
            button.accessibilityIdentifier = "pad.\(title)"
            button.accessibilityLabel = title
            button.accessibilityHint = meaning
            button.isExclusiveTouch = false
            button.addTarget(self, action: #selector(press(_:)), for: [.touchDown, .touchDragEnter])
            button.addTarget(self, action: #selector(release(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            buttons[button] = mask; named[title] = button
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let baseKey: CGFloat = bounds.width < 750 ? 44 : 48
        // Expand the actual frames and touch regions, not just the artwork.
        // Native tablets use 200%; a smaller resized Mac window fits uniformly.
        let scale = min(Self.preferredScale, bounds.height / Self.baselineHeight,
                        bounds.width / (baseKey * 6 + 28))
        let key = baseKey * scale
        let stick: CGFloat = (bounds.width < 750 ? 68 : 76) * scale
        let width = key * 3
        let right = bounds.width - width
        func place(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat? = nil) {
            named[name]?.frame = CGRect(x: x, y: y, width: w ?? key, height: key)
            named[name]?.layer.cornerRadius = key / 2
            named[name]?.layer.borderWidth = scale
            named[name]?.titleLabel?.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
        }
        place("ZL", 0, 0, width / 2 - 3 * scale); place("L", width / 2 + 3 * scale, 0, width / 2 - 3 * scale)
        place("R", right, 0, width / 2 - 3 * scale); place("ZR", right + width / 2 + 3 * scale, 0, width / 2 - 3 * scale)
        let top = key + 8 * scale
        // Move menu buttons below the shoulder row so the enlarged hit areas
        // cannot collide with L/R. Keep their Switch positions at the center.
        let menuTop = top + key * 0.65
        place("−", bounds.midX - key - 6 * scale, menuTop)
        place("+", bounds.midX + 6 * scale, menuTop)
        leftStick.frame = CGRect(x: 8 * scale, y: top, width: stick, height: stick)
        leftStick.layer.cornerRadius = stick / 2
        place("L3", stick + 16 * scale, top + (stick - key) / 2)
        // Switch face diamond: X north, Y west, A east, B south.
        place("X", right + key, top); place("Y", right, top + key)
        place("A", right + key * 2, top + key); place("B", right + key, top + key * 2)
        let bottom = bounds.height - key * 3
        place("↑", key, bottom); place("←", 0, bottom + key)
        place("→", key * 2, bottom + key); place("↓", key, bottom + key * 2)
        rightStick.frame = CGRect(x: right - stick - 12 * scale, y: bounds.height - stick, width: stick, height: stick)
        rightStick.layer.cornerRadius = stick / 2
        place("R3", rightStick.frame.maxX + 8 * scale, bounds.height - stick + (stick - key) / 2)
        let custom = configurationOverride ?? StickLayout.load(layoutProfile)
        leftStick.frame = StickLayout.frame(leftStick.frame, in: bounds, placement: custom.left)
        rightStick.frame = StickLayout.frame(rightStick.frame, in: bounds, placement: custom.right)
        for control in PadControl.allCases where control != .leftStick && control != .rightStick {
            guard let button = named[control.title] else { continue }
            let base = button.frame
            button.frame = StickLayout.frame(base, in: bounds, placement: custom.placement(for: control))
            let factor = base.height > 0 ? button.frame.height / base.height : 1
            button.layer.cornerRadius = min(button.frame.width, button.frame.height) / 2
            button.titleLabel?.font = .systemFont(ofSize: max(9, 14 * scale * factor), weight: .semibold)
            button.layer.borderColor = (highlightedControl == control ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.4)).cgColor
            button.layer.borderWidth = highlightedControl == control ? 3 : scale
        }
        for (control, stick) in [(PadControl.leftStick, leftStick), (.rightStick, rightStick)] {
            stick.layer.cornerRadius = stick.bounds.width / 2
            stick.layer.borderColor = UIColor.systemYellow.cgColor
            stick.layer.borderWidth = highlightedControl == control ? 3 : 0
        }
    }
    func controlFrame(_ control: PadControl) -> CGRect {
        switch control {
        case .leftStick: return leftStick.frame
        case .rightStick: return rightStick.frame
        default: return named[control.title]?.frame ?? .zero
        }
    }
    func control(at point: CGPoint) -> PadControl? {
        // Matches the UIKit subview stacking order for overlapping custom keys.
        PadControl.allCases.reversed().first { controlFrame($0).contains(point) }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        var node: UIView? = hit
        while let current = node, current !== self {
            if current is UIControl || current is StickView { return hit }
            node = current.superview
        }
        return nil
    }
    func releaseButtons() {
        for button in buttons.keys { release(button) }
        leftStick.releaseInput(); rightStick.releaseInput()
    }
    @objc private func press(_ button: UIButton) {
        button.backgroundColor = UIColor.white.withAlphaComponent(0.4)
        input.update(source: "virtual-\(ObjectIdentifier(button))", state: PadState(buttons: buttons[button] ?? []))
    }
    @objc private func release(_ button: UIButton) {
        button.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        input.remove(source: "virtual-\(ObjectIdentifier(button))")
    }
}
