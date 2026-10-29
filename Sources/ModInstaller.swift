import Foundation
import zlib

enum ModInstallError: LocalizedError {
    case unsupportedCompression, integrity, storage, tooLarge
    var errorDescription: String? {
        switch self {
        case .unsupportedCompression:return "此 MOD 压缩方式暂不支持，请先解压后导入文件夹。"
        case .integrity:return "MOD 文件内容校验失败，未完成安装。请重新下载。"
        case .storage:return "可用空间不足，MOD 安装已安全停止。"
        case .tooLarge:return "MOD 超过单包安装上限（32 GB），请分包导入。"
        }
    }
}
struct ModInstallUpdate {
    let phase:String
    let file:String
    let completed:UInt64
    let total:UInt64
}
struct InstalledMod {
    let root:URL
    let name:String
    let inspection:ModInspection
}
// One caller-owned serial worker; two 64 KiB payload buffers, bounded directory
// metadata, no whole-file/whole-archive decompression. Installed assets remain
// separate from GameResources. Importing never executes a DLL or game patch.
enum ModInstaller {
    static let maximumExpanded:UInt64=32*1024*1024*1024
    static let chunk=64*1024
    private static func components(_ path:String) throws -> [String] {
        let value=path.replacingOccurrences(of:"\\",with:"/").precomposedStringWithCanonicalMapping
        guard !value.hasPrefix("/"),!value.contains(":"),!value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw ModPackageError.unsafePath}
        let parts=value.split(separator:"/").map(String.init)
        guard !parts.isEmpty,parts.count<=64,!parts.contains(".."),!parts.contains(".") else {throw ModPackageError.unsafePath}
        return parts
    }
    private static func ignored(_ parts:[String])->Bool {parts.contains{$0=="__MACOSX" || $0.hasPrefix("._") || $0==".DS_Store"}}
    private static func checkSpace(_ root:URL,_ required:UInt64) throws {
        let a=try FileManager.default.attributesOfFileSystem(forPath:root.path)
        let available=(a[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard available>=required+64*1024*1024 else {throw ModInstallError.storage}
    }
    static func install(_ source:URL, under root:URL, progress:Progress,
                        report:@escaping(ModInstallUpdate)->Void) throws -> InstalledMod {
        let fm=FileManager.default
        let inspected=try ModPackageInspector.inspect(source,progress:progress)
        guard inspected.expandedBytes<=maximumExpanded else {throw ModInstallError.tooLarge}
        guard !inspected.unusualCompression else {throw ModInstallError.unsupportedCompression}
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        // Inspection rejects a selected symlink; normalize trusted ancestor
        // aliases before comparing enumerated paths or returning the copy.
        let source=source.standardizedFileURL.resolvingSymlinksInPath()
        let root=root.standardizedFileURL.resolvingSymlinksInPath()
        try checkSpace(root,inspected.expandedBytes)
        let id=UUID().uuidString
        let stage=root.appendingPathComponent(".staging-"+id,isDirectory:true)
        let final=root.appendingPathComponent(id,isDirectory:true)
        try fm.createDirectory(at:stage,withIntermediateDirectories:false)
        var committed=false
        defer {if !committed {try? fm.removeItem(at:stage)}}
        progress.totalUnitCount=Int64(max(1,inspected.expandedBytes))
        var done:UInt64=0,last=Date.distantPast
        func check() throws {if progress.isCancelled {throw ModPackageError.cancelled}}
        func update(_ file:String,_ bytes:Int) throws {
            try check();done+=UInt64(bytes)
            guard done<=inspected.expandedBytes else {throw ModInstallError.integrity}
            progress.completedUnitCount=Int64(done)
            if Date().timeIntervalSince(last)>0.2 {
                last=Date();report(ModInstallUpdate(phase:"解压／校验 MOD",file:file,completed:done,total:inspected.expandedBytes))
                try checkSpace(root,0)
            }
        }
        let attr=try fm.attributesOfItem(atPath:source.path)
        if attr[.type] as? FileAttributeType == .typeDirectory {
            guard let enumerator=fm.enumerator(at:source,includingPropertiesForKeys:nil) else {throw ModPackageError.unknownStructure}
            let prefix=source.standardizedFileURL.path+"/"
            for case let item as URL in enumerator {
                try check()
                try autoreleasepool {
                    guard item.standardizedFileURL.path.hasPrefix(prefix) else {throw ModPackageError.unsafePath}
                    let relative=String(item.standardizedFileURL.path.dropFirst(prefix.count)), parts=try components(relative)
                    if ignored(parts) {enumerator.skipDescendants();return}
                    let before=try fm.attributesOfItem(atPath:item.path),type=before[.type] as? FileAttributeType
                    let target=parts.reduce(stage){$0.appendingPathComponent($1)}
                    if type == .typeDirectory {try fm.createDirectory(at:target,withIntermediateDirectories:true);return}
                    guard type == .typeRegular else {throw ModPackageError.specialFile}
                    try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    guard fm.createFile(atPath:target.path,contents:nil) else {throw ModInstallError.storage}
                    let input=try FileHandle(forReadingFrom:item),output=try FileHandle(forWritingTo:target)
                    defer {try? input.close();try? output.close()}
                    while true {
                        let count=try autoreleasepool {()->Int in
                            try check();let b=try input.read(upToCount:chunk) ?? Data()
                            if !b.isEmpty {try output.write(contentsOf:b);try update(relative,b.count)}
                            return b.count
                        }
                        if count==0 {break}
                    }
                    try output.synchronize()
                    let after=try fm.attributesOfItem(atPath:item.path)
                    guard (before[.size] as? NSNumber)==(after[.size] as? NSNumber),
                          (before[.modificationDate] as? Date)==(after[.modificationDate] as? Date) else {throw ModPackageError.changedSource}
                }
            }
        } else {
            let (_,entries)=try ModPackageInspector.zipCatalog(source,progress:progress)
            let input=try FileHandle(forReadingFrom:source);defer {try? input.close()}
            let length=(attr[.size] as? NSNumber)?.uint64Value ?? 0
            func read(_ offset:UInt64,_ size:Int)throws->Data {
                try check();guard offset<=length,UInt64(size)<=length-offset else {throw ModPackageError.invalidZIP}
                try input.seek(toOffset:offset);let b=try input.read(upToCount:size) ?? Data()
                guard b.count==size else {throw ModPackageError.invalidZIP};return b
            }
            func number(_ b:Data,_ p:Int,_ n:Int)->UInt64 {(0..<n).reduce(0){$0 | UInt64(b[p+$1])<<($1*8)}}
            var ranges=[Range<UInt64>]()
            // Validate every local header before creating a payload file.
            var payloads=[UInt64]()
            for e in entries {
                let h=try read(e.localOffset,30)
                guard number(h,0,4)==0x04034b50,number(h,6,2)==e.flags,number(h,8,2)==e.method else {throw ModPackageError.invalidZIP}
                let nl=Int(number(h,26,2)),el=number(h,28,2)
                guard nl==e.rawName.count,try read(e.localOffset+30,nl)==e.rawName else {throw ModPackageError.invalidZIP}
                let payload=e.localOffset+30+UInt64(nl)+el
                guard payload<=e.directoryOffset,e.compressed<=e.directoryOffset-payload else {throw ModPackageError.invalidZIP}
                if e.flags & 8 == 0 {guard number(h,14,4)==e.crc else {throw ModPackageError.invalidZIP}}
                payloads.append(payload);ranges.append(e.localOffset..<(payload+e.compressed))
            }
            let sorted=ranges.sorted{$0.lowerBound<$1.lowerBound}
            for i in 1..<sorted.count {guard sorted[i-1].upperBound<=sorted[i].lowerBound else {throw ModPackageError.invalidZIP}}
            for (i,e) in entries.enumerated() {
                try check()
                try autoreleasepool {
                    let parts=try components(e.path);if ignored(parts) {return}
                    let target=parts.reduce(stage){$0.appendingPathComponent($1)}
                    if e.directory {try fm.createDirectory(at:target,withIntermediateDirectories:true);return}
                    try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    guard fm.createFile(atPath:target.path,contents:nil) else {throw ModInstallError.storage}
                    let output=try FileHandle(forWritingTo:target);defer{try? output.close()}
                    var count:UInt64=0,crc:uLong=0
                    func consume(_ p:UnsafeRawPointer,_ n:Int) throws {
                        guard UInt64(n)<=e.expanded-count else {throw ModInstallError.integrity}
                        try output.write(contentsOf:Data(bytes:p,count:n))
                        crc=crc32(crc,p.assumingMemoryBound(to:Bytef.self),uInt(n));count+=UInt64(n);try update(e.path,n)
                    }
                    var offset=payloads[i],left=e.compressed
                    if e.method==0 {
                        guard e.compressed==e.expanded else {throw ModInstallError.integrity}
                        while left>0 {try autoreleasepool {
                            let n=Int(min(UInt64(chunk),left)),b=try read(offset,n)
                            try b.withUnsafeBytes{try consume($0.baseAddress!,n)};left-=UInt64(n);offset+=UInt64(n)
                        }}
                    } else if e.method==8 {
                        var stream=z_stream()
                        guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw ModInstallError.integrity}
                        defer{inflateEnd(&stream)}
                        var out=[UInt8](repeating:0,count:chunk),ended=false
                        while left>0 && !ended {try autoreleasepool {
                            let n=Int(min(UInt64(chunk),left)),b=try read(offset,n);offset+=UInt64(n);left-=UInt64(n)
                            try b.withUnsafeBytes {raw in
                                stream.next_in=UnsafeMutablePointer(mutating:raw.baseAddress!.assumingMemoryBound(to:Bytef.self));stream.avail_in=uInt(n)
                                var needsInput=false
                                repeat {
                                    try check();let before=stream.avail_in
                                    try out.withUnsafeMutableBytes {dst in
                                        stream.next_out=dst.baseAddress!.assumingMemoryBound(to:Bytef.self);stream.avail_out=uInt(chunk)
                                        let result=inflate(&stream,Z_NO_FLUSH),produced=chunk-Int(stream.avail_out)
                                        // A full output block can drain the current input exactly.
                                        // zlib then requests the next compressed chunk with
                                        // Z_BUF_ERROR; it is not a corrupt payload or CRC failure.
                                        needsInput=result==Z_BUF_ERROR && before==0 && produced==0 && left>0
                                        guard result==Z_OK || result==Z_STREAM_END || needsInput else {throw ModInstallError.integrity}
                                        if produced>0 {try consume(dst.baseAddress!,produced)}
                                        if result==Z_STREAM_END {ended=true}
                                        guard ended || needsInput || produced>0 || stream.avail_in<before else {throw ModInstallError.integrity}
                                    }
                                } while !ended && !needsInput && (stream.avail_in>0 || stream.avail_out==0)
                            }
                        }}
                        guard ended,left==0,stream.avail_in==0 else {throw ModInstallError.integrity}
                    } else {throw ModInstallError.unsupportedCompression}
                    guard count==e.expanded,UInt32(truncatingIfNeeded:crc)==e.crc else {throw ModInstallError.integrity}
                    try output.synchronize()
                }
            }
            let after=try fm.attributesOfItem(atPath:source.path)
            guard (attr[.size] as? NSNumber)==(after[.size] as? NSNumber),
                  (attr[.modificationDate] as? Date)==(after[.modificationDate] as? Date) else {throw ModPackageError.changedSource}
        }
        try check();guard done==inspected.expandedBytes else {throw ModInstallError.integrity}
        let verified=try ModPackageInspector.inspect(stage,progress:progress)
        guard verified.fileCount==inspected.fileCount,verified.expandedBytes==inspected.expandedBytes else {throw ModInstallError.integrity}
        try fm.moveItem(at:stage,to:final);committed=true
        report(ModInstallUpdate(phase:"MOD 已导入",file:"",completed:done,total:done))
        let report=ModInspection(kind:verified.kind,fileCount:verified.fileCount,expandedBytes:verified.expandedBytes,declaredTitleIDs:verified.declaredTitleIDs,containsCode:verified.containsCode,containsDatabases:verified.containsDatabases,unusualCompression:false,contentIntegrityChecked:source.pathExtension.lowercased()=="zip")
        return InstalledMod(root:final,name:source.deletingPathExtension().lastPathComponent,inspection:report)
    }
}
