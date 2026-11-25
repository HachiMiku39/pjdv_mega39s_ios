import Foundation
import CryptoKit

enum GameRenderQuality: CaseIterable {
    case automatic, standard, high

    static func selection(defaults: UserDefaults, key: String) -> Self {
        guard let value = defaults.object(forKey: key) as? Bool else { return .automatic }
        return value ? .high : .standard
    }

    func store(in defaults: UserDefaults, key: String) {
        if self == .automatic { defaults.removeObject(forKey: key) }
        else { defaults.set(self == .high, forKey: key) }
    }

    func usesHighGameProfile(initialDocked: Bool) -> Bool {
        self == .high || (self == .automatic && initialDocked)
    }

    func improvesSongRendering(family: Int) -> Bool {
        self == .high || (self == .automatic && family >= 9)
    }
}

struct InternalSceneResolution {
    static let environmentKey = "PJDV_INTERNAL_1080P"
    private static let preferenceKey = "experimentalInternal1080p"
    private let defaults: UserDefaults
    let testOverride: Bool?

    init(defaults: UserDefaults, testEnvironment: [String: String] = [:]) {
        self.defaults = defaults
        if testEnvironment["PJDV_APP_DATA_TEST_ROOT"]?.hasPrefix("/") == true,
           let flag = testEnvironment[Self.environmentKey], flag == "0" || flag == "1" {
            testOverride = flag == "1"
        } else {
            testOverride = nil
        }
    }

    var enabled: Bool { testOverride ?? defaults.bool(forKey: Self.preferenceKey) }

    func select(_ enabled: Bool) {
        guard testOverride == nil else { return }
        defaults.set(enabled, forKey: Self.preferenceKey)
    }
}

enum SongRenderOverlay {
    static let weights = "rom_switch/rom/pv_weight_db.txt"
    static func adpPath(_ id: Int) -> String { "rom_switch/rom/add_param/pv_\(id).adp" }

    // Offsets identify time-zero properties in these exact ADP files: 77 is
    // handheld resolution and 75 is the handheld PV 30 FPS limit (one byte).
    private struct Song {
        let id: Int, weight: Int, size: Int, scaleOffset: Int
        let rateLimitOffset: Int?
        let digest: String
    }
    private static let songs = [
        Song(id: 269, weight: 1, size: 15_032, scaleOffset: 0x430, rateLimitOffset: nil,
             digest: "982072ca82e580d6e98975bc4a5d91c5ef6abfbe39131fea85ebed78c51d6a01"),
        Song(id: 271, weight: 3, size: 7_512, scaleOffset: 0x730, rateLimitOffset: 0x770,
             digest: "b67d29601bd1b138d899c004c370df6131bb67b343d4e35fd03f8b3785e3c522"),
        Song(id: 832, weight: 1, size: 7_864, scaleOffset: 0x6d0, rateLimitOffset: 0x710,
             digest: "2c3fd54b6f7d7200fc6d07e157b33a57d36e6bda36c43985a1d18f8fba682e00")
    ]
    private static let ghostRule = Song(id: 266, weight: 3, size: 23_896, scaleOffset: 0x5f0, rateLimitOffset: nil,
        digest: "db35714c3b4dc442f4ab86defa8c3d83aabe93dd27a43634cace4fad81cdb144")
    private static let loveIsWar = Song(id: 1, weight: -1, size: 2_296, scaleOffset: 0x4b0, rateLimitOffset: nil,
        digest: "f3144fca02c96270087ad6cab50df4b7401f1e393c6ac262dc4e0feb0eb7cb29")
    static let loveIsWarADP = "rom_switch_dlc/dlc7/rom/add_param/pv_001.adp"
    static let dlc7Weights = "rom_switch_dlc/dlc7/rom/dlc7_pv_weight_db.txt"

