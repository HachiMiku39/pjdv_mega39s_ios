import Foundation
typealias F=ModFormats
let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
func require(_ v:Bool){precondition(v)}
func rejects(_ f:()throws->Void){do{try f();fatalError("Invalid input accepted")}catch{}}
func put(_ path:URL,_ b:Data)throws{try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try b.write(to:path)}
func props(_ d:[String:String])throws->Data{try F.propertyData(d)}
func farc(_ name:String,_ d:[String:String])throws->Data{try F.archiveData([.init(name:name,data:F.propertyData(d))])}
let base=root.appendingPathComponent("Base"),dlc=root.appendingPathComponent("DLC"),source=root.appendingPathComponent("Raw/Model")
let rel="rom_switch/rom/"
try put(base.appendingPathComponent(rel+"objset/obj_db.bin"),F.objectData([.init(id:1,name:"BASE",file:"base_obj.bin",texture:"base_tex.bin",archive:"base.farc",objects:[])]))
try put(base.appendingPathComponent(rel+"objset/tex_db.bin"),F.textureData([.init(id:1,name:"base")]))
try put(base.appendingPathComponent(rel+"chritm_prop.farc"),farc("mikitm_tbl.txt",["item.0.no":"0","item.length":"1","cos.0.id":"0","cos.0.item.length":"1","cos.0.item.0":"0","cos.length":"1"]))
try put(base.appendingPathComponent(rel+"gm_module_tbl.farc"),farc("gm_module_id.bin",["module.0.id":"2","module.0.name":"Base","module.0.chara":"MIKU","module.0.cos":"COS_001","module.data_list.length":"1"]))
let originalSprite=F.SpriteSet(id:1,name:"SPR_BASE",file:"base.bin",members:[.init(id:1,name:"BASE",index:0,texture:false)])
try put(base.appendingPathComponent(rel+"2d/spr_db.bin"),F.spriteData([originalSprite]))
var strings=Data(repeating:0,count:240*4)
for i in 0..<240{try F.put(&strings,i*4,strings.count);strings.append(contentsOf:"Base\(i)".utf8);strings.append(0)}
try put(base.appendingPathComponent(rel+"lang2/cn/str_array.bin"),strings)
let dlcTable=dlc.appendingPathComponent("one/rom_switch_dlc/dlc01/rom/objset/tex_db.bin")
let dlcBefore=try F.textureData([.init(id:8,name:"dlc")]);try put(dlcTable,dlcBefore)
let dlcSpritePath="rom_switch_dlc/dlc01/rom/2d/spr_db.bin"
let dlcSprite=F.SpriteSet(id:9,name:"SPR_DLC",file:"dlc.bin",members:[.init(id:9,name:"DLC",index:0,texture:false)])
try put(dlc.appendingPathComponent("one/"+dlcSpritePath),F.spriteData([dlcSprite]))
try put(source.appendingPathComponent("config.toml"),Data("name=\"Synthetic\"".utf8))
try put(source.appendingPathComponent("rom/objset/mod_obj_db.bin"),F.objectData([.init(id:100,name:"MODEL",file:"model_obj.bin",texture:"model_tex.bin",archive:"model.farc",objects:[])]))
try put(source.appendingPathComponent("rom/objset/mod_tex_db.bin"),F.textureData([.init(id:100,name:"model")]))
var object=Data(repeating:0,count:40);try F.put(&object,28,36);try F.put(&object,32,1);try F.put(&object,36,100)
var texture=Data(repeating:0,count:32);try F.put(&texture,4,1);try F.put(&texture,12,16);try F.put(&texture,16,7);try F.put(&texture,24,8)
try put(source.appendingPathComponent("rom/objset/model.farc"),F.archiveData([.init(name:"model_obj.bin",data:object),.init(name:"model_tex.bin",data:texture)]))
try put(source.appendingPathComponent("rom/mod_chritm_prop.farc"),farc("mikitm_tbl.txt",["item.0.no":"100","item.0.objset.0":"MODEL","item.0.objset.length":"1","item.length":"1","cos.0.id":"50","cos.0.item.length":"1","cos.0.item.0":"100","cos.length":"1"]))
try put(source.appendingPathComponent("rom/mod_gm_module_tbl.farc"),farc("gm_module_id.bin",["module.0.id":"100","module.0.name":"Fixture Model","module.0.chara":"MIKU","module.0.cos":"COS_051","module.data_list.length":"1"]))
let portrait=F.SpriteSet(id:500,name:"SPR_SEL_MD100CMN",file:"spr_sel_md100cmn.bin",members:[.init(id:501,name:"SPR_SEL_MD100CMN_MD_IMG",index:0,texture:false)])
try put(source.appendingPathComponent("rom/2d/mod_spr_db.bin"),F.spriteData([portrait]))
try put(source.appendingPathComponent("rom/2d/spr_sel_md100cmn.farc"),F.archiveData([.init(name:portrait.file,data:Data([1,2,3]))]))
try put(source.appendingPathComponent("rom/lang2/mod_str_array.toml"),Data("375 = \"Model\"\ncn.375 = \"测试角色\"\n".utf8))
let before=try PCModelConverter.baseline(base:base,dlc:dlc,progress:Progress())
var checks=[RuntimeMod.Check]()
for case let p as URL in fm.enumerator(at:source.appendingPathComponent("rom"),includingPropertiesForKeys:nil)! where (try? fm.attributesOfItem(atPath:p.path)[.type]) as? FileAttributeType == .typeRegular {
 let h=try PCModelConverter.hash(p,progress:Progress());checks.append(.init(path:String(p.path.dropFirst(source.path.count+1)),bytes:h.bytes,sha256:h.sha256))
}
let profile=PCModelConverter.Profile(id:"synthetic",name:"Synthetic model",files:checks)
let suite="PJDV.PCModel.Tests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
defer{defaults.removePersistentDomain(forName:suite)}
let catalog=RuntimeModCatalog(root:root.appendingPathComponent("Ready"),defaults:defaults)
let candidate=try PCModelConverter.recognize(source.deletingLastPathComponent(),profiles:[profile],progress:Progress())!
let first=try PCModelConverter.convert(candidate,base:base,dlc:dlc,catalog:catalog,progress:Progress())
require(!first.reused && catalog.selectedIDs.isEmpty && first.item.format=="pjdv-runtime-model-v1")
let paths=try catalog.overlayPaths(first.item,base:base,dlc:dlc),output=URL(fileURLWithPath:paths[0])
let modules=try F.archive(F.read(output.appendingPathComponent(rel+"gm_module_tbl.farc"))).flatMap{try F.group(F.properties($0.data),"module")}
let added=modules.first{$0["name"]=="Fixture Model"}!;let id=Int(added["id"]!)!
require(try F.strings(F.read(output.appendingPathComponent(rel+"lang2/cn/str_array.bin")))[id+220]=="测试角色")
let previews=try F.sprites(F.read(output.appendingPathComponent(rel+"2d/spr_db.bin")))
for name in [String(format:"SPR_SEL_MD%03dCMN",id),String(format:"SPR_CMNITM_THMB%03d",id)]{require(previews.contains{$0.name==name})}
let dlcPreviews=try F.sprites(F.read(output.appendingPathComponent(dlcSpritePath)))
require(dlcPreviews.contains(dlcSprite))
for name in [String(format:"SPR_SEL_MD%03dCMN",id),String(format:"SPR_CMNITM_THMB%03d",id)] {
 let row=dlcPreviews.first{$0.name==name}!;require(fm.fileExists(atPath:output.appendingPathComponent((dlcSpritePath as NSString).deletingLastPathComponent+"/"+(row.file as NSString).deletingPathExtension+".farc").path))
}
let second=try PCModelConverter.convert(candidate,base:base,dlc:dlc,catalog:catalog,progress:Progress())
require(second.reused && second.item.id==first.item.id)
require(try PCModelConverter.identity(candidate,before)==first.item.id)
let manifest=catalog.directory(first.item).appendingPathComponent("runtime.json"),storedManifest=try Data(contentsOf:manifest)
var altered=try JSONSerialization.jsonObject(with:storedManifest) as! [String:Any],receipt=altered["conversion"] as! [String:Any]
receipt["converter"]="wrong-revision";altered["conversion"]=receipt;try JSONSerialization.data(withJSONObject:altered).write(to:manifest)
rejects{_=try PCModelConverter.convert(candidate,base:base,dlc:dlc,catalog:catalog,progress:Progress())}
try storedManifest.write(to:manifest)
print("PASS: native raw-model conversion, wrapper, localized labels, both portraits, deterministic identity, reuse and no implicit activation")
// Every failure below leaves the installed model, original payload and selection intact.
let cancelled=Progress();cancelled.cancel();rejects{_=try PCModelConverter.convert(candidate,base:base,dlc:dlc,catalog:catalog,progress:cancelled)}
let src=source.appendingPathComponent("rom/objset/model.farc"),sourceBefore=try Data(contentsOf:src)
var bad=sourceBefore;bad[bad.count-1]^=1;try bad.write(to:src)
require(try PCModelConverter.recognize(source,profiles:[profile],progress:Progress())==nil)
try sourceBefore.write(to:src)
try put(source.appendingPathComponent("inject.dll"),Data([77,90]));require(try PCModelConverter.recognize(source,profiles:[profile],progress:Progress())==nil);try fm.removeItem(at:source.appendingPathComponent("inject.dll"))
let sym=root.appendingPathComponent("Symbolic");try fm.createSymbolicLink(at:sym,withDestinationURL:source)
// A root selected through a trusted ancestor alias is normalized, but an asset symlink is rejected.
let asset=source.appendingPathComponent("rom/symlink");try fm.createSymbolicLink(at:asset,withDestinationURL:src)
rejects{_=try PCModelConverter.recognize(source,profiles:[profile],progress:Progress())};try fm.removeItem(at:asset)
var changed=dlcBefore;changed[changed.count-1]^=1;try changed.write(to:dlcTable)
rejects{_=try catalog.overlayPaths(first.item,base:base,dlc:dlc)};try dlcBefore.write(to:dlcTable)
let more=dlc.appendingPathComponent("new");try fm.createDirectory(at:more,withIntermediateDirectories:true)
rejects{_=try catalog.overlayPaths(first.item,base:base,dlc:dlc)};try fm.removeItem(at:more)
require(try catalog.overlayPaths(first.item,base:base,dlc:dlc)==paths)
let after=try PCModelConverter.baseline(base:base,dlc:dlc,progress:Progress());require(try PCModelConverter.identity(candidate,after)==first.item.id)
require(try Data(contentsOf:src)==sourceBefore && catalog.selectedIDs.isEmpty)
require(!(try fm.contentsOfDirectory(at:catalog.root,includingPropertiesForKeys:nil)).contains{$0.lastPathComponent.hasPrefix(".converting-")})
rejects{_=try PCModelConverter.translations(Data("cn.1 = \"a\"\ncn.1 = \"b\"".utf8))}
rejects{_=try PCModelConverter.translations(Data("[cn]\n1='unsupported'".utf8))}
require(try PCModelConverter.translations(Data("cn.1 = \"a\\nb\"".utf8))["cn"]?[1]=="a\nb")
print("PASS: cancellation, source mutation, unknown DLL, asset symlink, changed DLC metadata/folders, rollback, strict translation parsing and source preservation")
