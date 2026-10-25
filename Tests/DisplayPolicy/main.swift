import Foundation
import CoreGraphics

func check(_ yes: Bool, _ message: String) { precondition(yes, message) }
for size in [CGSize(width: 1376, height: 1032), CGSize(width: 968, height: 440), CGSize(width: 1024, height: 768)] {
    let bounds = CGRect(origin: .zero, size: size), rect = GameDisplayPolicy.fittedRect(in: CGRect(origin: .zero, size: size))
    check(abs(rect.width / rect.height - 16.0 / 9.0) < 0.00001, "Aspect distortion")
    check(bounds.contains(rect), "Viewport outside device")
    check(abs(rect.midX - bounds.midX) < 0.001 && abs(rect.midY - bounds.midY) < 0.001, "Viewport not centered")
}
check(GameDisplayPolicy.showVirtualPad(enabled: true, controllerCount: 0), "Pad should appear")
check(!GameDisplayPolicy.showVirtualPad(enabled: false, controllerCount: 0), "User disabled pad")
check(!GameDisplayPolicy.showVirtualPad(enabled: true, controllerCount: 1), "Connected controller must hide pad")
check(!GameDisplayPolicy.showVirtualPad(enabled: false, controllerCount: 2), "Controller and preference override")
for density: CGFloat in [1, 2, 3] {
    for size in [CGSize(width: 1194, height: 834), CGSize(width: 752, height: 451)] {
        let fitted = GameDisplayPolicy.fittedRect(in: CGRect(origin: .zero, size: size))
        let pixels = GameDisplayPolicy.drawableSize(mode: "screenfx", bounds: fitted, scale: density)
        check(abs(pixels.width - fitted.width * density) <= 0.5 && abs(pixels.height - fitted.height * density) <= 0.5,
              "Display-size FX must track backing pixels after resize")
        check(pixels == GameDisplayPolicy.drawableSize(mode: "screen", bounds: fitted, scale: density),
              "FX and bilinear comparison must use the same output dimensions")
    }
}
check(GameDisplayPolicy.drawableSize(mode: "1440fx", bounds: .zero, scale: 2) == CGSize(width: 2560, height: 1440), "1440 output")
check(GameDisplayPolicy.drawableSize(mode: "screenfx", bounds: .zero, scale: 2) == CGSize(width: 1920, height: 1080), "Initial zero-size view")
let frames = PresentedFrames()
for i in 0...60 { frames.record(10 + Double(i) / 60) }
check(abs(frames.fps(at: 11) - 60) < 0.001, "Presented frame cadence incorrect")
frames.record(.nan); frames.record(11); frames.record(-1)
check(abs(frames.fps(at: 11) - 60) < 0.001, "Invalid timestamps affected FPS")
check(frames.fps(at: 12) == 0, "Paused renderer must report zero")
let cpu = PerformanceMonitor.cpuSeconds()
check(cpu != nil && cpu! >= 0, "Process CPU measurement unavailable")
let monitor = PerformanceMonitor()
_ = monitor.sample(at: 100)
check(monitor.sample(at: 101).cpuPercent != nil, "CPU delta unavailable")
print("Display/input policy and presentation-FPS tests: PASS")

// Regression: old iPad defaults must never bypass the iPhone output cap.
for requested in ["720p", "1080p", "1080fx", "1440fx", "screen", "screenfx"] {
    let mode = GameDisplayPolicy.outputMode(requested, phone: true)
    let size = GameDisplayPolicy.drawableSize(mode: mode, bounds: CGRect(x: 0, y: 0, width: 1400, height: 1000), scale: 3)
    check(size.width <= 1920 && size.height <= 1080, "Phone inherited an output above 1080p")
    check(GameDisplayPolicy.outputMode(requested, phone: false) == requested, "Tablet settings changed")
}
for bounds in [CGRect(x:0,y:0,width:968,height:440), CGRect(x:0,y:0,width:752,height:451)] {
    let safe = bounds.insetBy(dx:62,dy:24)
    let folded = GameDisplayPolicy.layout(bounds:bounds,safe:safe,phone:true,pose:.folded)
    check(bounds.contains(folded.game) && safe.contains(folded.pad), "Folded layout exceeds screen or control area")
}
let duoBounds = CGRect(x:0,y:0,width:753,height:1080)
let duoSafe = duoBounds.insetBy(dx:12,dy:24)
let duo = GameDisplayPolicy.layout(bounds:duoBounds,safe:duoSafe,phone:true,pose:.tabletop)
check(duo.game.maxY < duoSafe.midY - 15 && duo.pad.minY > duoSafe.midY + 15, "Game/controls overlap hinge")
check(duoSafe.contains(duo.game) && duoSafe.contains(duo.pad), "Tabletop elements outside safe area")
check(!duo.game.intersects(duo.pad), "Lower controller covers upper game")
let expandedBounds = CGRect(x:0,y:0,width:1080,height:753)
let expanded = GameDisplayPolicy.layout(bounds:expandedBounds,safe:expandedBounds.insetBy(dx:12,dy:24),phone:true,pose:.expanded)
check(expanded.game.height > duo.game.height, "Unfold did not restore large game viewport")
print("iPhone output cap / Duo hinge and safe-area regression: PASS")

