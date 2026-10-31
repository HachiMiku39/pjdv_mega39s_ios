import Foundation
import CryptoKit
let fm=FileManager.default
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let suite="PJDV.RuntimeMod.Tests."+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer {defaults.removePersistentDomain(forName:suite)}
let catalog=RuntimeModCatalog(root:root.appendingPathComponent("Ready"),defaults:defaults)
let base=root.appendingPathComponent("Base"),id=UUID()
let hash=SHA256.hash(data:Data("valid".utf8)).map{String(format:"%02x",$0)}.joined()
let check=RuntimeMod.Check(path:"rom_switch/rom/pv_db.txt",bytes:5,sha256:hash)
let payload=RuntimeMod.Check(path:"0/rom_switch/rom/pv_db.txt",bytes:5,sha256:hash)
func item(layers:[String]=["0"],files:[RuntimeMod.Check]=[payload])->RuntimeMod {
 RuntimeMod(format:"pjdv-runtime-mod-v1",id:id,name:"Fixture",notes:"Isolated test",layers:layers,baseChecks:[check],files:files)
}
func put(_ url:URL,_ data:Data) throws {try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)}
func manifest(_ value:RuntimeMod) throws {try put(catalog.directory(value).appendingPathComponent("runtime.json"),JSONEncoder().encode(value))}
func require(_ value:Bool) {precondition(value)}
func fails(_ body:()throws->Void) {do {try body();fatalError("invalid MOD was accepted")}catch{}}
try put(base.appendingPathComponent(check.path),Data("valid".utf8))
try put(catalog.directory(item()).appendingPathComponent(payload.path),Data("valid".utf8))
try manifest(item())
require(try catalog.records().count == 1)
require(try catalog.selected() == nil)
catalog.select(id)
require(try catalog.selected()?.id == id)
require(try catalog.overlayPaths(item(),base:base).count == 1)
try put(base.appendingPathComponent(check.path),Data("wrong".utf8))
fails {_=try catalog.overlayPaths(item(),base:base)}
try put(base.appendingPathComponent(check.path),Data("valid".utf8))
try put(catalog.directory(item()).appendingPathComponent(payload.path),Data("wrong".utf8))
fails {_=try catalog.overlayPaths(item(),base:base)}
try put(catalog.directory(item()).appendingPathComponent(payload.path),Data("valid".utf8))
fails {_=try catalog.overlayPaths(item(layers:["../escape"]),base:base)}
fails {_=try catalog.overlayPaths(item(files:[payload,payload]),base:base)}
let path=catalog.directory(item()).appendingPathComponent("0")
try fm.moveItem(at:path,to:path.appendingPathExtension("saved"))
try fm.createSymbolicLink(at:path,withDestinationURL:base)
fails {_=try catalog.overlayPaths(item(),base:base)}
try fm.removeItem(at:path)
try fm.moveItem(at:path.appendingPathExtension("saved"),to:path)
catalog.select(nil)
require(try catalog.selected() == nil)
let alias=root.appendingPathComponent("ReadyAlias")
try fm.createSymbolicLink(at:alias,withDestinationURL:catalog.root)
let aliasCatalog=RuntimeModCatalog(root:alias,defaults:defaults)
fails {_=try aliasCatalog.records()}
catalog.select(UUID())
fails {_=try catalog.selected()}
print("PASS: prepared MOD selection; base identity; payload corruption; traversal; duplicate paths; symlink escape; disable; stale selection")
func table(_ values: [Int:String]) -> Data {
 var data=Data(repeating:0,count:2088*4)
 for slot in 0..<2088 {
  let offset=data.count
  for i in 0..<4 {data[slot*4+i]=UInt8((offset >> (i*8)) & 255)}
  data.append(Data((values[slot] ?? "Original\(slot)").utf8));data.append(0)
 }
 return data
}
func string(_ data:Data,_ slot:Int)->String {
 let offset=(0..<4).reduce(0){$0 | Int(data[slot*4+$1]) << ($1*8)}
 return String(decoding:data[offset..<data[offset...].firstIndex(of:0)!],as:UTF8.self)
}
let modStrings=table([343:"星乃一歌",344:"天馬咲希"])
let exitStrings=table([190:"退出游戏"])
let composed=try ModSessionUI.compose(mod:modStrings,menu:exitStrings)
for slot in 0..<2088 {require(string(composed,slot) == (slot == 190 ? "退出游戏" : string(modStrings,slot)))}
require(composed.count-modStrings.count == Data("退出游戏".utf8).count+1)
fails {_=try ModSessionUI.compose(mod:Data(),menu:exitStrings)}
var invalidMenu=exitStrings
for i in 0..<4 {invalidMenu[190*4+i]=255}
fails {_=try ModSessionUI.compose(mod:modStrings,menu:invalidMenu)}
let bundle=root.appendingPathComponent("ExitMenu"),layer=root.appendingPathComponent("UIFix")
let relative="rom_switch/rom/lang2/cn/str_array.bin"
try put(bundle.appendingPathComponent("cn/"+relative),exitStrings)
try put(bundle.appendingPathComponent("keep.txt"),Data("preserve".utf8))
try put(layer.appendingPathComponent(relative),modStrings)
let prepared=try ModSessionUI.prepare(bundle:bundle,layers:[layer.path],temp:root.appendingPathComponent("Temp"),language:"zh-Hans")
require(prepared != bundle)
require(try Data(contentsOf:prepared.appendingPathComponent("keep.txt")) == Data("preserve".utf8))
require(try Data(contentsOf:bundle.appendingPathComponent("cn/"+relative)) == exitStrings)
require(try Data(contentsOf:prepared.appendingPathComponent("cn/"+relative)) == composed)
require(try ModSessionUI.prepare(bundle:bundle,layers:[],temp:root,language:"zh-Hans") == bundle)
print("PASS: localized MOD names preserved; exit-menu composition; malformed table rejected; bundle remains unchanged; no-MOD fallback")