    private static func read(_ url: URL, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, (0...limit).contains(size),
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: size + 1), bytes.count == size else { return nil }
        return bytes
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // Identify the digit in each unambiguous, stock song row. An absent,
    // changed or duplicate target opts out just that song, including its ADP.
    private static func weightFields(_ data: Data, songs: [Song]) -> (otherKeys: Set<String>, offsets: [Int: Int])? {
        let groups = ["pv_weight", "module_weight", "hairstyle_weight", "threshold_weight",
                      "game_mode_weight", "customize_item_weight"]
        var otherKeys = Set<String>(), seenSongs = Set<Int>(), offsets = [Int: Int]()
        for raw in data.split(separator: 10) {
            let line = raw.last == 13 ? raw.dropLast() : raw[...]
            guard var text = String(data: line, encoding: .utf8) else { return nil }
            if line.startIndex == 0, text.first == "\u{FEFF}" { text.removeFirst() }
            if text.isEmpty || text.hasPrefix("#") { continue }
            let fields = text.split(separator: "=", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let key = String(fields[0])
            let name = key.split(separator: ".", omittingEmptySubsequences: false)
            guard name.count == 2, groups.contains(String(name[0])) else { return nil }
            if name[0] == "pv_weight" {
                guard let id = Int(name[1]), id >= 0 else { return nil }
                if let song = songs.first(where: { $0.id == id }) {
                    let first = seenSongs.insert(id).inserted
                    if first && text == "pv_weight.\(id)=\(song.weight)" { offsets[id] = line.endIndex - 1 }
                    else { offsets.removeValue(forKey: id) }
                    continue
                }
            }
            guard Int32(fields[1]) != nil, otherKeys.insert(key).inserted else { return nil }
        }
        return (otherKeys, offsets)
    }

    private static func scaledADP(_ song: Song, file: URL, unlockPVRate: Bool) -> Data? {
        guard var adp = read(file, limit: song.size), adp.count == song.size, digest(adp) == song.digest else { return nil }
        var scale = Float(1).bitPattern.littleEndian
        withUnsafeBytes(of: &scale) { adp.replaceSubrange(song.scaleOffset..<(song.scaleOffset + $0.count), with: $0) }
        if unlockPVRate, let flag = song.rateLimitOffset { adp[flag] = 0 }
        return adp
    }

    static func prepare(enabled: Bool, unlockPVRate: Bool = false, internal1080: Bool = false,
                        rom: URL, dlc7: URL? = nil, layers: inout [String], temp: URL) -> URL? {
        let baseSongs = internal1080 ? songs + [ghostRule] : songs
        guard enabled || internal1080,
              let original = read(rom.appendingPathComponent(weights), limit: 3762), original.count == 3762,
              digest(original) == "e9ff207c2eeab9b73a4bc970d3173bbb90090327ee854d5df94eecf69d911202",
              let base = weightFields(original, songs: baseSongs) else { return nil }
        let fm = FileManager.default
        func provider(_ relativePath: String) -> Int? {
            layers.firstIndex { fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(relativePath).path) }
        }
        var table = original, offsets = base.offsets
        var position = layers.endIndex
        if let index = provider(weights) {
            let url = URL(fileURLWithPath: layers[index]).appendingPathComponent(weights)
            guard let custom = read(url, limit: 256 * 1024), let fields = weightFields(custom, songs: baseSongs),
                  base.otherKeys.isSubset(of: fields.otherKeys) else { return nil }
            table = custom
            offsets = fields.offsets
            // Preserve every unrelated byte and place the merged table
            // immediately before its provider so the change takes effect.
            position = index
        }
        var files = [(String, Data)]()
        for song in baseSongs {
            let path = adpPath(song.id)
            guard let offset = offsets[song.id], provider(path) == nil,
                  let adp = scaledADP(song, file: rom.appendingPathComponent(path), unlockPVRate: unlockPVRate) else { continue }
            table[offset] = 0x30 // ASCII zero selects the original MAX quality threshold for this PV.
            files.append((path, adp))
        }
        if !files.isEmpty { files.append((weights, table)) }
        // This DLC has its own weight table and a negative weight for PV001.
        // Keep the DLC's table intact and defer to any Mod supplying it or the ADP.
        if internal1080, let dlc7, provider(loveIsWarADP) == nil, provider(dlc7Weights) == nil,
           let dlcTable = read(dlc7.appendingPathComponent(dlc7Weights), limit: 641),
           digest(dlcTable) == "60b01fbe93fc4446efd6a39d9d5c4e6c9e89af0edd99695f2eded54a7167467b",
           let adp = scaledADP(loveIsWar, file: dlc7.appendingPathComponent(loveIsWarADP), unlockPVRate: false) {
            files.append((loveIsWarADP, adp))
        }
        guard !files.isEmpty else { return nil }
        // Foundation creates a unique, purgeable directory on the session
        // volume. An abrupt process exit leaves no PV data in Documents.
        guard let root = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: temp, create: true) else { return nil }
        do {
            for (relativePath, data) in files {
                let target = root.appendingPathComponent(relativePath)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            layers.insert(root.path, at: position)
            return root
        } catch {
            try? fm.removeItem(at: root)
            NSLog("PJDV song render override unavailable (%d)", (error as NSError).code)
            return nil
        }
    }
}
