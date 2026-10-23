import Foundation
import CoreGraphics

struct StickPlacement: Codable {
    var scale: Double
    var x: Double?, y: Double?
}
struct StickLayout: Codable {
    var left: StickPlacement, right: StickPlacement
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
        return Self(left: clean(left), right: clean(right))
    }
    func save(_ profile: String) {
        if let data = try? JSONEncoder().encode(sanitized) { UserDefaults.standard.set(data, forKey: "stickLayout.v1." + profile) }
    }
    static func frame(_ base: CGRect, in bounds: CGRect, placement: StickPlacement) -> CGRect {
        let size = min(base.width * placement.scale, min(bounds.width, bounds.height))
        let center = CGPoint(x: placement.x.map { bounds.minX + $0 * bounds.width } ?? base.midX,
                             y: placement.y.map { bounds.minY + $0 * bounds.height } ?? base.midY)
        return CGRect(x: min(max(bounds.minX, center.x - size / 2), bounds.maxX - size),
                      y: min(max(bounds.minY, center.y - size / 2), bounds.maxY - size), width: size, height: size)
    }
}

