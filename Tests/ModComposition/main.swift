import Foundation
import CryptoKit
let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
func require(_ v:Bool){precondition(v)}
func reject(_ f:()throws->Void){do{try f();fatalError("Invalid input accepted")}catch{}}
typealias F=ModFormats
let objects=[F.ObjectSet(id:43,name:"MODEL",file:"model_obj.bin",texture:"model_tex.bin",archive:"model.farc",objects:[.init(id:8,name:"BODY")])]
let ob=try F.objectData(objects);require(try F.u(ob,0)==1);require(try F.u(ob,8)==32);require(try F.objects(ob)==objects)
let aliases=[F.Named(id:5,name:"texture"),F.Named(id:5,name:"texture_alias"),F.Named(id:6,name:"texture")]
require(try F.textures(F.textureData(aliases))==aliases)
let sets=[F.SpriteSet(id:91,name:"SPR_UI",file:"spr_ui.bin",members:[.init(id:9,name:"SPRTEX_UI",index:12,texture:true),.init(id:10,name:"SPRITE_UI",index:1,texture:false)])]
require(try F.sprites(F.spriteData(sets))==sets)
let arc=try F.archiveData([.init(name:"example.txt",data:Data("payload".utf8)),.init(name:"unknown.bin",data:Data([1,2,3]))])
let parsed=try F.archive(arc);require(parsed.count==2 && parsed[1].data==Data([1,2,3]))
let gzip=Data(base64Encoded:"RkFyQwAAABYAAAAQZi50eHQAAAAAIAAAABoAAAAGAAAfiwgAAAAAAAL/y0jNycnnAgAgMDo2BgAAAA==")!
require(try F.archive(gzip).first?.data==Data("hello\n".utf8))
require(try F.gzip(Data()).count>0)
let opaque=try Data(contentsOf:root.appendingPathComponent("opaque-large.farc")),sourceEntries=try F.archiveIndex(opaque)
let sourceTexture=sourceEntries.first{$0.name.hasSuffix("_tex.bin")}!
let encodedTexture=opaque.subdata(in:try F.span(opaque,sourceTexture.offset,sourceTexture.packed))
let edited=try F.rewriteArchive(opaque,rename:{$0},edit:{_,_ in Data("edited object".utf8)})
let editedEntries=try F.archiveIndex(edited),editedTexture=editedEntries.first{$0.name.hasSuffix("_tex.bin")}!
require(editedTexture.expanded==150*1024*1024)
require(edited.subdata(in:try F.span(edited,editedTexture.offset,editedTexture.packed))==encodedTexture)
require(try F.archiveEntry(edited,editedEntries[0])==Data("edited object".utf8))
reject{_=try F.archiveEntry(edited,editedTexture)}
var broken=gzip;broken[broken.count-1]^=1;reject{_=try F.archive(broken)}
reject{_=try F.objects(Data(repeating:255,count:20))};reject{_=try F.sprites(Data(repeating:255,count:16))}
reject{_=try F.archive(Data(arc.prefix(13)))}
let props=["unknown":"preserve","module.0.id":"123","module.0.name":"モデル","module.data_list.length":"1"]
let changed=F.setGroup(props,"module",[["id":"124","name":"new"]],countKey:"module.data_list.length")
require(changed["unknown"]=="preserve" && changed["module.length"]==nil)
require(try F.properties(F.propertyData(changed))==changed)
var strings=Data(repeating:0,count:12)
for i in 0..<3 {try F.put(&strings,i*4,strings.count);strings.append(contentsOf:"row\(i)".utf8);strings.append(0)}
require(try F.strings(F.changeStrings(strings,[1:"初音ミク"]))==["row0","初音ミク","row2"])
reject{_=try F.changeStrings(strings,[0:"would change the table-size offset"])}
print("PASS: classic object/texture/sprite codecs; aliases; plain/gzip FARC; bounds/CRC rejection; property groups; string-table header preservation")

