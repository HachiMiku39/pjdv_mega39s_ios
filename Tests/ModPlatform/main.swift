import Foundation
import CryptoKit

struct Input: Decodable {
    let name: String
    let source: String
    let expected: String?
}

struct Observation: Encodable {
    let name: String
    let result: String
    let reason: String?
}

let fm = FileManager.default
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    fatalError("Pass a case list, a new installation directory, and an output JSON path")
}
let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
let installed = URL(fileURLWithPath: arguments[1], isDirectory: true)
precondition(!fm.fileExists(atPath: installed.path))
try fm.createDirectory(at: installed, withIntermediateDirectories: true)
var observations = [Observation]()

for input in inputs {
    let result: String
    var reason: String?
    do {
        let package = try ModInstaller.install(URL(fileURLWithPath: input.source), under: installed,
                                               progress: Progress(totalUnitCount: 1)) { _ in }
        precondition(package.root.deletingLastPathComponent().standardizedFileURL.path == installed.standardizedFileURL.path)
        try fm.removeItem(at: package.root)
        result = "pass"
    } catch let requirement as ModWindowsRequirement {
        switch requirement {
        case .declaredPlugin(let path):
            result = "declaredPlugin"
            reason = path
        case .executableOnly(let path):
            result = "executableOnly"
            reason = path
        }
    } catch ModPackageError.unknownStructure {
        result = "unknownStructure"
    } catch ModInstallError.integrity {
        result = "archiveError"
    } catch ModPackageError.invalidZIP {
        result = "archiveError"
    } catch {
        result = "otherError"
        reason = String(describing: error)
    }

    let residue = try fm.contentsOfDirectory(atPath: installed.path)
    precondition(residue.isEmpty, "\(input.name) left installation files: \(residue)")
    let observation = Observation(name: input.name, result: result, reason: reason)
    observations.append(observation)
    print("\(input.name)\t\(result)\t\(reason ?? "")")
    if let expected = input.expected {
        precondition(result == expected, "\(input.name): expected \(expected), observed \(result) (\(reason ?? ""))")
    }
}
let output = JSONEncoder()
output.outputFormatting = [.prettyPrinted, .sortedKeys]
try output.encode(observations).write(to: URL(fileURLWithPath: arguments[2]))
print("PASS: \(observations.count) inputs, no leftover staged or installed files")

// Simulate upgrading with an old Ready directory. A Windows layer must stay
// isolated without hiding a resource-only neighbour or opening the old overlay.
let suite = "PJDV.ModPlatform.Tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let ready = installed.appendingPathExtension("legacy")
let catalog = RuntimeModCatalog(root: ready, defaults: defaults)
let base = installed.appendingPathExtension("base")
try fm.createDirectory(at: base, withIntermediateDirectories: true)
let asset = Data("test".utf8)
func fileCheck(_ path: String, _ data: Data) -> RuntimeMod.Check {
    .init(path: path, bytes: UInt64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
}
try asset.write(to: base.appendingPathComponent("base.bin"))
func legacyItem(_ name: String, _ entries: [String:Data]) throws -> RuntimeMod {
    let item = RuntimeMod(format: "pjdv-runtime-mod-v1", id: UUID(), name: name, notes: "", layers: ["0"],
                          baseChecks: [fileCheck("base.bin", asset)], files: entries.map { fileCheck($0.key, $0.value) })
    let directory = catalog.directory(item)
    for (path,data) in entries {
        let target = directory.appendingPathComponent(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    try JSONEncoder().encode(item).write(to: directory.appendingPathComponent("runtime.json"))
    return item
}
let legacyPlugin = try legacyItem("old plug-in package", [
    "0/config.toml": Data("dll = ['old.dll']".utf8), "0/rom/costume.bin": asset,
])
let normal = try legacyItem("resource package", ["0/rom/costume.bin": asset])
let inventory = try catalog.inventory()
precondition(inventory.ready.map(\.id) == [normal.id])
guard let blocked = inventory.unavailable.first(where: { $0.id == legacyPlugin.id }) else { fatalError("Missing blocked legacy entry") }
precondition(blocked.windowsRequirement == .declaredPlugin("old.dll"))
catalog.select(legacyPlugin.id)
do {
    _ = try catalog.selectedMods()
    fatalError("A stale selection re-enabled the Windows plug-in")
} catch ModWindowsRequirement.declaredPlugin(_) {}
do {
    _ = try catalog.overlayPaths(legacyPlugin, base: base)
    fatalError("A caller opened the disallowed legacy overlay directly")
} catch ModWindowsRequirement.declaredPlugin(_) {}
print("PASS: mixed legacy inventory, restored selection and direct overlay gate")
