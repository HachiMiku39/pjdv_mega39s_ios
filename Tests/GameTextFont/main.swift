import Foundation

// From the project root, build into an existing external test directory:
// xcrun swiftc Sources/ModFormats.swift Sources/GameTextFontContent.swift Tests/GameTextFont/main.swift -lz -o "$PJDV_TEST_ROOT/font-fields"
// "$PJDV_TEST_ROOT/font-fields"
// Sample the same glyph in scoped text, a sort reading, a credit, a menu
// hint and an accessory. A global atlas replacement would change every one.
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("PJDVFontTest-" + UUID().uuidString)
defer { try? fm.removeItem(at: dir) }
let base = dir.appendingPathComponent("base"), dlc = dir.appendingPathComponent("DLC")
let mod = dir.appendingPathComponent("mod"), layer = dir.appendingPathComponent("font")
let s = "你", alias = Unicode.Scalar(0xe911)!, marked = String(alias)
func put(_ root: URL, _ name: String, _ payload: Data) throws {
    let path = root.appendingPathComponent(name)
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try payload.write(to: path)
}
func get(_ root: URL, _ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
let pv = "rom_switch/rom/pv_db.txt", dlcPV = "rom_switch_dlc/dlc7/rom/dlc7_pv_db.txt"
let table = "rom_switch/rom/gm_module_tbl.farc", list = "rom_switch/rom/gm_pv_list_tbl.farc"
let strings = "rom_switch/rom/lang2/"
let original = Array(repeating: "UNCHANGED", count: 240)
func packed(_ values: [String]) throws -> Data {
    let w = try ModFormats.Writer(values.count*4)
    for (i,v) in values.enumerated() { try w.put(i*4, w.text(v)) }
    return w.data
}
let stockPV = Data("pv_001.song_name=stock only".utf8)
try put(base, pv, stockPV)
let input = "\u{FEFF}# 你\r\npv_001.song_name=你Test\r\npv_001.song_name_reading=你\r\npv_001.another_song.0.name=你 edition\r\npv_001.another_song.0.name_en=你 edition\r\npv_001.another_song.0.file=你\r\npv_001.songinfo.lyrics=你\r\npv_001.lyric.010=你=你\r\npv_001.lyric.length=101\r\npv_001.lyric.120=\u{E011} \\n\r\n"
try put(mod, pv, Data(input.utf8))
try put(dlc.appendingPathComponent("8"), dlcPV, Data("pv_123.lyric_en.001=你".utf8))
try put(dlc.appendingPathComponent("9"), "rom_switch_dlc/dlc8/rom/dlc8_pv_db.txt", Data("pv_100.song_name=Z".utf8))
let module = "module.0.id=2\nmodule.0.name=你\nmodule.1.id=3\nmodule.1.name=別\nmodule.0.sort_index=7\n"
try put(mod, table, ModFormats.archiveData([.init(name:"gm_module_id.bin", data:Data(module.utf8)),.init(name:"extra.bin",data:Data("你".utf8))]))
try put(base, list, ModFormats.archiveData([.init(name:"gm_pv_list.bin", data:Data("pv_list.0.name=你\npv_list.0.id=1\n".utf8))]))
var jp = original, cn = original
jp[222] = s; jp[223] = "accessory"; cn[222] = s; cn[223] = s; cn[224] = s
try put(mod, strings+"jp/str_array.bin", packed(jp))
try put(mod, strings+"cn/str_array.bin", packed(cn))
let plan = try GameTextFontContent.plan(rom:base,dlc:dlc,dlcIndexes:[8],layers:[mod.path],language:"zh-Hans")
precondition(plan.characters.contains("你") && !plan.characters.contains("Z") && !plan.characters.contains("\u{E011}"))
try plan.write(aliases:["你":alias],to:layer)
let out = try String(decoding:get(layer,pv),as:UTF8.self)
let expected = input.replacingOccurrences(of:".song_name=你",with:".song_name="+marked)
    .replacingOccurrences(of:".name=你 edition",with:".name="+marked+" edition")
    .replacingOccurrences(of:".name_en=你 edition",with:".name_en="+marked+" edition")
    .replacingOccurrences(of:".010=你=你",with:".010="+marked+"="+marked)
precondition(out == expected)
let localized = try ModFormats.strings(get(layer,strings+"cn/str_array.bin"))
precondition(localized[222] == marked && localized[223] == s && localized[224] == s)
let costume = try ModFormats.archive(get(layer,table))
precondition(String(decoding:costume[0].data,as:UTF8.self) == module.replacingOccurrences(of:".name=你",with:".name="+marked))
precondition(costume[1].data == Data(s.utf8))
let songList = try ModFormats.archive(get(layer,list))
precondition(String(decoding:songList[0].data,as:UTF8.self) == "pv_list.0.name="+marked+"\npv_list.0.id=1\n")
let addon = try get(layer,dlcPV), unchanged = try get(base,pv)
precondition(addon == Data(("pv_123.lyric_en.001="+marked).utf8) && unchanged == stockPV)
let noChange = dir.appendingPathComponent("off")
try plan.write(aliases:[:],to:noChange)
precondition(!fm.fileExists(atPath:noChange.path))
try put(mod,pv,Data("pv_001.song_name=changed".utf8))
do {
    try plan.write(aliases:["你":alias],to:dir.appendingPathComponent("stale"))
    fatalError("Rewriting stale source data must fail")
} catch ModLoadError.invalid {}
print("PASS scoped font fields, language anchors, DLC selection, input precedence, unchanged UI and stale-source detection")
