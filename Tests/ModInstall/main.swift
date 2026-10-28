import Foundation
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