func importFixture(_ folder:String, wrapped:Bool=false)->(URL,RuntimeMod) {
 let installed=root.appendingPathComponent(folder)
 let source=wrapped ? installed.appendingPathComponent("Pack") : installed
 let value=RuntimeMod(format:"pjdv-runtime-mod-v1",id:UUID(),name:"Import fixture",notes:"",layers:["0"],baseChecks:[check],files:[payload])
 try! put(source.appendingPathComponent("runtime.json"),JSONEncoder().encode(value))
 try! put(source.appendingPathComponent(payload.path),Data("valid".utf8))
 return (installed,value)
}
let (direct,directItem)=importFixture("ImportDirect")
require(try catalog.adoptPrepared(from:direct,progress:Progress())?.id == directItem.id)
require(!fm.fileExists(atPath:direct.path))
require(try catalog.overlayPaths(directItem,base:base).count == 1)
// Importing does not silently change the user's selected combination.
require(catalog.selectedID != directItem.id)
let (wrapped,wrappedItem)=importFixture("ImportWrapped",wrapped:true)
require(try catalog.adoptPrepared(from:wrapped,progress:Progress())?.id == wrappedItem.id)
require(!fm.fileExists(atPath:wrapped.path))
let (duplicate,_)=importFixture("ImportDuplicate")
try put(duplicate.appendingPathComponent("runtime.json"),JSONEncoder().encode(directItem))
fails {_=try catalog.adoptPrepared(from:duplicate,progress:Progress())}
require(try Data(contentsOf:catalog.directory(directItem).appendingPathComponent(payload.path)) == Data("valid".utf8))
let (bad,badItem)=importFixture("ImportBad")
try put(bad.appendingPathComponent(payload.path),Data("wrong".utf8))
fails {_=try catalog.adoptPrepared(from:bad,progress:Progress())}
require(fm.fileExists(atPath:bad.path) && !fm.fileExists(atPath:catalog.directory(badItem).path))
let (extra,extraItem)=importFixture("ImportExtra")
try put(extra.appendingPathComponent("0/unlisted.bin"),Data([1]))
fails {_=try catalog.adoptPrepared(from:extra,progress:Progress())}
require(!fm.fileExists(atPath:catalog.directory(extraItem).path))
let (missing,_)=importFixture("ImportMissing")
try fm.removeItem(at:missing.appendingPathComponent(payload.path))
fails {_=try catalog.adoptPrepared(from:missing,progress:Progress())}
let (cancelledImport,_)=importFixture("ImportCancelled")
let cancellation=Progress();cancellation.cancel()
fails {_=try catalog.adoptPrepared(from:cancelledImport,progress:cancellation)}
require(fm.fileExists(atPath:cancelledImport.path))
let raw=root.appendingPathComponent("RawMod")
try put(raw.appendingPathComponent("rom/pv_db.txt"),Data("valid".utf8))
require(try catalog.adoptPrepared(from:raw,progress:Progress()) == nil)
print("PASS: native prepared-package adoption; wrapped ZIP layout; full payload hashes; extra/missing/corrupt payload rejection; duplicate protection; cancellation; raw packages stay inactive")

