import Foundation
import CryptoKit
import Darwin

struct ImportCatalog: Decodable {
    struct DLC: Codable { let index:Int;let title_id:String;let nca:String }
    let contents:[DLC]
}
private struct PreparedMarker: Codable, Equatable {
    let format:String, index_sha256:String
    let romfs_bytes:Int
}
private struct PreparedFile: Codable { let path:String;let bytes:Int;let sha256:String }
struct ImportSnapshot { let completed:Int;let total:Int;let message:String }
private func importCheck(_ test:Bool,_ message:String) throws {if !test {throw ImportFailure.invalid(message)}}
private func jsonData<T:Encodable>(_ value:T) throws -> Data {try JSONEncoder().encode(value)}
private func jsonString(_ value:String) throws -> Data {
    let bytes=try JSONSerialization.data(withJSONObject:[value],options:[.withoutEscapingSlashes])
    return bytes.subdata(in:1..<bytes.count-1)
}
private func fingerprint(_ entries:[RomEntry]) throws -> String {
    var hash=SHA256();hash.update(data:Data("[".utf8))
    for (i,row) in entries.enumerated() {
        if i != 0 {hash.update(data:Data(",".utf8))}
        hash.update(data:Data("{\"path\":".utf8));hash.update(data:try jsonString(row.path))
        hash.update(data:Data(",\"offset\":\(row.offset),\"bytes\":\(row.bytes)}".utf8))
    }
    hash.update(data:Data("]".utf8));return hash.finalize().map{String(format:"%02x",$0)}.joined()
}
final class XCIImportPlan {
    struct Volume { let relative:String;let rom:XCIRomFS;let fingerprint:String;let dlc:ImportCatalog.DLC? }
    let file:XCIFile,volumes:[Volume],totalBytes:Int
    let content:GameContentInfo
    init(xci:URL,keys:URL,catalog:URL?=nil,checkCancelled:()->Bool={false},contentNames:Set<String>?=nil,io:ImportIOMeter?=nil,report:(String)->Void={_ in}) throws {
        report("正在读取 XCI 目录…")
        let file=try XCIFile(url:xci,io:io),keys=try XCIKeys(url:keys),allEntries=try xciSecureEntries(file)
        // Internal content-subset selection supports bounded package tests and
        // base-only regression without ever rewriting a user's source XCI.
        if let contentNames {try importCheck(contentNames.isSubset(of:Set(allEntries.map(\.name))),"所选内容不在原始 XCI 中")}
        let entries=allEntries.filter{contentNames?.contains($0.name) ?? true}
        var archives=[NCAArchive]()
        let ncas=entries.filter{$0.name.lowercased().hasSuffix(".nca")}
        for (index,entry) in ncas.enumerated() {
            if checkCancelled(){throw ImportFailure.cancelled}
            report("正在识别 NCA 内容…\n\(index+1) / \(ncas.count)")
            archives.append(try NCAArchive(file:file,entry:entry,keys:keys))
        }
        let app=Mega39Content.applicationID
        func related(_ archive:NCAArchive)->Bool {
            guard let id=UInt64(archive.title,radix:16) else{return false}
            return id==app || id==app+0x800 || Mega39Content.dlcIndex(id) != nil
        }
        let game=archives.filter(related)
        try importCheck(!game.isEmpty,"XCI 中未找到 MEGA39’s（Title ID 0100F3100DA46000）。其他地区的独立游戏代码尚需适配。")
        var metas=[XCIContentMeta]()
        report("正在读取版本与 DLC 元数据…")
        for archive in game where archive.contentType==1 {
            if checkCancelled(){throw ImportFailure.cancelled}
            metas += try contentMeta(archive)
        }
        metas=metas.filter{$0.application==app}
        func latest(_ rows:[XCIContentMeta]) throws -> XCIContentMeta? {
            guard let version=rows.map(\.version).max() else{return nil}
            let best=rows.filter{$0.version==version}
            try importCheck(Set(best.map{$0.contents.map(\.id).joined(separator:":")}).count==1,"同一版本含冲突的内容元数据，无法安全选择")
            return best.first
        }
        func referenced(_ meta:XCIContentMeta,_ type:Int) throws -> NCAArchive {
            let rows=meta.contents.filter{$0.type==type && $0.idOffset==0}
            try importCheck(rows.count==1,"游戏内容元数据缺少唯一的主资源")
            let row=rows[0]
            let matches=game.filter{$0.entry.name.lowercased()==row.id+".nca"}
            if matches.count==1 && matches[0].entry.size==row.bytes {return matches[0]}
            // A repacker may rename NCA files. Resolve such entries by the
            // CNMT content hash instead of trusting a coincidental file size.
            let kind = type==1 ? 0 : type==2 ? 4 : 2
            let title = type==2 ? meta.title : meta.application
            var found:NCAArchive?
            for candidate in game where candidate.entry.size==row.bytes && candidate.title==Mega39Content.title(title) && (candidate.contentType==kind || (type==2 && candidate.contentType==5)) {
                var hash=SHA256(),at=0,lastReport=Date.distantPast
                while at<candidate.entry.size {
                    if checkCancelled(){throw ImportFailure.cancelled}
                    let n=min(4*1024*1024,candidate.entry.size-at)
                    hash.update(data:try file.read(candidate.entry.offset+at,n));at+=n
                    if Date().timeIntervalSince(lastReport)>0.25 || at==candidate.entry.size {
                        report("正在校验重命名的 NCA 内容…\n"+ByteCountFormatter.string(fromByteCount:Int64(at),countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:Int64(candidate.entry.size),countStyle:.file))
                        lastReport=Date()
                    }
                }
                if hash.finalize().map({String(format:"%02x",$0)}).joined()==row.sha256 {
                    try importCheck(found==nil,"CNMT 对应多个重复资源，无法安全选择");found=candidate
                }
            }
            guard let found else {throw ImportFailure.invalid("XCI 缺少所选版本必需的内容："+row.id)}
            return found
        }
        func romSection(_ archive:NCAArchive) throws -> NCASection {
            let rows=archive.sections.filter{$0.partition==0}
            try importCheck(rows.count==1,"NCA 没有唯一 RomFS 分区");return rows[0]
        }
        func unique(_ rows:[NCAArchive],_ message:String) throws -> NCAArchive? {
            try importCheck(rows.count<=1,message);return rows.first
        }
        let application=try latest(metas.filter{$0.type==0x80 && $0.title==app})
        let patch=try latest(metas.filter{$0.type==0x81 && $0.title==app+0x800})
        let programs=game.filter{$0.contentType==0 && $0.title==Mega39Content.title(app) && $0.sections.contains{$0.partition==0}}
        let base: NCAArchive?
        if let application {base=try referenced(application,1)} else {
            base=try unique(programs.filter{a in a.sections.contains{$0.partition==0 && $0.crypto != 4}},"多个基础资源缺少可判定版本的 CNMT")
        }
        let update: NCAArchive?
        if let patch {update=try referenced(patch,1)} else {
            update=try unique(programs.filter{a in a.sections.contains{$0.partition==0 && $0.crypto==4}},"多个更新资源缺少可判定版本的 CNMT")
        }
        guard let selected=update ?? base else {throw ImportFailure.invalid("XCI 缺少可用的 MEGA39’s 基础资源")}
        try importCheck(selected.contentType==0 && selected.title==Mega39Content.title(app),"程序内容与 MEGA39’s 不匹配")
        let selectedSection=try romSection(selected),reader:XCIReadable
        if selectedSection.crypto==4 {
            guard let base else{throw ImportFailure.invalid("这个 XCI 只有增量更新，缺少合并更新所需的基础资源")}
            reader=try NCAPatch(selected,selectedSection,NCAPlain(base,romSection(base)))
        } else {reader=try NCAPlain(selected,selectedSection)}
        report("正在读取基础资源文件表…")
        let rom=try XCIRomFS(IVFCReader(selectedSection,reader)),identity=try fingerprint(rom.entries)
        let files=Set(rom.entries.filter{$0.bytes>0}.map(\.path))
        try importCheck(files.contains("rom_switch/rom/pv_db.txt") && files.contains("rom_switch/rom/gm_module_tbl.farc"),"游戏资源缺少 MEGA39’s 曲库或服装数据库")
        let languages=ResourceLanguageProbe.detect{files.contains($0)}
        try importCheck(languages.contains("ja"),"资源缺少完整日语菜单，无法使用当前 MEGA39’s 运行程序安全回落")
        var volumes=[Volume(relative:"romfs",rom:rom,fingerprint:identity,dlc:nil)]
        let dlcCandidates=game.filter{a in
            (a.contentType==4 || a.contentType==5) && UInt64(a.title,radix:16).flatMap(Mega39Content.dlcIndex) != nil && a.sections.contains{$0.partition==0}
        }
        let ids=Set(dlcCandidates.compactMap{UInt64($0.title,radix:16)}).union(metas.filter{$0.type==0x82}.map(\.title))
        for (number,id) in ids.sorted().enumerated() {
            if checkCancelled(){throw ImportFailure.cancelled}
            report("正在读取 DLC 资源文件表…\n\(number+1) / \(ids.count)")
            guard let index=Mega39Content.dlcIndex(id) else{continue}
            let archive:NCAArchive
            if let meta=try latest(metas.filter{$0.type==0x82 && $0.title==id}) {archive=try referenced(meta,2)} else {
                guard let found=try unique(dlcCandidates.filter{$0.title==Mega39Content.title(id)},"DLC 多个版本缺少内容元数据") else{continue};archive=found
            }
            try importCheck((archive.contentType==4 || archive.contentType==5) && archive.title==Mega39Content.title(id),"DLC 内容所属游戏不匹配")
            let section=try romSection(archive),dlc=try XCIRomFS(IVFCReader(section,NCAPlain(archive,section)))
            try importCheck(!dlc.entries.isEmpty,"DLC 资源为空")
            let row=ImportCatalog.DLC(index:index,title_id:Mega39Content.title(id),nca:archive.entry.name)
            volumes.append(Volume(relative:"DLC/\(index)",rom:dlc,fingerprint:try fingerprint(dlc.entries),dlc:row))
        }
        try importCheck(volumes.count<=257,"此包 DLC 数量超出运行程序的安全上限")
        var displayVersion:String?,buildID:String?
        let chosen=patch ?? application
        if let meta=chosen,meta.contents.contains(where:{$0.type==3 && $0.idOffset==0}) {
            let control=try referenced(meta,3),section=try romSection(control)
            let controlRom=try XCIRomFS(IVFCReader(section,NCAPlain(control,section)))
            if let nacp=controlRom.entries.first(where:{$0.path=="control.nacp"}),nacp.bytes>=0x3070 {
                let bytes=try controlRom.reader.read(nacp.offset+0x3060,16)
                displayVersion=String(data:bytes.prefix{ $0 != 0 },encoding:.utf8)
            }
            controlRom.reader.trimCache()
        }
        if let section=selected.sections.first(where:{$0.partition==1 && $0.crypto != 4}) {
            let exefs=try NCAHashedPFS(selected,section)
            if let main=try pfsEntries(exefs).first(where:{$0.name=="main"}),main.bytes>=0x60 {
                let header=try exefs.read(main.offset,0x60)
                if header.prefix(4)==Data("NSO0".utf8) {buildID=header.subdata(in:0x40..<0x60).map{String(format:"%02x",$0)}.joined()}
            }
        }
        self.content=GameContentInfo(format:"pjdv-game-content-v1",application_id:Mega39Content.title(app),content_version:chosen?.version,display_version:displayVersion,source_program_build_id:buildID,index_sha256:identity,dlc_indexes:volumes.compactMap{$0.dlc?.index},languages:languages,runtime_profile:Mega39Content.runtimeProfile)
        var total=0
        for v in volumes {for f in v.rom.entries {let(n,overflow)=total.addingReportingOverflow(f.bytes);try importCheck(!overflow,"资源总量溢出");total=n}}
        for v in volumes {v.rom.reader.trimCache()}
        self.file=file;self.volumes=volumes;totalBytes=total
        report("资源预检完成，正在检查保存位置…")
    }
    func data(volume:Int,entry:RomEntry,offset:Int,count:Int) throws -> Data {
        try importCheck(offset>=0 && count>=0 && offset<=entry.bytes && count<=entry.bytes-offset,"文件读取范围无效")
        return try volumes[volume].rom.reader.read(entry.offset+offset,count)
    }
}
final class XCIResourceImporter {
    private let plan:XCIImportPlan,root:URL,cancel:()->Bool,report:(ImportSnapshot)->Void
    private var completed=0,lastReport=Date.distantPast
    init(plan:XCIImportPlan,root:URL,cancel:@escaping()->Bool,report:@escaping(ImportSnapshot)->Void) {
        self.plan=plan;self.root=root;self.cancel=cancel;self.report=report
    }
    private func update(_ message:String,force:Bool=false) throws {
        if cancel(){throw ImportFailure.cancelled}
        if force || Date().timeIntervalSince(lastReport)>0.15 {report(ImportSnapshot(completed:completed,total:plan.totalBytes,message:message));lastReport=Date()}
    }
    private func regular(_ url:URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let a=try FileManager.default.attributesOfItem(atPath:url.path)
        try importCheck(a[.type] as? FileAttributeType == .typeRegular,"目标路径不是普通文件；保留原文件：\(url.lastPathComponent)")
        return (a[.size] as? NSNumber)?.intValue
    }
    private func sha(_ url:URL) throws -> String {
        let f=try FileHandle(forReadingFrom:url);defer{try?f.close()};var hash=SHA256()
        while let b=try f.read(upToCount:1024*1024),!b.isEmpty {plan.file.io?.didRead(b.count);hash.update(data:b);try update("校验已有资源："+url.lastPathComponent)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private func target(_ volume:XCIImportPlan.Volume) -> URL {
        if volume.dlc==nil && FileManager.default.fileExists(atPath:root.appendingPathComponent("MEGA39-v1.0.9/preparation.json").path) {
            return root.appendingPathComponent("MEGA39-v1.0.9",isDirectory:true)
        }
        return root.appendingPathComponent(volume.relative,isDirectory:true)
    }
    private func marker(_ v:XCIImportPlan.Volume) -> PreparedMarker {
        PreparedMarker(format:"pjdv-prepared-romfs-v1",index_sha256:v.fingerprint,romfs_bytes:v.rom.reader.size)
    }
    private func knownFiles(_ dir:URL) throws -> [String:PreparedFile] {
        let p=dir.appendingPathComponent("files.jsonl");guard FileManager.default.fileExists(atPath:p.path) else{return [:]}
        try importCheck((try regular(p) ?? 0)<64*1024*1024,"旧资源清单过大")
        let text=try String(contentsOf:p,encoding:.utf8);var rows=[String:PreparedFile]()
        for line in text.split(separator:"\n") {
            let row=try JSONDecoder().decode(PreparedFile.self,from:Data(line.utf8));rows[row.path]=row
        };return rows
    }
    func run() throws {
        let fm=FileManager.default
        try update("正在检查保存位置与已有资源…",force:true)
        // Preflight all identities before touching any old payload or metadata.
        var missing=0
        for v in plan.volumes {
            let dir=target(v),p=dir.appendingPathComponent("preparation.json")
            if fm.fileExists(atPath:dir.path) {
                try importCheck(fm.fileExists(atPath:p.path),"目标文件夹不是本导入器的资源目录；请选择新的空目录，原文件已保留")
                let old=try JSONDecoder().decode(PreparedMarker.self,from:Data(contentsOf:p))
                try importCheck(old==marker(v),"已有资源属于其他版本，不能覆盖")
            }
            for f in v.rom.entries {
                let url=dir.appendingPathComponent(f.path)
                let canonical=url.resolvingSymlinksInPath().path
                try importCheck(canonical.hasPrefix(dir.resolvingSymlinksInPath().path+"/"),"目标资源路径指向目录外部")
                if let size=try regular(url) {try importCheck(size==f.bytes,"已有文件大小不同，保留原文件："+f.path)}else{
                    let(n,overflow)=missing.addingReportingOverflow(f.bytes);try importCheck(!overflow,"资源大小溢出");missing=n
                }
            }
        }
        var parent=root
        while !fm.fileExists(atPath:parent.path) && parent.path != "/" {parent.deleteLastPathComponent()}
        try importCheck(missing<=Int.max-512*1024*1024,"资源大小超出导入范围")
        let space=try fm.attributesOfFileSystem(forPath:parent.path)[.systemFreeSize] as? NSNumber
        try importCheck((space?.int64Value ?? 0)>=Int64(missing)+512*1024*1024,"空间不足：还需约 \(ByteCountFormatter.string(fromByteCount:Int64(missing)+512*1024*1024,countStyle:.file))。XCI 不会被复制。")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let lockURL=root.appendingPathComponent(".pjdv-import.lock")
        let lockFD=Darwin.open(lockURL.path,O_RDWR|O_CREAT|O_NOFOLLOW,0o600)
        try importCheck(lockFD>=0,"无法锁定目标资源目录；请选择可写的位置")
        defer {Darwin.close(lockFD)}
        try importCheck(flock(lockFD,LOCK_EX|LOCK_NB)==0,"此资源目录正在被另一个导入任务使用")
        defer {flock(lockFD,LOCK_UN)}
        let pending=root.appendingPathComponent(".pjdv-import-in-progress")
        let pendingData=Data("pjdv-import-session-v1".utf8)
        if fm.fileExists(atPath:pending.path) {try importCheck(try Data(contentsOf:pending)==pendingData,"目标目录含未知导入标记，原文件已保留")}
        else if missing>0 {try pendingData.write(to:pending,options:.withoutOverwriting)}
        for v in plan.volumes {
            try update(v.dlc==nil ? "游戏资源（自动选择包内更新）":"DLC \(v.dlc!.index)",force:true)
            let dir=target(v);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            let markerURL=dir.appendingPathComponent("preparation.json")
            if !fm.fileExists(atPath:markerURL.path) {try jsonData(marker(v)).write(to:markerURL,options:.withoutOverwriting)}
            var known=try knownFiles(dir)
            let journalURL=dir.appendingPathComponent("files.jsonl")
            if !fm.fileExists(atPath:journalURL.path) {try Data().write(to:journalURL,options:.withoutOverwriting)}
            let journal=try FileHandle(forWritingTo:journalURL);defer{try?journal.close()};try journal.seekToEnd()
            for f in v.rom.entries.sorted(by:{$0.offset<$1.offset}) {
                try update("导入："+f.path)
                let dest=dir.appendingPathComponent(f.path)
                if fm.fileExists(atPath:dest.path) {
                    let existing=try sha(dest)
                    if let row=known[f.path] {
                        try importCheck(row.bytes==f.bytes && row.sha256==existing,"已有资源 SHA-256 不同，保留原文件："+f.path)
                    } else {
                        var hash=SHA256(),at=0
                        while at<f.bytes {let n=min(1024*1024,f.bytes-at);hash.update(data:try v.rom.reader.read(f.offset+at,n));at+=n;try update("校验未完成记录："+f.path)}
                        try importCheck(existing==hash.finalize().map{String(format:"%02x",$0)}.joined(),"已有未记录文件与 XCI 不同，保留原文件："+f.path)
                        let row=PreparedFile(path:f.path,bytes:f.bytes,sha256:existing);known[f.path]=row
                        try journal.write(contentsOf:jsonData(row)+Data([10]));try journal.synchronize()
                    }
                    completed+=f.bytes;continue
                }
                try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
                let temp=dest.deletingLastPathComponent().appendingPathComponent(".pjdv-import-"+UUID().uuidString)
                try Data().write(to:temp,options:.withoutOverwriting)
                do {
                    let out=try FileHandle(forWritingTo:temp);var hash=SHA256(),at=0
                    do {
                        while at<f.bytes {
                            let n=min(1024*1024,f.bytes-at),b=try v.rom.reader.read(f.offset+at,n)
                            try out.write(contentsOf:b);plan.file.io?.didWrite(b.count);hash.update(data:b);at+=n;completed+=n;try update("导入："+f.path)
                        }
                        try out.synchronize();try out.close()
                    } catch {try?out.close();throw error}
                    try fm.moveItem(at:temp,to:dest) // refuses to replace an existing destination
                    let row=PreparedFile(path:f.path,bytes:f.bytes,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
                    known[f.path]=row;try journal.write(contentsOf:jsonData(row)+Data([10]));try journal.synchronize()
                } catch {
                    // Only this invocation's UUID temp may be removed; source / prior files are untouched.
                    try?fm.removeItem(at:temp);throw error
                }
            }
            let complete:[String:Any]=["format":"pjdv-prepared-romfs-v1","file_count":v.rom.entries.count,"file_bytes":v.rom.entries.reduce(0){$0+$1.bytes},"index_sha256":v.fingerprint,"file_payload_integrity":"all_file_bytes_checked_through_IVFC","whole_virtual_image":"metadata_and_file_payloads; unused padding not fully traversed"]
            try JSONSerialization.data(withJSONObject:complete,options:[.sortedKeys]).write(to:dir.appendingPathComponent("complete.json"),options:.atomic)
            v.rom.reader.trimCache()
        }
        let dlc=plan.volumes.compactMap(\.dlc)
        let manifest:[String:Any]=["format":"pjdv-dlc-local-v1","contents":try JSONSerialization.jsonObject(with:jsonData(dlc))]
        try fm.createDirectory(at:root.appendingPathComponent("DLC"),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:root.appendingPathComponent("DLC/manifest.json"),options:.atomic)
        try jsonData(plan.content).write(to:root.appendingPathComponent("game-content.json"),options:.atomic)
        if fm.fileExists(atPath:pending.path) {try fm.removeItem(at:pending)}
        try update("导入完成：游戏资源与 \(dlc.count) 个包内 DLC",force:true)
    }
}
