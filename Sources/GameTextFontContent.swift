import Foundation

/// Only values presented as song titles, lyrics, or costume names receive
/// private display codes. IDs, sort readings, credits and other UI strings
/// keep their original bytes, even when they contain exactly the same text.
enum GameTextFontContent {
    typealias Scalar = Unicode.Scalar
    private typealias F = ModFormats

    fileprivate enum Edits {
        case text([Range<Int>])
        case archive([String: [Range<Int>]])
        case strings([Int])
    }
    fileprivate struct Input {
        let source: URL, relative: String, fingerprint: String
        let edits: Edits
    }
    struct Plan {
        fileprivate var inputs = [Input]()
        fileprivate(set) var characters = Set<Scalar>()

        func write(aliases: [Scalar: Scalar], to root: URL) throws {
            guard !aliases.isEmpty else { return }
            for input in inputs {
                try autoreleasepool {
                    let original = try F.read(input.source)
                    guard F.sha(original) == input.fingerprint else { throw ModLoadError.invalid }
                    let output: Data
                    switch input.edits {
                    case let .text(ranges):
                        output = try GameTextFontContent.replace(original, ranges, aliases)
                    case let .archive(ranges):
                        var parts = try F.archive(original)
                        for index in parts.indices {
                            if let edits = ranges[parts[index].name] {
                                parts[index].data = try GameTextFontContent.replace(parts[index].data, edits, aliases)
                            }
                        }
                        output = try F.archiveData(parts)
                    case let .strings(indices):
                        let values = try F.strings(original)
                        var changed = [Int: String]()
                        for i in indices {
                            let next = GameTextFontContent.encoded(values[i], aliases)
                            if next != values[i] { changed[i] = next }
                        }
                        guard !changed.isEmpty else { return }
                        output = try F.changeStrings(original, changed)
                    }
                    let path = root.appendingPathComponent(input.relative)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // The caller publishes this private session directory only after every file succeeds.
                    try output.write(to: path)
                }
            }
        }
    }

    // The game uses a BMP character table. Keep whitespace, existing private
    // icons, multi-scalar sequences and escape sequences intact. NFC lets e.g.
    // a decomposed accented Latin letter use a single available glyph.
    private static func displayScalar(_ character: Character) -> Scalar? {
        let raw = character.unicodeScalars
        let normalized = raw.count == 1 ? raw : String(character).precomposedStringWithCanonicalMapping.unicodeScalars
        guard normalized.count == 1, let s = normalized.first,
              !s.properties.isWhitespace, s.properties.generalCategory != .control,
              s.properties.generalCategory != .format, s.properties.generalCategory != .privateUse,
              s.properties.generalCategory != .nonspacingMark, s.properties.generalCategory != .unassigned else { return nil }
        return s
    }

    private static func visit(_ value: String, _ body: (Character, Scalar?) -> Void) {
        var escaped = false
        for c in value {
            if escaped || c == "\\" {
                body(c, nil)
                escaped = !escaped && c == "\\"
            } else {
                body(c, displayScalar(c))
            }
        }
    }

    private static func encoded(_ value: String, _ aliases: [Scalar: Scalar]) -> String {
        var out = String()
        out.reserveCapacity(value.utf8.count)
        visit(value) { c, scalar in
            if let scalar, let alias = aliases[scalar] { out.unicodeScalars.append(alias) }
            else { out.append(c) }
        }
        return out
    }

    private static func replace(_ bytes: Data, _ ranges: [Range<Int>], _ aliases: [Scalar: Scalar]) throws -> Data {
        var out = Data(), cursor = 0
        out.reserveCapacity(bytes.count)
        for range in ranges {
            guard let value = String(data: bytes[range], encoding: .utf8) else { throw ModLoadError.invalid }
            out.append(bytes[cursor..<range.lowerBound])
            out.append(contentsOf: encoded(value, aliases).utf8)
            guard out.count <= F.fileLimit else { throw ModLoadError.limit }
            cursor = range.upperBound
        }
        out.append(bytes[cursor...])
        guard out.count <= F.fileLimit else { throw ModLoadError.limit }
        return out
    }