let suite="PJDV.MultiMods.Tests."+UUID().uuidString,defaults=UserDefaults(suiteName:"PJDV.MultiMods.Tests."+UUID().uuidString)!
let catalog=RuntimeModCatalog(root:root.appendingPathComponent("Ready"),defaults:defaults),base=root.appendingPathComponent("Base"),cache=root.appendingPathComponent("Cache")
func put(_ url:URL,_ data:Data)throws {try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)}
let marker=Data("baseline".utf8),baseCheck=RuntimeMod.Check(path:"rom/id.txt",bytes:8,sha256:F.sha(marker))
try put(base.appendingPathComponent(baseCheck.path),marker)
try put(base.appendingPathComponent("rom/data.txt"),Data("common=yes\na=old\nb=old\n".utf8))
func package(_ name:String,_ path:String,_ content:String)throws->RuntimeMod {
    try packageBytes(name,path,Data(content.utf8))
}
func packageBytes(_ name:String,_ path:String,_ raw:Data,format:String="pjdv-runtime-mod-v1")throws->RuntimeMod {
    let id=UUID(),file=RuntimeMod.Check(path:"0/"+path,bytes:UInt64(raw.count),sha256:F.sha(raw))
    let report=Data(name.utf8),sidecar=RuntimeMod.Check(path:"0/UI-FIX.json",bytes:UInt64(report.count),sha256:F.sha(report))
    let conversion:RuntimeMod.Conversion? = format=="pjdv-runtime-song-v1" ? .init(converter:"synthetic-test",profile:"movie-playlist",sourceSHA256:F.sha(raw),base:[baseCheck],dlc:[],dlcFolders:[]) : nil
    let item=RuntimeMod(format:format,id:id,name:name,notes:"This test report must never appear in the manager",layers:["0"],baseChecks:[baseCheck],files:[file,sidecar],conversion:conversion)
    try put(catalog.directory(item).appendingPathComponent(file.path),raw)
    try put(catalog.directory(item).appendingPathComponent(sidecar.path),report)
    try put(catalog.directory(item).appendingPathComponent("runtime.json"),JSONEncoder().encode(item));return item
}
let a=try package("A","rom/data.txt","common=yes\na=new\nb=old\n"),b=try package("B","rom/data.txt","common=yes\na=old\nb=new\n")
defaults.set(a.id.uuidString,forKey:"pjdv.runtimeMod.v1")
require(catalog.selectedIDs==[a.id]);try catalog.toggle(b.id)
require(Set(catalog.selectedIDs)==Set([a.id,b.id]));require(try catalog.selectedMods().count==2)
require(defaults.object(forKey:"pjdv.runtimeMod.v1")==nil)
let dlc=root.appendingPathComponent("DLC");try fm.createDirectory(at:dlc,withIntermediateDirectories:true)
// The single-package fast path must still reject changed payloads/baselines.
let single=try ModComposition.prepare([a],catalog:catalog,base:base,dlc:dlc,root:cache)
require(single.paths==[catalog.directory(a).appendingPathComponent("0").path] && single.profileID==a.id.uuidString)
let singlePayload=catalog.directory(a).appendingPathComponent("0/rom/data.txt")
let singleOriginal=try Data(contentsOf:singlePayload)
var singleCorrupt=singleOriginal;singleCorrupt[0]^=1;try singleCorrupt.write(to:singlePayload)
reject{_=try ModComposition.prepare([a],catalog:catalog,base:base,dlc:dlc,root:cache)}
try singleOriginal.write(to:singlePayload)
try Data("modified".utf8).write(to:base.appendingPathComponent(baseCheck.path))
reject{_=try ModComposition.prepare([a],catalog:catalog,base:base,dlc:dlc,root:cache)}
try marker.write(to:base.appendingPathComponent(baseCheck.path))
let first=try ModComposition.prepare([a,b],catalog:catalog,base:base,dlc:dlc,root:cache)
require(first.profileID==ModComposition.identity([b,a]))
let output=URL(fileURLWithPath:first.paths[0]).appendingPathComponent("rom/data.txt")
require(try F.properties(Data(contentsOf:output))==["common":"yes","a":"new","b":"new"])
require(!fm.fileExists(atPath:URL(fileURLWithPath:first.paths[0]).appendingPathComponent("UI-FIX.json").path))
let repeated=try ModComposition.prepare([b,a],catalog:catalog,base:base,dlc:dlc,root:cache)
require(repeated.paths==first.paths)
// Corrupt only generated cache metadata, never a hard-linked package asset.
var damaged=try Data(contentsOf:output);damaged[0]^=1;try damaged.write(to:output)
let rebuilt=try ModComposition.prepare([a,b],catalog:catalog,base:base,dlc:dlc,root:cache)
require(rebuilt.paths==first.paths);require(try F.properties(Data(contentsOf:output))["common"]=="yes")
let c=try package("C","rom/data.txt","common=yes\na=conflicting\nb=old\n")
reject{_=try ModComposition.prepare([a,c],catalog:catalog,base:base,dlc:dlc,root:cache)}
require(try F.properties(Data(contentsOf:output))["a"]=="new")
let folders=try fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
require(!folders.contains{$0.lastPathComponent.hasPrefix(".building-")})
let progress=Progress();progress.cancel()
reject{_=try ModComposition.prepare([a,b],catalog:catalog,base:base,dlc:dlc,root:cache,progress:progress)}
require(try String(contentsOf:catalog.directory(a).appendingPathComponent("0/rom/data.txt"),encoding:.utf8)=="common=yes\na=new\nb=old\n")
require(try Data(contentsOf:base.appendingPathComponent(baseCheck.path))==marker)
try catalog.toggle(a.id);require(catalog.selectedIDs==[b.id]);catalog.select(nil);require(catalog.selectedIDs.isEmpty)
print("PASS: single-selection migration; independent toggles; canonical combination identity; native property delta merge; cache reuse/rebuild; conflict/cancellation rollback; source preservation")

