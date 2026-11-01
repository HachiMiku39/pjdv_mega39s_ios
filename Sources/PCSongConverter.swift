import Foundation

// Native resource adapter for conventional FT charts + movie-only PC songs.
// Detection is structural; no author/package hash allowlist or PC code runs.
enum PCSongConverter {
    typealias F=ModFormats
    typealias Props=[String:String]
    static let profile="resource-video-song-7"
    static func recognize(_ installed:URL,progress:Progress,report:((ModInstallUpdate)->Void)?=nil)throws->PCModelConverter.Candidate? {
        let fm=FileManager.default;var root=installed.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<4 {
            if fm.fileExists(atPath:root.appendingPathComponent("rom/mod_pv_db.txt").path){break}
            let dirs=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles).filter{(try? fm.attributesOfItem(atPath:$0.path)[.type]) as? FileAttributeType == .typeDirectory}
            guard dirs.count==1 else{return nil};root=dirs[0];guard root.resolvingSymlinksInPath()==root else{throw ModPackageError.specialFile}
        }
        guard fm.fileExists(atPath:root.appendingPathComponent("rom/mod_pv_db.txt").path) else{return nil}
        var failure:Error?
        guard let it=fm.enumerator(at:root,includingPropertiesForKeys:nil,options:[],errorHandler:{_,e in failure=e;return false}) else{throw ModLoadError.invalid}
        var inputs=[(String,URL)](),total:UInt64=0
        for case let url as URL in it {
            try PCModelConverter.check(progress);let rel=String(url.path.dropFirst(root.path.count+1)),parts=rel.split(separator:"/")
            if parts.contains(where:{$0.hasPrefix("._") || $0==".DS_Store" || $0=="__MACOSX"}){it.skipDescendants();continue}
            let a=try fm.attributesOfItem(atPath:url.path),type=a[.type] as? FileAttributeType
            if type == .typeDirectory{continue};guard type == .typeRegular else{throw ModPackageError.specialFile}
            let ext=url.pathExtension.lowercased()
            guard !["dll","exe","dylib","so","nro","ips","pchtxt"].contains(ext) else{throw ModLoadError.unsupported}
            if !rel.hasPrefix("rom/") {
                guard ["config.toml","mod.json"].contains(rel.lowercased()) || ["txt","md","png","jpg","jpeg","webp"].contains(ext) else{throw ModLoadError.unsupported};continue
            }
            guard ["rom/mod_pv_db.txt","rom/fontmap.farc"].contains(rel) || ["rom/2d/","rom/script/","rom/sound/song/","rom/movie/"].contains(where:{rel.hasPrefix($0)}) else{throw ModLoadError.unsupported}
            let bytes=(a[.size] as? NSNumber)?.uint64Value ?? UInt64.max,limit:UInt64=rel.hasPrefix("rom/movie/") ? 16*1024*1024*1024:UInt64(F.fileLimit)
            guard inputs.count<50000,bytes<=limit,total<=32*1024*1024*1024-bytes else{throw ModLoadError.limit};total+=bytes;inputs.append((rel,url))
        }
        if let failure{throw failure}
        guard !inputs.isEmpty,Set(inputs.map{$0.0.lowercased()}).count==inputs.count else{throw ModPackageError.unsafePath}
        var checks=[RuntimeMod.Check](),done:UInt64=0
        for (rel,url) in inputs.sorted(by:{$0.0<$1.0}) {
            let h=try PCModelConverter.hash(url,progress:progress);checks.append(.init(path:rel,bytes:h.bytes,sha256:h.sha256));done+=h.bytes
            report?(.init(phase:"正在识别 MOD…",file:"",completed:done,total:total))
        }
        let name=try PCModelConverter.displayName(root,fallback:"Song MOD"),raw=checks.map{$0.path+":"+String($0.bytes)+":"+$0.sha256}.joined(separator:"\n")
        return .init(root:root,profile:.init(id:profile,name:name,files:checks),sourceSHA256:F.sha(Data(raw.utf8)))
    }
    static func convert(_ candidate:PCModelConverter.Candidate,base baseURL:URL,dlc dlcURL:URL,catalog:RuntimeModCatalog,progress:Progress,report:((ModInstallUpdate)->Void)?=nil)throws->PCModelConverter.Outcome {
        let base=baseURL.standardizedFileURL.resolvingSymlinksInPath(),dlc=dlcURL.standardizedFileURL.resolvingSymlinksInPath()
        let fm=FileManager.default;try PCModelConverter.check(progress)
        var snapshot=try PCModelConverter.baseline(base:base,dlc:dlc,progress:progress)
        let folders=try fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:.skipsHiddenFiles).filter{$0.lastPathComponent.hasPrefix("rom_")}
        var urls=snapshot.urls,baseRows=snapshot.base
        for folder in folders {
            for file in ["pv_db.txt","gm_pv_list_tbl.farc","fontmap.farc"] {
                let p=folder.appendingPathComponent("rom/"+file)
                if fm.fileExists(atPath:p.path),!urls.contains(p) {
                    let h=try PCModelConverter.hash(p,progress:progress);guard h.bytes<=8*1024*1024 else{throw ModLoadError.limit}
                    urls.append(p);baseRows.append(.init(path:String(p.path.dropFirst(base.path.count+1)),bytes:h.bytes,sha256:h.sha256))
                }
            }
        }
        snapshot = .init(base:baseRows.sorted{$0.path<$1.path},dlc:snapshot.dlc,folders:snapshot.folders,urls:urls.sorted{$0.path<$1.path})
        let id=try PCModelConverter.identity(candidate,snapshot),receipt=RuntimeMod.Conversion(converter:PCModelConverter.revision,profile:profile,sourceSHA256:candidate.sourceSHA256,base:snapshot.base,dlc:snapshot.dlc,dlcFolders:snapshot.folders)
        if fm.fileExists(atPath:catalog.root.appendingPathComponent(id.uuidString).path) {
            guard let item=try catalog.records().first(where:{$0.id==id}),item.format=="pjdv-runtime-song-v1" else{throw ModPackageError.changedSource}
            try catalog.verifyFully(item,progress:progress);_=try catalog.overlayPaths(item,base:base,dlc:dlc);return .init(item:item,reused:true)
        }
        try fm.createDirectory(at:catalog.root,withIntermediateDirectories:true)
        let stage=catalog.root.appendingPathComponent(".converting-"+UUID().uuidString),input=stage.appendingPathComponent(".input")
        try fm.createDirectory(at:input,withIntermediateDirectories:true);defer{try? fm.removeItem(at:stage)}
        let builder=PCModelConverter.Builder(candidate:candidate,snapshot:snapshot,input:input,base:base,dlc:dlc,progress:progress)
        var pv=try F.properties(builder.source("rom/mod_pv_db.txt")),ids=Set<Int>()
        for key in pv.keys {
            let head=key.split(separator:".").first.map(String.init) ?? ""
            guard head.hasPrefix("pv_"),let id=Int(head.dropFirst(3)),(1...999).contains(id),head==String(format:"pv_%03d",id) else{throw ModLoadError.unsupported};ids.insert(id)
        }
        guard !ids.isEmpty,ids.count<=128 else{throw ModLoadError.limit}
        let fontFiles=["rom/fontmap.farc","rom/2d/spr_fnt_36.farc","rom/2d/spr_fnt_bold36.farc"]
        let available=Set(candidate.profile.files.map(\.path))
        if fontFiles.contains(where:available.contains) {
            guard fontFiles.allSatisfy(available.contains) else{throw ModLoadError.unsupported}
            let sourceMaps=try F.archive(builder.source(fontFiles[0]));guard sourceMaps.count==1 else{throw ModLoadError.unsupported}
            var required=Set<UInt16>()
            for (key,value) in pv where key.contains("song_name") || key.contains("lyric.") || key.contains("songinfo") {
                for scalar in value.unicodeScalars where scalar.value>=32 && scalar.value != 127 {
                    guard scalar.value<=65535 else{throw ModLoadError.unsupported};required.insert(UInt16(scalar.value))
                }
            }
            var paired=false
            for p in snapshot.urls where p.lastPathComponent=="fontmap.farc" {
                var blocks=try F.archive(F.read(p));guard blocks.count==1,blocks[0].name==sourceMaps[0].name else{throw ModLoadError.unsupported}
                blocks[0].data=try F.pairedFontMap(blocks[0].data,source:sourceMaps[0].data,required:required)
                try builder.put(try relative(p,base:base,dlc:dlc),F.archiveData(blocks));paired=true
            }
            guard paired else{throw ModLoadError.unsupported}
            for font in fontFiles.dropFirst() {
                try autoreleasepool {
                    let blocks=try F.archive(builder.source(font))
                    guard blocks.count==1,blocks[0].name==(font as NSString).lastPathComponent.replacingOccurrences(of:".farc",with:".bin") else{throw ModLoadError.unsupported}
                    _=try F.SpritePayload(blocks[0].data)
                }
                try builder.copy(font,"rom_switch/"+font)
            }
        }
        let sprites=try F.sprites(builder.source("rom/2d/mod_spr_db.bin"));var usedSets=Set<Int>(),usedMembers=Set<Int>(),known=[String:F.SpriteSet]()
        for p in snapshot.urls where p.lastPathComponent.hasSuffix("spr_db.bin") {for row in try F.sprites(F.read(p)){usedSets.insert(row.id);known[row.name]=row;for m in row.members{usedMembers.insert(m.id)}}}
        var nextSet=(usedSets.max() ?? 0)+1,nextMember=(usedMembers.max() ?? 0)+1
        var selected=[F.SpriteSet](),smallCovers=[Int:(F.SpritePayload,Int)]()
        for id in ids.sorted() {
            let prefix=String(format:"pv_%03d.",id)
            guard pv[prefix+"movie_pv_type"]=="ONLY",let declaredMovie=pv[prefix+"movie_file_name"],let audio=pv[prefix+"song_file_name"] else{throw ModLoadError.unsupported}
            let movie=try movieInput(declaredMovie,available:Set(candidate.profile.files.map(\.path)))
            for path in [movie,audio] {guard safeAsset(path),candidate.profile.files.contains(where:{$0.path==path}) else{throw ModLoadError.invalid}}
            let scripts=try activeScripts(pv,prefix:prefix)
            guard !scripts.isEmpty else{throw ModLoadError.invalid}
            for (key,script) in scripts {
                guard safeAsset(script),script.hasPrefix("rom/script/"),script.hasSuffix(".dsc") else{throw ModLoadError.unsupported}
                if builder.files[script] == nil {
                    let data=try builder.source(script);try validateVideoChart(data)
                    try builder.put(script,data);try builder.put("rom_switch/"+script,data)
                }
                // Only the explicitly validated common FT command subset is
                // advertised to the native reader. Chart words stay unchanged.
                pv[String(key.dropLast("script_file_name".count))+"script_format"]="0x14050921"
            }
            let audioPaths=Set(pv.filter{$0.key.hasPrefix(prefix) && $0.key.hasSuffix("song_file_name")}.map(\.value))
            for audio in audioPaths {
                guard safeAsset(audio),audio.hasPrefix("rom/sound/song/"),audio.hasSuffix(".ogg") else{throw ModLoadError.unsupported}
                if builder.files["rom_switch/"+audio]==nil{try builder.copy(audio,"rom_switch/"+audio)}
            }
            let outputMovie=(movie as NSString).deletingPathExtension+".mp4",target=input.appendingPathComponent(outputMovie)
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            if builder.files[outputMovie] != nil {} else if movie.hasSuffix(".usm") {try PCModVideo.convert(candidate.root.appendingPathComponent(movie),to:target,progress:progress,report:report)}
            else if movie.hasSuffix(".mp4") {try builder.copy(movie,outputMovie)}
            else{throw ModLoadError.unsupported}
            if builder.files[outputMovie]==nil {let h=try PCModelConverter.hash(target,progress:progress);builder.files[outputMovie] = .init(url:target,check:.init(path:outputMovie,bytes:h.bytes,sha256:h.sha256))}
            // The guest may resolve a relative movie through the Switch resource
            // namespace, just as it does for scripts. Both paths share a streamed
            // file reference; never materialize a movie as one Data allocation.
            guard let converted=builder.files[outputMovie] else{throw ModLoadError.invalid}
            let nativeMovie="rom_switch/"+outputMovie
            builder.files[nativeMovie] = .init(url:converted.url,check:.init(path:nativeMovie,bytes:converted.check.bytes,sha256:converted.check.sha256))
            builder.consumed.insert(movie);pv[prefix+"movie_file_name"]=outputMovie
            // Native movie-only setup from the title's own PV430. It has no
            // visible performer/stage; PC TEST_DESIGN dummy motions are absent
            // on Switch. Never apply this setup to a real-time 3D PV.
            for key in Array(pv.keys) where ["field.","motion.","motion2P.","performer."].contains(where:{key.hasPrefix(prefix+$0)}) {pv.removeValue(forKey:key)}
            for (key,value) in ["field.01.stage":"STGTST","field.length":"1","motion.00":"CMN_MRA00_13_01","motion2P.00":"CMN_MRA00_13_01","performer.0.chara":"MIK","performer.0.pv_costume":"1","performer.0.type":"VOCAL","performer.num":"1","is_old_pv":"1"]{pv[prefix+key]=value}
            let name=String(format:"SPR_SEL_PV%03d",id)
            guard var row=sprites.first(where:{$0.name==name}) else{throw ModLoadError.invalid}
            let archive="rom/2d/"+(row.file as NSString).deletingPathExtension+".farc",blocks=try F.archive(builder.source(archive))
            guard blocks.count==1,blocks[0].name==row.file else{throw ModLoadError.unsupported}
            let payload=try F.SpritePayload(blocks[0].data)
            guard let cover=row.members.first(where:{$0.name.hasSuffix(String(format:"_SONG_BG%03d",id)) && !$0.texture}),payload.sprites.indices.contains(cover.index) else{throw ModLoadError.invalid}
            let jacket=row.members.first(where:{$0.name.hasSuffix(String(format:"_SONG_JK%03d",id)) && !$0.texture}) ?? cover
            guard payload.sprites.indices.contains(jacket.index) else{throw ModLoadError.invalid}
            smallCovers[id]=(payload,jacket.index)
            row.id=nextSet;nextSet+=1
            for i in row.members.indices{row.members[i].id=nextMember;nextMember+=1;guard row.members[i].id<65536 else{throw ModLoadError.limit}}
            selected.append(row);try builder.put("rom_switch/"+archive,F.archiveData(blocks))
        }
        // Shared thumbnails supplied by PC packs often omit or overwrite native
        // entries. Build them from each large jacket; preserve the native atlas.
        var smallIDs=[String:Int]()
        func smallID(_ name:String)->Int {if let n=smallIDs[name]{return n};let n=nextMember;nextMember+=1;smallIDs[name]=n;return n}
        for p in snapshot.urls where p.lastPathComponent=="spr_db.bin" {
            let rel=try relative(p,base:base,dlc:dlc),dir=(rel as NSString).deletingLastPathComponent
            var additions=selected
            if let original=try ModComposition.Worker(packs:[],base:base,dlc:dlc,output:input,progress:progress).original(dir+"/spr_sel_pvtmb.farc") {
                let blocks=try F.archive(F.read(original));guard blocks.count==1 else{throw ModLoadError.unsupported}
                var payload=try F.SpritePayload(blocks[0].data)
                guard var row=try F.sprites(F.read(p)).first(where:{$0.name=="SPR_SEL_PVTMB"}) else{throw ModLoadError.invalid}
                for id in ids.sorted() {
                    let name=String(format:"SPR_SEL_PVTMB_%03d",id);guard !row.members.contains(where:{$0.name==name}),let (source,index)=smallCovers[id] else{throw ModLoadError.unsupported}
                    let textureIndex=payload.textures.count
                    let position=try payload.add(from:source,index:index,name:String(format:"%03d",id),texturePrefix:"PJDV_\(id)_",displayLike:payload.sprites.first)
                    let textureName="SPRTEX_SEL_PVTMB_PJDV_\(id)_0"
                    row.members.append(.init(id:smallID(textureName),name:textureName,index:textureIndex,texture:true))
                    row.members.append(.init(id:smallID(name),name:name,index:position,texture:false))
                }
                additions.append(row);try builder.put(dir+"/spr_sel_pvtmb.farc",F.archiveData([.init(name:blocks[0].name,data:payload.data())]))
            }
            try builder.put(rel,F.spriteData(additions))
        }
        var playlistFound=false
        for p in snapshot.urls where p.path.hasPrefix(base.path+"/") {
            let rel=String(p.path.dropFirst(base.path.count+1))
            if p.lastPathComponent=="pv_db.txt" {
                var before=try F.properties(F.read(p))
                guard !before.keys.contains(where:{k in ids.contains(where:{k.hasPrefix(String(format:"pv_%03d.",$0))})}) else{throw ModLoadError.conflict(candidate.profile.name)}
                before.merge(pv){_,new in new};try builder.put(rel,F.propertyData(before))
            } else if p.lastPathComponent=="gm_pv_list_tbl.farc" {
                var blocks=try F.archive(F.read(p))
                for i in blocks.indices {
                    let d=try F.properties(blocks[i].data);var rows=F.group(d,"pv_list")
                    guard let template=rows.first(where:{$0["id"]=="2"}) else{throw ModLoadError.unsupported}
                    for id in ids.sorted() {
                        guard !rows.contains(where:{$0["id"]==String(id)}) else{throw ModLoadError.conflict(candidate.profile.name)}
                        var row=template;row["id"]=String(id);row["name"]=pv[String(format:"pv_%03d.song_name",id)];row["ignore"]="0"
                        for diff in ["easy","normal","hard","extreme","encore"] {
                            for key in Array(row.keys) where key.hasPrefix(diff+"."){row.removeValue(forKey:key)}
                            let count=Int(pv[String(format:"pv_%03d.difficulty.",id)+diff+".length"] ?? "0") ?? 0
                            guard (0...4).contains(count) else{throw ModLoadError.limit};row[diff+".length"]=String(count)
                            for j in 0..<count {for (k,v) in ["edition":String(j),"ver":"1","st_day":"1","st_month":"1","st_year":"2000","ed_day":"1","ed_month":"1","ed_year":"2099"]{row[diff+".\(j)."+k]=v}}
                        };rows.append(row)
                    }
                    blocks[i].data=try F.propertyData(F.setGroup(d,"pv_list",rows,countKey:"pv_list.data_list.length"));playlistFound=true
                };try builder.put(rel,F.archiveData(blocks))
            }
        }
        guard playlistFound else{throw ModLoadError.invalid}
        // Extra covers and a legacy PC thumbnail atlas can describe commented-out
        // songs. They are not mounted. Other unhandled resources are rejected.
        for row in candidate.profile.files where !builder.consumed.contains(row.path) {
            guard row.path.hasPrefix("rom/2d/"),row.path.hasSuffix(".farc") else{throw ModLoadError.unsupported}
        }
        let draft=RuntimeMod(format:"pjdv-runtime-song-v1",id:id,name:candidate.profile.name,notes:"",layers:["0"],baseChecks:[snapshot.base[0]],files:[],conversion:receipt)
        let worker=try ModComposition.Worker(packs:[.init(draft,builder.files)],base:base,dlc:dlc,output:stage.appendingPathComponent("0"),progress:progress)
        try fm.createDirectory(at:worker.output,withIntermediateDirectories:true);try worker.build();try PCModelConverter.check(progress)
        // Source hashes are verified by copy/source and the movie adapter. Check
        // all payloads again before the atomic installation publication.
        for row in candidate.profile.files {let h=try PCModelConverter.hash(candidate.root.appendingPathComponent(row.path),progress:progress);guard h.bytes==row.bytes,h.sha256==row.sha256 else{throw ModPackageError.changedSource}}
        for (root,rows) in [(base,snapshot.base),(dlc,snapshot.dlc)] {for row in rows {
            let h=try PCModelConverter.hash(root.appendingPathComponent(row.path),progress:progress)
            guard h.bytes==row.bytes,h.sha256==row.sha256 else{throw ModPackageError.changedSource}
        }}
        try fm.removeItem(at:input)
        let files=worker.records.sorted{$0.path<$1.path}.map{RuntimeMod.Check(path:"0/"+$0.path,bytes:$0.bytes,sha256:$0.sha256)}
        let item=RuntimeMod(format:draft.format,id:id,name:draft.name,notes:"",layers:["0"],baseChecks:draft.baseChecks,files:files,conversion:receipt)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];try encoder.encode(item).write(to:stage.appendingPathComponent("runtime.json"))
        guard let adopted=try catalog.adoptPrepared(from:stage,progress:progress) else{throw ModLoadError.invalid}
        report?(.init(phase:"MOD 已导入。",file:"",completed:1,total:1));return .init(item:adopted,reused:false)
    }
    static func safeAsset(_ path:String)->Bool {path.hasPrefix("rom/") && !path.contains("\\") && !path.contains(":") && path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy{!$0.isEmpty && !$0.hasPrefix(".")}}
    static func movieInput(_ declared:String,available:Set<String>)throws->String {
        guard safeAsset(declared),declared.hasPrefix("rom/movie/"),["usm","mp4"].contains((declared as NSString).pathExtension) else{throw ModLoadError.unsupported}
        if available.contains(declared){return declared}
        // Some exported PC packs already advertise MP4 but still ship the
        // same-named USM. Only this exact sibling is eligible for conversion;
        // the USM reader validates its actual channel and codec afterwards.
        let sibling=(declared as NSString).deletingPathExtension+".usm"
        guard declared.hasSuffix(".mp4"),available.contains(sibling) else{throw ModLoadError.invalid}
        return sibling
    }
    static func activeScripts(_ pv:Props,prefix:String)throws->Props {
        var result=Props()
        for difficulty in ["easy","normal","hard","extreme","encore"] {
            let stem=prefix+"difficulty."+difficulty+"."
            guard let count=Int(pv[stem+"length"] ?? "0"),(0...4).contains(count) else{throw ModLoadError.unsupported}
            for index in 0..<count {
                let key=stem+String(index)+".script_file_name"
                guard let path=pv[key],safeAsset(path) else{throw ModLoadError.invalid};result[key]=path
            }
        }
        return result
    }
    static func validateVideoChart(_ data:Data)throws {
        // Classic DSC command layouts: ReDIVA src/KKdLib/dsc.cpp, dsc_ac_func.
        // Movie-only imports do not enable stage scripts or New Classics targets.
        let lengths=[0:0,1:1,4:2,6:7,14:1,24:2,25:0,32:0,58:1,67:1,68:1]
        guard data.count>=8,data.count%4==0,[0x12020220,0x14050921].contains(try F.u(data,0)) else{throw ModLoadError.unsupported}
        var at=4,lastTime = -1,ended=false
        while at<data.count {
            let code=try F.u(data,at);guard let count=lengths[code],count<=(data.count-at-4)/4 else{throw ModLoadError.unsupported}
            func argument(_ n:Int)throws->Int {Int(Int32(bitPattern:UInt32(try F.u(data,at+4+n*4))))}
            if code==1 {let time=try argument(0);guard time>=lastTime,time<=360_000_000 else{throw ModLoadError.unsupported};lastTime=time}
            if code==6 {guard (0...23).contains(try argument(0)) else{throw ModLoadError.unsupported}}
            if code==14 {guard (0...1).contains(try argument(0)) else{throw ModLoadError.unsupported}}
            if code==4 {guard (0...5).contains(try argument(0)),try argument(1)==0 else{throw ModLoadError.unsupported}}
            at+=4+count*4
            if code==0 {ended=true;break}
        }
        guard ended,data[at...].allSatisfy({$0==0}) else{throw ModLoadError.unsupported}
    }
    static func relative(_ url:URL,base:URL,dlc:URL)throws->String {
        if url.path.hasPrefix(base.path+"/"){return String(url.path.dropFirst(base.path.count+1))}
        guard url.path.hasPrefix(dlc.path+"/") else{throw ModLoadError.invalid}
        let parts=url.path.dropFirst(dlc.path.count+1).split(separator:"/");guard parts.count>1 else{throw ModLoadError.invalid};return parts.dropFirst().joined(separator:"/")
    }
}
