import Foundation
import CryptoKit

// Inspection only: never extracts assets, executes plugins or registers a runtime provider.
// ZIP directory fields follow PKWARE APPNOTE6.3.10; payload CRC/content is not checked.
enum ModPackageError: LocalizedError {
    case unsupportedArchive, unknownStructure, unsafePath, invalidZIP, encryptedOrSplit
    case limitExceeded, specialFile, changedSource, invalidRecord, cancelled, preparedAlreadyInstalled
    var errorDescription: String? {
        switch self {
        case .unsupportedArchive: return "此压缩格式暂不支持，请先解压后选择 MOD 文件夹。"
        case .unknownStructure: return "未识别 MOD 结构，请选择含 romfs 或 rom 的完整 MOD 文件夹。"
        case .unsafePath: return "MOD 路径不安全或存在大小写冲突。"
        case .invalidZIP: return "MOD 包已损坏或使用不支持的 ZIP 格式。"
        case .encryptedOrSplit: return "暂不支持加密或分卷 ZIP，请先完整解压。"
        case .limitExceeded: return "MOD 文件过多或目录信息超出检查上限。"
        case .specialFile: return "MOD 包包含符号链接或特殊文件，请使用普通文件夹。"
        case .changedSource: return "选择的文件在检查期间发生变化，请重试。"
        case .invalidRecord: return "MOD 登记记录无法读取，请重新选择文件。"
        case .cancelled: return "已取消检查。原文件保持不变。"
        case .preparedAlreadyInstalled: return "此已适配包已存在，请在启动前列表中选择；没有覆盖现有包。"
        }
    }
}
struct ModInspection: Codable {
    enum Kind: String, Codable { case layeredFS, pluginAssets, mixedAssets, codeOnly }
    let kind: Kind
    let fileCount: Int
    let expandedBytes: UInt64
    let declaredTitleIDs: [String]
    let containsCode: Bool
    let containsDatabases: Bool
    let unusualCompression: Bool
    // No compatibility, CRC, decryption or payload validation is implied.
    let contentIntegrityChecked: Bool
}
struct ModZIPEntry {
    let path: String
    let rawName: Data
    let directory: Bool
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressed: UInt64
    let expanded: UInt64
    let localOffset: UInt64
    let directoryOffset: UInt64
}
private struct ModDirectoryIndex {
    private var paths = [String: String]()
    private var files = Set<String>(), directories = Set<String>()
    private var assetRoots = Set<String>()
    private var titleIDs = Set<String>()
    private var nameBytes = 0, indexedPathBytes = 0
    private var layered = false, code = false, database = false
    var fileCount = 0
    var expandedBytes: UInt64 = 0
    static let maximumEntries = 50000
    static func title(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    mutating func seedTitle(_ value: String) { if Self.title(value) { titleIDs.insert(value.uppercased()) } }
    mutating func add(_ raw: String, directory: Bool, size: UInt64) throws {
        let value = raw.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
        guard !value.hasPrefix("/"), !value.contains(":"), value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ModPackageError.unsafePath }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, !parts.contains(".."), !parts.contains(".") else { throw ModPackageError.unsafePath }
        if parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") || $0 == ".DS_Store" }) { return }
        nameBytes += value.utf8.count
        guard nameBytes <= 8*1024*1024 else { throw ModPackageError.limitExceeded }
        var prefix = ""
        for (i, part) in parts.enumerated() {
            prefix = prefix.isEmpty ? part : prefix + "/" + part
            let key = prefix.lowercased()
            if let old = paths[key], old != prefix { throw ModPackageError.unsafePath }
            if paths[key] == nil {
                indexedPathBytes += key.utf8.count + prefix.utf8.count
                guard indexedPathBytes <= 32*1024*1024 else { throw ModPackageError.limitExceeded }
            }
            paths[key] = prefix
            if i < parts.count-1 {
                guard !files.contains(key) else { throw ModPackageError.unsafePath }
                directories.insert(key)
            }
        }
        let lower = prefix.lowercased(), p = parts.map { $0.lowercased() }
        if directory {
            guard !files.contains(lower) else { throw ModPackageError.unsafePath }
            directories.insert(lower); return
        }
        guard !directories.contains(lower), files.insert(lower).inserted else { throw ModPackageError.unsafePath }
        fileCount += 1
        let sum = expandedBytes.addingReportingOverflow(size)
        guard !sum.overflow, sum.partialValue <= 128*1024*1024*1024 else { throw ModPackageError.limitExceeded }
        expandedBytes = sum.partialValue
        let base = p.last!
        if let rom = p.firstIndex(of: "rom"), rom < p.count-1 {
            let parents=p.prefix(rom)
            if !parents.contains("rom_switch") && !parents.contains("rom_switch_dlc") && (!parents.contains("romfs") || parents.contains("mods")) {
                assetRoots.insert(parents.joined(separator: "/"))
            }
        }
        if let romfs = p.firstIndex(of: "romfs"), romfs < p.count-1 {
            layered = true
            if romfs > 0 { seedTitle(p[romfs-1]) }
        }
        if p.contains("rom_switch") || p.contains("rom_switch_dlc") { layered = true }
        if p.contains("exefs") || p.contains("exefs_patches") ||
            ["dll","dylib","ips","pchtxt","nso","nro","elf","npdm"].contains((base as NSString).pathExtension) ||
            base.range(of: "^subsdk[0-9]+$", options: .regularExpression) != nil { code = true }
        if base.hasPrefix("mod_") && (base.contains("_db") || base.contains("str_array")) { database = true }
    }
    func finish(unusualCompression: Bool = false) throws -> ModInspection {
        // rom_steam and rom_steam_en are alternative asset roots supported by MMSP.
        let plugin = !assetRoots.isEmpty
        let kind: ModInspection.Kind
        if layered && plugin { kind = .mixedAssets }
        else if layered { kind = .layeredFS }
        else if plugin { kind = .pluginAssets }
        else if code { kind = .codeOnly }
        else { throw ModPackageError.unknownStructure }
        guard fileCount > 0 else { throw ModPackageError.unknownStructure }
        return ModInspection(kind: kind, fileCount: fileCount, expandedBytes: expandedBytes,
            declaredTitleIDs: titleIDs.sorted(), containsCode: code, containsDatabases: database,
            unusualCompression: unusualCompression, contentIntegrityChecked: false)
    }
}
enum ModPackageInspector {
    static func zipCatalog(_ url: URL, progress: Progress) throws -> (ModInspection, [ModZIPEntry]) {
        var entries=[ModZIPEntry]()
        let inspection=try inspectZIP(url,progress:progress,onEntry:{entries.append($0)})
        return (inspection,entries)
    }
    static func inspect(_ source: URL, progress: Progress = Progress(totalUnitCount: 1)) throws -> ModInspection {
        guard source.isFileURL else { throw ModPackageError.unsupportedArchive }
        let attr = try FileManager.default.attributesOfItem(atPath: source.path)
        if attr[.type] as? FileAttributeType == .typeDirectory { return try inspectFolder(source, progress: progress) }
        guard attr[.type] as? FileAttributeType == .typeRegular else { throw ModPackageError.specialFile }
        guard source.pathExtension.lowercased() == "zip" else { throw ModPackageError.unsupportedArchive }
        return try inspectZIP(source, progress: progress)
    }
    private static func inspectFolder(_ root: URL, progress: Progress) throws -> ModInspection {
        let fm = FileManager.default
        // The selected item has already been checked with lstat. Resolve only
        // its ancestor aliases (for example /var -> /private/var) before
        // enumerating, so Foundation returns paths in the same spelling.
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],
            options: [], errorHandler: { _, error in enumerationError=error; return false }) else { throw ModPackageError.unknownStructure }
        let prefix = root.standardizedFileURL.path + "/"
        var index = ModDirectoryIndex(), count = 0
        index.seedTitle(root.lastPathComponent)
        if root.lastPathComponent.lowercased() == "romfs" { index.seedTitle(root.deletingLastPathComponent().lastPathComponent) }
        for case let url as URL in iterator {
            if progress.isCancelled { throw ModPackageError.cancelled }
            count += 1
            guard count <= ModDirectoryIndex.maximumEntries else { throw ModPackageError.limitExceeded }
            try autoreleasepool {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { throw ModPackageError.unsafePath }
                let relative = String(path.dropFirst(prefix.count))
                if relative.split(separator: "/").contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") || $0 == ".DS_Store" }) { iterator.skipDescendants(); return }
                let attr = try fm.attributesOfItem(atPath: url.path)
                let type = attr[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { throw ModPackageError.specialFile }
                try index.add(relative, directory: type == .typeDirectory, size: (attr[.size] as? NSNumber)?.uint64Value ?? 0)
            }
        }
        if let error = enumerationError { throw error }
        if progress.isCancelled { throw ModPackageError.cancelled }
        return try index.finish()
    }
    private static func inspectZIP(_ url: URL, progress: Progress, onEntry: ((ModZIPEntry)->Void)? = nil) throws -> ModInspection {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let length = (before[.size] as? NSNumber)?.uint64Value ?? 0
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, count <= 32*1024*1024, offset <= length, UInt64(count) <= length-offset else { throw ModPackageError.invalidZIP }
            return try autoreleasepool {
                try file.seek(toOffset: offset)
                let b = try file.read(upToCount: count) ?? Data()
                guard b.count == count else { throw ModPackageError.invalidZIP }; return b
            }
        }
        func number(_ b: Data, _ at: Int, _ size: Int) throws -> UInt64 {
            guard at >= 0, size > 0, at <= b.count, size <= b.count-at else { throw ModPackageError.invalidZIP }
            var n: UInt64=0
            for i in 0..<size { n |= UInt64(b[at+i]) << (i*8) }; return n
        }
        guard length >= 22 else { throw ModPackageError.invalidZIP }
        let tailLength = Int(min(length,65557)), tail = try read(length-UInt64(tailLength),tailLength)
        var eocd: Int?
        for at in stride(from:tail.count-22,through:0,by:-1) where try number(tail,at,4) == 0x06054b50 {
            if try at+22+Int(number(tail,at+20,2)) == tail.count { eocd=at;break }
        }
        guard let end = eocd else { throw ModPackageError.invalidZIP }
        guard (try number(tail,end+4,2)) == 0, (try number(tail,end+6,2)) == 0,
              (try number(tail,end+8,2)) == (try number(tail,end+10,2)) else { throw ModPackageError.encryptedOrSplit }
        var count = try number(tail,end+10,2), size = try number(tail,end+12,4), offset = try number(tail,end+16,4)
        let eocdOffset = length-UInt64(tailLength)+UInt64(end)
        var directoryEnd = eocdOffset
        if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
            guard eocdOffset >= 20 else { throw ModPackageError.invalidZIP }
            let locator = try read(eocdOffset-20,20)
            guard (try number(locator,0,4)) == 0x07064b50, (try number(locator,4,4)) == 0, (try number(locator,16,4)) == 1 else { throw ModPackageError.encryptedOrSplit }
            let zip64Offset = try number(locator,8,8), z = try read(zip64Offset,56)
            guard (try number(z,0,4)) == 0x06064b50, (try number(z,4,8)) >= 44,
                  (try number(z,16,4)) == 0, (try number(z,20,4)) == 0, (try number(z,24,8)) == (try number(z,32,8)) else { throw ModPackageError.invalidZIP }
            count = try number(z,32,8);size = try number(z,40,8);offset = try number(z,48,8);directoryEnd = zip64Offset
        }
        guard count > 0, count <= UInt64(ModDirectoryIndex.maximumEntries), size <= 32*1024*1024 else { throw ModPackageError.limitExceeded }
        guard offset <= directoryEnd, size <= directoryEnd-offset else { throw ModPackageError.invalidZIP }
        let central = try read(offset,Int(size)); var at=0, index=ModDirectoryIndex(), unusual=false
        for _ in 0..<Int(count) {
            if progress.isCancelled { throw ModPackageError.cancelled }
            guard try number(central,at,4) == 0x02014b50 else { throw ModPackageError.invalidZIP }
            let flags = try number(central,at+8,2), method = try number(central,at+10,2)
            guard flags & 0x2041 == 0 else { throw ModPackageError.encryptedOrSplit }
            unusual = unusual || (method != 0 && method != 8)
            var expanded = try number(central,at+24,4), compressed = try number(central,at+20,4), local = try number(central,at+42,4)
            let nameLength=Int(try number(central,at+28,2)), extraLength=Int(try number(central,at+30,2)), commentLength=Int(try number(central,at+32,2))
            let disk=try number(central,at+34,2), total=46+nameLength+extraLength+commentLength
            guard nameLength > 0, at <= central.count, total <= central.count-at, disk == 0 else { throw ModPackageError.invalidZIP }
            let rawName=central.subdata(in:at+46..<at+46+nameLength)
            guard let name=String(data:rawName,encoding:.utf8) else { throw ModPackageError.invalidZIP }
            if expanded == 0xffffffff || compressed == 0xffffffff || local == 0xffffffff {
                var ex=at+46+nameLength; let extraEnd=ex+extraLength; var found=false
                while ex+4 <= extraEnd {
                    let tag=try number(central,ex,2), n=Int(try number(central,ex+2,2));ex+=4
                    guard n <= extraEnd-ex else { throw ModPackageError.invalidZIP }
                    if tag == 1 {
                        var pos=ex
                        func next() throws -> UInt64 { guard pos+8 <= ex+n else { throw ModPackageError.invalidZIP };defer{pos+=8};return try number(central,pos,8) }
                        if expanded == 0xffffffff { expanded=try next() }
                        if compressed == 0xffffffff { compressed=try next() }
                        if local == 0xffffffff { local=try next() }
                        found=true;break
                    }
                    ex+=n
                }
                guard found else { throw ModPackageError.invalidZIP }
            }
            guard local <= offset, offset-local >= 30, compressed <= offset-local-30 else { throw ModPackageError.invalidZIP }
            let mode=try number(central,at+38,4) >> 16, type=mode & 0xf000
            guard type == 0 || type == 0x8000 || type == 0x4000 else { throw ModPackageError.specialFile }
            let directory=name.hasSuffix("/") || type == 0x4000
            try index.add(name, directory:directory, size:expanded)
            onEntry?(ModZIPEntry(path:name,rawName:rawName,directory:directory,flags:UInt16(flags),method:UInt16(method),crc:UInt32(try number(central,at+16,4)),compressed:compressed,expanded:expanded,localOffset:local,directoryOffset:offset))
            at+=total
        }
        guard at == central.count else { throw ModPackageError.invalidZIP }
        let after=try FileManager.default.attributesOfItem(atPath:url.path)
        guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
              (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw ModPackageError.changedSource }
        return try index.finish(unusualCompression:unusual)
    }
}
struct ModRegistration: Codable {
    let schema: String
    let id: UUID
    let sourceID: String
    let name: String
    let bookmark: Data
    let registeredAt: Date
    let inspection: ModInspection
    // An enabled flag is intentionally absent: registration cannot activate a MOD.
}
struct ModRegistry {
    let root: URL
    func records() throws -> [ModRegistration] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        let urls=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json" && !$0.lastPathComponent.hasPrefix("._")}
        guard urls.count <= 500 else { throw ModPackageError.limitExceeded }
        return try urls.map { url in
            let attr=try FileManager.default.attributesOfItem(atPath:url.path)
            guard attr[.type] as? FileAttributeType == .typeRegular, (attr[.size] as? NSNumber)?.intValue ?? Int.max <= 256*1024 else { throw ModPackageError.invalidRecord }
            let r=try JSONDecoder().decode(ModRegistration.self,from:Data(contentsOf:url))
            guard r.schema == "pjdv-mod-registration-v1", url.deletingPathExtension().lastPathComponent == r.id.uuidString else { throw ModPackageError.invalidRecord }
            return r
        }.sorted{$0.registeredAt > $1.registeredAt}
    }
    func register(_ source: URL, inspection: ModInspection, name: String? = nil) throws {
        let identity=SHA256.hash(data:Data(source.standardizedFileURL.absoluteString.utf8)).map{String(format:"%02x",$0)}.joined()
        let all=try records()
        let existing=all.first{$0.sourceID==identity}
        guard existing != nil || all.count < 500 else { throw ModPackageError.limitExceeded }
        #if targetEnvironment(macCatalyst)
        let bookmark=try source.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)
        #else
        let bookmark=try source.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        #endif
        let r=ModRegistration(schema:"pjdv-mod-registration-v1",id:existing?.id ?? UUID(),sourceID:identity,name:name ?? source.lastPathComponent,bookmark:bookmark,registeredAt:Date(),inspection:inspection)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bytes=try JSONEncoder().encode(r)
        guard bytes.count <= 256*1024 else { throw ModPackageError.limitExceeded }
        try bytes.write(to:root.appendingPathComponent(r.id.uuidString+".json"),options:.atomic)
    }
    func remove(_ record: ModRegistration) throws {
        try FileManager.default.removeItem(at:root.appendingPathComponent(record.id.uuidString+".json"))
    }
    func source(_ record: ModRegistration) throws -> URL {
        var stale=false
        #if targetEnvironment(macCatalyst)
        return try URL(resolvingBookmarkData:record.bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        #else
        return try URL(resolvingBookmarkData:record.bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
        #endif
    }
}

// Prepared resource overlays are separate from raw DML/Switch registrations.
// The native composition step merges selected databases; this catalog never
// runs plugin code.
struct RuntimeMod: Codable {
    struct Check: Codable { let path: String; let bytes: UInt64; let sha256: String }
    let format: String
    let id: UUID
    let name: String
    let notes: String
    let layers: [String]
    let baseChecks: [Check]
    let files: [Check]
}
struct RuntimeModCatalog {
    let root: URL
    let defaults: UserDefaults
    private let selectionKey = "pjdv.runtimeMod.v1"
    private let multipleKey = "pjdv.runtimeMods.v2"
    var selectedIDs:[UUID] {
        if let values=defaults.stringArray(forKey:multipleKey) {return Array(Set(values.compactMap(UUID.init(uuidString:)))).sorted{$0.uuidString<$1.uuidString}}
        return defaults.string(forKey:selectionKey).flatMap(UUID.init(uuidString:)).map{[$0]} ?? []
    }
    var selectedID: UUID? {selectedIDs.first}
    func select(_ value: UUID?) {
        select(values:value.map{[$0]} ?? [])
    }
    func select(values:[UUID]) {
        defaults.set(Array(Set(values.map(\.uuidString))).sorted(),forKey:multipleKey)
        defaults.removeObject(forKey:selectionKey)
    }
    func toggle(_ value:UUID)throws {
        var ids=selectedIDs
        if let i=ids.firstIndex(of:value){ids.remove(at:i)}else{guard ids.count<16 else {throw ModPackageError.limitExceeded};ids.append(value)}
        select(values:ids)
    }
    func selectedMods()throws->[RuntimeMod] {
        try resolve(selectedIDs)
    }
    func resolve(_ ids:[UUID])throws->[RuntimeMod] {
        if ids.isEmpty{return []}
        guard ids.count<=16,Set(ids).count==ids.count else {throw ModPackageError.limitExceeded}
        let all=try records();return try ids.map{id in guard let value=all.first(where:{$0.id==id}) else {throw ModPackageError.invalidRecord};return value}
    }
    private func child(_ path: String, under folder: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, path.utf8.count <= 2048,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else { throw ModPackageError.unsafePath }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { throw ModPackageError.unsafePath }
        return url
    }
    func directory(_ item: RuntimeMod) -> URL { root.appendingPathComponent(item.id.uuidString, isDirectory: true) }
    private func validate(_ item: RuntimeMod) throws {
        guard item.format == "pjdv-runtime-mod-v1", !item.name.isEmpty, item.name.utf8.count <= 256,
              item.notes.utf8.count <= 4096, (1...4).contains(item.layers.count), Set(item.layers).count == item.layers.count,
              (1...32).contains(item.baseChecks.count), (1...50000).contains(item.files.count) else { throw ModPackageError.invalidRecord }
        var names = Set<String>(), total: UInt64 = 0
        for c in item.files + item.baseChecks {
            guard c.sha256.count == 64, c.sha256.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else { throw ModPackageError.invalidRecord }
            _ = try child(c.path, under: directory(item))
        }
        for c in item.files {
            guard item.layers.contains(where: {c.path.hasPrefix($0 + "/")}), names.insert(c.path.lowercased()).inserted,
                  c.bytes <= 128*1024*1024*1024-total else { throw ModPackageError.limitExceeded }
            total += c.bytes
        }
        guard item.baseChecks.allSatisfy({$0.bytes <= 8*1024*1024}), Set(item.baseChecks.map(\.path)).count == item.baseChecks.count else { throw ModPackageError.limitExceeded }
        for layer in item.layers {
            _ = try child(layer, under: directory(item))
            guard item.files.contains(where: {$0.path.hasPrefix(layer + "/")}) else { throw ModPackageError.invalidRecord }
        }
    }
    struct Unavailable {
        let id:UUID
        let name:String
        let item:RuntimeMod?
    }
    struct Inventory {
        let ready:[RuntimeMod]
        let unavailable:[Unavailable]
    }
    private func invalidMarker(_ id:UUID)->URL {root.appendingPathComponent(".invalid",isDirectory:true).appendingPathComponent(id.uuidString)}
    func inventory() throws -> Inventory {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return Inventory(ready:[],unavailable:[]) }
        guard try fm.attributesOfItem(atPath:root.path)[.type] as? FileAttributeType == .typeDirectory else {throw ModPackageError.unsafePath}
        let dirs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard dirs.count <= 100 else { throw ModPackageError.limitExceeded }
        var ready=[RuntimeMod](),unavailable=[Unavailable]()
        for folder in dirs {
            guard let id=UUID(uuidString:folder.lastPathComponent) else {continue}
            var name="MOD "+String(id.uuidString.prefix(8)),candidate:RuntimeMod?
            do {
                guard folder.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent(folder.lastPathComponent).path,
                      try fm.attributesOfItem(atPath:folder.path)[.type] as? FileAttributeType == .typeDirectory else {throw ModPackageError.unsafePath}
                let url=try child("runtime.json",under:folder),attr=try fm.attributesOfItem(atPath:url.path)
                guard attr[.type] as? FileAttributeType == .typeRegular,(attr[.size] as? NSNumber)?.intValue ?? Int.max <= 16*1024*1024 else {throw ModPackageError.invalidRecord}
                let raw=try Data(contentsOf:url)
                if let object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],let value=object["name"] as? String,!value.isEmpty,value.utf8.count<=256 {name=value}
                let item=try JSONDecoder().decode(RuntimeMod.self,from:raw)
                guard item.id==id else {throw ModPackageError.invalidRecord}
                try validate(item);candidate=item
                guard !fm.fileExists(atPath:invalidMarker(id).path) else {throw ModPackageError.changedSource}
                ready.append(item)
            } catch {unavailable.append(Unavailable(id:id,name:name,item:candidate))}
        }
        return Inventory(ready:ready.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending},
                         unavailable:unavailable.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending})
    }
    func records() throws -> [RuntimeMod] {try inventory().ready}
    // Explicit full verification complements the fast launch check. A failed
    // package stays unavailable across relaunches until a complete check passes.
    // Only our own marker is changed; payloads and saves are never rewritten.
    func verifyFully(_ item:RuntimeMod,progress:Progress,report:((UInt64,UInt64)->Void)?=nil)throws {
        let fm=FileManager.default
        if progress.isCancelled {throw ModPackageError.cancelled}
        do {
            try validate(item)
            let total=item.files.reduce(UInt64(0)){$0+$1.bytes};progress.totalUnitCount=Int64(max(1,total));progress.completedUnitCount=0
            var last=Date.distantPast;report?(0,total)
            for row in item.files {
                try autoreleasepool {
                    if progress.isCancelled {throw ModPackageError.cancelled}
                    let url=try child(row.path,under:directory(item)),before=try fm.attributesOfItem(atPath:url.path)
                    guard before[.type] as? FileAttributeType == .typeRegular,(before[.size] as? NSNumber)?.uint64Value==row.bytes else {throw ModPackageError.changedSource}
                    let input=try FileHandle(forReadingFrom:url);defer{try? input.close()};var digest=SHA256()
                    while true {
                        if progress.isCancelled {throw ModPackageError.cancelled}
                        let count=try autoreleasepool{()->Int in
                            let bytes=try input.read(upToCount:1024*1024) ?? Data();digest.update(data:bytes);return bytes.count
                        }
                        if count==0{break};progress.completedUnitCount+=Int64(count)
                        if Date().timeIntervalSince(last)>=0.2 {last=Date();report?(UInt64(progress.completedUnitCount),total)}
                    }
                    let after=try fm.attributesOfItem(atPath:url.path)
                    guard digest.finalize().map({String(format:"%02x",$0)}).joined()==row.sha256,
                          (before[.size] as? NSNumber)==(after[.size] as? NSNumber),
                          (before[.modificationDate] as? Date)==(after[.modificationDate] as? Date) else {throw ModPackageError.changedSource}
                }
            }
            if progress.isCancelled {throw ModPackageError.cancelled}
            let marker=invalidMarker(item.id);if fm.fileExists(atPath:marker.path){try fm.removeItem(at:marker)}
            report?(total,total)
        } catch {
            if !progress.isCancelled {
                let marker=invalidMarker(item.id);try fm.createDirectory(at:marker.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data("payload verification failed".utf8).write(to:marker,options:.atomic)
            }
            throw error
        }
    }
    // Adopt only an installer-owned directory after checking its complete
    // manifest and inventory. This is not a converter for raw PC databases.
    // Source ZIPs stay untouched; failed validation never changes Ready.
    func adoptPrepared(from installed: URL, progress: Progress,
                       report: ((UInt64,UInt64)->Void)? = nil) throws -> RuntimeMod? {
        let fm = FileManager.default
        var source = installed
        if !fm.fileExists(atPath: source.appendingPathComponent("runtime.json").path) {
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { !$0.lastPathComponent.hasPrefix("._") && $0.lastPathComponent != "__MACOSX" }
            guard children.count == 1,
                  fm.fileExists(atPath: children[0].appendingPathComponent("runtime.json").path) else { return nil }
            source = children[0]
        }
        guard try fm.attributesOfItem(atPath:source.path)[.type] as? FileAttributeType == .typeDirectory else { throw ModPackageError.specialFile }
        source = source.standardizedFileURL.resolvingSymlinksInPath()
        let metadata = source.appendingPathComponent("runtime.json")
        let attributes = try fm.attributesOfItem(atPath: metadata.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16*1024*1024 else { throw ModPackageError.invalidRecord }
        let item = try JSONDecoder().decode(RuntimeMod.self, from: Data(contentsOf: metadata))
        try validate(item)
        let expected = Set(item.files.map(\.path)).union(["runtime.json"])
        var actual = Set<String>(), enumerationError: Error?
        guard let iterator = fm.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw ModPackageError.invalidRecord }
        let prefix = source.standardizedFileURL.path + "/"
        for case let url as URL in iterator {
            if progress.isCancelled { throw ModPackageError.cancelled }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw ModPackageError.unsafePath }
            let relative = String(path.dropFirst(prefix.count))
            if relative.split(separator:"/").contains(where: { $0.hasPrefix("._") || $0 == ".DS_Store" || $0 == "__MACOSX" }) {
                iterator.skipDescendants(); continue
            }
            let type = try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            guard type == .typeRegular, expected.contains(relative), actual.insert(relative).inserted else { throw ModPackageError.invalidRecord }
            guard actual.count <= 50001 else { throw ModPackageError.limitExceeded }
        }
        if let error = enumerationError { throw error }
        guard actual == expected else { throw ModPackageError.invalidRecord }
        let total = item.files.reduce(UInt64(0)) { $0 + $1.bytes }
        progress.totalUnitCount = Int64(max(1,total)); progress.completedUnitCount = 0
        var lastReport = Date.distantPast
        report?(0,total)
        for row in item.files {
            try autoreleasepool {
                let url = try child(row.path, under: source)
                let before = try fm.attributesOfItem(atPath: url.path)
                guard (before[.size] as? NSNumber)?.uint64Value == row.bytes else { throw ModPackageError.changedSource }
                let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
                var digest = SHA256()
                while true {
                    if progress.isCancelled { throw ModPackageError.cancelled }
                    let count = try autoreleasepool { () throws -> Int in
                        let bytes = try input.read(upToCount: 1024*1024) ?? Data()
                        digest.update(data: bytes); return bytes.count
                    }
                    if count == 0 { break }; progress.completedUnitCount += Int64(count)
                    if Date().timeIntervalSince(lastReport) >= 0.2 {
                        lastReport = Date(); report?(UInt64(progress.completedUnitCount),total)
                    }
                }
                guard digest.finalize().map({String(format:"%02x",$0)}).joined() == row.sha256 else { throw ModPackageError.changedSource }
                let after = try fm.attributesOfItem(atPath: url.path)
                guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
                      (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw ModPackageError.changedSource }
            }
        }
        if progress.isCancelled { throw ModPackageError.cancelled }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: directory(item).path) else { throw ModPackageError.preparedAlreadyInstalled }
        try fm.moveItem(at: source, to: directory(item))
        if source != installed { try? fm.removeItem(at: installed) }
        report?(total,total)
        return item
    }
    func selected() throws -> RuntimeMod? {
        try selectedMods().first
    }
    // Stream metadata checks and stat payloads. Never read a song/movie into RAM.
    func overlayPaths(_ item: RuntimeMod, base: URL) throws -> [String] {
        try validate(item)
        let fm = FileManager.default
        guard !fm.fileExists(atPath:invalidMarker(item.id).path) else {throw ModPackageError.changedSource}
        func check(_ row: RuntimeMod.Check, under folder: URL, hash: Bool) throws {
            let url = try child(row.path, under: folder)
            let attr = try fm.attributesOfItem(atPath: url.path)
            guard attr[.type] as? FileAttributeType == .typeRegular,
                  (attr[.size] as? NSNumber)?.uint64Value == row.bytes else { throw ModPackageError.changedSource }
            if hash {
                let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
                var digest = SHA256()
                while let b = try f.read(upToCount: 1024*1024), !b.isEmpty { digest.update(data: b) }
                guard digest.finalize().map({String(format:"%02x",$0)}).joined() == row.sha256 else { throw ModPackageError.changedSource }
            }
        }
        for row in item.baseChecks { try check(row, under: base, hash: true) }
        for row in item.files { try check(row, under: directory(item), hash: row.bytes <= 2*1024*1024) }
        let paths = try item.layers.map { try child($0, under: directory(item)).path }
        guard paths.joined(separator:":").utf8.count <= 3000 else { throw ModPackageError.limitExceeded }
        return paths
    }
}