let spritePath="rom_switch/rom/2d/spr_db.bin"
let baseline=F.SpriteSet(id:1,name:"SPR_BASE",file:"base.bin",members:[.init(id:10,name:"BASE",index:0,texture:true)])
try put(base.appendingPathComponent(spritePath),F.spriteData([baseline]))
let atlasA=F.SpriteSet(id:2,name:"SPR_A",file:"a.bin",members:[.init(id:200,name:"SHARED_NAME",index:0,texture:true)])
let atlasB=F.SpriteSet(id:3,name:"SPR_B",file:"b.bin",members:[.init(id:201,name:"SHARED_NAME",index:4,texture:true),.init(id:200,name:"SHARED_NAME",index:7,texture:true)])
let sa=try packageBytes("Atlas A",spritePath,F.spriteData([baseline,atlasA]))
let sb=try packageBytes("Atlas B",spritePath,F.spriteData([baseline,atlasB]))
let sprites=try ModComposition.prepare([sa,sb],catalog:catalog,base:base,dlc:dlc,root:cache)
let merged=try F.sprites(Data(contentsOf:URL(fileURLWithPath:sprites.paths[0]).appendingPathComponent(spritePath)))
require(merged.contains(atlasA) && merged.contains(atlasB))
let collision=F.SpriteSet(id:4,name:"SPR_BAD",file:"bad.bin",members:[.init(id:200,name:"UNRELATED",index:0,texture:true)])
let bad=try packageBytes("Bad atlas",spritePath,F.spriteData([baseline,collision]))
reject{_=try ModComposition.prepare([sa,bad],catalog:catalog,base:base,dlc:dlc,root:cache)}
print("PASS: cross-atlas name aliases and local indices preserved; unrelated sprite-ID collisions rejected; converter reports excluded")