    private static func digits(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) }
    }
    private enum Table { case song, list, costume }
    private static func displayField(_ key: Substring, in table: Table) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        switch table {
        case .song:
            guard (2...4).contains(parts.count), parts[0].hasPrefix("pv_"), digits(parts[0].dropFirst(3)) else { return false }
            let locales = ["", "_en", "_cn", "_tw", "_kr", "_jp"]
            if parts.count == 2 { return locales.contains { parts[1] == "song_name" + $0 } }
            if parts.count == 3 { return digits(parts[2]) && locales.contains { parts[1] == "lyric" + $0 } }
            return parts[1] == "another_song" && digits(parts[2]) && locales.contains { parts[3] == "name" + $0 }
        case .list, .costume:
            return parts.count == 3 && parts[0] == (table == .list ? "pv_list" : "module") && digits(parts[1]) && parts[2] == "name"
        }
    }

    private static func textRanges(_ bytes: Data, table: Table, characters: inout Set<Scalar>) throws -> [Range<Int>] {
        var result = [Range<Int>]()
        for line in bytes.split(separator: 10, omittingEmptySubsequences: true) {
            var start = line.startIndex
            if start == 0 && line.starts(with: [0xef, 0xbb, 0xbf]) { start += 3 }
            guard let eq = line[start...].firstIndex(of: 61), eq - start < 160,
                  let key = String(data: bytes[start..<eq], encoding: .utf8), displayField(key[...], in: table) else { continue }
            let end = line.last == 13 ? line.endIndex - 1 : line.endIndex
            guard eq + 1 < end else { continue }
            let range = eq + 1..<end
            guard let value = String(data: bytes[range], encoding: .utf8) else { throw ModLoadError.invalid }
            visit(value) { _, s in if let s { characters.insert(s) } }
            result.append(range)
        }
        return result
    }

    // Discover only immediate data tables, including the nested rom in each
    // mounted DLC. A library scan must never walk media, models, or textures.
    private static func discover(_ root: URL, locales: Set<String>) throws -> [String: URL] {
        let fm = FileManager.default
        func listing(_ p: URL) throws -> [URL] {
            guard fm.fileExists(atPath: p.path) else { return [] }
            return try fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        }
        var directories = [String]()
        for namespace in try listing(root) {
            let name = namespace.lastPathComponent
            guard name == "rom" || name.hasPrefix("rom_") else { continue }
            guard (try? namespace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            directories.append(name == "rom" ? name : name + "/rom")
            if name.contains("_dlc") {
                for mounted in try listing(namespace) {
                    directories.append(name + "/" + mounted.lastPathComponent + "/rom")
                }
            }
        }
        var result = [String: URL]()
        for directory in directories {
            let rom = root.appendingPathComponent(directory)
            for file in try listing(rom) {
                let n = file.lastPathComponent
                if n == "pv_db.txt" || n == "pv_db_switch.txt" || n.hasSuffix("_pv_db.txt") || n.hasSuffix("_pv_db_switch.txt") ||
                    n == "gm_pv_list_tbl.farc" || n == "gm_module_tbl.farc" {
                    result[directory + "/" + n] = file
                }
            }
            for locale in locales {
                let path = directory + "/lang2/" + locale + "/str_array.bin"
                let strings = root.appendingPathComponent(path)
                if fm.fileExists(atPath: strings.path) { result[path] = strings }
            }
        }
        return result
    }

    static func plan(rom: URL, dlc: URL, dlcIndexes: [Int], layers: [String], language: String) throws -> Plan {
        let region = ["en": "en", "ja": "jp", "ko": "kr", "zh-Hans": "cn", "zh-Hant": "tw"][language] ?? "jp"
        let locales: Set<String> = [region, "jp"]
        let roots = layers.map { URL(fileURLWithPath: $0, isDirectory: true) } +
            [rom] + dlcIndexes.map { dlc.appendingPathComponent(String($0), isDirectory: true) }
        var sources = [String: URL]()
        for root in roots {
            for (name, file) in try discover(root, locales: locales) where sources[name] == nil { sources[name] = file }
        }
        guard sources.count < 2048 else { throw ModLoadError.limit }
        var plan = Plan(), moduleNames = [Int: Set<String>]()
        var totalBytes = 0
        func read(_ url: URL) throws -> Data {
            let b = try F.read(url)
            totalBytes += b.count
            guard totalBytes <= 128 * 1024 * 1024 else { throw ModLoadError.limit }
            return b
        }
        // Resolve costume translations only for actual module IDs and require
        // the Japanese anchor to match the module name. Other str_array slots
        // include accessories, hair, labels and instructions in the same file.
        for (rel, source) in sources.sorted(by: { $0.key < $1.key }) where source.lastPathComponent != "str_array.bin" {
            try autoreleasepool {
                let bytes = try read(source)
                let edits: Edits
                if source.pathExtension == "farc" {
                    var blocks = [String: [Range<Int>]]()
                    for block in try F.archive(bytes) {
                        let table: Table
                        switch (source.lastPathComponent, block.name) {
                        case ("gm_module_tbl.farc", "gm_module_id.bin"):
                            table = .costume
                            for row in F.group(try F.properties(block.data), "module") {
                                if let id = row["id"].flatMap(Int.init), (0..<(65536 - 220)).contains(id),
                                   let name = row["name"], !name.isEmpty {
                                    moduleNames[id+220, default: []].insert(name)
                                }
                            }
                        case ("gm_pv_list_tbl.farc", "gm_pv_list.bin"): table = .list
                        default: continue
                        }
                        let ranges = try textRanges(block.data, table: table, characters: &plan.characters)
                        if !ranges.isEmpty { blocks[block.name] = ranges }
                    }
                    guard !blocks.isEmpty else { return }
                    edits = .archive(blocks)
                } else {
                    let ranges = try textRanges(bytes, table: .song, characters: &plan.characters)
                    guard !ranges.isEmpty else { return }
                    edits = .text(ranges)
                }
                plan.inputs.append(Input(source: source, relative: rel, fingerprint: F.sha(bytes), edits: edits))
            }
        }
        var anchors = [String: Set<Int>]()
        for (rel, file) in sources where rel.hasSuffix("/jp/str_array.bin") {
            let strings = try F.strings(read(file))
            let safe = moduleNames.keys.filter { strings.indices.contains($0) && moduleNames[$0]!.contains(strings[$0]) }
            anchors[String(rel.dropLast("jp/str_array.bin".count))] = Set(safe)
        }
        for (rel, file) in sources where file.lastPathComponent == "str_array.bin" {
            let prefix = String(rel.dropLast((file.deletingLastPathComponent().lastPathComponent + "/str_array.bin").count))
            guard let slots = anchors[prefix], !slots.isEmpty else { continue }
            let bytes = try read(file), values = try F.strings(bytes)
            let selected = slots.sorted().filter { values.indices.contains($0) && !values[$0].isEmpty && values[$0] != "BLANK" }
            if selected.isEmpty { continue }
            for slot in selected {
                visit(values[slot]) { _, s in if let s { plan.characters.insert(s) } }
            }
            plan.inputs.append(Input(source: file, relative: rel, fingerprint: F.sha(bytes), edits: .strings(selected)))
        }
        return plan
    }
}
