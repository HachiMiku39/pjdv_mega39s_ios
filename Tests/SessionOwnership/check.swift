import Foundation

private let testRoot = URL(fileURLWithPath: CommandLine.arguments[1])
func L(_ text: String) -> String { text }

enum RuntimeModCatalog {
    static var current: Self.Type { Self.self }
    static let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    static func selectedMods() throws -> [Int] {
        entered.signal()
        precondition(resume.wait(timeout: .now() + 4) == .success)
        return []
    }
}

struct AVAudioSession {
    enum Category { case playback }
    enum Mode { case `default` }
    static func sharedInstance() -> Self { Self() }
    func setCategory(_ category: Category, mode: Mode) throws {}
    func setPreferredSampleRate(_ value: Double) throws {}
    func setPreferredIOBufferDuration(_ value: Double) throws {}
    func setActive(_ value: Bool) throws {}
}
struct ResourceAccess { let root: URL }
enum ResourceLibrary {
    static var appDataRoot: URL { testRoot }
    static func open() throws -> ResourceAccess { ResourceAccess(root: testRoot) }
}
struct ResourceLayout {
    struct DLC { let index: Int }
    let rom: URL, dlc: URL
    let languages = ["ja"], dlcContents = [DLC]()
    static func locate(_ root: URL) throws -> Self { Self(rom: root, dlc: root) }
}
enum ModComposition {
    struct Session { let paths: [String], profileID: String? }
    static func prepare(_ mods: [Int], catalog: RuntimeModCatalog.Type, base: URL, dlc: URL, root: URL) throws -> Session {
        fatalError("unexpected fixture mods")
    }
}
enum AppLanguage {
    static let current = "ja"
    static func configure(available: [String]) {}
    static func prepareSession() {}
}
enum GameRenderingAssets { static func root(_ layout: ResourceLayout) throws -> URL { testRoot } }
enum ModSessionUI { static func prepare(bundle: URL, layers: [String], temp: URL, language: String) throws -> URL { bundle } }
enum ModImportController { static func userMessage(_ error: Error) -> String { error.localizedDescription } }

@_silgen_name("test_phase") private func phase() -> Int32
@_silgen_name("test_autoplay") private func autoplay() -> Int32
@_silgen_name("test_save_path") private func savePath() -> UnsafePointer<CChar>
@_silgen_name("test_end_native") private func stopGuest()
@_silgen_name("test_fail_boot") private func failBoot()

@main struct Test {
    final class Host { var started = false; var failure: String? }
    @MainActor static func main() throws {
        let sessions = GameSessionOwnership<Host>()
        let fm = FileManager.default
        let normal = testRoot.appendingPathComponent("GuestSave/score")
        try fm.createDirectory(at: normal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let score = Data("ordinary profile".utf8)
        try score.write(to: normal)
        AutoPlaySession.enabled = true

        func launch(_ host: Host, enhanceSongs: Bool = false) -> Bool {
            guard sessions.claim(host) else { return false }
            GuestRuntime.validateMapping(enhanceSongs: enhanceSongs) { [weak host] event in
                guard let host, sessions.current === host else { return }
                switch event {
                case .status: break
                case .started: host.started = true
                case .failed(let message):
                    precondition(phase() == 0)
                    host.failure = message
                    precondition(sessions.finish(host, cleanup: GuestRuntime.releaseResourceAccess))
                }
            }
            return true
        }
        func runUntil(_ ready: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 4)
            while !ready(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            precondition(ready())
        }
        func unblockPreparation() {
            precondition(RuntimeModCatalog.entered.wait(timeout: .now() + 4) == .success)
            RuntimeModCatalog.resume.signal()
        }

        let externalOverlay = testRoot.appendingPathComponent("developer-overlay", isDirectory: true)
        setenv("DM_ROMFS_OVERLAY", externalOverlay.path, 1)
        let originalROM = ProcessInfo.processInfo.environment["PJDV_RENDER_TEST_ROM"]
        if let rom = originalROM {
            for path in [SongRenderOverlay.adpPath(269), SongRenderOverlay.weights] {
                let source = URL(fileURLWithPath: rom).appendingPathComponent(path)
                let dest = testRoot.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
            }
        }
        func layers() -> [String] {
            String(cString: getenv("PJDV_SESSION_OVERLAY")!).split(separator: ":").map(String.init)
        }
        var windowA: Host? = Host()
        weak var detached = windowA
        let windowB = Host()
        precondition(launch(windowA!, enhanceSongs: true))
        precondition(RuntimeModCatalog.entered.wait(timeout: .now() + 4) == .success)
        precondition(phase() == 0 && !launch(windowB))
        windowA = nil
        precondition(detached != nil && sessions.current === detached)
        RuntimeModCatalog.resume.signal()
        runUntil { detached?.started == true }
        let initialLayers = layers()
        precondition(initialLayers.first == externalOverlay.path)
        if originalROM != nil {
            precondition(initialLayers.count == 2)
            let asset = URL(fileURLWithPath: initialLayers[1]).appendingPathComponent(SongRenderOverlay.adpPath(269))
            precondition(fm.fileExists(atPath: asset.path))
        }
        let path = String(cString: savePath())
        precondition(phase() == 2 && !launch(windowB))
        precondition(!sessions.finish(windowB, cleanup: GuestRuntime.releaseResourceAccess))
        precondition(autoplay() == 1 && fm.fileExists(atPath: path))
        stopGuest()
        precondition(sessions.finish(detached!, cleanup: GuestRuntime.releaseResourceAccess))
        precondition(sessions.current == nil && !fm.fileExists(atPath: path))

        if initialLayers.count == 2 { precondition(!fm.fileExists(atPath: initialLayers[1])) }

        failBoot()
        precondition(launch(windowB))
        unblockPreparation()
        runUntil { windowB.failure != nil }
        precondition(phase() == 0 && sessions.current == nil && autoplay() == 0)
        precondition(!fm.fileExists(atPath: String(cString: savePath())))
        let retry = Host()
        precondition(launch(retry))
        unblockPreparation()
        runUntil { retry.started }
        precondition(layers() == [externalOverlay.path])
        precondition(!sessions.finish(windowB, cleanup: GuestRuntime.releaseResourceAccess))
        precondition(autoplay() == 1 && fm.fileExists(atPath: String(cString: savePath())))
        stopGuest()
        precondition(sessions.finish(retry, cleanup: GuestRuntime.releaseResourceAccess))
        let finalScore = try Data(contentsOf: normal)
        precondition(finalScore == score)
        print("PASS duplicate preparation, retained disconnected owner, stale cleanup rejection, native thread startup failure and retry, ordinary save preserved")
    }
}
