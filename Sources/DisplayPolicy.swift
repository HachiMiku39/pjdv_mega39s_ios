import Foundation
import CoreGraphics

/// Apple7/8 uses a conservative preset; capability flags still gate features.
struct GameHardwarePolicy {
    let family: Int
    var supported: Bool { family >= 7 }
    var conservative: Bool { family < 9 }
    var allowsHDR: Bool { supported && !conservative }
    var allowsRayTracing: Bool { supported && !conservative }
    func allows120(phone: Bool) -> Bool { supported && !conservative }
    func cappedTo1080(phone: Bool) -> Bool { phone || conservative }
    func defaultOutput(phone: Bool, metalFX: Bool, mac: Bool = false) -> String {
        if mac { return !conservative && metalFX ? "1080fx" : "1080p" }
        if conservative { return "720p" }
        return metalFX ? (phone ? "1080fx" : "screenfx") : "1080p"
    }
    /// Diagnostic caps can exercise restrictions, never grant newer GPU features.
    static func cappedFamily(detected: Int, requested: Int?) -> Int {
        guard let requested, (7...9).contains(requested) else { return detected }
        return min(detected, requested)
    }
}

enum GameFrameGenerationPolicy {
    static func native120ModelAllowed(soc: String, mac: Bool) -> Bool {
        mac && ["Apple M3 Ultra", "Apple M5 Max", "Apple M5 Ultra"].contains(soc)
    }
    static func permits120(hardware: GameHardwarePolicy, phone: Bool, maximumRefresh: Int, lowPower: Bool) -> Bool {
        hardware.allows120(phone: phone) && maximumRefresh >= 120 && !lowPower
    }
    static func launchMode(_ requested: String?, permits120: Bool) -> Int32 {
        if requested == "1" { return 1 }
        if requested == "2", permits120 { return 2 }
        return 0
    }
}

struct GameDisplayPolicy {
    enum DuoPose: String { case ordinary, folded, tabletop, expanded }
    static func outputMode(_ requested: String, phone: Bool, conservative: Bool = false, mac: Bool = false) -> String {
        // Explicit desktop/window pixel matching is available on every Apple
        // Silicon Mac. It grants no HDR/RT/120 capability or new default preset.
        if requested == "desktop" { return mac ? requested : "1080p" }
        if mac && requested == "screen" { return requested }
        guard phone || conservative else { return requested }
        switch requested {
        case "1440fx", "screenfx": return "1080fx"
        case "screen": return "1080p"
        default: return requested
        }
    }
    static func layout(bounds: CGRect, safe: CGRect, phone: Bool, pose: DuoPose) -> (game: CGRect, pad: CGRect, controls: CGRect, metrics: CGRect) {
        if phone && pose == .tabletop {
            // Leave the physical fold free of both image edges and hit regions.
            let upper = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, safe.height / 2 - 16))
            let lower = CGRect(x: safe.minX, y: safe.midY + 16, width: safe.width, height: max(0, safe.height / 2 - 16))
            let pad = CGRect(x: lower.minX + 12, y: lower.minY + 72, width: max(0, lower.width - 24), height: max(0, lower.height - 84))
            return (fittedRect(in: upper), pad, lower, upper)
        }
        // Duo uses the full display: asymmetric sensor insets must not shift
        // its 16:9 image. Natural letterboxing holds the system status bar.
        let available = phone && pose == .ordinary ? safe : bounds
        let padHeight = min(CGFloat(572), max(0, safe.height - 24))
        return (fittedRect(in: available), CGRect(x: safe.minX + 12, y: safe.maxY - padHeight - 12,
                 width: max(0, safe.width - 24), height: padHeight), safe, safe)
    }
    static let aspect = CGFloat(16.0 / 9.0)
    static func fittedRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }
    static func showVirtualPad(enabled: Bool, controllerCount: Int) -> Bool {
        enabled && controllerCount == 0
    }
    static func drawableSize(mode: String, bounds: CGRect, scale: CGFloat) -> CGSize {
        switch mode {
        case "720p": return CGSize(width: 1280, height: 720)
        case "1440fx": return CGSize(width: 2560, height: 1440)
        case "screen", "screenfx":
            guard bounds.width > 0, bounds.height > 0, scale.isFinite, scale > 0 else {
                return CGSize(width: 1920, height: 1080)
            }
            return CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        default: return CGSize(width: 1920, height: 1080)
        }
    }
    static func usesMetalFX(mode: String) -> Bool {
        ["1080fx", "1440fx", "screenfx"].contains(mode)
    }
    static func fitOutput(_ requested: CGSize, within panel: CGSize) -> CGSize {
        // A detached or reconfiguring display does not yet have a usable limit.
        let placeholder = CGSize(width: 1, height: 1)
        guard requested.width.isFinite, requested.height.isFinite, requested.width >= 1, requested.height >= 1,
              panel.width.isFinite, panel.height.isFinite, panel.width >= 1, panel.height >= 1 else { return placeholder }
        let width = floor(panel.width), height = floor(panel.height)
        let ratio = min(1, width / requested.width, height / requested.height)
        return CGSize(width: min(width, max(1, (requested.width * ratio).rounded())),
                      height: min(height, max(1, (requested.height * ratio).rounded())))
    }
    static func orientedPanel(_ native: CGSize, displayBounds: CGSize) -> CGSize {
        guard (native.width > native.height) != (displayBounds.width > displayBounds.height),
              displayBounds.width > 0, displayBounds.height > 0 else { return native }
        return CGSize(width: native.height, height: native.width)
    }
    static func desktopDrawableSize(pixels: CGSize) -> CGSize {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 16, pixels.height >= 9,
              pixels.width <= 16384, pixels.height <= 16384 else { return CGSize(width: 1920, height: 1080) }
        let fitted = fittedRect(in: CGRect(origin: .zero, size: pixels))
        return CGSize(width: fitted.width.rounded(), height: fitted.height.rounded())
    }
}
