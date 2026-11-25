// swiftc Sources/SongRenderProfile.swift Tests/SongRenderProfile/main.swift -o <test>
// <test> <scratch-directory> [user's original romfs directory]
import Foundation
import Darwin

let args = CommandLine.arguments
precondition((2...3).contains(args.count))
let fm = FileManager.default
let temp = URL(fileURLWithPath: args[1]).appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }

let domain = "pjdv.tests.render." + UUID().uuidString
let defaults = UserDefaults(suiteName: domain)!
defer { defaults.removePersistentDomain(forName: domain) }
let key = "highRenderQuality"
func choice() -> GameRenderQuality { .selection(defaults: defaults, key: key) }

precondition(choice() == .automatic)
precondition(!choice().usesHighGameProfile(initialDocked: false))
precondition(choice().usesHighGameProfile(initialDocked: true))
precondition(!choice().improvesSongRendering(family: 7) && !choice().improvesSongRendering(family: 8))
precondition(choice().improvesSongRendering(family: 9))
GameRenderQuality.high.store(in: defaults, key: key)
precondition(choice().improvesSongRendering(family: 7) && choice().usesHighGameProfile(initialDocked: false))
GameRenderQuality.standard.store(in: defaults, key: key)
precondition(!choice().improvesSongRendering(family: 9) && !choice().usesHighGameProfile(initialDocked: true))
GameRenderQuality.automatic.store(in: defaults, key: key)
precondition(choice() == .automatic && defaults.object(forKey: key) == nil)

