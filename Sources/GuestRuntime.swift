import Foundation
import AVFAudio

@_silgen_name("pjdv_guest_load")
private func loadGuestImages(_ error: UnsafeMutablePointer<CChar>, _ capacity: UInt) -> Int32
@_silgen_name("pjdv_guest_math_probe")
private func guestMathProbe() -> Int32

@_silgen_name("pjdv_attach_metal_layer")
func attachGuestMetalLayer(_ layer: UnsafeMutableRawPointer)

@_silgen_name("pjdv_guest_boot")
private func bootGuest(_ rom: UnsafePointer<CChar>, _ dlc: UnsafePointer<CChar>, _ save: UnsafePointer<CChar>, _ temp: UnsafePointer<CChar>, _ log: UnsafePointer<CChar>)
@_silgen_name("pjdv_guest_state")
private func readGuestState(_ out: UnsafeMutablePointer<CChar>, _ capacity: UInt)

enum GuestRuntime {
    private static var resources: ResourceAccess?
    static func releaseResourceAccess() { resources = nil }
    static func currentStatus() -> String {
        var value = [CChar](repeating: 0, count: 256)
        value.withUnsafeMutableBufferPointer { readGuestState($0.baseAddress!, UInt($0.count)) }
        return String(cString: value)
    }
    static func validateMapping(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error = [CChar](repeating: 0, count: 256)
            let loaded = error.withUnsafeMutableBufferPointer {
                loadGuestImages($0.baseAddress!, UInt($0.count))
            }
            let message: String
            if loaded == 0 {
                message = "Guest mapping failed: " + String(cString: error)
            } else if guestMathProbe() == 0 {
                message = "Guest native SDK probe failed"
            } else {
                message = "Guest images mapped • SDK probe passed\nGame initialization pending"
            }
            DispatchQueue.main.async { completion(message) }
            guard loaded != 0, guestMathProbe() != 0 else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .default)
                try audio.setPreferredSampleRate(48_000)
                try audio.setPreferredIOBufferDuration(0.005)
                try audio.setActive(true)
                let documents = ResourceLibrary.appDataRoot
                #if targetEnvironment(macCatalyst)
                // An explicit isolated profile is useful for first-boot regression.
                // Ordinary launches always keep the existing Documents profile.
                let save = ProcessInfo.processInfo.environment["PJDV_SAVE_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? documents.appendingPathComponent("GuestSave", isDirectory: true)
                #else
                let save = documents.appendingPathComponent("GuestSave", isDirectory: true)
                #endif
                let temp = documents.appendingPathComponent("GuestTemp", isDirectory: true)
                try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let access = try ResourceLibrary.open()
                let layout = try ResourceLayout.locate(access.root)
                AppLanguage.configure(available: layout.languages)
                AppLanguage.prepareSession()
                // Declare only this import's validated, physically complete
                // DLC set. Stale folders and unrelated content are not exposed.
                setenv("PJDV_DLC_INDEXES",layout.dlcContents.map{String($0.index)}.joined(separator:","),1)
                setenv("PJDV_UNLOCK_ALL","1",1)
                let renderingRoot = try GameRenderingAssets.root(layout)
                setenv("PJDV_RENDER_ROOT", renderingRoot.path, 1)
                resources = access
                let rom = layout.rom.path
                let dlc = layout.dlc.path
                guard let menuRoot = Bundle.main.url(forResource: "ExitMenu", withExtension: nil),
                      FileManager.default.fileExists(atPath: menuRoot.appendingPathComponent("manifest.json").path) else {
                    DispatchQueue.main.async { completion("Exit menu resources unavailable") };return
                }
                setenv("PJDV_EXIT_MENU_ROOT", menuRoot.path, 1)
                rom.withCString { r in dlc.withCString { d in save.path.withCString { s in temp.path.withCString { t in
                    documents.appendingPathComponent("PJDV-runtime.log").path.withCString { log in bootGuest(r, d, s, t, log) }
                } } } }
            } catch {
                DispatchQueue.main.async { completion("Guest storage: " + error.localizedDescription) }
            }
        }
    }
}

@_silgen_name("pjdv_game_graphics_active")
func gameGraphicsActive() -> Int32
@_silgen_name("dm_nvn_frame_count")
func guestSubmittedFrames() -> UInt64
@_silgen_name("dm_pad_set")
private func setGuestPad(_ buttons: UInt64, _ lx: Int32, _ ly: Int32, _ rx: Int32, _ ry: Int32)
private struct NativeTouch { let id: UInt32; let x: Float; let y: Float }
@_silgen_name("dm_touch_set")
private func setGuestTouches(_ values: UnsafePointer<NativeTouch>?, _ count: Int32)
@_silgen_name("dm_touch_reset")
private func resetGuestTouches()
func publishGuestInput(_ frame: InputFrame, resetTouches: Bool = false) {
    if resetTouches { resetGuestTouches() }
    func axis(_ n: Float) -> Int32 { Int32((n * 32767).rounded()) }
    let pad = frame.pad
    setGuestPad(pad.buttons.rawValue, axis(pad.leftStick.x), axis(pad.leftStick.y), axis(pad.rightStick.x), axis(pad.rightStick.y))
    let values = frame.touches.map { NativeTouch(id: UInt32($0.id), x: $0.x, y: $0.y) }
    values.withUnsafeBufferPointer { setGuestTouches($0.baseAddress, Int32($0.count)) }
}
