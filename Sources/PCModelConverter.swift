import Foundation
import CryptoKit

// Native conversion is deliberately scoped to exact, previously exercised
// payloads. These profiles contain hashes/paths only, never MOD assets. A
// different version remains inactive until its references have been tested.
enum PCModelConverter {
    typealias F=ModFormats
    typealias Props=[String:String]
    static let revision="native-pc-model-2"
    struct Profile:Codable {let id:String;let name:String;let files:[RuntimeMod.Check]}
    struct Profiles:Codable {let format:String;let profiles:[Profile]}
    struct Candidate {let root:URL;let profile:Profile;let sourceSHA256:String}
    struct Outcome {let item:RuntimeMod;let reused:Bool}
    struct Baseline {let base:[RuntimeMod.Check];let dlc:[RuntimeMod.Check];let folders:[String];let urls:[URL]}
    static func profiles(_ url:URL)throws->[Profile] {
        let raw=try F.read(url);guard raw.count<=2*1024*1024 else {throw ModLoadError.limit}
        let list=try JSONDecoder().decode(Profiles.self,from:raw)
        guard list.format=="pjdv-pc-model-profiles-v1",list.profiles.count<=32 else {throw ModLoadError.unsupported}
        for p in list.profiles {
            guard !p.id.isEmpty,p.id.utf8.count<=128,!p.name.isEmpty,p.name.utf8.count<=256,
                  !p.files.isEmpty,p.files.count<=2000,Set(p.files.map(\.path)).count==p.files.count,
                  p.files.allSatisfy({$0.bytes<=512*1024*1024}) else {throw ModLoadError.limit}
            guard p.files.reduce(UInt64(0),{$0+$1.bytes})<=512*1024*1024 else {throw ModLoadError.limit}
            for f in p.files {guard f.path.hasPrefix("rom/"),!f.path.split(separator:"/").contains(".."),!f.path.contains("\\"),
                f.sha256.count==64,f.sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw ModLoadError.invalid}}
        };return list.profiles
    }
    static func check(_ progress:Progress)throws {if progress.isCancelled {throw ModPackageError.cancelled}}
    static func hash(_ url:URL,progress:Progress)throws->RuntimeMod.Check {
        try check(progress);let fm=FileManager.default,before=try fm.attributesOfItem(atPath:url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else {throw ModPackageError.specialFile}
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var h=SHA256(),count:UInt64=0
        while true {
            let n=try autoreleasepool{()->Int in try check(progress);let b=try file.read(upToCount:1024*1024) ?? Data();h.update(data:b);return b.count}
            if n==0{break};count+=UInt64(n)
        }
        let after=try fm.attributesOfItem(atPath:url.path)
        guard before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              (after[.size] as? NSNumber)?.uint64Value==count else {throw ModPackageError.changedSource}
        return .init(path:"",bytes:count,sha256:h.finalize().map{String(format:"%02x",$0)}.joined())
    }
    static func recognize(_ installed:URL,profiles:[Profile],progress:Progress,
                          report:((ModInstallUpdate)->Void)?=nil)throws->Candidate? {
        let fm=FileManager.default;try check(progress)
        var root=installed.standardizedFileURL.resolvingSymlinksInPath()
        if !fm.fileExists(atPath:root.appendingPathComponent("rom/mod_gm_module_tbl.farc").path) {
            let children=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)
            guard children.count==1 else {return nil};root=children[0]
        }
        guard try fm.attributesOfItem(atPath:root.path)[.type] as? FileAttributeType == .typeDirectory,
              root.resolvingSymlinksInPath()==root else {throw ModPackageError.specialFile}
        guard fm.fileExists(atPath:root.appendingPathComponent("rom/mod_gm_module_tbl.farc").path) else {return nil}
        var actual=[String:URL](),failure:Error?
        guard let it=fm.enumerator(at:root,includingPropertiesForKeys:nil,options:[],errorHandler:{_,e in failure=e;return false}) else {throw ModLoadError.invalid}
        let prefix=root.path+"/"
        for case let url as URL in it {
            try check(progress);guard url.standardizedFileURL.path.hasPrefix(prefix) else {throw ModPackageError.unsafePath}
            let rel=String(url.path.dropFirst(prefix.count)),parts=rel.split(separator:"/")
            if parts.contains(where:{$0.hasPrefix("._") || $0==".DS_Store" || $0=="__MACOSX"}){it.skipDescendants();continue}
            let type=try fm.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType
            if type == .typeDirectory {continue};guard type == .typeRegular else {throw ModPackageError.specialFile}
            if rel=="config.toml" || rel=="mod.json" {continue}
            guard actual.count<2000,actual[rel]==nil else {throw ModLoadError.limit};actual[rel]=url
        }
        if let failure {throw failure}
        let matches=profiles.filter{p in
            Set(p.files.map(\.path))==Set(actual.keys) && p.files.allSatisfy{row in
                guard let url=actual[row.path],let a=try? fm.attributesOfItem(atPath:url.path) else {return false}
                return (a[.size] as? NSNumber)?.uint64Value==row.bytes
            }
        };guard !matches.isEmpty else {return nil}
        let total=matches[0].files.reduce(UInt64(0)){$0+$1.bytes};var done:UInt64=0,checks=[RuntimeMod.Check]()
        for rel in actual.keys.sorted() {
            let value=try hash(actual[rel]!,progress:progress);done+=value.bytes
            checks.append(.init(path:rel,bytes:value.bytes,sha256:value.sha256))
            report?(.init(phase:"正在识别 MOD…",file:"",completed:done,total:total))
        }
        let expected=checks.map{$0.path+":"+String($0.bytes)+":"+$0.sha256}
        guard let profile=matches.first(where:{$0.files.sorted{$0.path<$1.path}.map{$0.path+":"+String($0.bytes)+":"+$0.sha256}==expected}) else {return nil}
        return Candidate(root:root,profile:profile,sourceSHA256:F.sha(Data(expected.joined(separator:"\n").utf8)))
    }
    private static func children(_ url:URL)throws->[URL] {
        let fm=FileManager.default;guard fm.fileExists(atPath:url.path) else {return []}
        return try fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil,options:.skipsHiddenFiles).sorted{$0.path<$1.path}
    }
    static func baseline(base:URL,dlc:URL,progress:Progress)throws->Baseline {
        let fm=FileManager.default,probe=try ModComposition.Worker(packs:[],base:base,dlc:dlc,output:base,progress:progress)
        let folders=try children(dlc).filter{try fm.attributesOfItem(atPath:$0.path)[.type] as? FileAttributeType == .typeDirectory}
        guard folders.count<=256 else {throw ModLoadError.limit}
        var urls=Set(probe.originals.values)
        for root in [base]+folders {
            var roms=[root.appendingPathComponent("rom")]
            for folder in try children(root) where folder.lastPathComponent.hasPrefix("rom_") {
                roms.append(folder.appendingPathComponent("rom"))
                for sub in try children(folder) where sub.lastPathComponent.hasPrefix("dlc") {roms.append(sub.appendingPathComponent("rom"))}
            }
            for rom in roms {
                for p in try children(rom.appendingPathComponent("2d")) where p.lastPathComponent.hasSuffix("spr_db.bin"){urls.insert(p)}
                for lang in try children(rom.appendingPathComponent("lang2")) {
                    let p=lang.appendingPathComponent("str_array.bin");if fm.fileExists(atPath:p.path){urls.insert(p)}
                }
                let setting=rom.appendingPathComponent("skin_param/osage_setting.txt");if fm.fileExists(atPath:setting.path){urls.insert(setting)}
            }
        }
        guard urls.count<=2048 else {throw ModLoadError.limit};var a=[RuntimeMod.Check](),b=[RuntimeMod.Check]()
        for url in urls.sorted(by:{$0.path<$1.path}) {
            guard url.resolvingSymlinksInPath()==url else {throw ModPackageError.unsafePath}
            let attrs=try fm.attributesOfItem(atPath:url.path);guard (attrs[.size] as? NSNumber)?.uint64Value ?? UInt64.max<=8*1024*1024 else {throw ModLoadError.limit}
            let h=try hash(url,progress:progress)
            if url.path.hasPrefix(base.path+"/"){a.append(.init(path:String(url.path.dropFirst(base.path.count+1)),bytes:h.bytes,sha256:h.sha256))}
            else if url.path.hasPrefix(dlc.path+"/"){b.append(.init(path:String(url.path.dropFirst(dlc.path.count+1)),bytes:h.bytes,sha256:h.sha256))}
            else {throw ModPackageError.unsafePath}
        }
        guard !a.isEmpty else {throw ModLoadError.invalid}
        return .init(base:a.sorted{$0.path<$1.path},dlc:b.sorted{$0.path<$1.path},folders:folders.map(\.lastPathComponent).sorted(),urls:urls.sorted{$0.path<$1.path})
    }
    static func identity(_ c:Candidate,_ b:Baseline)throws->UUID {
        let receipt=RuntimeMod.Conversion(converter:revision,profile:c.profile.id,sourceSHA256:c.sourceSHA256,base:b.base,dlc:b.dlc,dlcFolders:b.folders)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let h=Array(F.sha(try encoder.encode(receipt)).prefix(32))
        let value=[String(h[0..<8]),String(h[8..<12]),String(h[12..<16]),String(h[16..<20]),String(h[20..<32])].joined(separator:"-")
        guard let id=UUID(uuidString:value) else {throw ModLoadError.invalid};return id
    }
    static func convert(_ candidate:Candidate,base:URL,dlc:URL,catalog:RuntimeModCatalog,progress:Progress,
                        report:((ModInstallUpdate)->Void)?=nil)throws->Outcome {
        let fm=FileManager.default;try check(progress)
        report?(.init(phase:"正在转换 MOD…",file:"",completed:0,total:1))
        let base=base.standardizedFileURL.resolvingSymlinksInPath(),dlc=dlc.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot=try baseline(base:base,dlc:dlc,progress:progress),id=try identity(candidate,snapshot)
        let receipt=RuntimeMod.Conversion(converter:revision,profile:candidate.profile.id,sourceSHA256:candidate.sourceSHA256,base:snapshot.base,dlc:snapshot.dlc,dlcFolders:snapshot.folders)
        if fm.fileExists(atPath:catalog.root.appendingPathComponent(id.uuidString).path) {
            guard let existing=try catalog.records().first(where:{$0.id==id}),existing.format=="pjdv-runtime-model-v1",
                  let saved=existing.conversion else {throw ModPackageError.changedSource}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard try encoder.encode(saved)==encoder.encode(receipt) else {throw ModPackageError.changedSource}
            try catalog.verifyFully(existing,progress:progress);_=try catalog.overlayPaths(existing,base:base,dlc:dlc)
            report?(.init(phase:"MOD 已导入。",file:"",completed:1,total:1));return .init(item:existing,reused:true)
        }
        try fm.createDirectory(at:catalog.root,withIntermediateDirectories:true)
        let stage=catalog.root.appendingPathComponent(".converting-"+UUID().uuidString),input=stage.appendingPathComponent(".input")
        try fm.createDirectory(at:input,withIntermediateDirectories:true);defer{try? fm.removeItem(at:stage)}
        let builder=Builder(candidate:candidate,snapshot:snapshot,input:input,base:base,dlc:dlc,progress:progress)
        try builder.normalize()
        let draft=RuntimeMod(format:"pjdv-runtime-model-v1",id:id,name:candidate.profile.name,notes:"",layers:["0"],baseChecks:[snapshot.base[0]],files:[],conversion:receipt)
        let pack=ModComposition.Pack(draft,builder.files)
        let worker=try ModComposition.Worker(packs:[pack],base:base,dlc:dlc,output:stage.appendingPathComponent("0"),progress:progress)
        try fm.createDirectory(at:worker.output,withIntermediateDirectories:true);try worker.build();try check(progress)
        // Catch replaced resources before publishing, not on the next launch.
        guard try identity(candidate,baseline(base:base,dlc:dlc,progress:progress))==id else {throw ModPackageError.changedSource}
        try fm.removeItem(at:input)
        let files=worker.records.sorted{$0.path<$1.path}.map{RuntimeMod.Check(path:"0/"+$0.path,bytes:$0.bytes,sha256:$0.sha256)}
        let item=RuntimeMod(format:draft.format,id:id,name:draft.name,notes:"",layers:["0"],baseChecks:draft.baseChecks,files:files,conversion:receipt)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];try encoder.encode(item).write(to:stage.appendingPathComponent("runtime.json"))
        guard let adopted=try catalog.adoptPrepared(from:stage,progress:progress) else {throw ModLoadError.invalid}
        report?(.init(phase:"MOD 已导入。",file:"",completed:1,total:1));return .init(item:adopted,reused:false)
    }

    final class Builder {
        let candidate:Candidate,snapshot:Baseline,input:URL,base:URL,dlc:URL,progress:Progress
        let fm=FileManager.default
        var files=[String:ModComposition.File](),consumed=Set<String>()
        init(candidate:Candidate,snapshot:Baseline,input:URL,base:URL,dlc:URL,progress:Progress){self.candidate=candidate;self.snapshot=snapshot;self.input=input;self.base=base;self.dlc=dlc;self.progress=progress}
        func source(_ path:String)throws->Data {
            try check(progress);guard let row=candidate.profile.files.first(where:{$0.path==path}) else {throw ModLoadError.unsupported}
            let b=try F.read(candidate.root.appendingPathComponent(path));guard UInt64(b.count)==row.bytes,F.sha(b)==row.sha256 else {throw ModPackageError.changedSource};consumed.insert(path);return b
        }
        func put(_ path:String,_ data:Data)throws {
            try check(progress);guard files[path]==nil else {throw ModLoadError.invalid}
            let p=input.appendingPathComponent(path);try fm.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:p)
            files[path] = .init(url:p,check:.init(path:path,bytes:UInt64(data.count),sha256:F.sha(data)))
        }
        func copy(_ sourcePath:String,_ path:String)throws {
            guard let row=candidate.profile.files.first(where:{$0.path==sourcePath}) else {throw ModLoadError.invalid}
            let target=input.appendingPathComponent(path);try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            guard fm.createFile(atPath:target.path,contents:nil) else {throw ModLoadError.invalid}
            let a=try FileHandle(forReadingFrom:candidate.root.appendingPathComponent(sourcePath)),b=try FileHandle(forWritingTo:target);defer{try? a.close();try? b.close()}
            var h=SHA256(),count:UInt64=0
            while true {
                let n=try autoreleasepool{()->Int in try check(progress);let data=try a.read(upToCount:1024*1024) ?? Data();guard UInt64(data.count)<=row.bytes-count else {throw ModPackageError.changedSource};try b.write(contentsOf:data);h.update(data:data);return data.count}
                if n==0{break};count+=UInt64(n)
            }
            guard count==row.bytes,h.finalize().map({String(format:"%02x",$0)}).joined()==row.sha256 else {throw ModPackageError.changedSource}
            try b.synchronize();consumed.insert(sourcePath);files[path] = .init(url:target,check:.init(path:path,bytes:row.bytes,sha256:row.sha256))
        }
        func number(_ row:Props,_ key:String)throws->Int {guard let raw=row[key],let n=Int(raw),n>=0 else {throw ModLoadError.invalid};return n}
        func normalize()throws {
            let probe=try ModComposition.Worker(packs:[],base:base,dlc:dlc,output:input,progress:progress)
            var usedO=Set<Int>(),usedT=Set<Int>(),usedModules=Set<Int>(),usedItems=[String:Set<Int>](),usedCos=[String:Set<Int>]()
            var spriteKnown=[String:F.SpriteSet](),memberKnown=[String:F.Sprite](),maxSprite=0,maxMember=0
            for p in snapshot.urls {try autoreleasepool {
                try check(progress)
                if p.lastPathComponent.hasSuffix("obj_db.bin"){usedO.formUnion(try F.objects(F.read(p)).map(\.id))}
                else if p.lastPathComponent.hasSuffix("tex_db.bin"){usedT.formUnion(try F.textures(F.read(p)).map(\.id))}
                else if p.lastPathComponent.hasSuffix("module_tbl.farc") {
                    for b in try F.archive(F.read(p)){for r in F.group(try F.properties(b.data),"module"){usedModules.insert(try number(r,"id"))}}
                } else if p.lastPathComponent.hasSuffix("chritm_prop.farc") {
                    for b in try F.archive(F.read(p)) {
                        let d=try F.properties(b.data)
                        for r in F.group(d,"item"){usedItems[b.name,default:[]].insert(try number(r,"no"))}
                        for r in F.group(d,"cos"){usedCos[b.name,default:[]].insert(try number(r,"id"))}
                    }
                } else if p.lastPathComponent.hasSuffix("spr_db.bin") {
                    for r in try F.sprites(F.read(p)){spriteKnown[r.name]=r;maxSprite=max(maxSprite,r.id);for m in r.members{memberKnown[m.name]=m;maxMember=max(maxMember,m.id)}}
                }
            }}
            var objects=try F.objects(source("rom/objset/mod_obj_db.bin")),textures=try F.textures(source("rom/objset/mod_tex_db.bin")),textureMap=[Int:Int]()
            guard !objects.isEmpty,objects.count<=256,!textures.isEmpty,textures.count<=10000 else {throw ModLoadError.limit}
            let firstO=(usedO.max() ?? 0)+1,firstT=(usedT.max() ?? 0)+1
            for i in objects.indices{objects[i].id=firstO+i;guard objects[i].id<65536 else {throw ModLoadError.limit}}
            for i in textures.indices{let old=textures[i].id;if textureMap[old]==nil{textureMap[old]=firstT+textureMap.count};textures[i].id=textureMap[old]!}
            try put("rom_switch/rom/objset/obj_db.bin",F.objectData(objects));try put("rom_switch/rom/objset/tex_db.bin",F.textureData(textures))
            for row in candidate.profile.files where row.path.hasPrefix("rom/objset/") && row.path.hasSuffix(".farc") {
                try autoreleasepool {
                    let result=try F.rewriteArchive(source(row.path),rename:{$0},edit:{_,raw in
                        var b=raw;for p in try probe.texturePositions(raw){if let id=textureMap[try F.u(raw,p)]{try F.put(&b,p,id)}};return b
                    });try put("rom_switch/"+row.path,result)
                }
            }
            var chritm=try F.archive(source("rom/mod_chritm_prop.farc")),costumeMaps=[String:[Int:Int]]()
            for i in chritm.indices {
                var d=try F.properties(chritm[i].data),items=F.group(d,"item"),costumes=F.group(d,"cos")
                guard let before=usedItems[chritm[i].name],let cosBefore=usedCos[chritm[i].name] else {throw ModLoadError.unsupported}
                var next=1,itemMap=[Int:Int](),cosMap=[Int:Int]()
                for r in items{while before.contains(next){next+=1};let old=try number(r,"no");guard itemMap[old]==nil,next<100000 else {throw ModLoadError.limit};itemMap[old]=next;next+=1}
                next=1
                for r in costumes{while cosBefore.contains(next){next+=1};let old=try number(r,"id");guard cosMap[old]==nil,next<1023 else {throw ModLoadError.limit};cosMap[old]=next;next+=1}
                for j in items.indices{items[j]["no"]=String(itemMap[try number(items[j],"no")]!);if let raw=items[j]["org_itm"],let n=Int(raw),let target=itemMap[n]{items[j]["org_itm"]=String(target)}}
                for j in costumes.indices {
                    costumes[j]["id"]=String(cosMap[try number(costumes[j],"id")]!);let count=try number(costumes[j],"item.length");guard count<=256 else {throw ModLoadError.limit}
                    for k in 0..<count{let key="item.\(k)",old=try number(costumes[j],key);guard let n=itemMap[old] ?? (before.contains(old) ? old:nil) else {throw ModLoadError.invalid};costumes[j][key]=String(n)}
                }
                costumeMaps[chritm[i].name]=cosMap;d=F.setGroup(F.setGroup(d,"item",items),"cos",costumes);chritm[i].data=try F.propertyData(d)
            }
            try put("rom_switch/rom/chritm_prop.farc",F.archiveData(chritm))
            var modulesArchive=try F.archive(source("rom/mod_gm_module_tbl.farc")),moduleMap=[Int:Int](),modules=[Props]()
            var holes=(0..<min(1868,(usedModules.max() ?? 0)+1)).filter{!usedModules.contains($0)}
            let characters=["MIKU":"mikitm","RIN":"rinitm","LEN":"lenitm","LUKA":"lukitm","MEIKO":"meiitm","KAITO":"kaiitm","HAKU":"hakitm","NERU":"neritm","SAKINE":"sakitm","TETO":"tetitm"]
            for i in modulesArchive.indices {
                let d=try F.properties(modulesArchive[i].data);var rows=F.group(d,"module")
                for j in rows.indices {
                    let old=try number(rows[j],"id");guard !holes.isEmpty,moduleMap[old]==nil,let char=rows[j]["chara"],let stem=characters[char],let value=rows[j]["cos"],value.hasPrefix("COS_"),let cos=Int(value.dropFirst(4)),let target=costumeMaps[stem+"_tbl.txt"]?[cos-1] else {throw ModLoadError.invalid}
                    let id=holes.removeFirst();moduleMap[old]=id;rows[j]["id"]=String(id);rows[j]["cos"]=String(format:"COS_%03d",target+1);rows[j]["sort_index"]=String(1000+id);rows[j]["shop_price"]="0";modules.append(rows[j])
                }
                modulesArchive[i].data=try F.propertyData(F.setGroup(d,"module",rows,countKey:"module.data_list.length"))
            }
            guard !modules.isEmpty,modules.count<=32 else {throw ModLoadError.limit}
            try put("rom_switch/rom/gm_module_tbl.farc",F.archiveData(modulesArchive))
            let portraits=try F.sprites(source("rom/2d/mod_spr_db.bin"));var nativePortraits=[F.SpriteSet]()
            for (old,new) in moduleMap.sorted(by:{$0.key<$1.key}) {
                for kind in ["MD","THMB"] {
                    func name(_ n:Int)->String {kind=="MD" ? String(format:"SPR_SEL_MD%03dCMN",n):String(format:"SPR_CMNITM_THMB%03d",n)}
                    guard let sourceRow=portraits.first(where:{$0.name==name(old)}) ?? portraits.first(where:{$0.name==String(format:"SPR_SEL_MD%03dCMN",old)}) else {throw ModLoadError.invalid}
                    let targetName=name(new),canonical=spriteKnown[targetName];maxSprite+=1
                    var row=F.SpriteSet(id:canonical?.id ?? maxSprite,name:targetName,file:"spr_"+targetName.dropFirst(4).lowercased()+".bin",members:[])
                    for m in sourceRow.members {
                        let label=m.texture ? targetName.replacingOccurrences(of:"SPR_",with:"SPRTEX_")+"_MERGE_BC5COMP_\(m.index)" : targetName+(kind=="MD" ? "_MD_IMG":"_ITM_IMG")+(m.name.hasSuffix("_FT") ? "_FT":"")
                        maxMember+=1;row.members.append(.init(id:memberKnown[label]?.id ?? maxMember,name:label,index:m.index,texture:m.texture))
                    }
                    for m in canonical?.members ?? [] where !row.members.contains(where:{$0.name==m.name}){var extra=m;extra.index=0;row.members.append(extra)}
                    nativePortraits.append(row)
                    let archive="rom/2d/"+(sourceRow.file as NSString).deletingPathExtension+".farc",blocks=try F.archive(source(archive));guard blocks.count==1,blocks[0].name==sourceRow.file else {throw ModLoadError.unsupported}
                    try put("rom_switch/rom/2d/"+(row.file as NSString).deletingPathExtension+".farc",F.archiveData([.init(name:row.file,data:blocks[0].data)]))
                }
            }
            for p in snapshot.urls where p.lastPathComponent=="spr_db.bin" {
                let rel:String
                if p.path.hasPrefix(base.path+"/"){rel=String(p.path.dropFirst(base.path.count+1))}
                else if p.path.hasPrefix(dlc.path+"/") {
                    // The runtime searches DLC namespaces after the base UI.
                    // Strip only the mounted DLC's host folder (e.g. "36"),
                    // retaining rom_switch_dlc/dlcNN/rom/... in the overlay.
                    let parts=p.path.dropFirst(dlc.path.count+1).split(separator:"/")
                    guard parts.count>1 else {throw ModLoadError.invalid};rel=parts.dropFirst().joined(separator:"/")
                } else {throw ModLoadError.invalid}
                try put(rel,F.spriteData(nativePortraits))
            }
            let translationPath="rom/lang2/mod_str_array.toml"
            let translations=candidate.profile.files.contains(where:{$0.path==translationPath}) ? try PCModelConverter.translations(source(translationPath)):[:]
            for p in snapshot.urls where p.path.hasPrefix(base.path+"/") && p.lastPathComponent=="str_array.bin" {
                let lang=p.deletingLastPathComponent().lastPathComponent,original=try F.read(p);var changes=[Int:String]()
                for (old,new) in moduleMap {
                    guard let row=modules.first(where:{$0["id"]==String(new)}),let fallback=row["name"] else {throw ModLoadError.invalid}
                    changes[new+220]=translations[lang]?[old+275] ?? translations[""]?[old+275] ?? fallback
                }
                try put(String(p.path.dropFirst(base.path.count+1)),F.changeStrings(original,changes))
            }
            for row in candidate.profile.files where !consumed.contains(row.path) {
                if row.path=="rom/skin_param/mod_osage_setting.txt" {try put("rom_switch/rom/skin_param/osage_setting.txt",source(row.path))}
                else if row.path.hasPrefix("rom/skin_param/") || row.path.hasPrefix("rom/osage_play_data/"){try copy(row.path,"rom_switch/"+row.path)}
                else {throw ModLoadError.unsupported}
            }
            guard consumed==Set(candidate.profile.files.map(\.path)) else {throw ModLoadError.invalid}
        }
    }
    // The verified profile uses this strict TOML subset. Unknown TOML syntax
    // fails rather than silently losing localized labels; no script is run.
    static func translations(_ data:Data)throws->[String:[Int:String]] {
        guard let text=String(data:data,encoding:.utf8) else {throw ModLoadError.invalid};var result=[String:[Int:String]]()
        for raw in text.replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespaces);if line.isEmpty || line.hasPrefix("#"){continue}
            guard let eq=line.firstIndex(of:"=") else {throw ModLoadError.unsupported}
            let key=line[..<eq].trimmingCharacters(in:.whitespaces),parts=key.split(separator:".").map(String.init)
            guard (1...2).contains(parts.count),let id=Int(parts.last!),id>=0,id<1000000 else {throw ModLoadError.unsupported}
            let lang=parts.count==1 ? "":parts[0];guard ["","jp","cn","tw","en","kr"].contains(lang) else {throw ModLoadError.unsupported}
            let encoded=String(line[line.index(after:eq)...]).trimmingCharacters(in:.whitespaces)
            guard encoded.utf8.count<=4096,let value=try JSONSerialization.jsonObject(with:Data(encoded.utf8),options:.fragmentsAllowed) as? String,
                  result[lang]?[id]==nil,!value.contains("\0") else {throw ModLoadError.invalid}
            result[lang,default:[:]][id]=value
        };return result
    }
}
