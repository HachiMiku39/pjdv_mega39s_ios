import Foundation
import Darwin

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

func expectFailure(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Unexpected success") }
    catch {}
}

let originalDownloads = try ModInbox.downloads(under: root)
let looseFiles = try ModInbox.sources(under: root, includingDownloads: false)
precondition(originalDownloads.count == 2 && looseFiles.allSatisfy { $0.origin == .files })
let incoming = root.appendingPathComponent("network.part")
let zipA = Data([0x50, 0x4b, 3, 4, 65, 65])
let zipB = Data([0x50, 0x4b, 3, 4, 66, 66, 66])
try zipA.write(to: incoming)
let a = try ModInbox.storeDownload(from: incoming, suggestedName: "../../Miku.zip", under: root)
try zipB.write(to: incoming)
let b = try ModInbox.storeDownload(from: incoming, suggestedName: "Miku.zip", under: root)
precondition(a != b && a.lastPathComponent == "Miku.zip" && b.lastPathComponent == "Miku.zip")
let bytesA = try Data(contentsOf: a), bytesB = try Data(contentsOf: b)
precondition(bytesA == zipA && bytesB == zipB && !fm.fileExists(atPath: incoming.path))
let saved = try ModInbox.downloads(under: root)
precondition(saved.count == 4 && saved.first(where: { $0.url.path == b.path })?.byteCount == 7)
try ModInbox.validateDownload(a, under: root)
try ModInbox.removeDownload(a, under: root)
precondition(!fm.fileExists(atPath: a.deletingLastPathComponent().path) && fm.fileExists(atPath: b.path))

let file = inbox.appendingPathComponent("A.ZIP")
expectFailure { try ModInbox.removeDownload(file, under: root) }
precondition(fm.fileExists(atPath: file.path))
let old = originalDownloads.first(where: { $0.url.pathExtension == "rar" })!.url
try ModInbox.removeDownload(old, under: root)
let afterRemoval = try ModInbox.downloads(under: root)
precondition(afterRemoval.contains { $0.url.lastPathComponent == "manual.7z" })
let unsafe = b.deletingLastPathComponent().appendingPathComponent("unsafe.zip")
try fm.createSymbolicLink(at: unsafe, withDestinationURL: file)
expectFailure { try ModInbox.removeDownload(unsafe, under: root) }
let withoutLinks = try ModInbox.downloads(under: root)
precondition(!withoutLinks.contains { $0.url.lastPathComponent == "unsafe.zip" })
try Data("<html>captcha</html>".utf8).write(to: incoming)
expectFailure { _ = try ModInbox.storeDownload(from: incoming, suggestedName: "fake.zip", under: root) }
let noPartial = try ModInbox.downloads(under: root)
precondition(noPartial.count == 2 && !noPartial.contains { $0.url.lastPathComponent == "fake.zip" })

let redirect = root.appendingPathComponent("Redirect", isDirectory: true)
let untouched = root.appendingPathComponent("Untouched", isDirectory: true)
try fm.createDirectory(at: redirect, withIntermediateDirectories: false)
try fm.createDirectory(at: untouched, withIntermediateDirectories: false)
try fm.createSymbolicLink(at: redirect.appendingPathComponent("mods"), withDestinationURL: untouched)
try zipB.write(to: incoming)
expectFailure { _ = try ModInbox.storeDownload(from: incoming, suggestedName: "model.zip", under: redirect) }
let untouchedNames = try fm.contentsOfDirectory(atPath: untouched.path)
precondition(untouchedNames.isEmpty)
print("PASS: persistent archive library, distinct same-name files, source-only deletion, legacy multi-file folders, link isolation, rejected HTML and scoped files")

let externalSessionFile = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fm.removeItem(at: externalSessionFile) }
try zipA.write(to: externalSessionFile)
let transferred = try ModInbox.storeDownload(from: externalSessionFile, suggestedName: "download", under: root)
let transferredBytes = try Data(contentsOf: transferred)
precondition(transferredBytes == zipA && transferred.lastPathComponent == "download.zip")
precondition(!fm.fileExists(atPath: externalSessionFile.path))
print("PASS: system temporary download to app library")

// Simulate a terminated cross-volume writer and an active writer sharing this library.
let abortFolder = internalRoot.appendingPathComponent("Downloads/" + UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: abortFolder, withIntermediateDirectories: false)
let partial = abortFolder.appendingPathComponent(".pjdv-incoming")
let activeCopy = open(abortFolder.path, O_RDONLY | O_DIRECTORY | O_EXLOCK)
precondition(activeCopy >= 0)
try zipA.write(to: partial)
_ = try ModInbox.downloads(under: root)
precondition(fm.fileExists(atPath: partial.path))
close(activeCopy)
_ = try ModInbox.downloads(under: root)
precondition(!fm.fileExists(atPath: abortFolder.path))
print("PASS: active transfer hidden and preserved, interrupted copy reclaimed")

let rootAlias = root.deletingLastPathComponent().appendingPathComponent("AliasDocuments")
try fm.createSymbolicLink(at: rootAlias, withDestinationURL: root)
try ModInbox.validateDownload(transferred.resolvingSymlinksInPath(), under: rootAlias)
try ModInbox.removeDownload(transferred.resolvingSymlinksInPath(), under: rootAlias)
precondition(!fm.fileExists(atPath: transferred.path))
print("PASS: remove enumerated download through an aliased Documents root")

let canonicalLoose = try ModInbox.sources(under: root, includingDownloads: false)
let aliasedLoose = try ModInbox.sources(under: rootAlias, includingDownloads: false)
precondition(aliasedLoose.map { $0.url.path } == canonicalLoose.map { $0.url.path })
precondition(ModInbox.managedRoot(under: rootAlias).path == ModInbox.managedRoot(under: root).path)
let legacyAlias = root.deletingLastPathComponent().appendingPathComponent("LegacyAlias")
try fm.createSymbolicLink(at: legacyAlias, withDestinationURL: legacy)
precondition(ModInbox.managedRoot(under: legacyAlias).lastPathComponent == "Mods")
let legacyInbox = try ModInbox.sources(under: legacyAlias, includingDownloads: false)
precondition(legacyInbox.isEmpty)
print("PASS: current and legacy MOD directories enumerated through Documents aliases")