// Exit-menu text is normally the first overlay. Compose its one description
// with MOD labels, so a complete bundled string table cannot hide new names.
enum ModSessionUI {
    private static func read(_ url: URL) throws -> Data {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.size] as? NSNumber)?.intValue ?? Int.max <= 2*1024*1024 else { throw ModPackageError.limitExceeded }
        return try Data(contentsOf: url)
    }
    static func compose(mod: Data, menu: Data) throws -> Data {
        func number(_ b: Data, _ at: Int) throws -> Int {
            guard at >= 0, at+4 <= b.count else { throw ModPackageError.invalidRecord }
            return (0..<4).reduce(0) { $0 | Int(b[at+$1]) << ($1*8) }
        }
        let slot = 190*4
        let modTable = try number(mod,0), menuTable = try number(menu,0)
        guard modTable > slot+4, modTable <= mod.count, modTable % 4 == 0,
              menuTable > slot+4, menuTable <= menu.count, menuTable % 4 == 0 else { throw ModPackageError.invalidRecord }
        let start = try number(menu,slot)
        guard start >= (try number(menu,0)), start < menu.count,
              let end = menu[start...].firstIndex(of: 0), end-start <= 4096 else { throw ModPackageError.invalidRecord }
        var result = mod
        let offset = result.count
        result.append(menu[start...end])
        for i in 0..<4 { result[slot+i] = UInt8((offset >> (i*8)) & 255) }
        return result
    }
    static func prepare(bundle: URL, layers: [String], temp: URL, language: String) throws -> URL {
        let tag = ["ja":"jp", "zh-Hans":"cn", "zh-Hant":"tw", "ko":"kr"][language] ?? "en"
        let relative = "rom_switch/rom/lang2/"+tag+"/str_array.bin"
        guard let source = layers.map({ URL(fileURLWithPath:$0).appendingPathComponent(relative) }).first(where: {FileManager.default.fileExists(atPath:$0.path)}) else { return bundle }
        let menu = bundle.appendingPathComponent(tag).appendingPathComponent(relative)
        let merged = try compose(mod:read(source),menu:read(menu))
        let target = temp.appendingPathComponent("ModMenu/"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        do {
            try FileManager.default.copyItem(at:bundle,to:target)
            try merged.write(to:target.appendingPathComponent(tag).appendingPathComponent(relative),options:.atomic)
        } catch { try? FileManager.default.removeItem(at:target); throw error }
        return target
    }
}
