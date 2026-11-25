import Foundation
import CoreText
import CryptoKit

enum GameTextFontOverlay {
    typealias A = GameTextFontAtlas
    typealias F = ModFormats
    private static let fm = FileManager.default
    private static let lock = NSLock()
    private static let revision = "google-noto-fmh3-2"

    struct FontInput {
        let path: String
        let url: URL
        let family: A.Family?
        let bold: Bool
    }
    private struct Stored: Codable {
        struct File: Codable { let bytes: Int; let sha256: String }
        let key: String
        let aliases: [String: UInt16]
        let files: [String: File]
    }

    private static func inputs(rom: URL, layers: [String], families: Set<A.Family>) throws -> [FontInput] {
        let roots = layers.map { URL(fileURLWithPath:$0,isDirectory:true) }+[rom]
        var names = Set(["rom"])
        for root in roots {
            let folders = try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles)
            for folder in folders where folder.lastPathComponent.hasPrefix("rom_") {
                guard folder.lastPathComponent.utf8.count<100 else { continue }
                names.insert(folder.lastPathComponent+"/rom")
            }
        }
        var assets = [FontInput]()
        var specs: [(String,A.Family?,Bool)] = [("fontmap.farc",nil,false)]
        for family in families {
            for bold in [false,true] {
                let name = "2d/spr_fnt_"+(bold ? "bold" : "")+"36"+family.suffix+".farc"
                specs.append((name,family,bold))
            }
        }
        for path in names.sorted() {
            for (file,family,bold) in specs {
                let relative = path+"/"+file
                if let url = roots.lazy.map({$0.appendingPathComponent(relative)}).first(where:{fm.fileExists(atPath:$0.path)}) {
                    assets.append(.init(path:relative,url:url,family:family,bold:bold))
                }
            }
        }
        return assets.sorted { $0.path < $1.path }
    }

    // Descriptors come from the two bundled files, without globally registering
    // any host font. The CJK collection has separate regional glyph forms (locl).
    struct Face {
        let url: URL
        let postScriptName: String
    }
    static func fontFiles(language: String, root: URL) -> [Face] {
        let region: String
        switch language {
        case "zh-Hans": region = "sc"
        case "zh-Hant": region = "tc"
        case "ko": region = "kr"
        default: region = "jp" // Japanese game content is also the English locale's CJK fallback.
        }
        return [Face(url:root.appendingPathComponent("GoogleSans-Regular.ttf"),postScriptName:"GoogleSans-Regular"),
                Face(url:root.appendingPathComponent("NotoSansCJK-Regular.ttc"),postScriptName:"NotoSansCJK"+region+"-Regular")]
    }

    static func readFace(_ face: Face) throws -> CTFont {
        guard let descriptors=CTFontManagerCreateFontDescriptorsFromURL(face.url as CFURL) as? [CTFontDescriptor],
              let descriptor=descriptors.first(where:{(CTFontDescriptorCopyAttribute($0,kCTFontNameAttribute) as? String) == face.postScriptName}) else {
            throw ModLoadError.unsupported
        }
        let font=CTFontCreateWithFontDescriptor(descriptor,34,nil)
        guard CTFontCopyPostScriptName(font) as String == face.postScriptName else { throw ModLoadError.unsupported }
        return font
    }

    private static func key(inputs: [FontInput], faces: [Face], characters: Set<Unicode.Scalar>, language: String) throws -> String {
        var h = SHA256()
        func add(_ string: String) { h.update(data:Data(string.utf8)); h.update(data:Data([0])) }
        add(revision);add(language)
        // OS fonts can supply a character missing from both the game and GoogleSans.
        add(ProcessInfo.processInfo.operatingSystemVersionString)
        for face in faces { add(face.postScriptName);add(try F.sha(F.read(face.url))) }
        for input in inputs { add(input.path);add(try F.sha(F.read(input.url))) }
        for c in characters.sorted(by:{$0.value<$1.value}) {
            var value = c.value.littleEndian
            withUnsafeBytes(of:&value) { h.update(data:Data($0)) }
        }
        return h.finalize().map{String(format:"%02x",$0)}.joined()
    }

    private static func load(_ folder: URL, key: String, paths: Set<String>, characters: Set<Unicode.Scalar>) -> Stored? {
        guard let data = try? F.read(folder.appendingPathComponent("index.json")), data.count<=1024*1024,
              let value = try? JSONDecoder().decode(Stored.self,from:data),value.key==key,
              Set(value.files.keys)==paths,value.aliases.count<=6400,
              Set(value.aliases.values).count==value.aliases.count else { return nil }
        for (code,alias) in value.aliases {
            guard let n=UInt32(code),let c=Unicode.Scalar(n),characters.contains(c),(0xe000...0xf8ff).contains(alias) else { return nil }
        }
        for (name,entry) in value.files {
            let url=folder.appendingPathComponent(name)
            guard let file=try? F.read(url),file.count==entry.bytes,F.sha(file)==entry.sha256 else { return nil }
        }
        return value
    }

    private static func build(_ inputs: [FontInput], faces: [Face], characters: Set<Unicode.Scalar>,
                              families: Set<A.Family>, key: String, stage: URL) throws -> Stored {
        let maps = try inputs.filter{$0.family==nil}.map { ($0,try A.Map(archive:F.read($0.url))) }
        let rows = maps.flatMap{$0.1.rows}
        let occupied = maps.reduce(into:Set<UInt16>()) { $0.formUnion($1.1.usedCodes) }
            .union(characters.compactMap{UInt16(exactly:$0.value)})
        var native: Set<UInt16>?, grids = [A.Family:A.Grid]()
        for family in families {
            let members=rows.filter{$0.family==family}
            guard !members.isEmpty else { continue }
            let files=inputs.filter{$0.family==family}
            guard files.contains(where:{$0.bold}),files.contains(where:{!$0.bold}) else { throw ModLoadError.unsupported }
            // A Mod can supply an 8192px Switch atlas while leaving a stock 4096px
            // PS4 fallback in a different namespace. Both need valid alias coordinates.
            var cols=256
            for file in files {
                cols=min(cols,try autoreleasepool { try A.columns(in:F.read(file.url)) })
            }
            grids[family]=try A.Grid(rows:members,textureColumns:cols)
            // Songs, costume lists and localized menus can select different maps.
            // Retain a native-only character only when every active map can render it.
            for row in members {
                if native == nil { native = row.codes } else { native?.formIntersection(row.codes) }
            }
        }
        guard grids[.japanese] != nil else { throw ModLoadError.unsupported }
        let glyphs=A.glyphs(characters:characters,fonts:try faces.map(readFace),occupied:occupied,
                            original:native ?? [],capacity:grids.values.map(\.capacity).min() ?? 0)
        guard !glyphs.isEmpty else { throw ModLoadError.unsupported }
        var files = [String:Stored.File]()
        func write(_ path:String,_ data:Data)throws {
            let dest=stage.appendingPathComponent(path)
            try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:dest)
            files[path] = .init(bytes:data.count,sha256:F.sha(data))
        }
        for (input,map) in maps { try write(input.path,map.adding(glyphs,grids:grids)) }
        for (family,grid) in grids {
            for bold in [false,true] {
                let band=try A.Band(glyphs:glyphs,grid:grid,bold:bold)
                for input in inputs where input.family==family && input.bold==bold {
                    try autoreleasepool { try write(input.path,A.image(F.read(input.url),grid:grid,band:band)) }
                }
            }
        }
        let aliases=Dictionary(uniqueKeysWithValues:glyphs.map{(String($0.source.value),$0.alias)})
        let record=Stored(key:key,aliases:aliases,files:files)
        try JSONEncoder().encode(record).write(to:stage.appendingPathComponent("index.json"))
        return record
    }

    static func prepare(rom: URL, dlc: URL, dlcIndexes: [Int], layers: inout [String], temp: URL,
                        language: String, fontDirectory: URL? = Bundle.main.url(forResource:"GoogleSans",withExtension:nil)) throws -> URL {
        guard let fontDirectory else { throw ModLoadError.unsupported }
        lock.lock();defer { lock.unlock() }
        let plan=try GameTextFontContent.plan(rom:rom,dlc:dlc,dlcIndexes:dlcIndexes,layers:layers,language:language)
        var families: Set<A.Family> = [.japanese]
        switch language { case "zh-Hant": families.insert(.traditional); case "zh-Hans": families.insert(.simplified)
        case "ko": families.insert(.korean); default: break }
        let inputs=try inputs(rom:rom,layers:layers,families:families)
        let faces=fontFiles(language:language,root:fontDirectory)
        let key=try key(inputs:inputs,faces:faces,characters:plan.characters,language:language)
        var cache=temp.appendingPathComponent("GameTextFontCache",isDirectory:true)
        try fm.createDirectory(at:cache,withIntermediateDirectories:true)
        var attributes=URLResourceValues();attributes.isExcludedFromBackup=true;try? cache.setResourceValues(attributes)
        let target=cache.appendingPathComponent(key,isDirectory:true)
        let paths=Set(inputs.map(\.path))
        let stored: Stored
        if let hit=load(target,key:key,paths:paths,characters:plan.characters) { stored=hit }
        else {
            let stage=cache.appendingPathComponent(".building-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:stage,withIntermediateDirectories:false)
            defer { try? fm.removeItem(at:stage) }
            stored=try build(inputs,faces:faces,characters:plan.characters,families:families,key:key,stage:stage)
            if fm.fileExists(atPath:target.path) { try fm.removeItem(at:target) }
            try fm.moveItem(at:stage,to:target)
        }
        let session=try fm.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:temp,create:true)
        do {
            var aliases=[Unicode.Scalar:Unicode.Scalar]()
            for (number,alias) in stored.aliases {
                guard let n=UInt32(number),let source=Unicode.Scalar(n),let dest=Unicode.Scalar(UInt32(alias)) else { throw ModLoadError.invalid }
                aliases[source]=dest
            }
            try plan.write(aliases:aliases,to:session)
            for path in stored.files.keys {
                let file=session.appendingPathComponent(path), source=target.appendingPathComponent(path)
                try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                do { try fm.linkItem(at:source,to:file) } catch { try fm.copyItem(at:source,to:file) }
            }
            layers.insert(session.path,at:0)
            // Existing sessions own links to their files. A language/mod change can reclaim
            // the previous cache without invalidating an already open guest resource.
            for old in (try? fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)) ?? [] where old != target {
                let name = old.lastPathComponent
                if (name.count==64 && name.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)})) ||
                    (name.hasPrefix(".building-") && UUID(uuidString:String(name.dropFirst(10))) != nil) {
                    try? fm.removeItem(at:old)
                }
            }
            return session
        } catch { try? fm.removeItem(at:session); throw error }
    }
}
