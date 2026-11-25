import Foundation
import CoreGraphics
import CoreText

/// The text renderer samples single-level DXT5 sprites from FMH3 character records.
/// Add records and paint unused atlas rows. Existing character UVs, widths and
/// DXT blocks keep their original values, including out-of-scope menu text.
enum GameTextFontAtlas {
    typealias F = ModFormats
    static let cell = 38
    enum Family: Int, CaseIterable {
        case japanese, traditional, simplified, korean
        var suffix: String {
            switch self { case .japanese: return ""; case .traditional: return "cn"
            case .simplified: return "cn2"; case .korean: return "kr" }
        }
        init?(map: Int) {
            switch map { case 15, 17: self = .japanese; case 16: self = .traditional
            case 18: self = .simplified; case 19: self = .korean; default: return nil }
        }
    }

    struct Row {
        let offset: Int
        let family: Family
        let columns: Int
        let codes: Set<UInt16>
        let records: [Data]
        let lastRow: Int
    }
    struct Map {
        let block: F.Block
        let rows: [Row]
        let usedCodes: Set<UInt16>
        init(archive: Data) throws {
            let blocks = try F.archive(archive)
            guard blocks.count == 1, blocks[0].data.starts(with: "FMH3".utf8) else { throw ModLoadError.unsupported }
            let b = blocks[0].data, n = try F.u(b,8), table = try F.u(b,12)
            guard (1...256).contains(n) else { throw ModLoadError.limit }
            _ = try F.span(b, table, n*4)
            var rows = [Row](), used = Set<UInt16>(), seen = Set<Int>()
            for i in 0..<n {
                let p = try F.u(b,table+4*i), id = try F.u(b,p)
                guard seen.insert(id).inserted else { throw ModLoadError.invalid }
                let cols = try F.u(b,p+16), count = try F.u(b,p+20), at = try F.u(b,p+24)
                guard count <= 65536 else { throw ModLoadError.limit }
                _ = try F.span(b,at,count*8)
                let family = Family(map:id)
                var records = [Data](), codes = Set<UInt16>(), last = -1
                for j in 0..<count {
                    let o = at+8*j, code = UInt16(try F.u(b,o,2))
                    used.insert(code)
                    guard let _ = family else { continue }
                    guard codes.insert(code).inserted, Int(b[o+4]) < cols else { throw ModLoadError.invalid }
                    records.append(b.subdata(in:o..<o+8))
                    last = max(last, Int(b[o+5]))
                }
                if let family {
                    guard (1...256).contains(cols), b[p+6] == cell, b[p+7] == cell else { throw ModLoadError.unsupported }
                    rows.append(Row(offset:p, family:family, columns:cols, codes:codes, records:records, lastRow:last))
                }
            }
            self.block = blocks[0]; self.rows = rows; self.usedCodes = used
        }

        func adding(_ glyphs: [Glyph], grids: [Family: Grid]) throws -> Data {
            var b = block.data
            for row in rows {
                guard let grid = grids[row.family] else { continue }
                var records = row.records
                for (i,g) in glyphs.enumerated() {
                    let code = g.alias, x = i % grid.cols, y = grid.firstRow + i/grid.cols
                    guard !row.codes.contains(code), x < row.columns, y <= 255 else { throw ModLoadError.limit }
                    records.append(Data([UInt8(truncatingIfNeeded:code), UInt8(code>>8), g.half ? 1 : 0, 0,
                                         UInt8(x), UInt8(y), g.left, g.width]))
                }
                records.sort { Int($0[0]) + 256 * Int($0[1]) < Int($1[0]) + 256 * Int($1[1]) }
                b.append(Data(repeating:0,count:(-b.count)&15))
                let at = b.count
                for record in records { b.append(record) }
                try F.put(&b,row.offset+20,records.count)
                try F.put(&b,row.offset+24,at)
            }
            return try GameTextFontAtlas.singleArchive(name:block.name, data:b)
        }
    }

    struct Grid {
        let cols: Int
        let firstRow: Int
        init(rows: [Row], textureColumns: Int = 256) throws {
            guard let columns = rows.map(\.columns).min(), let last = rows.map(\.lastRow).max() else { throw ModLoadError.invalid }
            guard textureColumns > 0 else { throw ModLoadError.unsupported }
            cols = min(columns,textureColumns)
            // A pair of 38px rows ends on a 4px DXT block boundary.
            firstRow = ((last+2)/2)*2
        }
        var capacity: Int { (256-firstRow)*cols }
    }
    struct Glyph {
        let source: Unicode.Scalar
        let alias: UInt16
        let path: CGPath
        let scale: CGFloat
        let scaleX: CGFloat
        let origin: CGPoint
        let half: Bool
        let left: UInt8
        let width: UInt8
    }