// A later DLC DB can replace the base lookup although it has no local atlas.
// Use a tiny synthetic image to cover that real load-order failure.
let thumbBase=root.appendingPathComponent("ThumbBase"),thumbDLC=root.appendingPathComponent("ThumbDLC"),thumbInput=root.appendingPathComponent("ThumbInput")
var tiny=Data(repeating:0,count:96)
for (i,v) in [0,96,1,1,32,84,92,72].enumerated(){try F.put(&tiny,i*4,v)}
try F.put(&tiny,32+32,Int(Float(1).bitPattern));try F.put(&tiny,32+36,Int(Float(1).bitPattern))
tiny.replaceSubrange(80..<84,with:Data("FIX\0".utf8));try F.put(&tiny,84,80)
tiny.replaceSubrange(88..<92,with:Data("001\0".utf8));try F.put(&tiny,92,88)
let tinyTexture:[UInt32]=[0x03505854,1,0x01010101,16,0x04505854,1,0x01010101,16,0x02505854,1,1,2,0,4,0xff0000ff]
for v in tinyTexture{var v=v.littleEndian;withUnsafeBytes(of:&v){tiny.append(contentsOf:$0)}}
let originalThumb=try F.SpritePayload(tiny)
var expandedThumb=originalThumb;_=try expandedThumb.add(from:originalThumb,index:0,name:"871",texturePrefix:"NEW_")
let thumbRow=F.SpriteSet(id:99,name:"SPR_SEL_PVTMB",file:"spr_sel_pvtmb.bin",members:[.init(id:1000,name:"SPRTEX_SEL_PVTMB_FIX",index:0,texture:true),.init(id:1001,name:"SPR_SEL_PVTMB_001",index:0,texture:false)])
var expandedRow=thumbRow;expandedRow.members += [.init(id:2000,name:"SPRTEX_SEL_PVTMB_NEW_0",index:1,texture:true),.init(id:2001,name:"SPR_SEL_PVTMB_871",index:1,texture:false)]
let thumbArchive="rom_switch/rom/2d/spr_sel_pvtmb.farc",dlcSprite="rom_switch_dlc/dlc18/rom/2d/spr_db.bin"
try put(thumbBase.appendingPathComponent(spritePath),F.spriteData([thumbRow]))
try put(thumbDLC.appendingPathComponent("dlc18/"+dlcSprite),F.spriteData([thumbRow]))
try put(thumbBase.appendingPathComponent(thumbArchive),F.archiveData([.init(name:thumbRow.file,data:originalThumb.data())]))
var thumbFiles=[String:ModComposition.File]()
for (rel,data) in [(spritePath,try F.spriteData([expandedRow])),(dlcSprite,try F.spriteData([thumbRow])),(thumbArchive,try F.archiveData([.init(name:thumbRow.file,data:expandedThumb.data())]))] {
    let url=thumbInput.appendingPathComponent(rel);try put(url,data);thumbFiles[rel] = .init(url:url,check:.init(path:rel,bytes:UInt64(data.count),sha256:F.sha(data)))
}
let thumbItem=RuntimeMod(format:"pjdv-runtime-song-v1",id:UUID(),name:"Synthetic movie song",notes:"",layers:["0"],baseChecks:[],files:[])
let thumbWorker=try ModComposition.Worker(packs:[.init(thumbItem,thumbFiles)],base:thumbBase,dlc:thumbDLC,output:root.appendingPathComponent("ThumbOutput"),progress:Progress())
try fm.createDirectory(at:thumbWorker.output,withIntermediateDirectories:true);try thumbWorker.build()
let thumbDB=try F.sprites(Data(contentsOf:thumbWorker.output.appendingPathComponent(spritePath)))
let lastDB=try F.sprites(Data(contentsOf:thumbWorker.output.appendingPathComponent(dlcSprite)))
require(thumbDB==lastDB && thumbDB[0].members.contains(where:{$0.name=="SPR_SEL_PVTMB_871"}))
let actualThumb=try F.SpritePayload(F.archive(Data(contentsOf:thumbWorker.output.appendingPathComponent(thumbArchive)))[0].data)
let newTexture=thumbDB[0].members.first{$0.texture && $0.index==1}!
require(newTexture.name=="SPRTEX_SEL_PVTMB_"+actualThumb.textureNames[1])
require(actualThumb.sprites[0]==originalThumb.sprites[0] && actualThumb.textures[0].starts(with:originalThumb.textures[0]))
// Converted output must remain composable: its DLC lookup is now expanded,
// still without a local atlas. Exercise the second merge used by the App.
let convertedFiles=Dictionary(uniqueKeysWithValues:thumbWorker.records.map{($0.path,ModComposition.File(url:thumbWorker.output.appendingPathComponent($0.path),check:$0))})
let secondThumbWorker=try ModComposition.Worker(packs:[.init(thumbItem,convertedFiles)],base:thumbBase,dlc:thumbDLC,output:root.appendingPathComponent("ThumbReoutput"),progress:Progress())
try fm.createDirectory(at:secondThumbWorker.output,withIntermediateDirectories:true);try secondThumbWorker.build()
let secondDB=try F.sprites(Data(contentsOf:secondThumbWorker.output.appendingPathComponent(dlcSprite)))
require(secondDB[0].members.contains(where:{$0.name=="SPR_SEL_PVTMB_871"}))
print("PASS: later DLC thumbnail lookup without local atlas; converted-package recomposition; texture labels match payload; original images preserved")

