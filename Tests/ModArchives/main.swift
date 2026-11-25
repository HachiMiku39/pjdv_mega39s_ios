import CryptoKit
import Foundation

let args = CommandLine.arguments
precondition(args.count == 4)
let fixtures = URL(fileURLWithPath: args[1], isDirectory: true)
let upstream = URL(fileURLWithPath: args[2], isDirectory: true)
let work = URL(fileURLWithPath: args[3], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: work, withIntermediateDirectories: false)
let base = work.appendingPathComponent("Base")
let anchor = base.appendingPathComponent("rom_switch/rom/gm_module_tbl.farc")
try fm.createDirectory(at: anchor.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("fixture baseline".utf8).write(to: anchor)
let title = "0100F3100DA46000"
let suite = "PJDV.ModArchives.Tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
struct CheckError: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ text: String) throws {
    if !condition { throw CheckError(description: text) }
}
func install(_ source: URL, in dir: URL, progress: Progress = Progress(),
             report: @escaping (ModInstallUpdate) -> Void = { _ in }) throws -> InstalledMod {
    try ModInstaller.install(source, under: dir, progress: progress, report: report)
}
func cleanPackage(_ package: InstalledMod, under dir: URL) throws {
    if fm.fileExists(atPath: package.root.path) {
        try require(package.root.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path &&
                    UUID(uuidString: package.root.lastPathComponent) != nil, "unexpected staging path")
        try fm.removeItem(at: package.root)
    }
}
func empty(_ dir: URL) throws -> Bool {
    if !fm.fileExists(atPath: dir.path) { return true }
    return try fm.contentsOfDirectory(atPath: dir.path).isEmpty
}
func describe(_ error: Error) -> String {
    switch error {
    case ModWindowsRequirement.declaredPlugin: return "Windows DLL"
    case ModPackageError.wrongGame: return "wrong game"
    case ModPackageError.cancelled: return "cancelled"
    case ModPackageError.unsupportedRAR: return "unsupported RAR"
    case ModPackageError.invalidRAR: return "damaged RAR"
    case ModPackageError.specialFile: return "special file"
    case ModPackageError.unsafePath: return "duplicate or unsafe path"
    case ModPackageError.preparedAlreadyInstalled: return "duplicate package"
    default: return String(describing: error)
    }
}
var failures: [String] = []
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); print("PASS " + name) }
    catch { failures.append(name + ": " + describe(error)); print("FAIL " + failures.last!) }
}

// Different container formats, labels and member order must produce the same
// content identity. Each has an independent catalog for first-time acceptance.
var ids = Set<UUID>()
let expected = ["rom_switch/rom/2d/sample.bin": "synthetic UI", "rom/scene/sample.bin": "synthetic scene"]
for name in ["Directory", "Layer.zip", "Layer4.rar", "Layer5.rar"] {
    test(name + " to verified layer") {
        let installRoot = work.appendingPathComponent("Installed-" + name)
        let cat = RuntimeModCatalog(root: work.appendingPathComponent("Ready-" + name), defaults: defaults)
        let item = try install(fixtures.appendingPathComponent(name), in: installRoot)
        try require(item.inspection.declaredTitleIDs == [title], "missing or wrong title")
        try require(item.inspection.expandedBytes == UInt64(expected.values.reduce(0) { $0 + $1.utf8.count }), "missing member bytes")
        guard let ready = try ModSwitchOverlay.adopt(item, base: base, catalog: cat, progress: Progress()) else {
            throw CheckError(description: "native LayeredFS rejected")
        }
        try cat.verifyFully(ready, progress: Progress())
        let checked = try cat.resolve([ready.id])
        try require(checked.count == 1 && checked[0].id == ready.id, "catalog could not resolve the new mod")
        let paths = try cat.overlayPaths(ready, base: base)
        try require(paths.count == 1, "expected exactly one overlay layer")
        for (path, value) in expected {
            let data = try Data(contentsOf: URL(fileURLWithPath: paths[0]).appendingPathComponent(path))
            try require(data == Data(value.utf8), "payload mismatch for " + path)
        }
        ids.insert(ready.id)
        try cleanPackage(item, under: installRoot)
        let second = try install(fixtures.appendingPathComponent(name), in: installRoot)
        do {
            _ = try ModSwitchOverlay.adopt(second, base: base, catalog: cat, progress: Progress())
            throw CheckError(description:"duplicate was registered")
        } catch ModPackageError.preparedAlreadyInstalled {}
        try cleanPackage(second, under: installRoot)
        try cat.verifyFully(ready, progress: Progress())
        try require(try empty(installRoot), "installer left a staging directory")
    }
}
test("stable cross-format content ID") { try require(ids.count == 1, "identity depended on container or order") }

