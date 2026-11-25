import Foundation

/// Files users can select in the MOD manager. Discovery never extracts or registers packages.
enum ModInbox {
    enum Origin { case files, download }
    struct Entry {
        let url: URL
        let origin: Origin
        let isDirectory: Bool
    }
    static let archiveExtensions = ["zip", "rar"]
    private static let reserved = Set(["ready", "installed", "downloads", "registrations", "compositions", "profiles", "__macosx"])
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]

    /// Use the spelling actually published by Files. Some providers enumerate
    /// "mods" yet reject lookups through "Mods". Prefer the legacy store when
    /// both exist on a case-sensitive volume, so existing saves stay associated.
    static func managedRoot(under documents: URL) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath:documents.path)) ?? []
        let name = names.contains("Mods") ? "Mods" : (names.first(where:{ $0.lowercased() == "mods" }) ?? "mods")
        return documents.appendingPathComponent(name,isDirectory:true)
    }

    /// Download endpoints may send a numeric URL or an extensionless suggested name.
    static func downloadName(suggested: String?, file: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = Array(try handle.read(upToCount: 8) ?? Data())
        let ext: String
        if header.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { ext = "rar" }
        else if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) || header.starts(with: [0x50, 0x4B, 0x05, 0x06]) || header.starts(with: [0x50, 0x4B, 0x07, 0x08]) { ext = "zip" }
        else if header.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { ext = "7z" }
        else { return nil }
        let name = ((suggested ?? "").replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(":"), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "mod." + ext }
        if (name as NSString).pathExtension.lowercased() == ext { return name }
        return (name as NSString).deletingPathExtension + "." + ext
    }

    static func sources(under documents: URL) throws -> [Entry] {
        let fm = FileManager.default
        // On a case-sensitive volume, the public inbox and the internal store can coexist.
        // Enumerate the actual names once so they don't alias each other on other volumes.
        if !fm.fileExists(atPath:documents.path) { try fm.createDirectory(at:documents,withIntermediateDirectories:true) }
        var roots = try fm.contentsOfDirectory(at:documents,includingPropertiesForKeys:Array(keys),options:.skipsHiddenFiles)
            .filter { $0.lastPathComponent.lowercased() == "mods" }
        if roots.isEmpty {
            let inbox = documents.appendingPathComponent("mods",isDirectory:true)
            try fm.createDirectory(at:inbox,withIntermediateDirectories:true)
            roots = [inbox]
        }
        var entries = [Entry]()
        for root in roots {
            guard isDirectory(root) else { continue }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            for url in children {
                let name = url.lastPathComponent.lowercased()
                guard !reserved.contains(name), let kind = try? url.resourceValues(forKeys: keys),
                      kind.isSymbolicLink != true else { continue }
                let folder = kind.isDirectory == true
                if folder || (kind.isRegularFile == true && archiveExtensions.contains(url.pathExtension.lowercased())) {
                    entries.append(Entry(url: url, origin: .files, isDirectory: folder))
                }
            }
        }
        // The browser owns a UUID directory per download. Do not descend into other managed directories.
        let downloadRoot = managedRoot(under:documents).appendingPathComponent("Downloads", isDirectory: true)
        if isDirectory(downloadRoot.deletingLastPathComponent()) && isDirectory(downloadRoot) {
            let folders = try fm.contentsOfDirectory(at: downloadRoot, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && isDirectory(folder) {
                let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                for file in files where (archiveExtensions + ["7z"]).contains(file.pathExtension.lowercased()) {
                    guard let kind = try? file.resourceValues(forKeys: keys), kind.isRegularFile == true, kind.isSymbolicLink != true else { continue }
                    entries.append(Entry(url: file, origin: .download, isDirectory: false))
                }
            }
        }
        return entries.sorted {
            let order = $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
