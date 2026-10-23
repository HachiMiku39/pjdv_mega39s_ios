import Foundation

enum Mega39Content {
    static let applicationID: UInt64 = 0x0100F3100DA46000
    static let legacyIndex = "48ae20a1e013c89df6c15a55cb23ad79798702b5ec9f3e82f68ccd1efb639a26"
    static let runtimeProfile = "JP-1.0.9-signed-native-v1"
    static func title(_ id: UInt64) -> String { String(format:"%016llX",id) }
    static func dlcIndex(_ id: UInt64) -> Int? {
        let first=applicationID+0x1000
        guard id>first, id<=first+0xfff else{return nil}
        return Int(id-first)
    }
}

struct GameContentInfo: Codable {
    let format: String
    let application_id: String
    let content_version: Int?
    let display_version: String?
    let source_program_build_id: String?
    let index_sha256: String
    let dlc_indexes: [Int]
    let languages: [String]
    let runtime_profile: String
    // This describes the embedded executable, not a claim that every resource
    // version is compatible with its database schemas or translated shaders.
    var usesVerifiedResourceVersion: Bool { index_sha256 == Mega39Content.legacyIndex }
}

enum ResourceLanguageProbe {
    static let options = [("zh-Hans","简体中文","cn"), ("zh-Hant","繁體中文","tw"),
                          ("ja","日本語","jp"), ("en","English","en"), ("ko","한국어","kr")]
    static let menuFiles = ["spr_nswgam_menu.farc","spr_nswgam_option.farc","spr_nswgam_game.farc",
                            "aet_nswgam_menu.bin","aet_nswgam_option.bin","aet_nswgam_game.bin"]
    static func detect(hasFile:(String)->Bool) -> [String] {
        options.compactMap { code,_,tag in
            guard hasFile("rom_switch/rom/lang2/\(tag)/str_array.bin") else{return nil}
            let variant = tag == "jp" ? "rom_switch" : "rom_switch_\(tag)"
            guard menuFiles.allSatisfy({hasFile("\(variant)/rom/2d/\($0)")}) else{return nil}
            return code
        }
    }
    static func detect(root:URL) -> [String] {
        detect { relative in
            guard let a=try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(relative).path) else{return false}
            return a[.type] as? FileAttributeType == .typeRegular && (a[.size] as? NSNumber)?.intValue ?? 0 > 0
        }
    }
}