// Independent native movie-song packages patch the same full playlist. The
// composition must retain both additions without overwriting native records.
let playlistPath="rom_ps4/rom/gm_pv_list_tbl.farc",nativeSong=["id":"2","name":"Native","hard.length":"1"]
func playlist(_ rows:[[String:String]],extra:Data=Data([7,8]))throws->Data {
    try F.archiveData([.init(name:"gm_pv_list.bin",data:F.propertyData(F.setGroup(["unknown":"keep"],"pv_list",rows,countKey:"pv_list.data_list.length"))),.init(name:"opaque.bin",data:extra)])
}
try put(base.appendingPathComponent(playlistPath),playlist([nativeSong]))
let movieA=["id":"800","name":"First","hard.length":"1"],movieB=["id":"801","name":"Second","extreme.length":"1"]
func moviePackage(_ name:String,_ rows:[[String:String]],extra:Data=Data([7,8]))throws->RuntimeMod {
    try packageBytes(name,playlistPath,playlist(rows,extra:extra),format:"pjdv-runtime-song-v1")
}
let pa=try moviePackage("Movie A",[nativeSong,movieA]),pb=try moviePackage("Movie B",[nativeSong,movieB])
let movies=try ModComposition.prepare([pa,pb],catalog:catalog,base:base,dlc:dlc,root:cache)
let movieArchive=try F.archive(Data(contentsOf:URL(fileURLWithPath:movies.paths[0]).appendingPathComponent(playlistPath)))
let movieProps=try F.properties(movieArchive.first{$0.name=="gm_pv_list.bin"}!.data)
require(F.group(movieProps,"pv_list")==[nativeSong,movieA,movieB] && movieProps["unknown"]=="keep")
require(movieArchive.first{$0.name=="opaque.bin"}!.data==Data([7,8]))
require(try ModComposition.prepare([pb,pa],catalog:catalog,base:base,dlc:dlc,root:cache).paths==movies.paths)
let same=try moviePackage("Same identity",[nativeSong,movieA])
_=try ModComposition.prepare([pa,pb,same],catalog:catalog,base:base,dlc:dlc,root:cache)
let clash=try moviePackage("Collision",[nativeSong,["id":"800","name":"Wrong"]])
let removed=try moviePackage("Deleted baseline",[movieB])
let altered=try moviePackage("Changed native",[["id":"2","name":"Changed"],movieB])
let opaqueChange=try moviePackage("Changed opaque",[nativeSong,movieB],extra:Data([9]))
for bad in [clash,removed,altered,opaqueChange] {reject{_=try ModComposition.prepare([pa,bad],catalog:catalog,base:base,dlc:dlc,root:cache)}}
require(try Data(contentsOf:base.appendingPathComponent(playlistPath))==playlist([nativeSong]))
print("PASS: independent movie playlists merged by stable song ID; reverse selection and duplicates; native/opaque preservation; collision/deletion/unknown-member rejection")
