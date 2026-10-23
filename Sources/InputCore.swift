import Foundation

struct PadButtons: OptionSet {
    let rawValue: UInt64
    static let a = Self(rawValue: 1 << 0), b = Self(rawValue: 1 << 1)
    static let x = Self(rawValue: 1 << 2), y = Self(rawValue: 1 << 3)
    static let l3 = Self(rawValue: 1 << 4), r3 = Self(rawValue: 1 << 5)
    static let l = Self(rawValue: 1 << 6), r = Self(rawValue: 1 << 7)
    static let zl = Self(rawValue: 1 << 8), zr = Self(rawValue: 1 << 9)
    static let plus = Self(rawValue: 1 << 10), minus = Self(rawValue: 1 << 11)
    static let left = Self(rawValue: 1 << 12), up = Self(rawValue: 1 << 13)
    static let right = Self(rawValue: 1 << 14), down = Self(rawValue: 1 << 15)
}

struct PadState {
    var buttons: PadButtons = []
    var leftStick = SIMD2<Float>.zero
    var rightStick = SIMD2<Float>.zero
}

struct TouchContact {
    let id: Int
    let x: Float
    let y: Float
}

struct InputFrame {
    let timestampNanoseconds: UInt64
    let pad: PadState
    let touches: [TouchContact]
}

/// Sources merge independently, so releasing a virtual button never releases
/// the same button still held on a physical controller. Sample once per frame.
final class InputStore {
    var onChange: (() -> Void)?
    private let lock = NSLock()
    private var sources: [String: PadState] = [:]
    private var contacts: [Int: TouchContact] = [:]

    func update(source: String, state: PadState) {
        lock.lock(); defer { lock.unlock(); onChange?() }
        var value = state
        func bounded(_ axis: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(axis.x.isFinite ? min(1, max(-1, axis.x)) : 0,
                  axis.y.isFinite ? min(1, max(-1, axis.y)) : 0)
        }
        value.leftStick = bounded(value.leftStick)
        value.rightStick = bounded(value.rightStick)
        sources[source] = value
    }

    func remove(source: String) {
        lock.lock(); defer { lock.unlock(); onChange?() }
        sources.removeValue(forKey: source)
    }

    func touch(id: Int, x: Float, y: Float) {
        lock.lock(); defer { lock.unlock(); onChange?() }
        guard x.isFinite, y.isFinite, contacts[id] != nil || contacts.count < 10 else { return }
        contacts[id] = TouchContact(id: id, x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    func endTouch(id: Int) {
        lock.lock(); defer { lock.unlock(); onChange?() }
        contacts.removeValue(forKey: id)
    }

    func clear() {
        lock.lock(); defer { lock.unlock(); onChange?() }
        sources.removeAll(); contacts.removeAll()
    }

    func snapshot() -> InputFrame {
        lock.lock(); defer { lock.unlock() }
        var pad = PadState()
        func magnitude(_ v: SIMD2<Float>) -> Float { v.x * v.x + v.y * v.y }
        for key in sources.keys.sorted() {
            guard let value = sources[key] else { continue }
            pad.buttons.formUnion(value.buttons)
            if magnitude(value.leftStick) > magnitude(pad.leftStick) { pad.leftStick = value.leftStick }
            if magnitude(value.rightStick) > magnitude(pad.rightStick) { pad.rightStick = value.rightStick }
        }
        return InputFrame(timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                          pad: pad, touches: contacts.values.sorted { $0.id < $1.id })
    }
}

/// Display labels follow physical position; these values never change HID bits.
enum ControllerGlyphFamily: Int32 {
    case nintendo = 0, playStation = 1, xbox = 2
    var melodyPreview: [String] {
        switch self {
        case .nintendo: return ["X", "Y", "B", "A"]
        case .playStation: return ["△", "□", "×", "○"]
        case .xbox: return ["Y", "X", "A", "B"]
        }
    }
    static func identify(category: String, vendor: String?, xboxProfile: Bool, psProfile: Bool) -> Self {
        if xboxProfile || category == "Xbox One" { return .xbox }
        if psProfile || category == "DualSense" || category == "DualShock 4" { return .playStation }
        let name = (category + " " + (vendor ?? "")).lowercased()
        if name.contains("nintendo") || name.contains("joy-con") || name.contains("switch pro") { return .nintendo }
        // Keep the original legends for an unrecognized controller rather than
        // guessing a manufacturer from a generic MFi/HID profile.
        return .nintendo
    }
}