let damagedID=UUID(),damaged=catalog.root.appendingPathComponent(damagedID.uuidString)
try put(damaged.appendingPathComponent("runtime.json"),Data("{\"name\":\"Broken named pack\"}".utf8))
let inventory=try catalog.inventory()
require(inventory.ready.contains{$0.id==directItem.id})
require(inventory.unavailable.contains{$0.id==damagedID && $0.name=="Broken named pack"})
catalog.select(damagedID);fails{_=try catalog.selectedMods()}
catalog.select(directItem.id);require(try catalog.selectedMods().first?.id==directItem.id)
let linkedID=UUID(),linked=catalog.root.appendingPathComponent(linkedID.uuidString)
try fm.createSymbolicLink(at:linked,withDestinationURL:catalog.directory(directItem))
require(try catalog.inventory().unavailable.contains{$0.id==linkedID})
require(try catalog.records().contains{$0.id==directItem.id})
let largeID=UUID(),largeData=Data(repeating:65,count:3*1024*1024)
let largeCheck=RuntimeMod.Check(path:"0/rom/large.bin",bytes:UInt64(largeData.count),sha256:SHA256.hash(data:largeData).map{String(format:"%02x",$0)}.joined())
let largeItem=RuntimeMod(format:"pjdv-runtime-mod-v1",id:largeID,name:"Large payload",notes:"",layers:["0"],baseChecks:[check],files:[largeCheck])
let largeURL=catalog.directory(largeItem).appendingPathComponent(largeCheck.path)
try put(largeURL,largeData);try put(catalog.directory(largeItem).appendingPathComponent("runtime.json"),JSONEncoder().encode(largeItem))
let handle=try FileHandle(forWritingTo:largeURL);try handle.seek(toOffset:UInt64(largeData.count-1));try handle.write(contentsOf:Data([66]));try handle.close()
require(try catalog.overlayPaths(largeItem,base:base).count==1) // Fast launch intentionally stats large media.
fails{try catalog.verifyFully(largeItem,progress:Progress())}
require(try catalog.inventory().unavailable.contains{$0.id==largeID && $0.item != nil})
fails{_=try catalog.overlayPaths(largeItem,base:base)}
require(try catalog.records().contains{$0.id==directItem.id})
try put(largeURL,largeData);try catalog.verifyFully(largeItem,progress:Progress())
require(try catalog.records().contains{$0.id==largeID})
require(try catalog.resolve([largeID,directItem.id]).count==2)
require(catalog.selectedIDs==[directItem.id]) // Resolving a draft never commits it.
let cancelledCheck=Progress();cancelledCheck.cancel();fails{try catalog.verifyFully(largeItem,progress:cancelledCheck)}
require(try catalog.records().contains{$0.id==largeID})
print("PASS: malformed manifests and symlink packages isolated; healthy selection survives; same-size large-media corruption found by full hash; bad payload blocked until successful recheck; cancellation preserves availability")
