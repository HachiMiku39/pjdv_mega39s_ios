import Foundation
import CommonCrypto
import CryptoKit

// Bounded, streaming reader. Content selection is based on NCA/CNMT metadata,
// never a download filename, fixed content ID, or expected DLC count.
// XCI/HFS0, NCA3, BKTR and IVFC layouts follow the local Python reference tools.
// No original executable or key is emitted by the resource extractor.
enum ImportFailure: LocalizedError {
    case invalid(String), cancelled
    var errorDescription: String? {
        switch self { case .invalid(let text): return text; case .cancelled: return "已取消；已完成的资源保留，可再次选择同一 XCI 继续。" }
    }
}
private let tableLimit = 8 * 1024 * 1024
private func require(_ test: Bool, _ message: String) throws { if !test { throw ImportFailure.invalid(message) } }
private func add(_ a: Int, _ b: Int) throws -> Int {
    try require(a >= 0 && b >= 0 && a <= Int.max - b, "资源范围溢出")
    return a + b
}
private func bounded(_ offset: Int, _ length: Int, _ size: Int) throws {
    try require(offset >= 0 && length >= 0 && offset <= size && length <= size - offset, "资源范围越界或文件已截断")
}
extension Data {
    fileprivate func number(_ at: Int, _ width: Int) throws -> Int {
        try bounded(at, width, count)
        var value: UInt64 = 0
        for i in 0..<width { value |= UInt64(self[at+i]) << (i*8) }
        try require(value <= UInt64(Int.max), "资源整数超出范围")
        return Int(value)
    }
    fileprivate func slice(_ offset: Int, _ length: Int) throws -> Data {
        try bounded(offset, length, count); return subdata(in: offset..<offset+length)
    }
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
private func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
private func aes(_ data: Data, key: Data, encrypt: Bool = false, iv: Data? = nil) throws -> Data {
    try require(key.count == 16, "prod.keys 中所需 AES 密钥长度不正确")
    var context: CCCryptorRef?
    let status = key.withUnsafeBytes { k in
        if let iv { return iv.withUnsafeBytes { v in CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, 16, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &context) } }
        return CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeECB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), nil, k.baseAddress, 16, nil, 0, 0, 0, &context)
    }
    try require(status == kCCSuccess && context != nil, "无法创建本地 AES 解密器")
    defer { CCCryptorRelease(context) }
    var output = Data(count: data.count + 16); var used = 0
    let result = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in CCCryptorUpdate(context, input.baseAddress, data.count, out.baseAddress, out.count, &used) } }
    try require(result == kCCSuccess && used == data.count, "本地 AES 解密失败")
    output.count = used; return output
}
private func xtsHeader(_ raw: Data, _ key: Data) throws -> Data {
    try require(raw.count == 0xc00 && key.count == 32, "缺少可用的 header_key")
    var output = Data(capacity: raw.count)
    for sector in 0..<6 {
        var iv = Data(repeating: 0, count: 16); iv[15] = UInt8(sector)
        var tweak = try aes(iv, key: key.subdata(in: 16..<32), encrypt: true)
        var whitened = Data(count: 512); var tweaks = Data(capacity: 512)
        for block in 0..<32 {
            tweaks.append(tweak)
            for j in 0..<16 { whitened[block*16+j] = raw[sector*512+block*16+j] ^ tweak[j] }
            var carry: UInt8 = 0
            for j in 0..<16 { let n = tweak[j] >> 7; tweak[j] = (tweak[j] << 1) | carry; carry = n }
            if carry != 0 { tweak[0] ^= 0x87 }
        }
        var plain = try aes(whitened, key: key.subdata(in: 0..<16))
        for j in 0..<512 { plain[j] ^= tweaks[j] }; output.append(plain)
    }
    return output
}
struct XCIKeys {
    fileprivate let values: [String: Data]
    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require((attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024*1024, "密钥文件过大")
        let text = try String(contentsOf: url, encoding: .utf8)
        var result = [String: Data]()
        for row in text.components(separatedBy: .newlines) {
            let line = row.components(separatedBy: "#")[0]
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].count % 2 == 0 else { continue }
            let chars = Array(parts[1].utf8); var bytes = Data(); var valid = true
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(bytes: chars[i..<i+2], encoding: .ascii) ?? "", radix: 16) else { valid = false; break }
                bytes.append(byte)
            }
            if valid { result[parts[0]] = bytes }
        }
        try require(result["header_key"]?.count == 32, "内置 prod.keys 缺少 header_key，请在资源菜单中更换密钥")
        values = result
    }
}
protocol XCIReadable: AnyObject { var size: Int { get }; func read(_ offset: Int, _ length: Int) throws -> Data }
final class XCIFile: XCIReadable {
    let size: Int
    private let handle: FileHandle
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let attr = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(attr[.type] as? FileAttributeType == .typeRegular, "请选择已下载到本机或外置盘的 XCI 文件")
        size = (attr[.size] as? NSNumber)?.intValue ?? 0
    }
    deinit { try? handle.close() }
    func read(_ offset: Int, _ length: Int) throws -> Data {
        try bounded(offset, length, size); try require(length <= tableLimit, "单次 XCI 读取超出限制")
        try handle.seek(toOffset: UInt64(offset)); let data = try handle.read(upToCount: length) ?? Data()
        try require(data.count == length, "XCI 已截断、移动或无法读取"); return data
    }
}
struct XCIEntry { let name: String; let offset: Int; let size: Int }
private func name(_ table: Data, _ at: Int, _ maximum: Int = 4096, root: Bool = false) throws -> String {
    try require(at >= 0 && at < table.count, "文件名偏移越界")
    guard let end = table[at...].firstIndex(of: 0), end-at <= maximum,
          let value = String(data: table.subdata(in: at..<end), encoding: .utf8) else { throw ImportFailure.invalid("资源文件名格式无效") }
    if root && value.isEmpty { return value }
    try require(!value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\"), "资源包含不安全的文件名")
    return value
}
private func hfs(_ file: XCIFile, _ offset: Int, _ size: Int) throws -> [XCIEntry] {
    try bounded(offset, size, file.size)
    let head = try file.read(offset, 16)
    try require(head.prefix(4) == Data("HFS0".utf8), "XCI 分区不是 HFS0")
    let count = try head.number(4, 4), strings = try head.number(8, 4)
    try require(count <= 65536 && strings <= tableLimit, "XCI 分区目录过大")
    let total = try add(16 + count*64, strings); try bounded(0, total, size)
    let table = try file.read(offset, total), start = 16 + count*64
    var rows = [XCIEntry](), seen = Set<String>()
    for i in 0..<count {
        let at = 16+i*64, local = try table.number(at, 8), bytes = try table.number(at+8, 8), n = try table.number(at+16, 4)
        try require(n < strings, "HFS0 文件名越界")
        let value = try name(table, start+n)
        try require(seen.insert(value).inserted, "HFS0 文件重名")
        let position = try add(total, local); try bounded(position, bytes, size)
        try require(try table.number(at+20,4) <= bytes, "HFS0 哈希范围越界")
        rows.append(XCIEntry(name: value, offset: try add(offset,position), size: bytes))
    }
    let sorted = rows.filter { $0.size > 0 }.sorted { $0.offset < $1.offset }
    for i in 1..<max(1,sorted.count) { try require(sorted[i-1].offset + sorted[i-1].size <= sorted[i].offset, "XCI 分区范围重叠") }
    return rows
}
func xciSecureEntries(_ file: XCIFile) throws -> [XCIEntry] {
    let head = try file.read(0, 512)
    try require(try head.slice(0x100,4) == Data("HEAD".utf8), "文件不是支持的 XCI；ZIP/7z 请先解压")
    let root = try head.number(0x130,8), bytes = try head.number(0x138,8)
    try require(root >= 512 && bytes >= 16 && bytes <= tableLimit, "XCI 根目录范围无效")
    try bounded(root, bytes, file.size)
    let entries = try hfs(file,root,file.size-root)
    try require(entries.count <= 16, "XCI 分区数量异常")
    guard let secure = entries.first(where: { $0.name == "secure" }) else { throw ImportFailure.invalid("XCI 缺少 secure 分区") }
    return try hfs(file,secure.offset,secure.size)
}
struct NCASection { let start: Int; let size: Int; let crypto: Int; let partition: Int; let fs: Data }
final class NCAArchive {
    let file: XCIFile; let entry: XCIEntry; let title: String; let sections: [NCASection]
    let contentType: Int
    private let sectionKey: Data?
    init(file: XCIFile, entry: XCIEntry, keys: XCIKeys) throws {
        self.file = file; self.entry = entry
        try require(entry.size >= 0xc00, "NCA 太短")
        let header = try xtsHeader(file.read(entry.offset,0xc00), keys.values["header_key"]!)
        let magic = try header.slice(0x200,4)
        try require(magic == Data("NCA3".utf8) || magic == Data("NCA2".utf8), "prod.keys 无法解密此 XCI（或文件不是支持的 NCA2/NCA3）")
        try require(try header.number(0x208,8) == entry.size, "NCA 大小与 XCI 目录不符")
        title = String(format: "%016llX", UInt64(try header.number(0x210,8)))
        contentType = Int(header[0x205])
        try require(contentType <= 5, "NCA 内容类型无效")
        try require(try header.slice(0x230,16).allSatisfy { $0 == 0 }, "此包需要独立 title key，当前导入器只支持已测试的无票据 XCI")
        let kind = Int(header[0x207]); try require(kind <= 2, "不支持的 NCA 密钥类型")
        let generation = max(Int(header[0x206]),Int(header[0x220]))
        let label = String(format: "key_area_key_%@_%02x", ["application","ocean","system"][kind], max(0,generation-1))
        if let key = keys.values[label] { sectionKey = try aes(header.slice(0x300,64),key:key).subdata(in:32..<48) }
        else { sectionKey = nil }
        var rows = [NCASection]()
        for i in 0..<4 {
            let start = try header.number(0x240+i*16,4), end = try header.number(0x244+i*16,4)
            if start == 0 && end == 0 { continue }
            try require(start >= 6 && end > start && end <= entry.size/512, "NCA 分区越界")
            let fs = try header.slice(0x400+i*512,512)
            try require(try digest(fs) == header.slice(0x280+i*32,32), "NCA 分区头 SHA-256 校验失败")
            rows.append(NCASection(start:start*512,size:(end-start)*512,crypto:Int(fs[4]),partition:Int(fs[2]),fs:fs))
        }
        sections = rows
    }
    func read(_ section: NCASection, _ relative: Int, _ length: Int, counter: Int? = nil) throws -> Data {
        try bounded(relative,length,section.size)
        let offset = try add(section.start,relative)
        if section.crypto == 1 { return try file.read(add(entry.offset,offset),length) }
        try require(section.crypto == 3 || section.crypto == 4, "不支持的 NCA 分区加密")
        guard let sectionKey else { throw ImportFailure.invalid("缺少 NCA 资源密钥") }
        let aligned = offset & ~15, skip = offset-aligned
        var iv = Data(try section.fs.slice(0x140,8).reversed())
        let block = UInt64(aligned/16)
        for shift in stride(from:56,through:0,by:-8) { iv.append(UInt8(truncatingIfNeeded: block >> shift)) }
        if let counter { for i in 0..<4 { iv[4+i] = UInt8(truncatingIfNeeded: counter >> ((3-i)*8)) } }
        let plain = try aes(file.read(add(entry.offset,aligned),skip+length),key:sectionKey,iv:iv)
        return try plain.slice(skip,length)
    }
}
final class NCAPlain: XCIReadable {
    let archive: NCAArchive; let section: NCASection
    var size: Int { section.size }
    init(_ archive: NCAArchive,_ section: NCASection) throws {
        try require(section.crypto != 4,"基础资源不能是 BKTR")
        self.archive=archive;self.section=section
    }
    func read(_ offset: Int,_ length: Int) throws -> Data { try archive.read(section,offset,length) }
}
final class NCAPatch: XCIReadable {
    let archive: NCAArchive; let section: NCASection; let base: XCIReadable; let size: Int
    private let relocations: [[Int]], subsections: [[Int]]
    init(_ archive:NCAArchive,_ section:NCASection,_ base:XCIReadable) throws {
        self.archive=archive;self.section=section;self.base=base
        let fs=section.fs
        let ro=try fs.number(0x100,8), rz=try fs.number(0x108,8), so=try fs.number(0x120,8), sz=try fs.number(0x128,8)
        try require(try fs.number(0x110,4)==0x52544b42 && fs.number(0x130,4)==0x52544b42 && add(ro,rz)==so && add(so,sz)==section.size && rz<=tableLimit && sz<=tableLimit,"BKTR 更新映射无效")
        let (rel,total)=try Self.buckets(archive.read(section,ro,rz),20,fs.number(0x118,4))
        let (sub,end)=try Self.buckets(archive.read(section,so,sz),16,fs.number(0x138,4))
        try require(end==so && !rel.isEmpty && !sub.isEmpty,"BKTR 映射为空或大小错误")
        relocations=rel;size=total
        var counters=sub.map { [$0[0],$0[2]] }
        try require(counters.last![0]<=ro,"BKTR 子区段与元数据重叠")
        if counters.last![0]<ro { counters.append([ro,try fs.number(0x140,4)]) }
        subsections=counters
        try require(rel[0][0]==0 && counters[0][0]==0,"BKTR 映射没有从零开始")
        for i in rel.indices {
            let row=rel[i], end=i+1<rel.count ? rel[i+1][0]:total
            try require((row[2]==0 || row[2]==1) && row[0]<end,"BKTR 映射顺序无效")
            try bounded(row[1],end-row[0],row[2]==1 ? ro:base.size)
        }
    }
    private static func buckets(_ raw:Data,_ stride:Int,_ expected:Int) throws -> ([[Int]],Int) {
        try require(raw.count>=0x8000 && raw.count%0x4000==0,"BKTR 元数据长度无效")
        let count=try raw.number(4,4), total=try raw.number(8,8)
        try require(count>=1 && count<=2046 && (count+1)*0x4000<=raw.count,"BKTR 桶数量无效")
        var rows=[[Int]]()
        for i in 0..<count {
            let at=(i+1)*0x4000, n=try raw.number(at+4,4), end=try raw.number(at+8,8)
            try require(n>=1 && n<=0x3ff0/stride && end<=total,"BKTR 桶范围无效")
            for j in 0..<n {
                let p=at+16+j*stride
                rows.append(stride==20 ? [try raw.number(p,8),try raw.number(p+8,8),try raw.number(p+16,4)] : [try raw.number(p,8),try raw.number(p+8,4),try raw.number(p+12,4)])
            }
        }
        try require(rows.count==expected && !rows.isEmpty && rows.last![0]<total,"BKTR 条目数量错误")
        for i in 1..<rows.count { try require(rows[i-1][0]<rows[i][0],"BKTR 条目排序错误") }
        return (rows,total)
    }
    private func index(_ rows:[[Int]],_ offset:Int) -> Int {
        var lo=0,hi=rows.count
        while lo<hi { let mid=(lo+hi)/2;if rows[mid][0]<=offset {lo=mid+1}else{hi=mid} };return lo-1
    }
    private func physical(_ offset:Int,_ length:Int) throws -> Data {
        var offset=offset,left=length,out=Data()
        while left>0 {
            let i=index(subsections,offset);try require(i>=0,"BKTR 物理偏移无效")
            let end=i+1<subsections.count ? subsections[i+1][0]:section.size, n=min(left,end-offset)
            try require(n>0,"BKTR 物理读取无进展")
            out.append(try archive.read(section,offset,n,counter:subsections[i][1]));offset+=n;left-=n
        };return out
    }
    func read(_ offset:Int,_ length:Int) throws -> Data {
        try bounded(offset,length,size)
        var offset=offset,left=length,out=Data()
        while left>0 {
            let i=index(relocations,offset);try require(i>=0,"BKTR 虚拟偏移无效")
            let row=relocations[i],end=i+1<relocations.count ? relocations[i+1][0]:size,n=min(left,end-offset),p=try add(row[1],offset-row[0])
            try require(n>0,"BKTR 虚拟读取无进展")
            out.append(try row[2]==1 ? physical(p,n):base.read(p,n));offset+=n;left-=n
        };return out
    }
}
final class IVFCReader: XCIReadable {
    private let reader:XCIReadable, levels:[[Int]], master:Data
    private var cache=[Int:Data](), order=[Int](), cacheBytes=0
    var size:Int { levels[5][1] }
    private(set) var verifiedBlocks=0
    init(_ section:NCASection,_ reader:XCIReadable) throws {
        self.reader=reader;let fs=section.fs
        try require(try fs.slice(8,4)==Data("IVFC".utf8) && fs.number(20,4)==7,"不支持的 IVFC 资源校验层级")
        var rows=[[Int]]()
        for i in 0..<6 {
            let off=try fs.number(24+i*24,8),size=try fs.number(32+i*24,8),bits=try fs.number(40+i*24,4)
            try require((9...20).contains(bits) && size>0,"IVFC 块大小无效");try bounded(off,size,reader.size)
            rows.append([off,size,1<<bits])
        };levels=rows;master=try fs.slice(0xc8,32)
    }
    private func block(_ level:Int,_ index:Int) throws -> Data {
        let row=levels[level];try require(index>=0 && index<=Int.max/row[2],"IVFC 块序号越界")
        let key=index*8+level
        if let value=cache[key] { return value }
        let pos=index*row[2];try require(pos<row[1],"IVFC 块序号超出资源")
        let raw=try reader.read(add(row[0],pos),min(row[2],row[1]-pos))
        let hash=try level==0 ? master.slice(index*32,32):levelRead(level-1,index*32,32)
        var padded=raw;if padded.count<row[2] {padded.append(Data(repeating:0,count:row[2]-padded.count))}
        try require(digest(padded)==hash,"XCI 资源 SHA-256 校验失败（IVFC \(level)/\(index)）")
        while cacheBytes+raw.count>32*1024*1024 || order.count>=512 {
            guard !order.isEmpty else {break};let old=order.removeFirst();cacheBytes-=cache.removeValue(forKey:old)?.count ?? 0
        }
        cache[key]=raw;order.append(key);cacheBytes+=raw.count;verifiedBlocks+=1;return raw
    }
    private func levelRead(_ level:Int,_ offset:Int,_ length:Int) throws -> Data {
        let row=levels[level];try bounded(offset,length,row[1]);try require(length<=tableLimit,"IVFC 读取过大")
        var offset=offset,left=length,out=Data()
        while left>0 {
            let i=offset/row[2],local=offset%row[2],raw=try block(level,i),n=min(left,raw.count-local)
            try require(n>0,"IVFC 读取无进展");out.append(try raw.slice(local,n));offset+=n;left-=n
        };return out
    }
    func trimCache() {cache.removeAll(keepingCapacity:false);order.removeAll(keepingCapacity:false);cacheBytes=0}
    func read(_ offset:Int,_ length:Int) throws -> Data { try levelRead(5,offset,length) }
}
struct RomEntry: Codable { let path:String;let offset:Int;let bytes:Int }
final class XCIRomFS {
    let reader:IVFCReader, entries:[RomEntry]
    init(_ reader:IVFCReader) throws {
        self.reader=reader;let head=try reader.read(0,80)
        let h=try (0..<10).map {try head.number($0*8,8)}
        try require(h[0]==80 && h[9]<=reader.size,"RomFS 头格式无效")
        for i in [1,3,5,7] {try bounded(h[i],h[i+1],reader.size);try require(h[i+1]<=tableLimit,"RomFS 元数据过大")}
        let dirs=try reader.read(h[3],h[4]),files=try reader.read(h[7],h[8])
        var stack:[(Int,String,Int?)]=[(0,"",nil)],seenDirs=Set<Int>(),seenFiles=Set<Int>(),paths=Set<String>(),rows=[RomEntry]()
        func tableName(_ table:Data,_ at:Int,_ fixed:Int,_ length:Int,_ isRoot:Bool=false) throws -> String {
            try bounded(at,fixed,table.count);try require(length<=4096,"RomFS 文件名过长");let bytes=try table.slice(at+fixed,length)
            guard let value=String(data:bytes,encoding:.utf8) else {throw ImportFailure.invalid("RomFS 文件名不是 UTF-8")}
            if isRoot && value.isEmpty{return value}
            try require(!value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0"),"RomFS 包含不安全文件名");return value
        }
        while let (at,prefix,parent)=stack.popLast() {
            try bounded(at,24,dirs.count);try require(at%4==0 && seenDirs.insert(at).inserted,"RomFS 目录循环")
            let a=try (0..<6).map {try dirs.number(at+$0*4,4)}
            let n=try tableName(dirs,at,24,a[5],at==0),path=prefix.isEmpty ? n:prefix+"/"+n
            if let parent {try require(a[0]==parent,"RomFS 父目录不匹配")}
            if a[1] != 0xffffffff {stack.append((a[1],prefix,parent))}
            if a[2] != 0xffffffff {stack.append((a[2],path,at))}
            var file=a[3]
            while file != 0xffffffff {
                try bounded(file,32,files.count);try require(file%4==0 && seenFiles.insert(file).inserted,"RomFS 文件链循环")
                let parent=try files.number(file,4),next=try files.number(file+4,4),off=try files.number(file+8,8),size=try files.number(file+16,8),len=try files.number(file+28,4)
                let n=try tableName(files,file,32,len),full=path.isEmpty ? n:path+"/"+n
                try require(parent==at && full.utf8.count<1024 && paths.insert(full).inserted,"RomFS 路径重复或过长")
                let pos=try add(h[9],off);try bounded(pos,size,reader.size)
                rows.append(RomEntry(path:full,offset:pos,bytes:size));file=next
            }
        }
        entries=rows.sorted {$0.path<$1.path}
    }
}

// PFS0 hash hierarchy and content-meta layouts are independently implemented
// from the public hactool and Atmosphere format declarations (see README).
final class NCAHashedPFS: XCIReadable {
    private let archive: NCAArchive, section: NCASection, hashes: Data
    private let offset: Int, blockSize: Int
    let size: Int
    private var cache = [Int: Data]()
    init(_ archive: NCAArchive, _ section: NCASection) throws {
        try require(section.partition == 1 && section.fs[3] == 2 && section.crypto != 4, "不支持的内容元数据分区")
        self.archive = archive; self.section = section
        blockSize = try section.fs.number(0x28,4)
        let hashOffset = try section.fs.number(0x30,8), hashSize = try section.fs.number(0x38,8)
        offset = try section.fs.number(0x40,8); size = try section.fs.number(0x48,8)
        try require(blockSize >= 512 && blockSize <= 4*1024*1024 && blockSize.nonzeroBitCount == 1 && hashSize <= tableLimit && size > 0, "PFS0 校验表大小无效")
        try bounded(hashOffset,hashSize,section.size); try bounded(offset,size,section.size)
        try require(hashSize >= ((size-1)/blockSize+1)*32, "PFS0 校验表不完整")
        hashes = try archive.read(section,hashOffset,hashSize)
        try require(digest(hashes) == section.fs.slice(8,32), "PFS0 主校验失败")
    }
    func read(_ at: Int, _ count: Int) throws -> Data {
        try bounded(at,count,size); try require(count <= tableLimit, "PFS0 读取过大")
        var at=at, left=count, out=Data()
        while left>0 {
            let index=at/blockSize, local=at%blockSize, block: Data
            if let saved=cache[index] {block=saved} else {
                block=try archive.read(section,offset+index*blockSize,min(blockSize,size-index*blockSize))
                try require(digest(block) == hashes.slice(index*32,32), "PFS0 数据块校验失败")
                if cache.count>=4 {cache.removeAll(keepingCapacity:true)}
                cache[index]=block
            }
            let n=min(left,block.count-local); try require(n>0,"PFS0 读取无进展")
            out.append(try block.slice(local,n));at+=n;left-=n
        }
        return out
    }
}
struct PFSEntry {let name:String, offset:Int, bytes:Int}
func pfsEntries(_ reader:XCIReadable) throws -> [PFSEntry] {
    let header=try reader.read(0,16)
    try require(try header.slice(0,4)==Data("PFS0".utf8),"内容元数据缺少 PFS0")
    let count=try header.number(4,4), strings=try header.number(8,4)
    try require(count<=65536 && strings<=tableLimit && count<=(tableLimit-16-strings)/24,"PFS0 目录过大")
    let length=16+count*24+strings, table=try reader.read(0,length), names=try table.slice(16+count*24,strings)
    var rows=[PFSEntry](),seen=Set<String>(),ranges=[(Int,Int)]()
    for i in 0..<count {
        let p=16+i*24,relative=try table.number(p,8),size=try table.number(p+8,8)
        let label=try name(names,table.number(p+16,4)), offset=try add(length,relative)
        try require(seen.insert(label.lowercased()).inserted,"PFS0 文件名重复")
        try bounded(offset,size,reader.size)
        if size>0 {ranges.append((offset,offset+size))}
        rows.append(PFSEntry(name:label,offset:offset,bytes:size))
    }
    ranges.sort{$0.0<$1.0}
    for i in 1..<max(1,ranges.count) {try require(ranges[i-1].1<=ranges[i].0,"PFS0 文件范围重叠")}
    return rows
}
struct XCIContentMeta {
    struct Content {let id:String, sha256:String, type:Int, idOffset:Int, bytes:Int}
    let title:UInt64, application:UInt64, version:Int, type:Int, contents:[Content]
    init(_ data:Data) throws {
        try require(data.count>=32 && data.count<=tableLimit,"CNMT 元数据长度无效")
        title=UInt64(try data.number(0,8));version=try data.number(8,4);type=Int(data[12])
        let extended=try data.number(14,2), count=try data.number(16,2)
        try require([0x80,0x81,0x82].contains(type) && count>0 && count<=4096,"不支持或无效的游戏 CNMT")
        try bounded(32,extended,data.count)
        if type==0x80 {application=title} else {
            try require(extended>=8,"CNMT 缺少所属游戏标识");application=UInt64(try data.number(32,8))
        }
        let start=32+extended; try bounded(start,count*56,data.count)
        var rows=[Content](),seen=Set<String>()
        for i in 0..<count {
            let p=start+i*56,id=try data.slice(p+32,16).hex,bytes=try data.number(p+48,6)
            try require(seen.insert(id).inserted && bytes>0,"CNMT 内容重复或长度无效")
            rows.append(Content(id:id,sha256:try data.slice(p,32).hex,type:Int(data[p+54]),idOffset:Int(data[p+55]),bytes:bytes))
        }
        contents=rows
    }
}
func contentMeta(_ archive:NCAArchive) throws -> [XCIContentMeta] {
    try require(archive.contentType==1,"不是内容元数据 NCA")
    var metas=[XCIContentMeta]()
    for section in archive.sections where section.partition==1 {
        let reader=try NCAHashedPFS(archive,section)
        for file in try pfsEntries(reader) where file.name.lowercased().hasSuffix(".cnmt") {
            try require(file.bytes<=tableLimit,"CNMT 文件过大")
            metas.append(try XCIContentMeta(reader.read(file.offset,file.bytes)))
        }
    }
    try require(!metas.isEmpty,"NCA 缺少游戏内容元数据")
    return metas
}
