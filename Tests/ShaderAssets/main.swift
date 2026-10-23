import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("pjdv-shader-preflight-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let cache = root.appendingPathComponent("MetalCache/b-test")
try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: root.appendingPathComponent("Shaders"), withIntermediateDirectories: true)
let map = root.appendingPathComponent("Shaders/shader_map.tsv")
let library = cache.appendingPathComponent("0123456789abcdef_b.metallib")
let metadata = cache.appendingPathComponent("0123456789abcdef_b.json")
try "package\tstage\tkey\npv\tvertex\t0123456789abcdef\n".write(to: map, atomically: true, encoding: .utf8)
func rejected(_ label: String) {
    do { try ShaderAssets.validate(root: root, chain: "test"); fatalError("Accepted " + label) }
    catch { print("PASS rejected " + label) }
}
rejected("missing cache")
try Data("source".utf8).write(to: library)
rejected("missing reflection")
try Data("{\"chain\":\"old\"}".utf8).write(to: metadata)
rejected("wrong chain")
try Data("{\"chain\":\"test\"}".utf8).write(to: metadata)
try ShaderAssets.validate(root: root, chain: "test");print("PASS complete cache")
try Data().write(to: library);rejected("empty shader")
try "package\tstage\tkey\n".write(to: map, atomically: true, encoding: .utf8);rejected("empty map")
if CommandLine.arguments.count > 1 {
    try ShaderAssets.validate(root: URL(fileURLWithPath: CommandLine.arguments[1]), chain: "pjdv-842acf8d7583")
    print("PASS actual complete shader cache")
}
