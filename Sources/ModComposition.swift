import Foundation
import CryptoKit

// Prepared packages are combined on the device. Original resources and package
// payloads are read-only. The result is published only after the whole build
// succeeds, and has a save profile derived from the unordered selection.
enum ModComposition {
    typealias F=ModFormats
    typealias Props=[String:String]
    struct Session {let paths:[String];let profileID:String?}
    struct File {let url:URL;let check:RuntimeMod.Check}
    final class Pack {
        let item:RuntimeMod;let files:[String:File]
        var objects=[F.ObjectSet](),textures=[F.Named](),modules=[Props]()
        var objectMap=[Int:Int](),textureMap=[Int:Int](),moduleMap=[Int:Int]()
        var itemMaps=[String:[Int:Int]](),costumeMaps=[String:[Int:Int]]()
        var objectNames=[String:String](),archiveNames=[String:String](),textureNames=[String:String]()
        var objectHashes=[String:String](),textureHashes=[Int:String]()
        var ambiguousTextures=Set<Int>()
        var ignoredFiles=Set<String>()
        init(_ item:RuntimeMod,_ files:[String:File]){self.item=item;self.files=files}
    }
    struct Receipt:Codable {let key:String;let files:[RuntimeMod.Check];let generated:[String]}
    static let revision="native-composition-3"
    static func identity(_ items:[RuntimeMod])->String {
        let raw=items.map{$0.id.uuidString}.sorted().joined(separator:"\n")
        let h=F.sha(Data(raw.utf8));return String(h.prefix(32))
    }
    private static func effective(_ item:RuntimeMod,catalog:RuntimeModCatalog)throws->[String:File] {
        var files=[String:File]()
        for layer in item.layers {
            for c in item.files where c.path.hasPrefix(layer+"/") {
                let rel=String(c.path.dropFirst(layer.count+1))
                // Converter reports are package metadata, never game files.
                if ["UI-FIX.json","DLC-UI-FIX.json"].contains(rel) {continue}
                if files[rel]==nil {files[rel]=File(url:catalog.directory(item).appendingPathComponent(c.path),check:c)}
            }
        };return files
    }
    static func prepare(_ items:[RuntimeMod],catalog:RuntimeModCatalog,base:URL,dlc:URL,root:URL,progress:Progress=Progress())throws->Session {
        if progress.isCancelled {throw ModLoadError.cancelled}
        if items.isEmpty{return Session(paths:[],profileID:nil)}
        guard items.count<=16,Set(items.map(\.id)).count==items.count else {throw ModLoadError.limit}
        // Reuse this invocation's validated paths. A single-package launch
        // previously repeated every baseline hash and payload check here.
        let validatedPaths=try items.map{try catalog.overlayPaths($0,base:base,dlc:dlc)}
        if items.count==1 {return Session(paths:validatedPaths[0],profileID:items[0].id.uuidString)}
        let fm=FileManager.default
        var key=Data((revision+"\n"+base.resolvingSymlinksInPath().path).utf8)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var packs=[Pack]()
        for item in items.sorted(by:{$0.id.uuidString<$1.id.uuidString}) {
            key.append(try encoder.encode(item));let files=try effective(item,catalog:catalog)
            for path in files.keys.sorted() {
                let a=try fm.attributesOfItem(atPath:files[path]!.url.path)
                key.append(Data((path+":"+String((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)).utf8))
            }
            packs.append(Pack(item,files))
        }
        let staging=root.appendingPathComponent(".building-"+UUID().uuidString,isDirectory:true)
        let worker=try Worker(packs:packs,base:base,dlc:dlc,output:staging.appendingPathComponent("0"),progress:progress)
        for rel in worker.originals.keys.sorted() {
            let p=worker.originals[rel]!,a=try fm.attributesOfItem(atPath:p.path)
            key.append(Data((p.path+":"+String((a[.size] as? NSNumber)?.uint64Value ?? 0)+":"+String((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)).utf8))
        }
        let cacheKey=F.sha(key),profile=identity(items),destination=root.appendingPathComponent(cacheKey,isDirectory:true)
        if let raw=try? Data(contentsOf:destination.appendingPathComponent("complete.json")),let receipt=try? JSONDecoder().decode(Receipt.self,from:raw),receipt.key==cacheKey {
            var valid=true
            for c in receipt.files {
                if progress.isCancelled {throw ModLoadError.cancelled}
                let p=destination.appendingPathComponent("0/"+c.path),a=try? fm.attributesOfItem(atPath:p.path)
                if a?[.type] as? FileAttributeType != .typeRegular || (a?[.size] as? NSNumber)?.uint64Value != c.bytes {valid=false;break}
                if receipt.generated.contains(c.path) || c.bytes<=2*1024*1024 {
                    if (try? F.sha(F.read(p))) != c.sha256 {valid=false;break}
                }
            }
            if valid {return Session(paths:[destination.appendingPathComponent("0").path],profileID:profile)}
        }
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try fm.createDirectory(at:staging.appendingPathComponent("0"),withIntermediateDirectories:true)
        var committed=false;defer{if !committed {try? fm.removeItem(at:staging)}}
        try worker.build()
        try encoder.encode(Receipt(key:cacheKey,files:worker.records,generated:worker.generated.sorted())).write(to:staging.appendingPathComponent("complete.json"),options:.atomic)
        if fm.fileExists(atPath:destination.path) {
            // Only a failed/incomplete cache for this exact key is replaced.
            let stale=root.appendingPathComponent(".stale-"+UUID().uuidString)
            try fm.moveItem(at:destination,to:stale)
            do {try fm.moveItem(at:staging,to:destination)}catch{try? fm.moveItem(at:stale,to:destination);throw error}
            try? fm.removeItem(at:stale)
        } else {try fm.moveItem(at:staging,to:destination)}
        committed=true
        return Session(paths:[destination.appendingPathComponent("0").path],profileID:profile)
    }

    final class Worker {
        let packs:[Pack],base:URL,dlc:URL,output:URL,progress:Progress
        let fm=FileManager.default
        var originals=[String:URL](),handled=Set<String>(),records=[RuntimeMod.Check]()
        var written=[String:String](),owner=[String:String]()
        var generated=Set<String>()
        var objectBase=[String:[F.ObjectSet]](),textureBase=[String:[F.Named]](),spriteBase=[String:[F.SpriteSet]]()
        var archives=[String:[F.Block]]()
        var costumeBase=[String:[Props]](),moduleBase=[String:[Props]]()
        init(packs:[Pack],base:URL,dlc:URL,output:URL,progress:Progress)throws {
            // Stage registries carry references to object/texture IDs. Process
            // them before model packs, then rewrite all affected references.
            self.packs=packs.sorted {
                let a=$0.files.keys.contains{$0.hasSuffix("/stage_data.bin")},b=$1.files.keys.contains{$0.hasSuffix("/stage_data.bin")}
                return a != b ? a : $0.item.id.uuidString<$1.item.id.uuidString
            };self.base=base;self.dlc=dlc;self.output=output;self.progress=progress
            var roots=[base]
            roots += ((try? fm.contentsOfDirectory(at:dlc,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []).filter{(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true}
            for root in roots {
                var roms=[root.appendingPathComponent("rom")]
                for folder in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [] where folder.lastPathComponent.hasPrefix("rom_") {
                    roms.append(folder.appendingPathComponent("rom"))
                    // DLC layout may insert its dlcNN directory after rom_*.
                    for sub in (try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [] where sub.lastPathComponent.hasPrefix("dlc") {roms.append(sub.appendingPathComponent("rom"))}
                }
                for rom in roms {
                    var paths=(try? fm.contentsOfDirectory(at:rom,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
                    paths += ((try? fm.contentsOfDirectory(at:rom.appendingPathComponent("objset"),includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])
                    for p in paths where p.lastPathComponent.hasSuffix("chritm_prop.farc") || p.lastPathComponent.hasSuffix("module_tbl.farc") || p.lastPathComponent.hasSuffix("obj_db.bin") || p.lastPathComponent.hasSuffix("tex_db.bin") {
                        let rel=String(p.path.dropFirst(root.path.count+1));if let previous=originals[rel],previous != p {throw ModLoadError.invalid};originals[rel]=p
                    }
                }
            }
            for pack in packs {for rel in pack.files.keys {if originals[rel]==nil {originals[rel]=try original(rel,roots:roots)}}}
        }
        func original(_ rel:String,roots:[URL]?=nil)throws->URL? {
            if let p=originals[rel]{return p}
            if fm.fileExists(atPath:base.appendingPathComponent(rel).path){return base.appendingPathComponent(rel)}
            let candidates=(roots ?? ((try? fm.contentsOfDirectory(at:dlc,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])).map{$0.appendingPathComponent(rel)}.filter{fm.fileExists(atPath:$0.path)}
            guard candidates.count<=1 else {throw ModLoadError.invalid};return candidates.first
        }
        func check()throws {if progress.isCancelled {throw ModLoadError.cancelled}}
        func fail(_ a:String,_ b:String)throws->Never {throw ModLoadError.conflict(a+"、"+b)}
        func write(_ rel:String,_ data:Data,_ by:String="merged")throws {
            try check();guard !rel.hasPrefix("/"),!rel.split(separator:"/").contains("..") else {throw ModLoadError.invalid}
            guard data.count<=F.fileLimit else {throw ModLoadError.limit}
            let hash=F.sha(data)
            if let old=written[rel],old != hash {try fail(owner[rel] ?? "MOD",by)}
            if written[rel] != nil{return}
            let url=output.appendingPathComponent(rel);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)
            written[rel]=hash;owner[rel]=by;generated.insert(rel);records.append(.init(path:rel,bytes:UInt64(data.count),sha256:hash))
        }
        func copy(_ rel:String,_ file:File,_ by:String)throws {
            try check()
            if let h=written[rel] {if h != file.check.sha256 {try fail(owner[rel] ?? "MOD",by)};return}
            let url=output.appendingPathComponent(rel);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            do {try fm.linkItem(at:file.url,to:url)}catch {
                guard fm.createFile(atPath:url.path,contents:nil) else {throw ModLoadError.invalid}
                let input=try FileHandle(forReadingFrom:file.url),out=try FileHandle(forWritingTo:url);defer{try? input.close();try? out.close()}
                var digest=SHA256(),count:UInt64=0
                while true {
                    let n=try autoreleasepool {()->Int in try check();let b=try input.read(upToCount:1024*1024) ?? Data();if b.isEmpty{return 0};try out.write(contentsOf:b);digest.update(data:b);count+=UInt64(b.count);return b.count}
                    if n==0{break}
                }
                guard count==file.check.bytes,digest.finalize().map({String(format:"%02x",$0)}).joined()==file.check.sha256 else {throw ModLoadError.invalid};try out.synchronize()
            }
            written[rel]=file.check.sha256;owner[rel]=by;records.append(.init(path:rel,bytes:file.check.bytes,sha256:file.check.sha256))
        }
        func number(_ row:Props,_ key:String)throws->Int {guard let s=row[key],let n=Int(s),n>=0 else {throw ModLoadError.invalid};return n}
        func readArchive(_ rel:String)throws->[F.Block] {if let rows=archives[rel]{return rows};guard let p=try original(rel) else {throw ModLoadError.invalid};let rows=try F.archive(F.read(p));archives[rel]=rows;return rows}
        func build()throws {
            progress.totalUnitCount=8;try registries();progress.completedUnitCount=1
            try objectPayloads();progress.completedUnitCount=2
            try costumes();progress.completedUnitCount=3
            try modules();progress.completedUnitCount=4
            try stringTables();progress.completedUnitCount=5
            try sprites();progress.completedUnitCount=6
            try settings();progress.completedUnitCount=7
            try remainder();progress.completedUnitCount=8
        }
        func fingerprint(_ pack:Pack,_ file:File)throws->String {
            if let cached=pack.objectHashes[file.url.path]{return cached}
            let encoded=try F.read(file.url),index=try F.archiveIndex(encoded)
            if index.contains(where:{$0.expanded>F.fileLimit}) {
                // No pixel deduplication without a complete decoded identity.
                // Unique large costumes can still be remapped without ever
                // inflating their texture payloads into the host heap.
                var digest=SHA256()
                for entry in index.sorted(by:{$0.name<$1.name}) {
                    digest.update(data:Data(entry.name.utf8))
                    if entry.name.hasSuffix("_obj.bin") {
                        var raw=try F.archiveEntry(encoded,entry);let to=try F.u(raw,28),n=try F.u(raw,32)
                        guard n<=100000 else {throw ModLoadError.limit};var ordinal=[Int:Int]()
                        for i in 0..<n {ordinal[try F.u(raw,to+i*4)]=i+1}
                        for p in try texturePositions(raw) {if let v=ordinal[try F.u(raw,p)]{try F.put(&raw,p,v)}}
                        digest.update(data:raw)
                    } else {digest.update(data:encoded.subdata(in:try F.span(encoded,entry.offset,entry.packed)))}
                }
                let hash=digest.finalize().map{String(format:"%02x",$0)}.joined();pack.objectHashes[file.url.path]=hash;return hash
            }
            let blocks=try F.archive(encoded);var digest=SHA256()
            for block in blocks.sorted(by:{$0.name<$1.name}) {
                var raw=block.data
                if block.name.hasSuffix("_obj.bin") {
                    let n=try F.u(raw,4),to=try F.u(raw,28),nt=try F.u(raw,32)
                    guard n<=65536,nt<=100000 else {throw ModLoadError.limit}
                    let ids=try (0..<nt).map{try F.u(raw,to+$0*4)}
                    var ordinal=[Int:Int]();for (i,id) in ids.enumerated(){ordinal[id]=i+1}
                    var positions=try texturePositions(raw)
                    for p in positions {if let v=ordinal[try F.u(raw,p)]{try F.put(&raw,p,v)}}
                    positions.removeAll()
                    guard let tex=blocks.first(where:{$0.name==String(block.name.dropLast(8))+"_tex.bin"})?.data,try F.u(tex,4)==nt else {throw ModLoadError.invalid}
                    for (i,id) in ids.enumerated() {
                        let q=try F.u(tex,12+i*4),levels=try F.u(tex,q+4);guard levels<=128 else {throw ModLoadError.limit}
                        var h=SHA256();var head=Data(repeating:0,count:8);try F.put(&head,0,F.u(tex,q));try F.put(&head,4,F.u(tex,q+8));h.update(data:head)
                        for j in 0..<levels {let z=q+(try F.u(tex,q+12+j*4)),len=try F.u(tex,z+20);h.update(data:tex.subdata(in:try F.span(tex,z+4,12)));h.update(data:tex.subdata(in:try F.span(tex,z+24,len)))}
                        let hash=h.finalize().map{String(format:"%02x",$0)}.joined()
                        // Some song archives intentionally reuse one registry
                        // ID for different local texture payloads. Preserve the
                        // reference identity; it is not eligible for dedup.
                        if !pack.ambiguousTextures.contains(id) {
                            if let old=pack.textureHashes[id],old != hash {pack.textureHashes.removeValue(forKey:id);pack.ambiguousTextures.insert(id)}
                            else {pack.textureHashes[id]=hash}
                        }
                    }
                }
                digest.update(data:Data(block.name.utf8));digest.update(data:raw)
            }
            let hash=digest.finalize().map{String(format:"%02x",$0)}.joined();pack.objectHashes[file.url.path]=hash;return hash
        }
        func texturePositions(_ raw:Data)throws->[Int] {
            let n=try F.u(raw,4),nt=try F.u(raw,32),to=try F.u(raw,28),po=try F.u(raw,12)
            guard n<=65536,nt<=100000 else {throw ModLoadError.limit};var positions=(0..<nt).map{to+$0*4}
            for i in 0..<n {let q=try F.u(raw,po+i*4),nc=try F.u(raw,q+32),ma=q+(try F.u(raw,q+36));guard nc<=4096,positions.count<=2000000-nc*8 else {throw ModLoadError.limit};for j in 0..<nc {for k in 0..<8 {positions.append(ma+j*0x4b0+24+k*120)}}}
            for p in positions {_=try F.u(raw,p)};return positions
        }
        func objectFile(_ pack:Pack,_ row:F.ObjectSet)throws->File {
            let name=row.file.replacingOccurrences(of:"_obj.bin",with:".farc").lowercased()
            guard let f=pack.files.first(where:{$0.key.contains("/objset/") && URL(fileURLWithPath:$0.key).lastPathComponent.lowercased()==name})?.value else {throw ModLoadError.invalid};return f
        }
        func registries()throws {
            let objectPaths=Set(originals.keys.filter{$0.hasSuffix("/objset/obj_db.bin")}).union(packs.flatMap{$0.files.keys.filter{$0.hasSuffix("/objset/obj_db.bin")}})
            let texturePaths=Set(originals.keys.filter{$0.hasSuffix("/objset/tex_db.bin")}).union(packs.flatMap{$0.files.keys.filter{$0.hasSuffix("/objset/tex_db.bin")}})
            for rel in Set(originals.keys.filter{$0.hasSuffix("obj_db.bin")}).union(objectPaths) {if let p=try original(rel){objectBase[rel]=try F.objects(F.read(p))}}
            for rel in Set(originals.keys.filter{$0.hasSuffix("tex_db.bin")}).union(texturePaths) {if let p=try original(rel){textureBase[rel]=try F.textures(F.read(p))}}
            var usedO=Set(objectBase.values.flatMap{$0.map(\.id)}),usedT=Set(textureBase.values.flatMap{$0.map(\.id)})
            var nextO=(usedO.max() ?? 0)+1,nextT=(usedT.max() ?? 0)+1
            var addedObjects=[F.ObjectSet](),addedTextures=[F.Named](),objectShared=[String:(Pack,File,Int)](),textureShared=[String:Int]()
            var textureOwners=Set(textureBase.values.flatMap{$0.map(\.name)})
            for pack in packs {
                let anchored=pack.files.keys.contains{$0.hasSuffix("/stage_data.bin")}
                var deltaO=[String:F.ObjectSet](),deltaT=[String:F.Named]()
                for rel in pack.files.keys.sorted() where rel.hasSuffix("/objset/obj_db.bin") {
                    let before=Dictionary(uniqueKeysWithValues:(objectBase[rel] ?? []).map{($0.name,$0)})
                    for v in try F.objects(F.read(pack.files[rel]!.url)) where v != before[v.name] {
                        if before[v.name] != nil {throw ModLoadError.unsupported}
                        if let old=deltaO[v.name],old != v {throw ModLoadError.invalid};deltaO[v.name]=v
                    }
                }
                for rel in pack.files.keys.sorted() where rel.hasSuffix("/objset/tex_db.bin") {
                    let before=Set((textureBase[rel] ?? []).map{String($0.id)+":"+$0.name})
                    for v in try F.textures(F.read(pack.files[rel]!.url)) where !before.contains(String(v.id)+":"+v.name) {deltaT[String(v.id)+":"+v.name]=v}
                }
                for key in deltaO.keys.sorted() {
                    var v=deltaO[key]!;let file=try objectFile(pack,v),old=v.id
                    var sharedID:Int?
                    if let same=objectShared[v.name] {
                        if try fingerprint(pack,file)==fingerprint(same.0,same.1) {sharedID=same.2}
                        else {
                            // Preserve both variants rather than choosing an
                            // arbitrary winner. Property references are rebased
                            // below; unknown binary dependencies are rejected.
                            guard !anchored else {throw ModLoadError.unsupported}
                            let stem=URL(fileURLWithPath:file.url.path).deletingPathExtension().lastPathComponent
                            guard !pack.files.keys.contains(where:{!$0.contains("/objset/") && URL(fileURLWithPath:$0).lastPathComponent.lowercased().hasPrefix(stem.lowercased())}) else {throw ModLoadError.unsupported}
                            let renamed="PJDV_"+String(F.sha(Data((pack.item.id.uuidString+":"+v.name).utf8)).prefix(32))
                            if let old=pack.archiveNames[stem.lowercased()],old != renamed.lowercased() {throw ModLoadError.unsupported}
                            pack.objectNames[v.name]=renamed;pack.archiveNames[stem.lowercased()]=renamed.lowercased()
                            func filename(_ name:String)throws->String {
                                if name.isEmpty{return name};guard name.lowercased().hasPrefix(stem.lowercased()) else {throw ModLoadError.unsupported}
                                return renamed.lowercased()+name.dropFirst(stem.count)
                            }
                            v.name=renamed;v.file=try filename(v.file);v.texture=try filename(v.texture);v.archive=try filename(v.archive)
                        }
                    }
                    if let sharedID {v.id=sharedID}
                    else {
                        // An unchanged stage package can keep its existing IDs
                        // and opaque archives, including very large textures.
                        if !anchored {_=try fingerprint(pack,file)}
                        if usedO.contains(v.id){while usedO.contains(nextO){nextO+=1};v.id=nextO;nextO+=1};guard v.id<65536 else {throw ModLoadError.limit};usedO.insert(v.id);objectShared[v.name]=(pack,file,v.id);addedObjects.append(v)
                    }
                    if let prior=pack.objectMap[old],prior != v.id {throw ModLoadError.invalid};pack.objectMap[old]=v.id;pack.objects.append(v)
                }
                for key in deltaT.keys.sorted() {
                    var v=deltaT[key]!;let old=v.id,identity=pack.textureHashes[old].map{v.name+":"+$0}
                    let shared=identity.flatMap{textureShared[$0]}
                    if let existing=shared {v.id=existing}
                    else if let prior=pack.textureMap[old] {v.id=prior}
                    else {if usedT.contains(v.id){while usedT.contains(nextT){nextT+=1};v.id=nextT;nextT+=1};usedT.insert(v.id)}
                    if let identity {textureShared[identity]=v.id}
                    if shared==nil && textureOwners.contains(v.name) {
                        let name="PJDV_"+String(F.sha(Data((pack.item.id.uuidString+":texture:"+v.name).utf8)).prefix(32))
                        pack.textureNames[v.name]=name;v.name=name
                    }
                    textureOwners.insert(v.name)
                    if let prior=pack.textureMap[old],prior != v.id {throw ModLoadError.invalid};pack.textureMap[old]=v.id
                    if !addedTextures.contains(v){addedTextures.append(v)};pack.textures.append(v)
                }
            }
            for rel in objectPaths.sorted() {try write(rel,F.objectData((objectBase[rel] ?? [])+addedObjects));handled.insert(rel)}
            for rel in texturePaths.sorted() {try write(rel,F.textureData((textureBase[rel] ?? [])+addedTextures));handled.insert(rel)}
        }
        func objectPayloads()throws {
            var identity=[String:(Pack,File)]()
            for pack in packs {
                for rel in pack.files.keys.sorted() where rel.contains("/objset/") && rel.hasSuffix(".farc") {
                    try autoreleasepool {
                        let file=pack.files[rel]!
                        let stem=URL(fileURLWithPath:rel).deletingPathExtension().lastPathComponent,newStem=pack.archiveNames[stem.lowercased()]
                        let target=newStem.map{(rel as NSString).deletingLastPathComponent+"/"+$0+".farc"} ?? rel
                        if let old=identity[target] {
                            if old.1.check.sha256 != file.check.sha256,try fingerprint(old.0,old.1) != fingerprint(pack,file) {try fail(owner[rel] ?? "MOD",pack.item.name)};return
                        }
                        if newStem==nil && pack.textureMap.allSatisfy({$0.key==$0.value}) {try copy(target,file,pack.item.name);identity[target]=(pack,file);return}
                        let packed=try F.rewriteArchive(F.read(file.url),rename:{name in
                            if let newStem,name.lowercased().hasPrefix(stem.lowercased()){return newStem+name.dropFirst(stem.count)};return name
                        },edit:{_,source in
                            var data=source
                            for p in try texturePositions(data) {let id=try F.u(data,p);if let v=pack.textureMap[id]{try F.put(&data,p,v)}}
                            return data
                        })
                        try write(target,packed,pack.item.name);identity[target]=(pack,file)
                    };handled.insert(rel)
                }
            }
        }
        func costumes()throws {
            let paths=originals.keys.filter{$0.hasSuffix("chritm_prop.farc")}.sorted()
            var usedItems=[String:Set<Int>](),usedCostumes=[String:Set<Int>]()
            for rel in paths {
                for block in try readArchive(rel) {
                    let p=try F.properties(block.data);costumeBase[block.name,default:[]].append(p)
                    for row in F.group(p,"item"){usedItems[block.name,default:[]].insert(try number(row,"no"))}
                    for row in F.group(p,"cos"){usedCostumes[block.name,default:[]].insert(try number(row,"id"))}
                }
            }
            var additions=[String:[String:[Props]]]()
            for pack in packs {
                guard let file=pack.files["rom_switch/rom/chritm_prop.farc"] ?? pack.files.first(where:{$0.key.hasSuffix("chritm_prop.farc")})?.value else {continue}
                for block in try F.archive(F.read(file.url)) {
                    let p=try F.properties(block.data),before=costumeBase[block.name] ?? []
                    for (kind,idKey) in [("item","no"),("cos","id")] {
                        var prior=[String:[Props]]()
                        for b in before {for row in F.group(b,kind){prior[row[idKey] ?? "",default:[]].append(row)}}
                        let delta=F.group(p,kind).filter{!(prior[$0[idKey] ?? ""] ?? []).contains($0)}
                        var map=[Int:Int](),used=kind=="item" ? usedItems[block.name,default:[]]:usedCostumes[block.name,default:[]]
                        var next=1
                        for row in delta {
                            let old=try number(row,idKey);guard prior[String(old)]==nil else {throw ModLoadError.unsupported}
                            while used.contains(next){next+=1};guard next<100000 else {throw ModLoadError.limit};map[old]=next;used.insert(next);next+=1
                        }
                        if kind=="item" {pack.itemMaps[block.name]=map;usedItems[block.name]=used}
                        else {pack.costumeMaps[block.name]=map;usedCostumes[block.name]=used}
                        additions[block.name,default:[:]][kind,default:[]].append(contentsOf:[])
                        var remapped=delta
                        for i in remapped.indices {
                            let old=try number(remapped[i],idKey);remapped[i][idKey]=String(map[old]!)
                            if kind=="item",let raw=remapped[i]["org_itm"],let n=Int(raw),let new=map[n] {remapped[i]["org_itm"]=String(new)}
                            if kind=="item" {
                                for (key,value) in remapped[i] {
                                    if key.hasPrefix("objset."),let new=pack.objectNames[value] {remapped[i][key]=new}
                                    else if key.hasSuffix(".chg"),let new=pack.textureNames[value] {remapped[i][key]=new}
                                }
                            }
                            if kind=="cos" {
                                let n=try number(remapped[i],"item.length");guard n<=4096 else {throw ModLoadError.limit}
                                for j in 0..<n {let k="item.\(j)",id=try number(remapped[i],k);remapped[i][k]=String(pack.itemMaps[block.name]?[id] ?? id)}
                            }
                        }
                        additions[block.name,default:[:]][kind,default:[]].append(contentsOf:remapped)
                    }
                }
            }
            for rel in paths {
                var blocks=try readArchive(rel)
                for i in blocks.indices {
                    var d=try F.properties(blocks[i].data)
                    for kind in ["item","cos"] {d=F.setGroup(d,kind,F.group(d,kind)+(additions[blocks[i].name]?[kind] ?? []))}
                    blocks[i].data=try F.propertyData(d)
                }
                try write(rel,F.archiveData(blocks));handled.insert(rel)
            }
        }
        func modules()throws {
            let paths=originals.keys.filter{$0.hasSuffix("module_tbl.farc")}.sorted()
            var used=Set<Int>(),prior=[Int:[Props]]()
            for rel in paths {
                var all=[Props]()
                for block in try readArchive(rel){let rows=F.group(try F.properties(block.data),"module");all+=rows;for v in rows{let id=try number(v,"id");used.insert(id);prior[id,default:[]].append(v)}}
                moduleBase[rel]=all
            }
            let upper=min(1868,(used.max() ?? 0)+1);var holes=(0..<upper).filter{!used.contains($0)},added=[Props]()
            let character=["MIKU":"mikitm","RIN":"rinitm","LEN":"lenitm","LUKA":"lukitm","MEIKO":"meiitm","KAITO":"kaiitm","HAKU":"hakitm","NERU":"neritm","SAKINE":"sakitm","TETO":"tetitm"]
            for pack in packs {
                var delta=[Int:Props]()
                for rel in pack.files.keys.sorted() where rel.hasSuffix("module_tbl.farc") {
                    for block in try F.archive(F.read(pack.files[rel]!.url)) {
                        for row in F.group(try F.properties(block.data),"module") {
                            let id=try number(row,"id");if (prior[id] ?? []).contains(row){continue}
                            guard prior[id]==nil else {throw ModLoadError.unsupported}
                            if let old=delta[id],old != row {throw ModLoadError.invalid};delta[id]=row
                        }
                    }
                }
                for old in delta.keys.sorted() {
                    guard !holes.isEmpty else {throw ModLoadError.limit};let id=holes.removeFirst();var v=delta[old]!
                    guard let char=v["chara"],let table=character[char],let costume=v["cos"],costume.hasPrefix("COS_"),let oldCostume=Int(costume.dropFirst(4)),oldCostume>0 else {throw ModLoadError.invalid}
                    let new=pack.costumeMaps[table+"_tbl.txt"]?[oldCostume-1] ?? oldCostume-1
                    v["id"]=String(id);v["sort_index"]=String(1000+id);v["cos"]="COS_"+String(format:"%03d",new+1)
                    pack.moduleMap[old]=id;pack.modules.append(v);added.append(v)
                }
            }
            for rel in paths {
                var blocks=try readArchive(rel)
                for i in blocks.indices {
                    let d=try F.properties(blocks[i].data),rows=F.group(d,"module")
                    if !rows.isEmpty {blocks[i].data=try F.propertyData(F.setGroup(d,"module",rows+added,countKey:"module.data_list.length"))}
                }
                try write(rel,F.archiveData(blocks));handled.insert(rel)
            }
        }
        func stringTables()throws {
            let paths=Set(packs.flatMap{$0.files.keys.filter{$0.hasSuffix("/str_array.bin")}})
            for rel in paths.sorted() {
                guard let p=try original(rel) else {throw ModLoadError.unsupported};let raw=try F.read(p),before=try F.strings(raw)
                var changes=[Int:String](),owners=[Int:String]()
                func set(_ slot:Int,_ value:String,_ pack:Pack)throws {
                    if let old=changes[slot],old != value {try fail(owners[slot] ?? "MOD",pack.item.name)}
                    changes[slot]=value;owners[slot]=pack.item.name
                }
                for pack in packs {if let file=pack.files[rel] {
                    let values=try F.strings(F.read(file.url));guard values.count==before.count else {throw ModLoadError.unsupported}
                    for (i,value) in values.enumerated() where value != before[i] {
                        if pack.moduleMap[i-220] != nil {continue};try set(i,value,pack)
                    }
                    for (old,new) in pack.moduleMap {guard old+220<values.count else {throw ModLoadError.invalid};try set(new+220,values[old+220],pack)}
                }}
                try write(rel,F.changeStrings(raw,changes));handled.insert(rel)
            }
        }
        func sprites()throws {
            let paths=Set(packs.flatMap{$0.files.keys.filter{$0.hasSuffix("/2d/spr_db.bin")}})
            for rel in paths {if let p=try original(rel) {spriteBase[rel]=try F.sprites(F.read(p))}}
            var known=[String:F.SpriteSet](),members=[String:F.Sprite]()
            for rows in spriteBase.values {for row in rows {known[row.name]=row;for member in row.members{members[member.name]=member}}}
            var memberNamesByID=[Int:String]()
            for rows in spriteBase.values {for row in rows {for member in row.members {
                if let old=memberNamesByID[member.id],old != member.name {throw ModLoadError.invalid}
                memberNamesByID[member.id]=member.name
            }}}
            var usedSets=Set(known.values.map(\.id)),usedMembers=Set(memberNamesByID.keys)
            var nextSet=(usedSets.max() ?? 0)+1,nextMember=(usedMembers.max() ?? 0)+1
            var additions=[String:F.SpriteSet](),additionOwner=[String:String]()
            func add(_ row:F.SpriteSet,_ pack:Pack)throws {
                if let old=additions[row.name],old != row {try fail(additionOwner[row.name] ?? "MOD",pack.item.name)}
                additions[row.name]=row;additionOwner[row.name]=pack.item.name
            }
            // Song cover sets can extend an existing set; merge only the member
            // delta, retaining all original IDs and image indices.
            for pack in packs {
                var seen=[String:F.SpriteSet]()
                var spriteArchives=Set<String>()
                for rel in pack.files.keys.sorted() where rel.hasSuffix("/2d/spr_db.bin") {
                    let prior=Dictionary(uniqueKeysWithValues:(spriteBase[rel] ?? []).map{($0.name,$0)})
                    for row in try F.sprites(F.read(pack.files[rel]!.url)) {
                        spriteArchives.insert((row.file as NSString).deletingPathExtension+".farc")
                        if pack.moduleMap.keys.contains(where:{row.name==String(format:"SPR_SEL_MD%03dCMN",$0) || row.name==String(format:"SPR_CMNITM_THMB%03d",$0)}) {continue}
                        if row==prior[row.name]{continue}
                        if let old=seen[row.name],old != row {throw ModLoadError.invalid};seen[row.name]=row
                    }
                }
                // Prepared model packages can retain PC portrait archives after
                // their registry has moved to native slots. Keep only portraits
                // actually registered by this package; do not treat those
                // unreachable source leftovers as conflicting game resources.
                if !pack.moduleMap.isEmpty {
                    for path in pack.files.keys where path.contains("/2d/") {
                        let name=URL(fileURLWithPath:path).lastPathComponent
                        if name.range(of:#"^spr_(?:sel_md[0-9]+cmn|cmnitm_thmb[0-9]+)\.farc$"#,options:.regularExpression) != nil && !spriteArchives.contains(name) {pack.ignoredFiles.insert(path)}
                    }
                }
                for name in seen.keys.sorted() {
                    var row=seen[name]!
                    if let baseRow=known[name] {
                        guard row.id==baseRow.id,row.file==baseRow.file else {throw ModLoadError.unsupported}
                        var current=additions[name] ?? baseRow
                        let old=Dictionary(uniqueKeysWithValues:baseRow.members.map{($0.name,$0)})
                        for member in row.members where old[member.name] != member {
                            if let i=current.members.firstIndex(where:{$0.name==member.name}) {
                                if current.members[i] != old[member.name] && current.members[i] != member {try fail(additionOwner[name] ?? "MOD",pack.item.name)};current.members[i]=member
                            } else {guard !current.members.contains(where:{$0.id==member.id}) else {throw ModLoadError.conflict(pack.item.name)};current.members.append(member)}
                        }
                        row=current
                    } else {
                        if usedSets.contains(row.id){while usedSets.contains(nextSet){nextSet+=1};row.id=nextSet;nextSet+=1};usedSets.insert(row.id)
                        // Unknown collisions require a converter that also
                        // rewrites the payload's references, never last-wins.
                        // Names may alias several IDs across atlases; indices
                        // are local to each set. Only an ID pointing at a
                        // different name is an unresolved reference collision.
                        for member in row.members {if let prior=memberNamesByID[member.id],prior != member.name {throw ModLoadError.conflict(pack.item.name)};usedMembers.insert(member.id)}
                    }
                    additions[name]=row;additionOwner[name]=pack.item.name
                    known[name]=row;for member in row.members{members[member.name]=member;memberNamesByID[member.id]=member.name}
                }
            }
            nextSet=max(nextSet,(usedSets.max() ?? 0)+1);nextMember=max(nextMember,(usedMembers.max() ?? 0)+1)
            for pack in packs where !pack.moduleMap.isEmpty {
                guard let file=pack.files["rom_switch/rom/2d/spr_db.bin"] ?? pack.files.first(where:{$0.key.hasSuffix("/2d/spr_db.bin")})?.value else {throw ModLoadError.invalid}
                let source=Dictionary(uniqueKeysWithValues:try F.sprites(F.read(file.url)).map{($0.name,$0)})
                for (old,new) in pack.moduleMap.sorted(by:{$0.key<$1.key}) {
                    for template in ["SPR_SEL_MD%03dCMN","SPR_CMNITM_THMB%03d"] {
                        let oldName=String(format:template,old),newName=String(format:template,new)
                        guard var row=source[oldName] else {throw ModLoadError.invalid}
                        row.id=known[newName]?.id ?? nextSet;if known[newName]==nil {nextSet+=1};row.name=newName
                        let oldFile=row.file;row.file="spr_"+newName.dropFirst(4).lowercased()+".bin"
                        for i in row.members.indices {
                            row.members[i].name=row.members[i].name.replacingOccurrences(of:oldName,with:newName).replacingOccurrences(of:oldName.replacingOccurrences(of:"SPR_",with:"SPRTEX_"),with:newName.replacingOccurrences(of:"SPR_",with:"SPRTEX_"))
                            row.members[i].id=members[row.members[i].name]?.id ?? nextMember
                            if members[row.members[i].name]==nil {nextMember+=1}
                        }
                        try add(row,pack)
                        let oldArchive="rom_switch/rom/2d/"+URL(fileURLWithPath:oldFile).deletingPathExtension().lastPathComponent+".farc"
                        guard let payload=pack.files[oldArchive] else {throw ModLoadError.invalid};let blocks=try F.archive(F.read(payload.url));guard blocks.count==1 else {throw ModLoadError.unsupported}
                        for rel in paths {let dir=(rel as NSString).deletingLastPathComponent;try write(dir+"/"+(row.file as NSString).deletingPathExtension+".farc",F.archiveData([.init(name:row.file,data:blocks[0].data)]),pack.item.name)}
                        let oldBasename=URL(fileURLWithPath:oldArchive).lastPathComponent
                        for path in pack.files.keys where URL(fileURLWithPath:path).lastPathComponent==oldBasename {handled.insert(path)}
                    }
                }
            }
            for rel in paths.sorted() {
                var rows=spriteBase[rel] ?? [];var indices=Dictionary(uniqueKeysWithValues:rows.enumerated().map{($0.element.name,$0.offset)})
                for name in additions.keys.sorted(){let row=additions[name]!;if let i=indices[name]{rows[i]=row}else{indices[name]=rows.count;rows.append(row)}}
                guard Set(rows.map(\.id)).count==rows.count else {throw ModLoadError.conflict("角色图片")}
                var ids=[Int:String]();for row in rows{for member in row.members{if let old=ids[member.id],old != member.name{throw ModLoadError.conflict("角色图片")};ids[member.id]=member.name}}
                try write(rel,F.spriteData(rows));handled.insert(rel)
            }
        }
        func mergeProperties(_ base:Props,_ sources:[(Pack,Props)])throws->Props {
            var result=base,owners=[String:String]()
            for (pack,values) in sources {for (key,value) in values where value != base[key] {
                if let old=result[key],old != base[key],old != value {try fail(owners[key] ?? "MOD",pack.item.name)}
                result[key]=value;owners[key]=pack.item.name
            }};return result
        }
        func settings()throws {
            let rel="rom_switch/rom/skin_param/osage_setting.txt"
            let inputs=packs.compactMap{pack in pack.files[rel].map{(pack,$0)}};guard !inputs.isEmpty else {return}
            guard let source=try original(rel) else {throw ModLoadError.invalid};let before=try F.properties(F.read(source));var result=before
            for kind in ["cat","obj"] {
                let baseRows=F.group(before,kind),old=Dictionary(uniqueKeysWithValues:baseRows.compactMap{r in r["name"].map{($0,r)}})
                var rows=baseRows,indices=Dictionary(uniqueKeysWithValues:rows.enumerated().compactMap{n,r in r["name"].map{($0,n)}}),owners=[String:String]()
                for (pack,file) in inputs {for row in F.group(try F.properties(F.read(file.url)),kind) {
                    guard let name=row["name"] else {throw ModLoadError.invalid};if row==old[name]{continue}
                    if let i=indices[name] {if rows[i] != old[name] && rows[i] != row {try fail(owners[name] ?? "MOD",pack.item.name)};rows[i]=row}
                    else {indices[name]=rows.count;rows.append(row)};owners[name]=pack.item.name
                }}
                result=F.setGroup(result,kind,rows)
            }
            try write(rel,F.propertyData(result));handled.insert(rel)
        }
        func stage(_ raw:Data,_ pack:Pack)throws->Data {
            var b=raw;let n=try F.u(b,0),so=try F.u(b,4);guard n<=65536 else {throw ModLoadError.limit};_=try F.span(b,so,n*112)
            for i in 0..<n {let q=so+i*112
                let old=try F.u(b,q+8);if let new=pack.objectMap[old]{try F.put(&b,q+8,new)}
                for p in stride(from:12,to:36,by:4){let id=try F.u(b,q+p+2,2);if let new=pack.objectMap[id]{try F.put(&b,q+p+2,new,2)}}
                for p in [36,40,44,56,60]{let id=try F.u(b,q+p);if let new=pack.textureMap[id]{try F.put(&b,q+p,new)}}
            };return b
        }
        func remainder()throws {
            let paths=Set(packs.flatMap{$0.files.keys}).subtracting(handled)
            for rel in paths.sorted() {
                try check();let candidates=packs.compactMap{pack in pack.ignoredFiles.contains(rel) ? nil : pack.files[rel].map{(pack,$0)}}
                if candidates.isEmpty {continue}
                if candidates.count==1 {let (pack,file)=candidates[0]
                    if rel.hasSuffix("/stage_data.bin"){try write(rel,stage(F.read(file.url),pack),pack.item.name)}else{try copy(rel,file,pack.item.name)}
                } else {
                    let hashes=Set(candidates.map{$0.1.check.sha256})
                    if hashes.count==1 {try copy(rel,candidates[0].1,candidates[0].0.item.name);continue}
                    if rel.hasSuffix(".txt"),let p=try original(rel) {
                        let before=try F.properties(F.read(p));let sources=try candidates.map{($0.0,try F.properties(F.read($0.1.url)))}
                        try write(rel,F.propertyData(mergeProperties(before,sources)));continue
                    }
                    if let p=try original(rel) {
                        let hash=F.sha(try F.read(p)),changed=candidates.filter{$0.1.check.sha256 != hash}
                        if Set(changed.map{$0.1.check.sha256}).count==1 {try copy(rel,changed[0].1,changed[0].0.item.name);continue}
                    }
                    throw ModLoadError.conflict(candidates.map{$0.0.item.name}.joined(separator:"、"))
                }
            }
        }
    }
}