var ownedTestLayers = [URL]()
defer { for layer in ownedTestLayers { try? fm.removeItem(at: layer) } }
let asset = SongRenderOverlay.adpPath(269)
let weights = SongRenderOverlay.weights
let unknown = temp.appendingPathComponent("unknown"), mod = temp.appendingPathComponent("mod")
func store(_ data: Data, in root: URL, at name: String) throws {
    let file = root.appendingPathComponent(name)
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
}
func plan(_ rom: URL, layers: [String] = [], enabled: Bool = true, unlockPVRate: Bool = false, destination: URL = temp) -> (URL?, [String]) {
    var ordered = layers
    let output = SongRenderOverlay.prepare(enabled: enabled, unlockPVRate: unlockPVRate, rom: rom, layers: &ordered, temp: destination)
    if let output { ownedTestLayers.append(output) }
    return (output, ordered)
}
func require(_ value: URL?) throws -> URL {
    guard let value else { throw NSError(domain: "missing expected layer", code: 1) }
    return value
}
precondition(plan(unknown).0 == nil)
try store(Data(repeating: 0, count: 15_032), in: unknown, at: asset)
try store(Data(repeating: 0, count: 3762), in: unknown, at: weights)
precondition(plan(unknown).0 == nil)
if args.count == 3 {
    let rom = URL(fileURLWithPath: args[2])
    let table = try Data(contentsOf: rom.appendingPathComponent(weights))
    let source = String(decoding: table, as: UTF8.self)
    let ids = [269, 271, 832]
    func verifyLayer(_ root: URL, songs allowed: [Int], input: String) throws {
        var expected = input
        for id in ids {
            let path = SongRenderOverlay.adpPath(id)
            let file = root.appendingPathComponent(path)
            precondition(fm.fileExists(atPath: file.path) == allowed.contains(id))
            if allowed.contains(id) {
                let w = id == 271 ? 3 : 1
                expected = expected.replacingOccurrences(of: "pv_weight.\(id)=\(w)", with: "pv_weight.\(id)=0")
            }
        }
        let actual = try Data(contentsOf: root.appendingPathComponent(weights))
        precondition(actual == Data(expected.utf8))
    }
    let vanilla = try require(plan(rom).0)
    try verifyLayer(vanilla, songs: ids, input: source)
    for (id, offset, prior) in [(269, 0x430, 0x30), (271, 0x730, 0x30), (832, 0x6d0, 0x50)] {
        let path = SongRenderOverlay.adpPath(id)
        let original = try Data(contentsOf: rom.appendingPathComponent(path))
        let changed = try Data(contentsOf: vanilla.appendingPathComponent(path))
        precondition(original.count == changed.count)
        precondition(original.indices.filter { original[$0] != changed[$0] } == [offset + 2])
        precondition(original[offset..<(offset + 4)].elementsEqual([0, 0, UInt8(prior), 0x3f]))
        precondition(changed[offset..<(offset + 4)].elementsEqual([0, 0, 0x80, 0x3f]))
    }
    let explicitHigh = try require(plan(rom, unlockPVRate: true).0)
    try verifyLayer(explicitHigh, songs: ids, input: source)
    for id in ids {
        let path = SongRenderOverlay.adpPath(id)
        let automatic = try Data(contentsOf: vanilla.appendingPathComponent(path))
        let high = try Data(contentsOf: explicitHigh.appendingPathComponent(path))
        let changedOffsets = automatic.indices.filter { automatic[$0] != high[$0] }
        if let flag = [271: 0x770, 832: 0x710][id] {
            precondition(changedOffsets == [flag] && automatic[flag] == 1 && high[flag] == 0)
        } else { precondition(changedOffsets.isEmpty) }
    }
    let overlayADPs = try fm.contentsOfDirectory(atPath: vanilla.appendingPathComponent("rom_switch/rom/add_param").path)
    precondition(Set(overlayADPs) == Set(ids.map { "pv_\($0).adp" }))
    precondition(plan(rom, enabled: false).0 == nil)

    // A complete table may contain other Mod edits and its own formatting.
    let other = source.replacingOccurrences(of: "pv_weight.002=0", with: "pv_weight.002=-2")
        .replacingOccurrences(of: "\n", with: "\r\n") + "pv_weight.1999=-2\r\n"
    try store(Data(other.utf8), in: mod, at: weights)
    let unrelated = temp.appendingPathComponent("earlier").path
    let (merged, ordered) = plan(rom, layers: [unrelated, mod.path])
    let mergedRoot = try require(merged)
    precondition(ordered == [unrelated, mergedRoot.path, mod.path])
    try verifyLayer(mergedRoot, songs: ids, input: other)
    let modSource = try Data(contentsOf: mod.appendingPathComponent(weights))
    precondition(modSource == Data(other.utf8))

    for id in ids {
        let path = SongRenderOverlay.adpPath(id)
        try store(Data("custom ADP".utf8), in: mod, at: path)
        let root = try require(plan(rom, layers: [mod.path], unlockPVRate: true).0)
        try verifyLayer(root, songs: ids.filter { $0 != id }, input: other)
        try fm.removeItem(at: mod.appendingPathComponent(path))
    }
    for content in [
        source.replacingOccurrences(of: "pv_weight.269=1", with: "pv_weight.269=-2"),
        source.replacingOccurrences(of: "pv_weight.269=1", with: ""),
        source + "pv_weight.0269=1\n",
        source + "pv_weight.269=1\n"
    ] {
        try store(Data(content.utf8), in: mod, at: weights)
        try verifyLayer(require(plan(rom, layers: [mod.path]).0), songs: [271, 832], input: content)
    }
    for invalid in ["pv_weight.269=1\n", source + "unknown=1\n"] {
        try store(Data(invalid.utf8), in: mod, at: weights)
        let (layer, paths) = plan(rom, layers: [mod.path])
        precondition(layer == nil && paths == [mod.path])
    }
    // An unknown PV269 asset must not suppress PV271; a missing PV832 is skipped independently.
    try store(table, in: unknown, at: weights)
    let teo = SongRenderOverlay.adpPath(271)
    try store(Data(contentsOf: rom.appendingPathComponent(teo)), in: unknown, at: teo)
    try verifyLayer(require(plan(unknown).0), songs: [271], input: source)
    let separate = try require(plan(rom).0)
    precondition(separate != vanilla && !separate.path.hasPrefix(temp.path + "/"))
    var firstStat = stat(), secondStat = stat()
    precondition(stat(temp.path, &firstStat) == 0 && stat(separate.path, &secondStat) == 0)
    precondition(firstStat.st_dev == secondStat.st_dev)
    try fm.removeItem(at: separate)
    precondition(fm.fileExists(atPath: vanilla.appendingPathComponent(weights).path))

    // A real write failure occurs after the system grants our replacement directory.
    var saved = rlimit()
    precondition(getrlimit(RLIMIT_FSIZE, &saved) == 0)
    let originalHandler = signal(SIGXFSZ, SIG_IGN)
    var limited = saved
    limited.rlim_cur = 512
    precondition(setrlimit(RLIMIT_FSIZE, &limited) == 0)
    var failedLayers = [unrelated]
    let failed = SongRenderOverlay.prepare(enabled: true, rom: rom, layers: &failedLayers, temp: temp)
    precondition(setrlimit(RLIMIT_FSIZE, &saved) == 0)
    signal(SIGXFSZ, originalHandler)
    precondition(failed == nil && failedLayers == [unrelated])
    let afterTable = try Data(contentsOf: rom.appendingPathComponent(weights))
    precondition(afterTable == table)
    print("PV269/271/832: exact time-zero scale, explicit-high cadence flags and three weights; later keyframes, per-song Mod priority, unrelated rows, invalid assets and staging fallback passed")
}
print("Auto/standard/high, GPU family 7/8/9, missing and unknown baseline passed")
