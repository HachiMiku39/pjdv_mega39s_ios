import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
func check(_ filename:String,_ kind:ModInspection.Kind,_ extra:(ModInspection)->Bool={_ in true}) throws {
    let r=try ModPackageInspector.inspect(root.appendingPathComponent(filename))
    precondition(r.kind==kind && !r.contentIntegrityChecked && extra(r),filename)
}
func reject(_ filename:String,_ expected:ModPackageError) throws {
    do {_=try ModPackageInspector.inspect(root.appendingPathComponent(filename));fatalError("Accepted: "+filename)}
    catch let error as ModPackageError {precondition(error.localizedDescription==expected.localizedDescription,filename+": "+error.localizedDescription)}
}
try check("plugin.zip",.pluginAssets){$0.containsDatabases && $0.fileCount==3}
try check("layered.zip",.layeredFS){$0.declaredTitleIDs == ["0100F3100DA46000"]}
try check("foreign.zip",.layeredFS){$0.declaredTitleIDs == ["01001CC00FA1A000"]}
try check("steam.zip",.pluginAssets)
try check("mixed.zip",.mixedAssets){$0.containsCode && $0.containsDatabases}
try check("code.zip",.codeOnly){$0.containsCode}
try check("zip64.zip",.pluginAssets){$0.fileCount==3}
try check("odd-method.zip",.pluginAssets){$0.unusualCompression}
try check("FolderMod",.pluginAssets)
for name in ["unknown.zip","config-only.zip","EmptyFolder"] {try reject(name,.unknownStructure)}
for name in ["traversal.zip","absolute.zip","drive.zip","case-parent.zip","file-directory.zip"] {try reject(name,.unsafePath)}
for name in ["symlink.zip","FolderLink","RootLink"] {try reject(name,.specialFile)}
for name in ["encrypted.zip","split.zip"] {try reject(name,.encryptedOrSplit)}
for name in ["too-many.zip","huge-directory.zip","deep-metadata.zip"] {try reject(name,.limitExceeded)}
for name in ["truncated.zip","notzip.zip"] {try reject(name,.invalidZIP)}
try reject("unsupported.7z",.unsupportedArchive)
let cancelled=Progress(totalUnitCount:1);cancelled.cancel()
do {_=try ModPackageInspector.inspect(root.appendingPathComponent("plugin.zip"),progress:cancelled);fatalError("Cancellation ignored")}
catch let error as ModPackageError {precondition(error.localizedDescription==ModPackageError.cancelled.localizedDescription)}
for url in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Fuzz"),includingPropertiesForKeys:nil) {
    do {_=try ModPackageInspector.inspect(url)} catch {}
}
let registry=ModRegistry(root:root.appendingPathComponent("Registry",isDirectory:true))
let source=root.appendingPathComponent("plugin.zip"),report=try ModPackageInspector.inspect(source)
try registry.register(source,inspection:report);let first=try registry.records();precondition(first.count==1)
try registry.register(source,inspection:report);let again=try registry.records();precondition(again.count==1 && first[0].id==again[0].id)
let resolved=try registry.source(again[0]);precondition(resolved.standardizedFileURL==source.standardizedFileURL)
let bytes=try Data(contentsOf:registry.root.appendingPathComponent(first[0].id.uuidString+".json"))
let object=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];precondition(object["enabled"]==nil)
try registry.remove(again[0]);let remaining=try registry.records();precondition(remaining.isEmpty)
precondition(FileManager.default.fileExists(atPath:source.path))
print("PASS: ZIP/ZIP64/folder layouts; traversal/case/symlink/limits; cancellation;150 metadata mutations; bookmark registration/dedup/removal; no enable flag")
