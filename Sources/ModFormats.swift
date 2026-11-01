import Foundation
import CryptoKit
import CommonCrypto
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
// are checked before access. Only bounded thumbnail samples are decoded here;
// large model payloads and movies use separate streaming paths.
enum ModFormats {
    // IVF's numerator is a timebase, not the decoded frame rate. Real PC
    // exports use e.g. 5,114,000 / 213,043 (~24 ticks/s). CMTime accepts a
    // positive Int32 timescale; the denominator cap also bounds stamp*scale.
    static func ivfTimebase(rate:Int,scale:Int)throws {
        guard (1...Int(Int32.max)).contains(rate),(1...1_000_000).contains(scale) else {throw ModLoadError.limit}
    }
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
        guard Set(rows.map(\.name)).count==rows.count,Set(rows.map(\.id)).count==rows.count else{throw ModLoadError.invalid}
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
        for line in text.replacingOccurrences(of:"\u{feff}",with:"").replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").split(separator:"\n") {
            if line.trimmingCharacters(in:.whitespaces).hasPrefix("#"){continue}
            guard let p=line.firstIndex(of:"=") else {continue};values[String(line[..<p])]=String(line[line.index(after:p)...])
            guard values.count<=500000 else {throw ModLoadError.limit}
        };return values
    }
    static func propertyData(_ values:[String:String],header:Bool=false)throws->Data {
        let s=(header ? "#A3DA__________\n":"")+values.keys.sorted().map{$0+"="+values[$0]!}.joined(separator:"\n")+"\n"
        guard s.utf8.count<=fileLimit else {throw ModLoadError.limit};return Data(s.utf8)
    }
    // A supplied CJK atlas must travel with its matching character map. Keep
    // every other native font and require replacement maps to retain all old
    // characters, cell geometry and the imported song's BMP text coverage.
    static func pairedFontMap(_ base:Data,source:Data,required:Set<UInt16>)throws->Data {
        func rows(_ b:Data)throws->[Int:Int] {
            let count=try u(b,8),table=try u(b,12);guard (1...256).contains(count) else{throw ModLoadError.limit};_=try span(b,table,count*4)
            var result=[Int:Int]()
            for i in 0..<count {
                let p=try u(b,table+i*4);guard p>=16 else{throw ModLoadError.invalid};_=try span(b,p,28)
                let id=try u(b,p),n=try u(b,p+20),o=try u(b,p+24)
                guard result[id]==nil,n<=65536 else{throw ModLoadError.invalid};_=try span(b,o,n*8);result[id]=p
            };return result
        }
        func characters(_ b:Data,_ row:Int)throws->Set<UInt16> {
            let n=try u(b,row+20),o=try u(b,row+24)
            let values=try (0..<n).map{UInt16(try u(b,o+$0*8,2))}
            guard Set(values).count==n else{throw ModLoadError.invalid};return Set(values)
        }
        let originals=try rows(base),supplied=try rows(source);var output=base
        for id in [15,17] {
            guard let old=originals[id],let new=supplied[id],
                  base[old+4..<old+16]==source[new+4..<new+16] else{throw ModLoadError.unsupported}
            let codes=try characters(source,new)
            guard try characters(base,old).isSubset(of:codes),required.isSubset(of:codes) else{throw ModLoadError.unsupported}
            let columns=try u(source,new+16),count=try u(source,new+20),offset=try u(source,new+24)
            guard (1...1024).contains(columns) else{throw ModLoadError.invalid}
            let pad=(-output.count)&15;guard output.count+pad+count*8<=fileLimit else{throw ModLoadError.limit}
            output.append(Data(repeating:0,count:pad));let at=output.count
            output.append(source.subdata(in:try span(source,offset,count*8)))
            try put(&output,old+16,columns);try put(&output,old+20,count);try put(&output,old+24,at)
        };return output
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
    struct SpritePayload {
        var textures:[Data],textureNames:[String],sprites:[Data],names:[String],modes:[Data]
        init(_ b:Data)throws {
            guard try u(b,0)==0 else{throw ModLoadError.unsupported}
            let tx=try u(b,4),nt=try u(b,8),ns=try u(b,12),so=try u(b,16),tn=try u(b,20),sn=try u(b,24),mo=try u(b,28)
            guard (1...255).contains(nt),ns<65536 else{throw ModLoadError.limit}
            for (off,len) in [(so,ns*40),(tn,nt*4),(sn,ns*4),(mo,ns*8)]{_=try span(b,off,len)}
            guard try u(b,tx)==0x03505854,try u(b,tx+4)==nt else{throw ModLoadError.invalid}
            let starts=try (0..<nt).map{tx + (try u(b,tx+12+$0*4))},end=([so,tn,sn,mo].filter{$0>tx}+[b.count]).min()!
            guard starts==Array(Set(starts)).sorted(),let first=starts.first,first>=tx+12+nt*4,starts.last!<end else{throw ModLoadError.invalid}
            textures=try starts.enumerated().map{i,p in b.subdata(in:try span(b,p,(i+1<nt ? starts[i+1]:end)-p))}
            textureNames=try (0..<nt).map{try string(b,u(b,tn+$0*4))}
            sprites=try (0..<ns).map{b.subdata(in:try span(b,so+$0*40,40))}
            names=try (0..<ns).map{try string(b,u(b,sn+$0*4))}
            modes=try (0..<ns).map{b.subdata(in:try span(b,mo+$0*8,8))}
            guard Set(names).count==names.count else{throw ModLoadError.invalid}
            for row in sprites{guard try u(row,0)<nt else{throw ModLoadError.invalid}}
        }
        func data()throws->Data {
            guard textures.count==textureNames.count,sprites.count==names.count,sprites.count==modes.count,textures.count<256,sprites.count<65536 else{throw ModLoadError.limit}
            var b=Data(repeating:0,count:32)
            func append(_ raw:Data,_ alignment:Int=4)throws->Int {
                let pad=(-b.count)&(alignment-1);guard b.count+pad+raw.count<=fileLimit else{throw ModLoadError.limit}
                b.append(Data(repeating:0,count:pad));let at=b.count;b.append(raw);return at
            }
            let so=try append(sprites.reduce(into:Data()){$0.append($1)},16),mo=try append(modes.reduce(into:Data()){$0.append($1)},16)
            func labels(_ values:[String])throws->Int {
                var offsets=[Int]();for name in values{offsets.append(try append(Data((name+"\0").utf8),1))}
                var data=Data(repeating:0,count:values.count*4);for (i,p) in offsets.enumerated(){try put(&data,i*4,p)};return try append(data)
            }
            let tn=try labels(textureNames),sn=try labels(names)
            var header=Data(repeating:0,count:12+textures.count*4);try put(&header,0,0x03505854);try put(&header,4,textures.count);try put(&header,8,textures.count|0x01010100)
            let tx=try append(header,16)
            for (i,raw) in textures.enumerated(){let p=try append(raw);try put(&b,tx+12+i*4,p-tx)}
            for (i,value) in [0,tx,textures.count,sprites.count,so,tn,sn,mo].enumerated(){try put(&b,i*4,value)}
            return b
        }
        mutating func add(from source:SpritePayload,index:Int,name:String,texturePrefix:String,displayLike:Data?=nil)throws->Int {
            guard source.sprites.indices.contains(index),!names.contains(name) else{throw ModLoadError.invalid}
            var row=source.sprites[index];let texture=try u(row,0)
            guard source.textures.indices.contains(texture),textures.count<255 else{throw ModLoadError.limit}
            // Only a selected song's cover is appended. Original atlas sprites,
            // texture payloads and order are preserved byte-for-byte.
            try put(&row,0,textures.count);textures.append(source.textures[texture]);textureNames.append(texturePrefix+String(texture))
            if let template=displayLike {
                _=try span(template,0,40)
                let width=Float(bitPattern:UInt32(try u(template,32))),height=Float(bitPattern:UInt32(try u(template,36)))
                let sourceWidth=Float(bitPattern:UInt32(try u(row,32))),sourceHeight=Float(bitPattern:UInt32(try u(row,36)))
                guard width.isFinite,height.isFinite,sourceWidth.isFinite,sourceHeight.isFinite,width>0,height>0,sourceWidth>0,sourceHeight>0 else{throw ModLoadError.invalid}
                // The game also derives UVs from the pixel rectangle. Changing
                // only UV/size samples the jacket's empty corner. Materialize
                // a small texture so both rectangle representations agree.
                guard width.rounded()==width,height.rounded()==height,width<=512,height<=512 else{throw ModLoadError.limit}
                let templateTexture=try u(template,0)
                guard templateTexture<textures.count-1 else{throw ModLoadError.invalid}
                textures[textures.count-1]=try Self.framedThumbnail(source.textures[texture],sprite:row,layoutTexture:textures[templateTexture],layoutSprite:template,width:Int(width),height:Int(height))
                let coordinates:[(Int,Float)]=[(8,0),(12,0),(16,1),(20,1),(24,0),(28,0)]
                for (offset,value) in coordinates {try put(&row,offset,Int(value.bitPattern))}
                try put(&row,32,Int(width.bitPattern));try put(&row,36,Int(height.bitPattern))
            }
            let result=sprites.count;sprites.append(row);names.append(name);modes.append(source.modes[index]);return result
        }
        // Decode only sampled pixels, not an entire potentially large atlas.
        // Classic TXP formats follow MikuMikuLibrary TextureFormat/SubTexture.
        static func thumbnail(_ texture:Data,sprite:Data,width:Int,height:Int)throws->Data {
            guard (1...512).contains(width),(1...512).contains(height),try u(texture,0)==0x04505854 else{throw ModLoadError.unsupported}
            let count=try u(texture,4);guard (1...16).contains(count) else{throw ModLoadError.limit}
            _=try span(texture,12,count*4);let start=try u(texture,12)
            guard start>=12+count*4,try u(texture,start)==0x02505854 else{throw ModLoadError.invalid}
            let tw=try u(texture,start+4),th=try u(texture,start+8),format=try u(texture,start+12),bytes=try u(texture,start+20),at=start+24
            guard (1...8192).contains(tw),(1...8192).contains(th) else{throw ModLoadError.limit}
            let blockBytes:Int
            switch format{case 1:blockBytes=3;case 2:blockBytes=4;case 6,7:blockBytes=8;case 8,9:blockBytes=16;default:throw ModLoadError.unsupported}
            let expected=format<=2 ? tw*th*blockBytes:((tw+3)/4)*((th+3)/4)*blockBytes
            guard bytes==expected else{throw ModLoadError.invalid};_=try span(texture,at,bytes)
            func number(_ offset:Int)throws->Double {let v=Double(Float(bitPattern:UInt32(try u(sprite,offset))));guard v.isFinite else{throw ModLoadError.invalid};return v}
            var x=try number(24),y=try number(28),w=try number(32),h=try number(36)
            guard x>=0,y>=0,w>0,h>0,x+w<=Double(tw),y+h<=Double(th) else{throw ModLoadError.invalid}
            let aspect=Double(width)/Double(height)
            if w/h<aspect{let nh=w/aspect;y+=(h-nh)/2;h=nh}else{let nw=h*aspect;x+=(w-nw)/2;w=nw}
            // Classic SPR coordinates use the opposite vertical origin from
            // texture storage. Keep output pixels bottom-up, like the atlas.
            y=Double(th)-y-h
            func pixel(_ px:Int,_ py:Int)throws->[Int] {
                let px=max(0,min(tw-1,px)),py=max(0,min(th-1,py))
                if format<=2 {let p=at+(py*tw+px)*blockBytes;return [Int(texture[p]),Int(texture[p+1]),Int(texture[p+2]),format==2 ? Int(texture[p+3]):255]}
                let p=at+((py/4)*((tw+3)/4)+px/4)*blockBytes,ci=(py%4)*4+px%4,c=p+(blockBytes==16 ? 8:0)
                let c0=try u(texture,c,2),c1=try u(texture,c+2,2)
                func rgb(_ v:Int)->[Int]{let r=(v>>11)&31,g=(v>>5)&63,b=v&31;return [(r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2),255]}
                let a=rgb(c0),b=rgb(c1);var colors=[a,b]
                if c0>c1 || blockBytes==16 {colors.append((0..<4).map{(2*a[$0]+b[$0])/3});colors.append((0..<4).map{(a[$0]+2*b[$0])/3})}
                else{colors.append((0..<4).map{(a[$0]+b[$0])/2});colors.append([0,0,0,format==7 ? 0:255])}
                var rgba=colors[(try u(texture,c+4)>>(ci*2))&3]
                if format==8 {rgba[3]=Int((texture[p+ci/2]>>UInt8((ci%2)*4))&15)*17}
                if format==9 {
                    let a0=Int(texture[p]),a1=Int(texture[p+1]);var alpha=[a0,a1]
                    if a0>a1 {for i in 1...6{alpha.append(((7-i)*a0+i*a1)/7)}}
                    else{for i in 1...4{alpha.append(((5-i)*a0+i*a1)/5)};alpha += [0,255]}
                    var bits:UInt64=0;for i in 0..<6{bits |= UInt64(texture[p+2+i])<<UInt64(i*8)}
                    rgba[3]=alpha[Int((bits>>UInt64(ci*3))&7)]
                }
                return rgba
            }
            var rgba=Data(repeating:0,count:width*height*4)
            for dy in 0..<height {for dx in 0..<width {
                let sx=x+(Double(dx)+0.5)*w/Double(width)-0.5,sy=y+(Double(dy)+0.5)*h/Double(height)-0.5
                let ix=Int(floor(sx)),iy=Int(floor(sy)),fx=sx-Double(ix),fy=sy-Double(iy)
                let p00=try pixel(ix,iy),p10=try pixel(ix+1,iy),p01=try pixel(ix,iy+1),p11=try pixel(ix+1,iy+1)
                for c in 0..<4 {let top=Double(p00[c])*(1-fx)+Double(p10[c])*fx,bottom=Double(p01[c])*(1-fx)+Double(p11[c])*fx;rgba[(dy*width+dx)*4+c]=UInt8(max(0,min(255,(top*(1-fy)+bottom*fy).rounded())))}
            }}
            var out=Data(repeating:0,count:40)
            for (i,v) in [0x04505854,1,0x01010101,16,0x02505854,width,height,2,0,rgba.count].enumerated(){try put(&out,i*4,v)}
            out.append(rgba);return out
        }
        static func framedThumbnail(_ texture:Data,sprite:Data,layoutTexture:Data,layoutSprite:Data,width:Int,height:Int)throws->Data {
            let mask=try thumbnail(layoutTexture,sprite:layoutSprite,width:width,height:height)
            var bounds=[(Int,Int)](),minX=width,maxX = -1,minY=height,maxY = -1
            for y in 0..<height {
                var left=width,right = -1
                for x in 0..<width where mask[40+(y*width+x)*4+3]>0 {left=min(left,x);right=max(right,x)}
                bounds.append((left,right))
                if right>=left {minX=min(minX,left);maxX=max(maxX,right);minY=min(minY,y);maxY=max(maxY,y)}
            }
            guard maxX>=minX,maxY>=minY else{throw ModLoadError.invalid}
            let contentWidth=maxX-minX+1,contentHeight=maxY-minY+1
            let content=try thumbnail(texture,sprite:sprite,width:contentWidth,height:contentHeight)
            var out=mask;out.replaceSubrange(40..<out.count,with:Data(repeating:0,count:width*height*4))
            for y in minY...maxY {
                let (left,right)=bounds[y];if right<left{continue}
                for x in left...right {
                    let sx=(Double(x-left)+0.5)*Double(contentWidth)/Double(right-left+1)-0.5
                    let ix=Int(floor(sx)),fraction=sx-Double(ix),x0=max(0,min(contentWidth-1,ix)),x1=max(0,min(contentWidth-1,ix+1))
                    let a=40+((y-minY)*contentWidth+x0)*4,b=40+((y-minY)*contentWidth+x1)*4,d=40+(y*width+x)*4
                    for c in 0..<4 {out[d+c]=UInt8((Double(content[a+c])*(1-fraction)+Double(content[b+c])*fraction).rounded())}
                    out[d+3]=UInt8(Int(out[d+3])*Int(mask[d+3])/255)
                }
            }
            return out
        }
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
        if sig=="FARC"{return try countedArchive(b)}
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
    // Counted FARC, including the fixed format-level CBC variant used by
    // native UI atlases. This format constant is unrelated to Switch prod.keys.
    // Layout follows the project's existing bounded Python FARC reader.
    private static func farcCBC(_ data:Data,iv:Data)throws->Data {
        let count=data.count/16*16;guard count>0,iv.count==16,count<=fileLimit else{throw ModLoadError.invalid}
        let key:[UInt8]=[0x13,0x72,0xd5,0x7b,0x6e,0x9e,0x31,0xeb,0xa2,0x39,0xb8,0x3c,0x15,0x57,0xc6,0xbb]
        var output=Data(repeating:0,count:count),used=0
        let status=key.withUnsafeBytes{k in iv.withUnsafeBytes{v in data.withUnsafeBytes{input in output.withUnsafeMutableBytes{out in
            CCCrypt(CCOperation(kCCDecrypt),CCAlgorithm(kCCAlgorithmAES),0,k.baseAddress,key.count,v.baseAddress,input.baseAddress,count,out.baseAddress,count,&used)
        }}}}
        guard status==kCCSuccess,used==count else{throw ModLoadError.invalid};return output
    }
    private static func countedArchive(_ b:Data)throws->[Block] {
        let end=try u(b,4,4,true)+8;guard end>=32,end<=min(b.count,16*1024*1024) else{throw ModLoadError.invalid}
        let flags=try u(b,8,4,true);guard flags & ~6 == 0 else{throw ModLoadError.unsupported}
        let header:Data
        if flags&4 != 0 {header=try farcCBC(b.subdata(in:32..<end),iv:b.subdata(in:16..<32))}
        else{header=b.subdata(in:16..<end)}
        let headSize=try u(header,0,4,true),count=try u(header,8,4,true),entrySize=try u(header,12,4,true)
        guard headSize>=16,headSize<=header.count,count<=100000,entrySize>=16,entrySize<=256 else{throw ModLoadError.limit}
        var at=headSize,total=0,rows=[Block](),names=Set<String>(),regions=[Range<Int>]()
        for _ in 0..<count {
            guard at<header.count,let zero=header[at...].firstIndex(of:0),let name=String(data:header[at..<zero],encoding:.utf8),!name.isEmpty,names.insert(name).inserted else{throw ModLoadError.invalid}
            let off=try u(header,zero+1,4,true),packed=try u(header,zero+5,4,true),size=try u(header,zero+9,4,true),flags=try u(header,zero+13,4,true)
            guard flags & ~6 == 0 else{throw ModLoadError.unsupported}
            guard size<=fileLimit,total<=128*1024*1024-size,off>=end else{throw ModLoadError.limit};total+=size
            let length=flags&4 != 0 ? (packed+15)/16*16:packed
            let region=try span(b,off,length);regions.append(region);var raw=b.subdata(in:region)
            if flags&4 != 0 {guard raw.count>=32 else{throw ModLoadError.invalid};raw=try farcCBC(raw.subdata(in:16..<raw.count),iv:raw.subdata(in:0..<16))}
            if flags&2 != 0 && packed != size {
                var result=[UInt8](repeating:0,count:max(1,size)),stream=z_stream()
                guard inflateInit2_(&stream,31,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else{throw ModLoadError.invalid};defer{inflateEnd(&stream)}
                let status=raw.withUnsafeBytes{input in result.withUnsafeMutableBytes{output in
                    stream.next_in=UnsafeMutablePointer(mutating:input.baseAddress!.assumingMemoryBound(to:Bytef.self));stream.avail_in=uInt(raw.count)
                    stream.next_out=output.baseAddress!.assumingMemoryBound(to:Bytef.self);stream.avail_out=uInt(max(1,size));return inflate(&stream,Z_FINISH)
                }}
                guard status==Z_STREAM_END,Int(stream.total_out)==size else{throw ModLoadError.invalid};raw=Data(result.prefix(size))
            } else{guard raw.count>=size else{throw ModLoadError.invalid};raw=Data(raw.prefix(size))}
            rows.append(.init(name:name,data:raw));at=zero+1+entrySize;guard at<=header.count else{throw ModLoadError.invalid}
        }
        let sorted=regions.sorted{$0.lowerBound<$1.lowerBound}
        for i in 1..<max(1,sorted.count){guard sorted[i-1].upperBound<=sorted[i].lowerBound else{throw ModLoadError.invalid}}
        return rows
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
