import Foundation
import CryptoKit
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let installed=root.appendingPathComponent("Installed",isDirectory:true)
let fm=FileManager.default
func run(_ name:String,progress:Progress=Progress(totalUnitCount:1),report:@escaping(ModInstallUpdate)->Void={_ in}) throws -> InstalledMod {
    try ModInstaller.install(root.appendingPathComponent(name),under:installed,progress:progress,report:report)
}
for name in ["stored.zip","deflated.zip","chunk-boundary.zip","FolderMod","zip64.zip"] {
    let r=try run(name)
    precondition(r.inspection.fileCount>0 && !r.root.lastPathComponent.hasPrefix(".staging"))
    precondition(r.inspection.contentIntegrityChecked == name.hasSuffix(".zip"))
    try fm.removeItem(at:r.root)
}
for name in ["bad-crc.zip","local-name.zip","declared-short.zip","too-large.zip","traversal.zip","symlink.zip"] {
    do {_=try run(name);fatalError("Accepted corrupt archive: "+name)} catch {}
    let left=try fm.contentsOfDirectory(at:installed,includingPropertiesForKeys:nil)
    precondition(left.isEmpty,"Failed install left payloads")
}
let cancel=Progress(totalUnitCount:1)
do {_=try run("large.zip",progress:cancel){_ in cancel.cancel()};fatalError("Cancellation ignored")}
catch let e as ModPackageError {precondition(e.localizedDescription==ModPackageError.cancelled.localizedDescription)}
let afterCancel=try fm.contentsOfDirectory(at:installed,includingPropertiesForKeys:nil)
precondition(afterCancel.isEmpty)
var last:UInt64=0
let large=try run("large.zip") {u in precondition(u.completed>=last && u.completed<=u.total);last=u.completed}
let file=large.root.appendingPathComponent("Pack/rom/objset/large.farc")
let expandedAttributes=try fm.attributesOfItem(atPath:file.path)
precondition((expandedAttributes[.size] as! NSNumber).uint64Value==256*1024*1024)
precondition(last==large.inspection.expandedBytes)
try fm.removeItem(at:large.root)
print("PASS: stored/deflated/ZIP64/folder install; CRC/local-header/size/path/symlink rejection; cancellation cleanup; streamed 256 MiB expansion")

// iPad data URLs can name /var while Foundation enumerates /private/var.
// An ancestor alias is valid; a symlink selected as the package is not.
let alias=root.appendingPathComponent("ParentAlias")
try fm.createSymbolicLink(at:alias,withDestinationURL:root)
let fixture=root.appendingPathComponent("PreparedFixture")
let relative="0/rom_switch/rom/pv_db.txt",data=Data("valid".utf8)
try fm.createDirectory(at:fixture.appendingPathComponent(relative).deletingLastPathComponent(),withIntermediateDirectories:true)
try data.write(to:fixture.appendingPathComponent(relative))
let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
let item=RuntimeMod(format:"pjdv-runtime-mod-v1",id:UUID(),name:"Alias fixture",notes:"",layers:["0"],baseChecks:[.init(path:"rom_switch/rom/pv_db.txt",bytes:5,sha256:digest)],files:[.init(path:relative,bytes:5,sha256:digest)])
try JSONEncoder().encode(item).write(to:fixture.appendingPathComponent("runtime.json"))
let copied=try ModInstaller.install(alias.appendingPathComponent("PreparedFixture"),under:alias.appendingPathComponent("AliasInstalled"),progress:Progress()) {_ in}
let defaults=UserDefaults(suiteName:"PJDV.ImportAlias."+UUID().uuidString)!
let catalog=RuntimeModCatalog(root:root.appendingPathComponent("AliasReady"),defaults:defaults)
let adopted=try catalog.adoptPrepared(from:copied.root,progress:Progress())
precondition(adopted?.id==item.id)
let link=root.appendingPathComponent("SelectedLink")
try fm.createSymbolicLink(at:link,withDestinationURL:fixture)
do {_=try ModInstaller.install(link,under:installed,progress:Progress()){_ in};fatalError("Selected symlink accepted")}catch{}
try fm.removeItem(at:alias);try fm.removeItem(at:link)
print("PASS: complete prepared-package installation through an ancestor alias; selected symlink still rejected")
