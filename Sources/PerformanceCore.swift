import Foundation
import Darwin
import QuartzCore

/// Count presented frames on devices and successful GPU completions on the
/// simulator, whose SDK does not expose drawable presentation callbacks.
final class PresentedFrames {
    private let lock = NSLock()
    private var times: [Double] = []
    private var diagnosticCount = 0
    private let timingDiagnostic = ProcessInfo.processInfo.environment["PJDV_TIMING_DIAG"] == "1"
    private var benchmark = ProcessInfo.processInfo.environment["PJDV_PERF_TRACE"] == "1"
    private var intervals: [Double] = []
    func record(_ time: Double) {
        guard time.isFinite, time > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard times.last.map({ time > $0 }) ?? true else { return }
        if diagnosticCount < 3 && timingDiagnostic {
            diagnosticCount += 1
            NSLog("PJDV present clock timestamp=%.6f now=%.6f uptime=%.6f", time, CACurrentMediaTime(), Double(DispatchTime.now().uptimeNanoseconds)/1e9)
        }
        if benchmark, let last = times.last { intervals.append((time - last) * 1000); if intervals.count > 1024 { intervals.removeFirst(intervals.count - 1024) } }
        times.append(time)
        if times.count > 240 { times.removeFirst(times.count - 240) }
    }
    func reset() { lock.lock(); times.removeAll(); intervals.removeAll(); lock.unlock() }
    func enableBenchmark() { lock.lock(); benchmark = true; lock.unlock() }
    func takeBenchmarkIntervals() -> [Double] {
        lock.lock(); defer { lock.unlock() }; let value = intervals; intervals.removeAll(keepingCapacity: true); return value
    }
    func fps(at now: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        times.removeAll { $0 < now - 1 }
        guard let first = times.first, let last = times.last,
              times.count >= 2, last > first, now - last < 0.5 else { return 0 }
        return Double(times.count - 1) / (last - first)
    }
}

final class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    let frames = PresentedFrames()
    struct Sample { let fps: Double; let cpuPercent: Double?; let memoryBytes: UInt64? }
    private var lastCPU: Double?
    private var lastWall: Double?
    static func cpuSeconds() -> Double? {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return nil }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
    static func memoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
    /// Sample from one UI timer; 100% CPU is one fully occupied CPU core.
    func sample(at now: Double) -> Sample {
        let cpu = Self.cpuSeconds()
        var percent: Double?
        if let cpu, let old = lastCPU, let wall = lastWall, now > wall, cpu >= old {
            percent = 100 * (cpu - old) / (now - wall)
        }
        lastCPU = cpu; lastWall = now
        let value = Sample(fps: frames.fps(at: now), cpuPercent: percent, memoryBytes: Self.memoryBytes())
        return value
    }
}


@_cdecl("pjdv_frame_presented")
func pjdvFramePresented(_ timestamp: Double) {
    PerformanceMonitor.shared.frames.record(timestamp)
}

@_cdecl("pjdv_monitor_reset")
func resetGamePerformanceFrames() { PerformanceMonitor.shared.frames.reset() }

// Same actual drawable-presented clock as the overlay; source commits and
// synthetic-frame attempts must not be mistaken for physical display FPS.
@_cdecl("pjdv_presented_fps")
func reportedGamePresentedFPS() -> Double {
    PerformanceMonitor.shared.frames.fps(at: CACurrentMediaTime())
}
