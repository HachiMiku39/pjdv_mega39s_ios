import Foundation
import CryptoKit

private let testChain = "test" as NSString
@_cdecl("pjdv_shader_cache_chain") func fixtureShaderChain() -> UnsafePointer<CChar> {testChain.utf8String!}

@main struct ContentTests {
    static func main() throws {
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let keys=fixture.appendingPathComponent("fixture.keys")
        func plan(_ name:String) throws -> XCIImportPlan {try XCIImportPlan(xci:fixture.appendingPathComponent(name+".xci"),keys:keys)}
        let before=SHA256.hash(data:try Data(contentsOf:fixture.appendingPathComponent("base-only.xci")))
        var preparation=[String]()
        let base=try XCIImportPlan(xci:fixture.appendingPathComponent("base-only.xci"),keys:keys,report:{preparation.append($0)})
        precondition(preparation.first=="正在读取 XCI 目录…" && preparation.last=="资源预检完成，正在检查保存位置…")
        precondition(preparation.contains{$0.hasPrefix("正在识别 NCA 内容…")})
        var renamedPreparation=[String]()
        let renamed=try XCIImportPlan(xci:fixture.appendingPathComponent("renamed.xci"),keys:keys,report:{renamedPreparation.append($0)})
        precondition(renamedPreparation.contains{$0.hasPrefix("正在校验重命名的 NCA 内容…")})
        let metadataFree=try plan("metadata-free")
        precondition(renamed.content.index_sha256==base.content.index_sha256)
        precondition(metadataFree.content.index_sha256==base.content.index_sha256 && metadataFree.content.content_version==nil)
        precondition(base.volumes.count==1 && base.content.content_version==0 && base.content.languages==["ja"])
        precondition(!base.content.usesVerifiedResourceVersion)
        let baseOut=out.appendingPathComponent("base-only")
        try XCIResourceImporter(plan:base,root:baseOut,cancel:{false},report:{_ in}).run()
        let baseLayout=try ResourceLayout.locate(baseOut)
        precondition(baseLayout.dlcContents.isEmpty && baseLayout.languages==["ja"])
        let pv=try Data(contentsOf:baseLayout.rom.appendingPathComponent("rom_switch/rom/pv_db.txt"))
        precondition(pv==Data("fixture-pv-db\n".utf8))
        try XCIResourceImporter(plan:base,root:baseOut,cancel:{false},report:{_ in}).run()
        let sourceAfter=try Data(contentsOf:fixture.appendingPathComponent("base-only.xci"))
        precondition(before==SHA256.hash(data:sourceAfter))
        print("PASS visible preparation/hash-verification phases, base-only CNMT discovery, hash-resolved renamed NCA, metadata-free unique package, zero DLC, extraction, verified resume and unchanged source")
        let mixed=try plan("update-subset")
        precondition(mixed.content.content_version==65536)
        precondition(mixed.volumes.compactMap{$0.dlc?.index}==[2,23,99])
        precondition(mixed.content.languages==["zh-Hans","ja"])
        let mixedOut=out.appendingPathComponent("subset")
        var checks=0,cancelled=false
        do {
            try XCIResourceImporter(plan:mixed,root:mixedOut,cancel:{checks+=1;return checks>8},report:{_ in}).run()
        } catch ImportFailure.cancelled {cancelled=true}
        precondition(cancelled && FileManager.default.fileExists(atPath:mixedOut.appendingPathComponent(".pjdv-import-in-progress").path))
        do {_=try ResourceLayout.locate(mixedOut);preconditionFailure("Accepted incomplete resources")} catch {}
        try XCIResourceImporter(plan:mixed,root:mixedOut,cancel:{false},report:{_ in}).run()
        let mixedLayout=try ResourceLayout.locate(mixedOut)
        precondition(mixedLayout.dlcContents.map(\.index)==[2,23,99])
        precondition(mixedLayout.languages==["zh-Hans","ja"])
        let markerBefore=try Data(contentsOf:baseOut.appendingPathComponent("game-content.json"))
        do {try XCIResourceImporter(plan:mixed,root:baseOut,cancel:{false},report:{_ in}).run();preconditionFailure("Overwrote other version")} catch {}
        let markerAfter=try Data(contentsOf:baseOut.appendingPathComponent("game-content.json"))
        precondition(markerBefore==markerAfter)
        print("PASS automatic update selection, subset/new DLC index, interrupted import recovery and cross-version overwrite refusal")
        for name in ["missing-update","wrong-game","ambiguous","corrupt-meta"] {
            do {_=try plan(name);preconditionFailure("Accepted "+name)} catch {print("PASS reject "+name)}
        }
        AppLanguage.configure(available:baseLayout.languages)
        precondition(AppLanguage.available.map{$0.0}==["ja"])
        for language in ["en","zh-Hans","zh-Hant","ko"] {precondition(AppLanguage.gameLanguageCode(language)=="ja")}
        AppLanguage.configure(available:mixedLayout.languages)
        precondition(AppLanguage.gameLanguageCode("zh-CN")=="zh-Hans")
        precondition(AppLanguage.gameLanguageCode("zh-Hant")=="ja")
        precondition(AppLanguage.gameLanguageCode("en")=="ja")
        let englishPaths=Set(["rom_switch/rom/lang2/en/str_array.bin"]+ResourceLanguageProbe.menuFiles.map{"rom_switch_en/rom/2d/"+$0})
        precondition(ResourceLanguageProbe.detect{englishPaths.contains($0)}==["en"])
        let stringsOnly=Set(["rom_switch/rom/lang2/en/str_array.bin"])
        precondition(ResourceLanguageProbe.detect{stringsOnly.contains($0)}.isEmpty)
        print("PASS menu completeness, resource-dependent UI choices, consistent host/game language and Japanese fallback")
        var wrongMeta=Data(repeating:0,count:32);wrongMeta[12]=0x80
        do {_=try XCIContentMeta(wrongMeta);preconditionFailure("Accepted empty CNMT")} catch {}
        let contentFile=mixedOut.appendingPathComponent("game-content.json")
        var record=try JSONSerialization.jsonObject(with:Data(contentsOf:contentFile)) as! [String:Any]
        record["application_id"]="0100000000000000"
        try JSONSerialization.data(withJSONObject:record).write(to:contentFile)
        do {_=try ResourceLayout.locate(mixedOut);preconditionFailure("Accepted mismatched application")} catch {}
        print("PASS invalid metadata and resource identity mismatch rejection")
        if CommandLine.arguments.count>3 {
            let actual=try ResourceLayout.locate(URL(fileURLWithPath:CommandLine.arguments[3]))
            precondition(actual.languages==["zh-Hans","zh-Hant","ja"] && actual.dlcContents.count==27)
            print("PASS existing real resource folder remains compatible and complete locale detection matches actual JP assets")
        }
    }
}
