import Foundation
import CryptoKit
import zlib

enum ModLoadError: LocalizedError {
    case invalid, unsupported, conflict(String), limit, cancelled
    var errorDescription:String? {
        switch self {
        case .invalid:return "MOD 文件无法读取，请重新导入。"
        case .unsupported:return "此 MOD 的资源格式暂不支持加载。"
        case .conflict(let names):return "这些 MOD 不能同时加载："+names
        case .limit:return "此 MOD 组合超过当前加载上限，请减少启用数量。"
        case .cancelled:return "已取消加载。"
        }
    }
}

// Classic resource codecs used by the native composition worker. All offsets
// are checked before access; opaque media is never decoded by this worker.
enum ModFormats {
    static let fileLimit=64*1024*1024
    static func read(_ url:URL)throws->Data {
        let a=try FileManager.default.attributesOfItem(atPath:url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.size] as? NSNumber)?.intValue ?? Int.max <= fileLimit else {throw ModLoadError.limit}
        return try Data(contentsOf:url)
    }
    static func sha(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func span(_ b:Data,_ at:Int,_ n:Int)throws->Range<Int> {
        guard at>=0,n>=0,at<=b.count,n<=b.count-at else {throw ModLoadError.invalid};return at..<at+n
    }
    static func u(_ b:Data,_ at:Int,_ count:Int=4,_ big:Bool=false)throws->Int {
        _=try span(b,at,count);var v:UInt64=0
        for i in 0..<count {v |= UInt64(b[at+i]) << UInt64(8*(big ? count-1-i : i))}
        guard v<=UInt64(Int.max) else {throw ModLoadError.invalid};return Int(v)
    }
    static func put(_ b:inout Data,_ at:Int,_ value:Int,_ count:Int=4,_ big:Bool=false)throws {
        _=try span(b,at,count);guard value>=0,UInt64(value)<=(count==2 ? UInt64(UInt16.max):UInt64(UInt32.max)) else {throw ModLoadError.limit}
        for i in 0..<count {b[at+i]=UInt8(truncatingIfNeeded:value >> (8*(big ? count-1-i:i)))}
    }
    static func string(_ b:Data,_ at:Int)throws->String {
        if at==0{return ""};guard at>0,at<b.count else {throw ModLoadError.invalid}
        let endLimit=min(b.count,at+1024*1024)
        guard let end=b[at..<endLimit].firstIndex(of:0),let s=String(data:b[at..<end],encoding:.utf8) else {throw ModLoadError.invalid};return s
    }
    final class Writer {
        var data:Data;private var strings=[String:Int]()
        init(_ n:Int)throws {guard n>=0,n<=fileLimit else {throw ModLoadError.limit};data=Data(repeating:0,count:n)}
        func text(_ s:String)throws->Int {
            if s.isEmpty{return 0};if let p=strings[s]{return p}
            guard s.utf8.count<=1024*1024,data.count+s.utf8.count+1<=fileLimit else {throw ModLoadError.limit}
            let p=data.count;data.append(contentsOf:s.utf8);data.append(0);strings[s]=p;return p
        }
        func put(_ at:Int,_ values:Int...)throws {for (i,v) in values.enumerated(){try ModFormats.put(&data,at+i*4,v)}}
    }
    struct Named:Equatable {var id:Int;var name:String}
    struct ObjectSet:Equatable {var id:Int;var name:String;var file:String;var texture:String;var archive:String;var objects:[Named]}
    static func objects(_ b:Data)throws->[ObjectSet] {
        let n=try u(b,0),o=try u(b,8),m=try u(b,12),mo=try u(b,16)
        guard n<65536,m<=1000000 else {throw ModLoadError.limit};_=try span(b,o,n*36);_=try span(b,mo,m*8)
        var rows=[ObjectSet](),lookup=[Int:Int]()
        for i in 0..<n {
            let q=o+i*36,id=try u(b,q+4);guard lookup[id]==nil else {throw ModLoadError.invalid};lookup[id]=i
            rows.append(ObjectSet(id:id,name:try string(b,u(b,q)),file:try string(b,u(b,q+8)),texture:try string(b,u(b,q+12)),archive:try string(b,u(b,q+16)),objects:[]))
        }
        for i in 0..<m {
            let q=mo+i*8,sid=try u(b,q+2,2);guard let s=lookup[sid] else {throw ModLoadError.invalid}
            rows[s].objects.append(Named(id:try u(b,q,2),name:try string(b,u(b,q+4))))
        };return rows
    }
    static func objectData(_ rows:[ObjectSet])throws->Data {
        guard rows.count<65536 else {throw ModLoadError.limit}
        let mo=(32+rows.count*36+15)/16*16,m=rows.reduce(0){$0+$1.objects.count};let w=try Writer(mo+m*8)
        try w.put(0,rows.count,rows.map(\.id).max() ?? 0,32,m,mo);var j=0
        for (i,s) in rows.enumerated() {
            guard s.id<65536 else {throw ModLoadError.limit}
            try w.put(32+i*36,w.text(s.name),s.id,w.text(s.file),w.text(s.texture),w.text(s.archive),0,0,0,0)
            for v in s.objects {try put(&w.data,mo+j*8,v.id,2);try put(&w.data,mo+j*8+2,s.id,2);try w.put(mo+j*8+4,w.text(v.name));j+=1}
        };return w.data
    }
    static func textures(_ b:Data)throws->[Named] {
        let n=try u(b,0),o=try u(b,4);guard n<=1000000 else {throw ModLoadError.limit};_=try span(b,o,n*8)
        return try (0..<n).map{Named(id:try u(b,o+$0*8),name:try string(b,u(b,o+$0*8+4)))}
    }
    static func textureData(_ rows:[Named])throws->Data {
        let w=try Writer(16+rows.count*8);try w.put(0,rows.count,16)
        for (i,v) in rows.enumerated(){try w.put(16+i*8,v.id,w.text(v.name))};return w.data
    }
    struct Sprite:Equatable {var id:Int;var name:String;var index:Int;var texture:Bool}
    struct SpriteSet:Equatable {var id:Int;var name:String;var file:String;var members:[Sprite]}
    static func sprites(_ b:Data)throws->[SpriteSet] {
        let n=try u(b,0),so=try u(b,4),m=try u(b,8),mo=try u(b,12)
        guard n<4096,m<=1000000 else {throw ModLoadError.limit};_=try span(b,so,n*16);_=try span(b,mo,m*12)
        var rows=[SpriteSet]()
        for i in 0..<n {let q=so+i*16;guard try u(b,q+12)==i else {throw ModLoadError.invalid};rows.append(SpriteSet(id:try u(b,q),name:try string(b,u(b,q+4)),file:try string(b,u(b,q+8)),members:[]))}
        for i in 0..<m {
            let q=mo+i*12,info=try u(b,q+8),s=(info>>16)&0xfff;guard s<n else {throw ModLoadError.invalid}
            rows[s].members.append(Sprite(id:try u(b,q),name:try string(b,u(b,q+4)),index:info&65535,texture:info&0x10000000 != 0))
        };return rows
    }
    static func spriteData(_ rows:[SpriteSet])throws->Data {
        guard rows.count<4096 else {throw ModLoadError.limit};let mo=16+rows.count*16,m=rows.reduce(0){$0+$1.members.count};let w=try Writer(mo+m*12)
        try w.put(0,rows.count,16,m,mo);var j=0
        for (i,s) in rows.enumerated() {
            try w.put(16+i*16,s.id,w.text(s.name),w.text(s.file),i)
            for v in s.members {guard (0...65535).contains(v.index) else {throw ModLoadError.invalid};try w.put(mo+j*12,v.id,w.text(v.name),(i<<16)|v.index|(v.texture ? 0x10000000:0));j+=1}
        };return w.data
    }
    static func properties(_ b:Data)throws->[String:String] {
        guard let text=String(data:b,encoding:.utf8) else {throw ModLoadError.invalid};var values=[String:String]()
        for line in text.replacingOccurrences(of:"\u{feff}",with:"").split(whereSeparator:{$0=="\n" || $0=="\r"}) {
            if line.trimmingCharacters(in:.whitespaces).hasPrefix("#"){continue}
            guard let p=line.firstIndex(of:"=") else {continue};values[String(line[..<p])]=String(line[line.index(after:p)...])
            guard values.count<=500000 else {throw ModLoadError.limit}
        };return values
    }
    static func propertyData(_ values:[String:String],header:Bool=false)throws->Data {
        let s=(header ? "#A3DA__________\n":"")+values.keys.sorted().map{$0+"="+values[$0]!}.joined(separator:"\n")+"\n"
        guard s.utf8.count<=fileLimit else {throw ModLoadError.limit};return Data(s.utf8)
    }
    static func group(_ d:[String:String],_ prefix:String)->[[String:String]] {
        var out=[Int:[String:String]]();let stem=prefix+"."
        for (k,v) in d where k.hasPrefix(stem) {
            let tail=k.dropFirst(stem.count);guard let dot=tail.firstIndex(of:"."),let n=Int(tail[..<dot]),n>=0 else {continue}
            out[n,default:[:]][String(tail[tail.index(after:dot)...])]=v
        };return out.keys.sorted().map{out[$0]!}
    }
    static func setGroup(_ input:[String:String],_ prefix:String,_ rows:[[String:String]],countKey:String?=nil)->[String:String] {
        var d=input.filter{!$0.key.hasPrefix(prefix+".")}
        for (i,row) in rows.enumerated(){for (k,v) in row {d[prefix+".\(i)."+k]=v}}
        d[countKey ?? prefix+".length"]=String(rows.count);return d
    }
    static func strings(_ b:Data)throws->[String] {
        let end=try u(b,0);guard end%4==0,end<=b.count,end/4<=65536 else {throw ModLoadError.invalid}
        return try (0..<end/4).map{try string(b,u(b,$0*4))}
    }
    static func changeStrings(_ base:Data,_ changes:[Int:String])throws->Data {
        var b=base;let n=try u(b,0)/4
        for key in changes.keys.sorted() {
            // The first offset also encodes the original table size. Moving
            // it would make the game read appended strings as table entries.
            guard key != 0 else {throw ModLoadError.unsupported}
            guard (0..<n).contains(key),b.count+(changes[key]?.utf8.count ?? 0)+1<=fileLimit else {throw ModLoadError.limit}
            let pos=b.count;b.append(contentsOf:changes[key]!.utf8);b.append(0);try put(&b,key*4,pos)
        };return b
    }
    struct Block {var name:String;var data:Data}
    struct ArchiveEntry {let name:String;let offset:Int;let packed:Int;let expanded:Int;let compressed:Bool}
    static func archiveIndex(_ b:Data)throws->[ArchiveEntry] {
        guard b.count>=12,b.count<=fileLimit else {throw ModLoadError.limit}
        let sig=String(decoding:b.prefix(4),as:UTF8.self);guard sig=="FArC" || sig=="FArc" else {throw ModLoadError.unsupported}
        let end=try u(b,4,4,true)+8;guard end>=12,end<=min(b.count,16*1024*1024) else {throw ModLoadError.invalid}
        var rows=[ArchiveEntry](),at=12,total=0,names=Set<String>()
        while at<end {
            guard let zero=b[at..<end].firstIndex(of:0),let name=String(data:b[at..<zero],encoding:.utf8) else {throw ModLoadError.invalid}
            if name.isEmpty{break};guard names.insert(name).inserted,rows.count<100000 else {throw ModLoadError.invalid}
            let off=try u(b,zero+1,4,true),packed=try u(b,zero+5,4,true),size=sig=="FArC" ? try u(b,zero+9,4,true):0
            let expanded=size>0 ? size:packed
            guard expanded<=256*1024*1024,total<=384*1024*1024-expanded,off>=end else {throw ModLoadError.limit}
            _=try span(b,off,packed);total+=expanded
            rows.append(.init(name:name,offset:off,packed:packed,expanded:expanded,compressed:size>0));at=zero+1+(sig=="FArC" ? 12:8)
        };return rows
    }
    static func archiveEntry(_ b:Data,_ row:ArchiveEntry)throws->Data {
        guard row.expanded<=fileLimit else {throw ModLoadError.limit}
        let region=try span(b,row.offset,row.packed)
        if !row.compressed{return b.subdata(in:region)}
        let capacity=max(1,row.expanded);var out=[UInt8](repeating:0,count:capacity),stream=z_stream()
        guard inflateInit2_(&stream,31,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw ModLoadError.invalid};defer{inflateEnd(&stream)}
        let result=b.withUnsafeBytes{src in out.withUnsafeMutableBytes{dst in
            stream.next_in=UnsafeMutablePointer(mutating:src.baseAddress!.advanced(by:region.lowerBound).assumingMemoryBound(to:Bytef.self));stream.avail_in=uInt(row.packed)
            stream.next_out=dst.baseAddress!.assumingMemoryBound(to:Bytef.self);stream.avail_out=uInt(capacity);return inflate(&stream,Z_FINISH)
        }}
        guard result==Z_STREAM_END,Int(stream.total_out)==row.expanded else {throw ModLoadError.invalid};return Data(out.prefix(row.expanded))
    }
    static func gzip(_ b:Data)throws->Data {
        guard b.count<=fileLimit else {throw ModLoadError.limit};var stream=z_stream()
        guard deflateInit2_(&stream,6,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw ModLoadError.invalid};defer{deflateEnd(&stream)}
        let capacity=Int(deflateBound(&stream,uLong(b.count)));guard capacity<=fileLimit else {throw ModLoadError.limit}
        var out=[UInt8](repeating:0,count:capacity)
        let result=b.withUnsafeBytes{src in out.withUnsafeMutableBytes{dst in
            stream.next_in=src.baseAddress.map{UnsafeMutablePointer(mutating:$0.assumingMemoryBound(to:Bytef.self))};stream.avail_in=uInt(b.count)
            stream.next_out=dst.baseAddress!.assumingMemoryBound(to:Bytef.self);stream.avail_out=uInt(capacity);return deflate(&stream,Z_FINISH)
        }}
        guard result==Z_STREAM_END else {throw ModLoadError.invalid};return Data(out.prefix(Int(stream.total_out)))
    }
    // Re-encode only edited object entries. Texture gzip blocks stay byte-for-
    // byte intact, even when their decoded size is hundreds of megabytes.
    static func rewriteArchive(_ b:Data,rename:(String)->String,edit:(String,Data)throws->Data?)throws->Data {
        let entries=try archiveIndex(b);var chunks=[(String,Data,Int)]()
        for row in entries {
            if row.name.hasSuffix("_obj.bin"),let changed=try edit(row.name,archiveEntry(b,row)) {
                chunks.append((rename(row.name),try gzip(changed),changed.count))
            } else {chunks.append((rename(row.name),b.subdata(in:try span(b,row.offset,row.packed)),row.compressed ? row.expanded:0))}
        }
        let length=12+chunks.reduce(0){$0+$1.0.utf8.count+1+12};var head=Data("FArC".utf8);head.append(Data(repeating:0,count:8))
        try put(&head,4,length-8,4,true);try put(&head,8,16,4,true);var body=Data(),offset=(length+15)/16*16
        for (name,encoded,expanded) in chunks {
            guard !name.isEmpty,!name.contains("\0"),offset+encoded.count<=fileLimit else {throw ModLoadError.limit}
            head.append(contentsOf:name.utf8);head.append(0);let p=head.count;head.append(Data(repeating:0,count:12))
            try put(&head,p,offset,4,true);try put(&head,p+4,encoded.count,4,true);try put(&head,p+8,expanded,4,true)
            body.append(encoded);let pad=(-(offset+encoded.count))&15;body.append(Data(repeating:0,count:pad));offset+=encoded.count+pad
        }
        head.append(Data(repeating:0,count:(length+15)/16*16-head.count));head.append(body);return head
    }
    static func archive(_ b:Data)throws->[Block] {
        guard b.count>=12 else {throw ModLoadError.invalid};let sig=String(decoding:b.prefix(4),as:UTF8.self)
        guard sig=="FArC" || sig=="FArc" else {throw ModLoadError.unsupported}
        let end=try u(b,4,4,true)+8;guard end>=12,end<=min(b.count,16*1024*1024) else {throw ModLoadError.invalid}
        var at=12,out=[Block](),total=0
        while at<end {
            guard let z=b[at..<end].firstIndex(of:0),let name=String(data:b[at..<z],encoding:.utf8) else {throw ModLoadError.invalid}
            if name.isEmpty{break};guard out.count<100000 else {throw ModLoadError.limit}
            let off=try u(b,z+1,4,true),packed=try u(b,z+5,4,true),declared=sig=="FArC" ? try u(b,z+9,4,true):0
            let n=declared>0 ? declared:packed;guard n<=fileLimit,total<=128*1024*1024-n else {throw ModLoadError.limit};total+=n
            let region=try span(b,off,packed);at=z+1+(sig=="FArC" ? 12:8)
            var raw:Data
            if declared>0 {
                let capacity=max(1,n);var target=[UInt8](repeating:0,count:capacity),stream=z_stream()
                guard inflateInit2_(&stream,31,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw ModLoadError.invalid};defer{inflateEnd(&stream)}
                let status=b.withUnsafeBytes{src in target.withUnsafeMutableBytes{dst in
                    stream.next_in=UnsafeMutablePointer(mutating:src.baseAddress!.advanced(by:region.lowerBound).assumingMemoryBound(to:Bytef.self));stream.avail_in=uInt(packed)
                    stream.next_out=dst.baseAddress!.assumingMemoryBound(to:Bytef.self);stream.avail_out=uInt(capacity)
                    return inflate(&stream,Z_FINISH)
                }}
                guard status==Z_STREAM_END,Int(stream.total_out)==n else {throw ModLoadError.invalid};raw=Data(target.prefix(n))
            } else {raw=b.subdata(in:region)}
            guard !out.contains(where:{$0.name==name}) else {throw ModLoadError.invalid};out.append(Block(name:name,data:raw))
        };return out
    }
    static func archiveData(_ rows:[Block])throws->Data {
        let hlen=12+rows.reduce(0){$0+$1.name.utf8.count+1+8};var header=Data("FArc".utf8);header.append(Data(repeating:0,count:8))
        try put(&header,4,hlen-8,4,true);try put(&header,8,16,4,true);var body=Data(),offset=(hlen+15)/16*16
        for row in rows {
            guard !row.name.isEmpty,!row.name.contains("\0"),offset+row.data.count<=128*1024*1024 else {throw ModLoadError.limit}
            header.append(contentsOf:row.name.utf8);header.append(0);let p=header.count;header.append(Data(repeating:0,count:8))
            try put(&header,p,offset,4,true);try put(&header,p+4,row.data.count,4,true)
            body.append(row.data);let pad=(-(offset+row.data.count))&15;body.append(Data(repeating:0,count:pad));offset+=row.data.count+pad
        }
        header.append(Data(repeating:0,count:(hlen+15)/16*16-header.count));header.append(body);return header
    }
}
