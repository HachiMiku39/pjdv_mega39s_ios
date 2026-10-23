import Foundation

enum ShaderAssets {
    static func validate(root: URL, chain: String) throws {
        let fm = FileManager.default
        let cache = root.appendingPathComponent("MetalCache/b-" + chain, isDirectory: true)
        let text = try String(contentsOf: root.appendingPathComponent("Shaders/shader_map.tsv"), encoding: .utf8)
        let keys = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let last = line.split(whereSeparator: \.isWhitespace).last,
                  last.count == 16, last.allSatisfy({ $0.isHexDigit }) else { return nil }
            return String(last)
        })
        guard !keys.isEmpty else { throw failure }
        for key in keys {
            let library = cache.appendingPathComponent(key + "_b.metallib")
            guard let size = try? fm.attributesOfItem(atPath: library.path)[.size] as? NSNumber,
                  size.intValue > 0,
                  let metadata = try? Data(contentsOf: cache.appendingPathComponent(key + "_b.json")),
                  let json = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                  json["chain"] as? String == chain else { throw failure }
        }
    }
    private static var failure: NSError {
        NSError(domain: "PJDVRenderingAssets", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "渲染资源缺失或版本不匹配。请更新与此 App 配套的 Shaders 和 MetalCache 后重试；现有存档及游戏数据可以保留。"])
    }
}
