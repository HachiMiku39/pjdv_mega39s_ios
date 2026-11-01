import Foundation
try ModFormats.ivfTimebase(rate:5_114_000,scale:213_043)
try ModFormats.ivfTimebase(rate:1000,scale:1)
for (rate,scale) in [(0,1),(30,0),(Int(Int32.max)+1,1),(30,1_000_001)] {
    do {try ModFormats.ivfTimebase(rate:rate,scale:scale);fatalError("Invalid movie timebase accepted")} catch {}
}
print("PASS: fractional IVF timebase accepted within CMTime bounds; zero/overflow and unsafe denominator rejected")
func require(_ value:Bool){precondition(value)}
func reject(_ f:()throws->Void){do{try f();fatalError("Unsupported chart accepted")}catch{}}
func chart(_ words:[UInt32])->Data {var b=Data();for word in words {var v=word.littleEndian;withUnsafeBytes(of:&v){b.append(contentsOf:$0)}};return b}
// One complete, synthetic movie chart, independent of copyrighted song payloads.
let valid:[UInt32]=[0x12020220,1,0,14,1,4,0,0,25,67,1,68,1,1,100000,58,500000,6,0,1,2,3,4,5,6,32,0]
try PCSongConverter.validateVideoChart(chart(valid))
var nativeHeader=valid;nativeHeader[0]=0x14050921
try PCSongConverter.validateVideoChart(chart(nativeHeader))
reject{try PCSongConverter.validateVideoChart(chart(Array(nativeHeader.dropLast(2))+[999,0]))}
let difficultyFixture=["pv_701.difficulty.easy.length":"0","pv_701.difficulty.easy.0.script_file_name":"rom/script/missing-placeholder.dsc","pv_701.difficulty.hard.length":"1","pv_701.difficulty.hard.0.script_file_name":"rom/script/hard.dsc"]
let scripts=try PCSongConverter.activeScripts(difficultyFixture,prefix:"pv_701.")
require(scripts==["pv_701.difficulty.hard.0.script_file_name":"rom/script/hard.dsc"])
reject{_=try PCSongConverter.activeScripts(["pv_701.difficulty.hard.length":"1"],prefix:"pv_701.")}
reject{_=try PCSongConverter.activeScripts(["pv_701.difficulty.hard.length":"-1"],prefix:"pv_701.")}
let movieFiles:Set<String>=["rom/movie/test.mp4","rom/movie/test.usm"]
require(try PCSongConverter.movieInput("rom/movie/test.mp4",available:movieFiles)=="rom/movie/test.mp4")
require(try PCSongConverter.movieInput("rom/movie/test.mp4",available:["rom/movie/test.usm"])=="rom/movie/test.usm")
reject{_=try PCSongConverter.movieInput("rom/movie/test.mp4",available:["rom/movie/different.usm"])}
reject{_=try PCSongConverter.movieInput("rom/movie/../private.mp4",available:movieFiles)}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,6,0,1]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,999,0]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,1,100,1,99,0]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,6,30,1,2,3,4,5,6,0]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,14,2,0]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,4,0,1,0]))}
reject{try PCSongConverter.validateVideoChart(chart([0x12020220,0,123]))}
reject{try PCSongConverter.validateVideoChart(chart([0x15122517,0]))}
reject{try PCSongConverter.validateVideoChart(Data(chart(valid).dropLast()))}
let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1]);try fm.createDirectory(at:root.appendingPathComponent("rom"),withIntermediateDirectories:true)
try Data("name = \"Unseen song pack\"\n".utf8).write(to:root.appendingPathComponent("config.toml"))
try Data("pv_701.song_name=Test\r\n".utf8).write(to:root.appendingPathComponent("rom/mod_pv_db.txt"))
let candidate=try PCSongConverter.recognize(root,progress:Progress())!
require(candidate.profile.name=="Unseen song pack" && candidate.profile.id==PCSongConverter.profile)
require(PCSongConverter.safeAsset("rom/movie/pv_701.usm"))
for p in ["rom/../private","rom//movie/x","rom/movie/.hidden","rom/movie/a:b","rom\\movie\\x"]{require(!PCSongConverter.safeAsset(p))}
try Data([0]).write(to:root.appendingPathComponent("plugin.dll"))
reject{_=try PCSongConverter.recognize(root,progress:Progress())}
let cancelled=Progress();cancelled.cancel();reject{_=try PCSongConverter.recognize(root,progress:cancelled)}
// A jacket crop must have matching texture pixels, pixel rectangle and UVs.
// These fixtures contain no game assets and catch the former blank thumbnail.
func txp(_ format:Int,_ pixels:Data)throws->Data {
    var b=Data(repeating:0,count:40)
    for (i,v) in [0x04505854,1,0x01010101,16,0x02505854,4,4,format,0,pixels.count].enumerated(){try ModFormats.put(&b,i*4,v)}
    b.append(pixels);return b
}
var sprite=Data(repeating:0,count:40)
let rectangle:[(Int,Float)]=[(24,0),(28,0),(32,4),(36,4)]
for (o,v) in rectangle{try ModFormats.put(&sprite,o,Int(v.bitPattern))}
var pixels=Data();for y in 0..<4{for x in 0..<4{pixels.append(contentsOf:[UInt8(x*50),UInt8(y*50),0,255])}}
let thumb=try ModFormats.SpritePayload.thumbnail(txp(2,pixels),sprite:sprite,width:4,height:2)
require(Array(thumb[40..<44])==[0,50,0,255] && Array(thumb[68..<72])==[150,100,0,255])
var topSprite=sprite;try ModFormats.put(&topSprite,36,Int(Float(2).bitPattern))
let topCrop=try ModFormats.SpritePayload.thumbnail(txp(2,pixels),sprite:topSprite,width:4,height:2)
require(topCrop[41]==100 && topCrop[57]==150) // SPR top maps to stored bottom.
// One opaque red BC3 block, independently encoded from RGB565 endpoints.
let bc3=Data([255,0,0,0,0,0,0,0,0,248,0,0,0,0,0,0])
let red=try ModFormats.SpritePayload.thumbnail(txp(9,bc3),sprite:sprite,width:4,height:2)
require(stride(from:40,to:red.count,by:4).allSatisfy{Array(red[$0..<$0+4])==[255,0,0,255]})
var layout=Data();for y in 0..<4{for x in 0..<4{layout.append(contentsOf:[0,255,0,x>=y/2 ? 255:0])}}
let framed=try ModFormats.SpritePayload.framedThumbnail(txp(9,bc3),sprite:sprite,layoutTexture:txp(2,layout),layoutSprite:sprite,width:4,height:4)
for i in 0..<16 {require(framed[40+i*4+3]==layout[i*4+3]);if layout[i*4+3]>0{require(Array(framed[40+i*4..<43+i*4])==[255,0,0])}}
reject{_=try ModFormats.SpritePayload.thumbnail(txp(15,bc3),sprite:sprite,width:4,height:2)}
reject{_=try ModFormats.SpritePayload.thumbnail(Data(thumb.dropLast()),sprite:sprite,width:4,height:2)}
func fontFixture(_ codes:[UInt16],geometry:Int=36)throws->Data {
    var b=Data(repeating:0,count:96+codes.count*8*2)
    try ModFormats.put(&b,8,2);try ModFormats.put(&b,12,16)
    for (i,id) in [15,17].enumerated() {
        let row=32+i*32,chars=96+i*codes.count*8
        try ModFormats.put(&b,16+i*4,row);try ModFormats.put(&b,row,id)
        try ModFormats.put(&b,row+4,geometry);try ModFormats.put(&b,row+8,38);try ModFormats.put(&b,row+12,1)
        try ModFormats.put(&b,row+16,215);try ModFormats.put(&b,row+20,codes.count);try ModFormats.put(&b,row+24,chars)
        for (j,c) in codes.enumerated(){try ModFormats.put(&b,chars+j*8,Int(c),2);try ModFormats.put(&b,chars+j*8+2,j,2)}
    };return b
}
let originalFont=try fontFixture([65,66]),suppliedFont=try fontFixture([65,66,0x7f8e])
let pairedFont=try ModFormats.pairedFontMap(originalFont,source:suppliedFont,required:[0x7f8e])
for row in [32,64] {
    require(try ModFormats.u(pairedFont,row+20)==3)
    let offset=try ModFormats.u(pairedFont,row+24)
    require(try ModFormats.u(pairedFont,offset+16,2)==0x7f8e)
    require(pairedFont[row+4..<row+16]==originalFont[row+4..<row+16])
}
reject{_=try ModFormats.pairedFontMap(originalFont,source:fontFixture([65,0x7f8e]),required:[0x7f8e])}
reject{_=try ModFormats.pairedFontMap(originalFont,source:fontFixture([65,66],geometry:35),required:[])}
reject{_=try ModFormats.pairedFontMap(originalFont,source:suppliedFont,required:[0x7f8f])}
reject{_=try ModFormats.pairedFontMap(originalFont,source:fontFixture([65,65]),required:[])}
reject{_=try ModFormats.pairedFontMap(Data(originalFont.prefix(20)),source:suppliedFont,required:[])}
print("PASS: complete movie DSC; truncation/unknown opcode/New Classics target/time rewind/stage dependency rejection; structural song discovery; unsafe paths/executable rejection; cancellation; RGBA/BC3 thumbnail pixels/crop and malformed texture rejection")
print("PASS: native DSC header, inactive difficulty placeholders, exact movie sibling fallback; supplied CJK map pairing, native-character/geometry preservation and missing/duplicate/truncated glyph rejection")