// A wrong title or a code-bearing RomFS must never be mounted.
test("code-bearing RomFS") {
        let name = "Code.rar"
        let installed = work.appendingPathComponent("Installed-" + name)
        let cat = RuntimeModCatalog(root: work.appendingPathComponent("Ready-" + name), defaults: defaults)
        let item = try install(fixtures.appendingPathComponent(name), in: installed)
        let result = try ModSwitchOverlay.adopt(item, base: base, catalog: cat, progress: Progress())
        try require(result == nil, "unsupported overlay was mounted")
        try cleanPackage(item, under: installed)
        try require(try empty(installed), "installer left a staging directory")
        try require(try empty(cat.root), "unexpected active overlay")
}

let negatives = ["Foreign.rar": "wrong game", "Plugin.rar": "Windows DLL", "Split4.rar": "unsupported RAR", "Split5.rar": "unsupported RAR",
                 "Encrypted4.rar":"unsupported RAR", "Encrypted5.rar":"unsupported RAR",
                 "Corrupt4.rar":"damaged RAR", "Corrupt5.rar":"damaged RAR", "Truncated4.rar":"damaged RAR",
                 "Truncated5.rar":"damaged RAR", "Collision.rar":"duplicate or unsafe path",
                 "Duplicate.rar":"duplicate or unsafe path", "Cancel.rar":"cancelled",
                 "test_read_format_rar_compress_normal.rar":"special file"]
for name in negatives.keys.sorted() {
    test(name) {
        let installed = work.appendingPathComponent("Installed-" + name)
        let parent = name.hasPrefix("test_read_") ? upstream : fixtures
        let progress = Progress()
        var observed = "accepted"
        do {
            let item = try install(parent.appendingPathComponent(name), in: installed, progress: progress) { update in
                if name == "Cancel.rar" && !update.file.isEmpty { progress.cancel() }
            }
            try cleanPackage(item, under: installed)
        } catch { observed = describe(error) }
        try require(try empty(installed), "residual staging after " + observed)
        try require(observed == negatives[name], "expected " + negatives[name]! + ", received " + observed)
    }
}

// Upstream's compressed vectors are not game mods. Verify decoded payload
// bytes directly, so the format gate cannot hide a broken decompressor.
let streams = [
    ("UpstreamCompressed4.rar", "LibarchiveAddingTest.html", 20111, "ee16390e87152d7dec632ae2b37566da6135966e46b5166e6f40a1c827fa61ad"),
    ("test_read_format_rar5_compressed.rar", "test.bin", 1200, "588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375"),
    ("test_read_format_rar_subblock.rar", "test.txt", 20, "5a5f16e01faf8adf92eb4499a2d3e93010c4b41dbb7f698f4a8466d9f58e6dd2"),
]
for (name, member, length, hash) in streams {
    test(name + " compressed content") {
        let decoded = work.appendingPathComponent("Decoded-" + name)
        try fm.createDirectory(at: decoded, withIntermediateDirectories: false)
        let source = (name == "UpstreamCompressed4.rar" ? fixtures : upstream).appendingPathComponent(name)
        let inspected = try ModRARReader.read(source, to: decoded, progress: Progress())
        let data = try Data(contentsOf: decoded.appendingPathComponent(member))
        let digest = SHA256.hash(data: data).map { String(format:"%02x", $0) }.joined()
        try require(inspected.expandedBytes == UInt64(length) && data.count == length && digest == hash, "compressed data checksum mismatch")
    }
}
if !failures.isEmpty {
    FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
    exit(1)
}
print("PASS \(ids.count) shared stable identity; all expected outcomes passed.")
