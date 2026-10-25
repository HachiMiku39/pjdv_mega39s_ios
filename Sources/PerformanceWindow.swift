import UIKit
import QuartzCore

@_silgen_name("pjdv_game_frame_generation_mode") private func performanceGameFGMode() -> Int32
@_silgen_name("pjdv_game_fg_source_fps") private func gameFGSourceFPS() -> Double
@_silgen_name("pjdv_game_fg_generated_fps") private func gameFGGeneratedFPS() -> Double

final class PerformanceWindow: UIView {
    private let label = UILabel()
    private let benchmark = AutoPlaySession.enabled || ProcessInfo.processInfo.environment["PJDV_PERF_TRACE"] == "1"
    private var benchmarkFile: FileHandle?
    private var timer: Timer?
    private var position: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var placement = CGRect.zero
    private var compactPlacement = false
    private var expandedPlacement = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        if benchmark { PerformanceMonitor.shared.frames.enableBenchmark() }
        backgroundColor = UIColor.black.withAlphaComponent(0.76)
        layer.cornerRadius = 12
        layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        layer.borderWidth = 1
        label.numberOfLines = AutoPlaySession.enabled ? 4 : 3
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.text = "FPS    —\nCPU    —\nRAM    —"
        label.frame = CGRect(x: 12, y: 9, width: 164, height: 62)
        addSubview(label)
        accessibilityIdentifier = "performance.window"
        isAccessibilityElement = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    deinit { timer?.invalidate() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil {
            update()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
        }
    }
    func place(in safe: CGRect, controlsExpanded: Bool = false, compact: Bool = false) {
        placement = safe; compactPlacement = compact; expandedPlacement = controlsExpanded
        let width: CGFloat = compact ? 126 : (AutoPlaySession.enabled ? 230 : 188), height: CGFloat = (compact ? 56 : 80) + (AutoPlaySession.enabled ? (compact ? 18 : 24) : 0)
        label.font = .monospacedDigitSystemFont(ofSize: compact ? 10 : 14, weight: .medium)
        label.frame = CGRect(x: compact ? 7 : 12, y: compact ? 5 : 9, width: width - (compact ? 14 : 24), height: height - (compact ? 10 : 18))
        let defaultCenter: CGPoint
        if compact && controlsExpanded {
            defaultCenter = CGPoint(x: safe.midX, y: safe.minY + 72 + height / 2)
        } else if controlsExpanded {
            // The enlarged ZR occupies the old top-right panel location.
            // Leave the pad/output toggles above the panel and +/- below it.
            defaultCenter = safe.height >= 500
                ? CGPoint(x: safe.midX, y: safe.minY + 88 + height / 2)
                : CGPoint(x: safe.midX, y: safe.midY)
        } else {
            defaultCenter = CGPoint(x: safe.maxX - width / 2 - 12, y: safe.minY + height / 2 + 12)
        }
        let center = position ?? defaultCenter
        frame = CGRect(x: min(max(safe.minX + 4, center.x - width / 2), safe.maxX - width - 4),
                       y: min(max(safe.minY + 4, center.y - height / 2), safe.maxY - height - 4),
                       width: width, height: height)
    }
    private func update() {
        let sample = PerformanceMonitor.shared.sample(at: CACurrentMediaTime())
        if benchmark { recordBenchmark(sample) }
        let cpu = sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let ram = sample.memoryBytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "—"
        #if targetEnvironment(simulator)
        let fpsLabel = "FPS(GPU)"
        #else
        let fpsLabel = "FPS"
        #endif
        let fpsLine = performanceGameFGMode() != 0
            ? String(format: "%@ %.0f (%.0f+%.0f)", fpsLabel, sample.fps, gameFGSourceFPS(), gameFGGeneratedFPS())
            : String(format: "%@ %.1f", fpsLabel, sample.fps)
        label.text = String(format: "%@\nCPU    %@\nRAM    %@", fpsLine, cpu, ram)
        if AutoPlaySession.enabled { label.text! += "\n" + L("AutoPlay 测试 · 不记录成绩") }
        accessibilityLabel = label.text
        accessibilityValue = L("CPU 单核满载为 100%，RAM 为 App 内存占用") + (performanceGameFGMode() != 0 ? L("；括号为真实源帧率＋生成帧率") : "")
    }
    private func recordBenchmark(_ sample: PerformanceMonitor.Sample) {
        let row: [String: Any] = ["uptime": CACurrentMediaTime(), "presentedFPS": sample.fps,
            "cpuPercent": sample.cpuPercent.map { $0 as Any } ?? NSNull(),
            "memoryBytes": sample.memoryBytes.map { $0 as Any } ?? NSNull(),
            "frameIntervalsMS": PerformanceMonitor.shared.frames.takeBenchmarkIntervals(),
            "autoplay": AutoPlaySession.enabled, "diagnosticCoolHits": autoplayHits(), "sourceFrames": guestSubmittedFrames()]
        do {
            if benchmarkFile == nil {
                let path = ResourceLibrary.appDataRoot.appendingPathComponent("PJDV-benchmark.jsonl")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                benchmarkFile = try FileHandle(forWritingTo: path)
            }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            try benchmarkFile?.write(contentsOf: data)
        } catch { NSLog("PJDV benchmark log: %@", error.localizedDescription) }
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        if gesture.state == .began { dragOrigin = center }
        let delta = gesture.translation(in: parent)
        position = CGPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y)
        place(in: placement, controlsExpanded: expandedPlacement, compact: compactPlacement)
    }
}

@_silgen_name("pjdv_autoplay_hits") private func autoplayHits() -> UInt64
