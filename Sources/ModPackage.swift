import Foundation
import CryptoKit

// Inspection only: never extracts assets, executes plugins or registers a runtime provider.
// ZIP directory fields follow PKWARE APPNOTE6.3.10; payload CRC/content is not checked.
enum ModPackageError: LocalizedError {
    case unsupportedArchive, unknownStructure, unsafePath, invalidZIP, encryptedOrSplit
    case limitExceeded, specialFile, changedSource, invalidRecord, cancelled
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