    static func glyphs(characters: Set<Unicode.Scalar>, fonts: [CTFont], occupied: Set<UInt16>,
                       original: Set<UInt16>, capacity: Int) -> [Glyph] {
        // Nintendo reserves the low PUA for controller icons (even when no row exists
        // in FMH3). Stay out of it and of the platform-specific high PUA.
        let free = (UInt16(0xe800)...UInt16(0xf7ff)).filter { !occupied.contains($0) }
        let ordered = characters.sorted { a,b in
            let aCovered = UInt16(exactly:a.value).map(original.contains) == true
            let bCovered = UInt16(exactly:b.value).map(original.contains) == true
            return aCovered == bCovered ? a.value < b.value : !aCovered
        }
        var result = [Glyph]()
        let system = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
        for c in ordered {
            guard result.count < min(free.count,capacity) else { break }
            guard c.value >= 0x21, !(0xe000...0xf8ff).contains(c.value),
                  !CharacterSet.whitespacesAndNewlines.contains(c), !CharacterSet.controlCharacters.contains(c),
                  !CharacterSet.nonBaseCharacters.contains(c) else { continue }
            let string = String(c), units = Array(string.utf16)
            var choices = fonts
            // Preserve an existing game glyph when none of the bundled faces
            // covers it. A system fallback is only useful for a genuinely missing character.
            if UInt16(exactly:c.value).map(original.contains) != true {
                choices.append(CTFontCreateForString(system, string as CFString, CFRange(location:0,length:units.count)))
            }
            for face in choices {
                var ids = [CGGlyph](repeating:0,count:units.count)
                _ = CTFontGetGlyphsForCharacters(face, units, &ids, units.count)
                guard let gid = ids.first(where:{$0 != 0}), let path = CTFontCreatePathForGlyph(face,gid,nil) else { continue }
                let bounds = path.boundingBoxOfPath
                guard !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { continue }
                let scale = min(1,34/bounds.width,34/bounds.height)
                var glyph = gid, advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(face,.horizontal,&glyph,&advance,1)
                // ASCII uses 18px advances in the guest even for wide letters like M
                // and W. Preserve that half/full distinction independently of the alias.
                let latin = (0x21...0x7e).contains(c.value) || (0xc0...0x24f).contains(c.value)
                let half = latin || (0xff61...0xffdc).contains(c.value) || advance.width*scale <= 18
                let advanceCell: CGFloat = half ? 18 : 36
                let horizontal = min(scale, (advanceCell-1)/bounds.width)
                let ink = bounds.width*horizontal
                let left = max(0,floor((advanceCell-ink)/2))
                let width = min(advanceCell-left,max(1,ceil(ink+1)))
                let originX = 1+left-bounds.minX*horizontal
                // Coordinates below are measured upwards from the bottom of the cell.
                let originY = min(37-bounds.maxY*scale,max(1-bounds.minY*scale,8))
                result.append(.init(source:c,alias:free[result.count],path:path,scale:scale,scaleX:horizontal,
                                    origin:.init(x:originX,y:originY),half:half,left:UInt8(left),width:UInt8(width)))
                break
            }
        }
        return result
    }

