import Foundation

@_silgen_name("pjdv_shader_cache_chain") private func shaderCacheChain() -> UnsafePointer<CChar>
enum GameRenderingAssets {
    static func root(_ layout: ResourceLayout) throws -> URL {
        let chain = String(cString: shaderCacheChain())
        #if targetEnvironment(simulator)
        let root = URL(fileURLWithPath: "/Volumes/Switch-iOS-Dev/GameBuild/MEGA39-v1.0.9", isDirectory: true)
        #else
        // Ship the matching small rendering cache with the app. Importing an
        // XCI supplies game data, not this host's translated shader libraries.
        let root = Bundle.main.url(forResource: "RendererAssets", withExtension: nil) ?? layout.root
        #endif
        try ShaderAssets.validate(root: root, chain: chain)
        return root
    }
    static func validate(_ layout: ResourceLayout) throws { _ = try root(layout) }
}

final class ResourceAccess {
    let root:URL
    private let scoped:Bool
    init(_ root:URL) {self.root=root;scoped=root.startAccessingSecurityScopedResource()}
    deinit {if scoped {root.stopAccessingSecurityScopedResource()}}
}
private func resourceMetadata(_ url:URL) throws -> Data {
    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size=attributes[.size] as? NSNumber,size.int64Value<=8*1024*1024 else {
        throw ImportFailure.invalid("资源元数据不是受支持的普通文件，或大小异常")
    }
    let file=try FileHandle(forReadingFrom:url);defer{try?file.close()}
    let bytes=try file.read(upToCount:8*1024*1024+1) ?? Data()
    guard bytes.count==size.intValue else{throw ImportFailure.invalid("资源元数据在读取期间发生变化")}
    return bytes
}
struct ResourceLayout {
    let root:URL,rom:URL,dlc:URL
    let content:GameContentInfo?
    let dlcContents:[ImportCatalog.DLC]
    var languages:[String] {ResourceLanguageProbe.detect(root:rom)}
    var resourceVersionVerified:Bool {content?.usesVerifiedResourceVersion ?? true}
    static func locate(_ root:URL,requireComplete:Bool=true) throws -> ResourceLayout {
        let fm=FileManager.default
        if requireComplete && fm.fileExists(atPath:root.appendingPathComponent(".pjdv-import-in-progress").path) {throw ImportFailure.invalid("资源导入尚未完成，请重新选择同一 XCI 继续。 ")}
        let rom=["romfs","MEGA39-v1.0.9"].map{root.appendingPathComponent($0,isDirectory:true)}.first{fm.fileExists(atPath:$0.appendingPathComponent("preparation.json").path)}
        guard let rom else {throw ImportFailure.invalid("请选择 GameResources 文件夹，内含 romfs 与 DLC。也可直接导入 MEGA39’s XCI。")}
        let dlc=root.appendingPathComponent("DLC",isDirectory:true)
        let decoder=JSONDecoder()
        let baseMarker=try JSONSerialization.jsonObject(with:resourceMetadata(rom.appendingPathComponent("preparation.json"))) as? [String:Any]
        guard baseMarker?["format"] as? String=="pjdv-prepared-romfs-v1",
              let identity=baseMarker?["index_sha256"] as? String,
              identity.count==64,identity.allSatisfy({$0.isHexDigit}) else {throw ImportFailure.invalid("游戏资源标记无效")}
        let infoURL=root.appendingPathComponent("game-content.json")
        let content:GameContentInfo?
        if fm.fileExists(atPath:infoURL.path) {
            let info=try decoder.decode(GameContentInfo.self,from:resourceMetadata(infoURL))
            guard info.format=="pjdv-game-content-v1",info.application_id==Mega39Content.title(Mega39Content.applicationID),
                  info.index_sha256==identity,info.runtime_profile==Mega39Content.runtimeProfile else {throw ImportFailure.invalid("资源身份或运行配置不匹配，请重新导入")}
            content=info
        } else {
            // Existing verified folders stay usable without modifying their
            // original manifests. New versions receive explicit import identity.
            if requireComplete && identity != Mega39Content.legacyIndex {throw ImportFailure.invalid("资源缺少游戏身份记录，请通过 XCI 导入生成")}
            content=nil
        }
        var contents=[ImportCatalog.DLC]()
        let manifest=dlc.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath:manifest.path) {contents=try decoder.decode(ImportCatalog.self,from:resourceMetadata(manifest)).contents}
        else if requireComplete {throw ImportFailure.invalid("DLC 清单缺失；无 DLC 的资源也需包含空清单")}
        guard contents.count<=256,Set(contents.map(\.index)).count==contents.count,
              contents.allSatisfy({row in
                  guard let id=UInt64(row.title_id,radix:16) else{return false}
                  return Mega39Content.dlcIndex(id)==row.index
              }) else {throw ImportFailure.invalid("DLC 清单存在冲突或不属于 MEGA39’s")}
        if requireComplete {
            if let content {guard content.dlc_indexes.sorted()==contents.map(\.index).sorted() else {throw ImportFailure.invalid("DLC 清单与本次导入结果不一致")}}
            for dir in [rom]+contents.map({dlc.appendingPathComponent(String($0.index),isDirectory:true)}) {
                let marker=dir.appendingPathComponent("complete.json")
                guard let row=try JSONSerialization.jsonObject(with:resourceMetadata(marker)) as? [String:Any],row["format"] as? String=="pjdv-prepared-romfs-v1",(row["file_count"] as? Int ?? 0)>0 else {throw ImportFailure.invalid("资源未完成导入："+dir.lastPathComponent)}
            }
            let critical=["rom_switch/rom/pv_db.txt","rom_switch/rom/gm_module_tbl.farc"]
            guard critical.allSatisfy({fm.fileExists(atPath:rom.appendingPathComponent($0).path)}),ResourceLanguageProbe.detect(root:rom).contains("ja") else {throw ImportFailure.invalid("资源缺少曲库、服装数据库或完整日语菜单")}
        }
        return ResourceLayout(root:root,rom:rom,dlc:dlc,content:content,dlcContents:contents.sorted{$0.index<$1.index})
    }
}
enum ResourceLibrary {
    private static let selection="pjdv.resourceRootBookmark.v1"
    static var appDataRoot:URL {
        #if targetEnvironment(macCatalyst)
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PJDVM39",isDirectory:true)
        #else
        return FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        #endif
    }
    static var localRoot:URL {appDataRoot.appendingPathComponent("GameResources",isDirectory:true)}
    private static var privateKeys:URL {
        #if targetEnvironment(macCatalyst)
        return appDataRoot.appendingPathComponent("ImportKeys/prod.keys")
        #else
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ImportKeys/prod.keys")
        #endif
    }
    static func open() throws -> ResourceAccess {
        #if targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.environment["PJDV_RESOURCES_TEST_BUNDLE_ONLY"] == "1" {
            guard let root=Bundle.main.url(forResource:"GameResources",withExtension:nil) else {throw ImportFailure.invalid("整合包缺少内置资源")}
            return ResourceAccess(root)
        }
        #endif
        if let bookmark=UserDefaults.standard.data(forKey:selection) {
            var stale=false
            #if targetEnvironment(macCatalyst)
            let root=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            #else
            let root=try URL(resolvingBookmarkData:bookmark,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
            #endif
            let access=ResourceAccess(root)
            _=try ResourceLayout.locate(root)
            if stale {try select(root)}
            return access
        }
        if (try?ResourceLayout.locate(localRoot)) != nil {return ResourceAccess(localRoot)}
        if let bundle=Bundle.main.url(forResource:"GameResources",withExtension:nil) {return ResourceAccess(bundle)}
        if FileManager.default.fileExists(atPath:localRoot.path) {return ResourceAccess(localRoot)}
        #if targetEnvironment(simulator)
        return ResourceAccess(URL(fileURLWithPath:"/Volumes/Switch-iOS-Dev/GameResources",isDirectory:true))
        #else
        throw ImportFailure.invalid("尚未导入游戏资源。请选择 XCI，或拷入完整 GameResources 文件夹。")
        #endif
    }
    static func select(_ root:URL) throws {
        if root.standardizedFileURL==localRoot.standardizedFileURL {UserDefaults.standard.removeObject(forKey:selection);return}
        #if targetEnvironment(macCatalyst)
        let data=try root.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)
        #else
        let data=try root.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        #endif
        UserDefaults.standard.set(data,forKey:selection)
    }
    static func useLocal() throws { _=try ResourceLayout.locate(localRoot);UserDefaults.standard.removeObject(forKey:selection) }
    static func keysURL() throws -> URL {
        let local=privateKeys
        if FileManager.default.fileExists(atPath:local.path) {return local}
        if let bundled=Bundle.main.url(forResource:"prod",withExtension:"keys",subdirectory:"ImportKeys") {return bundled}
        throw ImportFailure.invalid("请先在“资源”菜单中选择你本地的 prod.keys。密钥不会上传。")
    }
    static func storeKeys(_ source:URL) throws {
        _=try XCIKeys(url:source)
        let target=privateKeys
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(contentsOf:source).write(to:target,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
    }
}