let malformed = StickLayout(left: StickPlacement(scale: .infinity, x: -2, y: 4), right: StickPlacement(scale: 10, x: .nan, y: nil)).sanitized
check(malformed.left.scale == 1 && malformed.left.x == 0 && malformed.left.y == 1, "Invalid stick coordinates survived")
check(malformed.right.scale == 1.5 && malformed.right.x == nil, "Invalid stick size survived")
let area = CGRect(x: 12, y: 18, width: 400, height: 180)
for x in [0.0, 1.0] { for y in [0.0, 1.0] {
    let frame = StickLayout.frame(CGRect(x: 10, y: 10, width: 150, height: 150), in: area, placement: StickPlacement(scale: 1.5, x: x, y: y))
    check(area.contains(frame), "Dragging placed stick outside controller area")
} }
check(StickLayout.defaults("duo.folded").left.scale < StickLayout.defaults("tablet").left.scale, "Duo sticks were not reduced")
print("Stick sizing / invalid settings / drag boundary regressions: PASS")

// Entry GPUs must reject inherited high-end settings, including debug caps.
for family in [7, 8] {
    let policy = GameHardwarePolicy(family: family)
    check(policy.supported && policy.conservative, "Entry GPU was excluded")
    check(!policy.allowsHDR && !policy.allowsRayTracing, "Entry GPU enabled HDR/RT")
    check(!policy.allows120(phone: false), "Entry tablet enabled 120 FPS")
    for phone in [false, true] {
        check(policy.defaultOutput(phone: phone, metalFX: true) == "720p", "Entry default exceeds conservative target")
        for mode in ["1440fx", "screenfx", "screen", "1080p", "1080fx", "720p"] {
            let capped = GameDisplayPolicy.outputMode(mode, phone: phone, conservative: policy.conservative)
            let pixels = GameDisplayPolicy.drawableSize(mode: capped, bounds: CGRect(x: 0,y: 0,width: 1920,height: 1440), scale: 3)
            check(pixels.width <= 1920 && pixels.height <= 1080, "Saved setting bypasses entry resolution limit")
        }
    }
}
let modern = GameHardwarePolicy(family: 9)
check(modern.allowsHDR && modern.allowsRayTracing && modern.allows120(phone: false), "Modern feature policy regressed")
check(modern.allows120(phone: true), "Family9 phone interpolation research must be eligible")
check(GameHardwarePolicy.cappedFamily(detected: 6, requested: 7) == 6, "Diagnostic cap grants unsupported GPU capability")
check(GameHardwarePolicy.cappedFamily(detected: 9, requested: 7) == 7, "Entry diagnostic cap unavailable")
check(!GameHardwarePolicy(family: 6).supported, "Below minimum GPU admitted")
print("Apple7/8 conservative preset, saved resolution, HDR/RT/120 and minimum-GPU regression: PASS")

// Existing two-stick JSON must decode with no button overrides.
let legacy = Data(#"{"left":{"scale":0.65,"x":0.2,"y":0.7},"right":{"scale":1}}"#.utf8)
let migrated = try JSONDecoder().decode(StickLayout.self, from: legacy).sanitized
check(migrated.left.scale == 0.65 && migrated.buttons == nil, "Legacy stick settings lost")
var allControls = migrated
for control in PadControl.allCases {
    allControls.setPlacement(StickPlacement(scale: 0.7, x: 0.95, y: 0.9), for: control)
}
let decoded = try JSONDecoder().decode(StickLayout.self, from: JSONEncoder().encode(allControls)).sanitized
for control in PadControl.allCases {
    check(decoded.placement(for: control).scale == 0.7 && decoded.placement(for: control).x == 0.95, "Control layout did not round trip")
    let f = StickLayout.frame(CGRect(x: 0, y: 0, width: 150, height: 80), in: area, placement: decoded.placement(for: control))
    check(area.contains(f) && abs(f.width / f.height - 150.0 / 80) < 0.001, "Shoulder aspect/bounds changed")
}
check(StickLayout.defaults("tablet").placement(for: .a).scale == 1, "Default face key size changed")
print("All 18 virtual controls, legacy migration, persistence codec and rectangular shoulder sizing: PASS")

// ProMotion research includes family9+ phones; real refresh and power still gate.
for family in [7, 8, 9] { for phone in [false, true] { for hz in [60, 80, 120] { for lowPower in [false, true] {
    let allowed = GameFrameGenerationPolicy.permits120(hardware: GameHardwarePolicy(family: family), phone: phone, maximumRefresh: hz, lowPower: lowPower)
    check(allowed == (family >= 9 && hz >= 120 && !lowPower), "ProMotion hardware/screen/power cap bypass")
    check(GameFrameGenerationPolicy.launchMode("2", permits120: allowed) == (allowed ? 2 : 0), "Launch override bypassed ProMotion gate")
} } } }
check(GameFrameGenerationPolicy.launchMode("1", permits120: false) == 1, "30-to-60 research mode removed")
for value: String? in [nil, "0", "3", "120", "invalid"] {
    check(GameFrameGenerationPolicy.launchMode(value, permits120: true) == 0, "Unknown FG mode admitted")
}
print("ProMotion family/display/phone/low-power gates and research launch modes: PASS")

for name in ["Apple M3 Ultra", "Apple M5 Max", "Apple M5 Ultra"] {
 check(GameFrameGenerationPolicy.native120ModelAllowed(soc: name, mac: true), "Requested native120 allowlist missing")
 check(!GameFrameGenerationPolicy.native120ModelAllowed(soc: name, mac: false), "Non-Mac enabled native120")
}
for name in ["Apple M3 Max", "Apple M4", "Apple M5", "Unknown"] { check(!GameFrameGenerationPolicy.native120ModelAllowed(soc: name, mac: true), "Native120 allowlist bypass") }
print("Native120 exact Mac SoC allowlist and family9+ interpolation policy: PASS")
