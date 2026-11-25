import Foundation
import Darwin

/// Files users can select in the MOD manager. Discovery never extracts or registers packages.
enum ModInbox {
    enum Origin { case files, download }
    struct Entry {
        let url: URL
        let origin: Origin
        let isDirectory: Bool
    }
    struct Download {
        let url: URL
        let byteCount: Int64
        let date: Date
    }
    enum DownloadError: LocalizedError {
        case unsupported, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "下载的文件不是 ZIP、RAR 或 7z 压缩包。"
            case .unavailable: return "无法访问此下载文件。"
            }
        }
    }
    static let archiveExtensions = ["zip", "rar"]
    private static let unfinishedName = ".pjdv-incoming"
    private static let reserved = Set(["ready", "installed", "downloads", "registrations", "compositions", "profiles", "__macosx"])
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]

    /// Use the spelling actually published by Files. Some providers enumerate
    /// "mods" yet reject lookups through "Mods". Prefer the legacy store when
    /// both exist on a case-sensitive volume, so existing saves stay associated.
    static func managedRoot(under documents: URL) -> URL {
        let documents = documents.resolvingSymlinksInPath()
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
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(":"), !name.contains("/"), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "mod." + ext }
        if (name as NSString).pathExtension.lowercased() == ext { return name }
        return (name as NSString).deletingPathExtension + "." + ext
    }

    static func sources(under documents: URL, includingDownloads: Bool = true) throws -> [Entry] {
        // Resolve the trusted root, preserving the link checks on its children.
        let documents = documents.resolvingSymlinksInPath()
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
        if includingDownloads {
            entries += try downloads(under: documents).map { Entry(url: $0.url, origin: .download, isDirectory: false) }
        }
        return entries.sorted {
            let order = $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    /// Only finished files in our UUID folders belong to the download library.
    static func downloads(under documents: URL) throws -> [Download] {
        let directory = managedRoot(under: documents).appendingPathComponent("Downloads", isDirectory: true)
        guard isDirectory(directory.deletingLastPathComponent()), isDirectory(directory) else { return [] }
        let fm = FileManager.default
        let folderKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        let fileKeys = keys.union([.fileSizeKey, .contentModificationDateKey])
        var items = [Download]()
        let folders = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: folderKeys, options: .skipsHiddenFiles)
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && isDirectory(folder) {
            let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate
            let files: [URL]
            do { files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(fileKeys)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
            if files.contains(where: { $0.lastPathComponent == unfinishedName }) {
                removeAbandonedCopy(in: folder)
            }
            for file in files where !file.lastPathComponent.hasPrefix(".") && isArchive(file) {
                guard let metadata = try? file.resourceValues(forKeys: fileKeys),
                      metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
                items.append(Download(url: file, byteCount: Int64(metadata.fileSize ?? 0),
                                      date: created ?? metadata.contentModificationDate ?? .distantPast))
            }
        }
        return items.sorted { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date > $1.date }
    }

    /// Publish only after the complete archive has reached the destination volume.
    /// URLSession/WKDownload retain ownership of the supplied location until this call.
    static func storeDownload(from temporaryFile: URL, suggestedName: String?, under documents: URL) throws -> URL {
        let fm = FileManager.default
        let input = try temporaryFile.resourceValues(forKeys: keys)
        guard input.isRegularFile == true, input.isSymbolicLink != true else { throw DownloadError.unavailable }
        guard let name = try downloadName(suggested: suggestedName, file: temporaryFile) else { throw DownloadError.unsupported }
        let managed = managedRoot(under: documents)
        let directory = managed.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        guard isDirectory(managed) else { throw DownloadError.unavailable }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isDirectory(directory) else { throw DownloadError.unavailable }

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        do {
            // The common case is an atomic rename with no second disk copy.
            if rename(temporaryFile.path, destination.path) == 0 { return destination }
            guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Some external volumes do not grant access to the system replacement
            // directory. Stage inside this private slot so the final rename stays atomic.
            let lock = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_EXLOCK)
            guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(lock) }
            let stagedFile = folder.appendingPathComponent(unfinishedName, isDirectory: false)
            defer { _ = unlink(stagedFile.path) }
            try fm.copyItem(at: temporaryFile, to: stagedFile)
            try fm.moveItem(at: stagedFile, to: destination)
            try? fm.removeItem(at: temporaryFile)
            return destination
        } catch {
            _ = rmdir(folder.path)
            throw error
        }
    }

    private static func removeAbandonedCopy(in folder: URL) {
        // An active cross-volume copy holds this lock. A crash releases it.
        let lock = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
        guard lock >= 0 else { return }
        defer { close(lock) }
        if unlinkat(lock, unfinishedName, 0) == 0 { _ = rmdir(folder.path) }
    }

    static func validateDownload(_ file: URL, under documents: URL) throws {
        let directory = managedRoot(under: documents).appendingPathComponent("Downloads", isDirectory: true)
        let folder = file.deletingLastPathComponent()
        let listedRoot = folder.deletingLastPathComponent()
        // File providers can enumerate a real path when Documents was opened
        // through an alias. The two roots must designate the same directory.
        guard file.isFileURL, isArchive(file), !file.lastPathComponent.hasPrefix("."),
              UUID(uuidString: folder.lastPathComponent) != nil,
              isDirectory(directory.deletingLastPathComponent()), isDirectory(directory),
              isDirectory(listedRoot.deletingLastPathComponent()), isDirectory(listedRoot), isDirectory(folder),
              listedRoot.resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw DownloadError.unavailable
        }
        let values = try file.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DownloadError.unavailable }
    }

    static func removeDownload(_ file: URL, under documents: URL) throws {
        try validateDownload(file, under: documents)
        guard unlink(file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Legacy folders may contain other archives. Remove the folder only if empty.
        _ = rmdir(file.deletingLastPathComponent().path)
    }

    private static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return archiveExtensions.contains(ext) || ext == "7z"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
