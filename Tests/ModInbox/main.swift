import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !fm.fileExists(atPath: root.path) else { fatalError("Use a new fixture directory") }
let inbox = root.appendingPathComponent("mods", isDirectory: true)
let first = try ModInbox.sources(under: root)
precondition(first.isEmpty && fm.fileExists(atPath: inbox.path))
precondition(ModInbox.managedRoot(under:root).lastPathComponent == "mods")
let legacy = root.deletingLastPathComponent().appendingPathComponent("LegacyRoot",isDirectory:true)
try fm.createDirectory(at:legacy.appendingPathComponent("Mods/Downloads"),withIntermediateDirectories:true)
_ = try ModInbox.sources(under:legacy)
precondition(ModInbox.managedRoot(under:legacy).lastPathComponent == "Mods")
let legacyNames = try fm.contentsOfDirectory(atPath:legacy.path)
precondition(legacyNames == ["Mods"])
let internalRoot = root.appendingPathComponent("Mods", isDirectory: true)
try fm.createDirectory(at: internalRoot, withIntermediateDirectories: true)
func write(_ relative: String, _ data: Data = Data(), under folder: URL = inbox) throws {
    let url = folder.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
let downloadID = UUID().uuidString
for name in ["A.ZIP", "B.RaR", "Folder/rom/a.bin", "Folder/nested.zip", "loose.bin", "skip.7z",
             ".unfinished.rar", ".hidden/a.zip", "__MACOSX/a.zip"] { try write(name) }
for name in ["Ready", "Installed", "Registrations", "Compositions", "Profiles"] {
    try write(name + "/private.rar", under: internalRoot)
}
try write("Other.rar", under: internalRoot)
try write("Downloads/" + downloadID + "/saved.rar", under: internalRoot)
try write("Downloads/" + downloadID + "/manual.7z", under: internalRoot)
try write("Downloads/unregistered/ignored.zip", under: internalRoot)
try fm.createSymbolicLink(at: inbox.appendingPathComponent("Alias.zip"), withDestinationURL: inbox.appendingPathComponent("A.ZIP"))
try fm.createSymbolicLink(at: inbox.appendingPathComponent("AliasFolder"), withDestinationURL: inbox.appendingPathComponent("Folder"))
try fm.createSymbolicLink(at: internalRoot.appendingPathComponent("Downloads/" + UUID().uuidString), withDestinationURL: inbox)
let expected = ["A.ZIP", "B.RaR", "Folder", "Other.rar", "saved.rar", "manual.7z"]
for _ in 0..<2 {
    let entries = try ModInbox.sources(under: root)
    precondition(entries.count == expected.count && Set(entries.map { $0.url.lastPathComponent }) == Set(expected))
    precondition(entries.filter { $0.origin == .download }.count == 2)
    precondition(entries.filter(\.isDirectory).map { $0.url.lastPathComponent } == ["Folder"])
}
let payload = root.appendingPathComponent("fixture")
func verifyName(_ bytes: [UInt8], suggested: String?, expected: String?) throws {
    try Data(bytes).write(to: payload)
    let name = try ModInbox.downloadName(suggested: suggested, file: payload)
    precondition(name == expected, "Unexpected downloaded filename")
}
try verifyName([82,97,114,33,26,7,1,0], suggested: "12345", expected: "12345.rar")
try verifyName([82,97,114,33,26,7,0], suggested: "model.zip", expected: "model.rar")
try verifyName([80,75,3,4], suggested: "song.ZIP", expected: "song.ZIP")
try verifyName([55,122,188,175,39,28], suggested: nil, expected: "mod.7z")
try verifyName([60,104,116,109,108], suggested: "file.rar", expected: nil)
print("PASS: inbox discovery, managed folders, case variants, link isolation, refresh, download formats")
