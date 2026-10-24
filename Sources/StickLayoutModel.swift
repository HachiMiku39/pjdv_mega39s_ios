import Foundation
import CoreGraphics

enum PadControl: String, CaseIterable {
    case leftStick, rightStick, x, y, a, b, l, r, zl, zr, l3, r3, minus, plus, up, left, right, down
    var title: String {
        switch self {
        case .leftStick: return "左摇杆"
        case .rightStick: return "右摇杆"
        case .minus: return "−"
        case .plus: return "+"
        case .up: return "↑"
        case .left: return "←"
        case .right: return "→"
        case .down: return "↓"
        default: return rawValue.uppercased()
        }
    }
}

struct StickPlacement: Codable {
    var scale: Double
    var x: Double?, y: Double?
}
struct StickLayout: Codable {
    var left: StickPlacement, right: StickPlacement
    // Optional for build14's persisted two-stick layout compatibility.
    var buttons: [String: StickPlacement]? = nil
    func placement(for control: PadControl) -> StickPlacement {
        switch control {
        case .leftStick: return left
        case .rightStick: return right
        default: return buttons?[control.rawValue] ?? StickPlacement(scale: 1)
        }
    }
    mutating func setPlacement(_ placement: StickPlacement, for control: PadControl) {
        switch control {
        case .leftStick: left = placement
        case .rightStick: right = placement
        default: if buttons == nil { buttons = [:] }; buttons?[control.rawValue] = placement
        }
    }
    static let profiles = [("phone", "普通手机"), ("duo.folded", "Duo 外屏"), ("duo.tabletop", "Duo 上下屏"), ("duo.expanded", "Duo 展开"), ("tablet", "iPad／Mac")]
    static func defaults(_ profile: String) -> Self {
        let size = profile.hasPrefix("duo.") ? 0.65 : 1.0
        return Self(left: StickPlacement(scale: size), right: StickPlacement(scale: size))
    }
    static func load(_ profile: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: "stickLayout.v1." + profile),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return defaults(profile) }
        return value.sanitized
    }
    var sanitized: Self {
        func clean(_ p: StickPlacement) -> StickPlacement {
            func unit(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
            return StickPlacement(scale: p.scale.isFinite ? min(1.5, max(0.4, p.scale)) : 1, x: unit(p.x), y: unit(p.y))
        }
        let valid = Set(PadControl.allCases.filter { $0 != .leftStick && $0 != .rightStick }.map(\.rawValue))
        let controls = buttons?.filter { valid.contains($0.key) }.mapValues(clean)
        return Self(left: clean(left), right: clean(right), buttons: controls)
    }
    func save(_ profile: String) {
        if let data = try? JSONEncoder().encode(sanitized) { UserDefaults.standard.set(data, forKey: "stickLayout.v1." + profile) }
    }
    static func frame(_ base: CGRect, in bounds: CGRect, placement: StickPlacement) -> CGRect {
        guard base.width > 0, base.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let factor = min(placement.scale, bounds.width / base.width, bounds.height / base.height)
        let size = CGSize(width: base.width * factor, height: base.height * factor)
        let center = CGPoint(x: placement.x.map { bounds.minX + $0 * bounds.width } ?? base.midX,
                             y: placement.y.map { bounds.minY + $0 * bounds.height } ?? base.midY)
        return CGRect(x: min(max(bounds.minX, center.x - size.width / 2), bounds.maxX - size.width),
                      y: min(max(bounds.minY, center.y - size.height / 2), bounds.maxY - size.height), width: size.width, height: size.height)
    }
}