    /// DXT5 stores this font's white RGB and glyph coverage in alpha.
    /// Keep the input blocks for existing cells. Encode only complete new block rows.
    struct Band {
        let pixelWidth: Int
        let pixelHeight: Int
        let blocks: Data
        init(glyphs: [Glyph], grid: Grid, bold: Bool) throws {
            guard !glyphs.isEmpty else { throw ModLoadError.invalid }
            let width = (grid.cols*cell+3)&(~3)
            let height = (((glyphs.count+grid.cols-1)/grid.cols)*cell+3)&(~3)
            guard width*height <= 16*1024*1024,
                  let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,
                                      space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue),
                  let buffer = ctx.data else { throw ModLoadError.limit }
            ctx.setFillColor(gray:0,alpha:1); ctx.fill(CGRect(x:0,y:0,width:width,height:height))
            ctx.setFillColor(gray:1,alpha:1); ctx.setStrokeColor(gray:1,alpha:1)
            ctx.setShouldAntialias(true); ctx.setLineJoin(.round); ctx.setLineWidth(0.65)
            for (i,g) in glyphs.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x:CGFloat((i%grid.cols)*cell)+g.origin.x,
                                y:CGFloat(height-(i/grid.cols+1)*cell)+g.origin.y)
                ctx.scaleBy(x:g.scaleX,y:g.scale)
                ctx.addPath(g.path); ctx.drawPath(using:bold ? .fillStroke : .fill)
                ctx.restoreGState()
            }
            ctx.flush()
            let mask = buffer.assumingMemoryBound(to:UInt8.self)
            var data = Data(repeating:0,count:width*height)
            // Fixed BC3 endpoints give eight alpha levels without a blockwise
            // search. Pixel order in TXP is bottom-up; CoreGraphics memory is top-down.
            let palette = [255,0,218,182,145,109,72,36]
            let lookup = (0..<256).map { sample in
                (0..<8).min { abs(sample-palette[$0]) < abs(sample-palette[$1]) }!
            }
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let dst = raw.bindMemory(to:UInt8.self)
                for by in 0..<height/4 {
                    for bx in 0..<width/4 {
                        let at = (by*(width/4)+bx)*16
                        var bits: UInt64 = 0
                        for y in 0..<4 {
                            let row = (height-1-(by*4+y))*width+bx*4
                            for x in 0..<4 {
                                bits |= UInt64(lookup[Int(mask[row+x])]) << ((y*4+x)*3)
                            }
                        }
                        dst[at]=255
                        for k in 0..<6 { dst[at+2+k] = UInt8(truncatingIfNeeded:bits>>(8*k)) }
                        dst[at+8]=255;dst[at+9]=255;dst[at+10]=255;dst[at+11]=255
                    }
                }
            }
            self.pixelWidth=width;self.pixelHeight=height;self.blocks=data
        }
    }

    static func columns(in archive: Data) throws -> Int {
        let entries=try F.archive(archive)
        guard entries.count==1 else { throw ModLoadError.unsupported }
        let b=entries[0].data,tx=try F.u(b,4)
        guard try F.u(b,8)==1,try F.u(b,12)==1,try F.u(b,tx)==0x03505854 else { throw ModLoadError.unsupported }
        let texture=tx+(try F.u(b,tx+12))
        guard try F.u(b,texture)==0x04505854,try F.u(b,texture+12)==16,
              try F.u(b,texture+16)==0x02505854 else { throw ModLoadError.unsupported }
        let width=try F.u(b,texture+20)
        guard (cell...16384).contains(width) else { throw ModLoadError.unsupported }
        return width/cell
    }

    static func image(_ archive: Data, grid: Grid, band: Band) throws -> Data {
        let entries = try F.archive(archive)
        guard entries.count == 1 else { throw ModLoadError.unsupported }
        var set = try F.SpritePayload(entries[0].data)
        guard set.textures.count == 1, set.sprites.count == 1, set.names == ["DIVA_36_38"] else { throw ModLoadError.unsupported }
        var t = set.textures[0]
        guard try F.u(t,0)==0x04505854,try F.u(t,4)==1,try F.u(t,12)==16,
              try F.u(t,16)==0x02505854,try F.u(t,28)==9 else { throw ModLoadError.unsupported }
        let w=try F.u(t,20),h=try F.u(t,24),length=try F.u(t,36)
        guard (38...16384).contains(w),(38...16384).contains(h),w%4==0,h%4==0,
              length==w*h, t.count>=40+length, band.pixelWidth<=w else { throw ModLoadError.unsupported }
        let firstY=cell*grid.firstRow
        let newH=max(h,firstY+band.pixelHeight)
        guard newH<=16384,w*newH+4096<F.fileLimit else { throw ModLoadError.limit }
        if newH>h {
            // Glyph cell (0,0) is at the top of the texture, last in TXP memory.
            t.insert(contentsOf:repeatElement(UInt8(0),count:w*(newH-h)),at:40)
            try F.put(&t,24,newH);try F.put(&t,36,w*newH)
            try F.put(&set.sprites[0],36,Int(Float(newH).bitPattern))
        }
        let firstBlock=(newH-firstY-band.pixelHeight)/4
        t.withUnsafeMutableBytes { dest in
            band.blocks.withUnsafeBytes { src in
                for by in 0..<band.pixelHeight/4 {
                    let row=40+(firstBlock+by)*4*w
                    memcpy(dest.baseAddress!.advanced(by:row),src.baseAddress!.advanced(by:by*4*band.pixelWidth),4*band.pixelWidth)
                }
            }
        }
        set.textures[0]=t
        return try singleArchive(name:entries[0].name,data:set.data())
    }

    private static func singleArchive(name:String,data:Data)throws->Data {
        let packed=try F.gzip(data)
        let length=12+name.utf8.count+1+12
        let offset=(length+15)&(~15)
        var head=Data("FArC".utf8);head.append(Data(repeating:0,count:offset-4))
        try F.put(&head,4,length-8,4,true);try F.put(&head,8,16,4,true)
        head.replaceSubrange(12..<12+name.utf8.count,with:name.utf8)
        let p=13+name.utf8.count
        try F.put(&head,p,offset,4,true);try F.put(&head,p+4,packed.count,4,true);try F.put(&head,p+8,data.count,4,true)
        head.append(packed); head.append(Data(repeating:0,count:(-head.count)&15)); return head
    }
}
