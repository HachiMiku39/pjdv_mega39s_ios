import Foundation
import Darwin

enum ModWindowsRequirement: Error, Equatable, Codable {
    case declaredPlugin(String)
    case executableOnly(String)
}

/// Classifies a validated installer-owned directory. A nil result leaves the
/// compatibility decision to the native format and conversion checks.
enum ModPlatformAnalyzer {
    private static let metadataLimit = 1024 * 1024

    static func windowsRequirement(in root: URL, progress: Progress) throws -> ModWindowsRequirement? {
        let fm = FileManager.default
        guard root.isFileURL, try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ModPackageError.specialFile
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path + "/"
        var enumerationError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                                           options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ModPackageError.unknownStructure
        }
        var files = [String](), entryCount = 0, nameBytes = 0
        for case let url as URL in iterator {
            if progress.isCancelled { throw ModPackageError.cancelled }
            entryCount += 1
            guard entryCount <= 50_000 else { throw ModPackageError.limitExceeded }
            try autoreleasepool {
                guard url.path.hasPrefix(prefix) else { throw ModPackageError.unsafePath }
                let name = url.lastPathComponent
                if name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._") {
                    iterator.skipDescendants()
                    return
                }
                let kind = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isSymbolicLink != true else { throw ModPackageError.specialFile }
                if kind.isDirectory == true { return }
                guard kind.isRegularFile == true else { throw ModPackageError.specialFile }
                let path = String(url.path.dropFirst(prefix.count))
                nameBytes += path.utf8.count
                guard nameBytes <= 8*1024*1024 else { throw ModPackageError.limitExceeded }
                files.append(path)
            }
        }
        if let error = enumerationError { throw error }
        return try windowsRequirement(in: root, knownFiles: files, progress: progress)
    }

    /// Screen the existing validated file manifest without touching the disk.
    static func needsRuntimeCheck(_ relativePaths: [String]) -> Bool {
        relativePaths.contains { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            return name != "mod.json" && !isDocumentation(name)
        }
    }

    /// The caller supplies validated regular-file paths relative to one layer.
    static func windowsRequirement(in root: URL, knownFiles: [String], progress: Progress) throws -> ModWindowsRequirement? {
        if progress.isCancelled { throw ModPackageError.cancelled }
        var commonDirectory: [Substring]?
        var configs = [String: String](), executables = [String]()
        for path in knownFiles {
            if progress.isCancelled { throw ModPackageError.cancelled }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), let last = parts.last else {
                throw ModPackageError.unsafePath
            }
            let name = last.lowercased()
            if isDocumentation(name) { continue }
            let directory = parts.dropLast()
            if let previous = commonDirectory {
                let shared = zip(previous, directory).prefix { $0 == $1 }.count
                if shared < previous.count { commonDirectory = Array(previous.prefix(shared)) }
            } else {
                commonDirectory = Array(directory)
            }
            if name == "config.toml" {
                configs[directory.joined(separator: "/")] = path
            } else if name != "mod.json" {
                executables.append(path)
            }
        }
        // A nested tool or bundled sub-mod can have its own DML configuration.
        // Only the config at the effective package root speaks for the selection.
        if let directory = commonDirectory,
           !directory.contains(where: { ["rom","romfs","tools","docs","examples","samples"].contains($0.lowercased()) }),
           let path = configs[directory.joined(separator: "/")],
           let data = try readConfig(root.appendingPathComponent(path)), let plugin = DLLDeclaration.plugin(in: data) {
            if try hasAlternative(in: root, files: knownFiles, progress: progress) { return nil }
            return .declaredPlugin(plugin)
        }
        // A DLL beside a chart or model is insufficient evidence. For packages
        // with no manifest decision, require every non-document payload to
        // have a Windows executable image header. Never execute or load it.
        guard let first = executables.first else { return nil }
        for path in executables {
            if progress.isCancelled { throw ModPackageError.cancelled }
            if try !isWindowsImage(root.appendingPathComponent(path)) { return nil }
        }
        return .executableOnly((first as NSString).lastPathComponent)
    }

    /// A distribution can include a Windows loader and a separate Switch or
    /// prepared PJDV version. Structural evidence of the latter leaves the
    /// final format and payload verification to the normal importer.
    private static func hasAlternative(in root: URL, files: [String], progress: Progress) throws -> Bool {
        struct Prepared: Decodable { let format: String; let id: UUID; let layers: [String] }
        var manifests = [String]()
        var nativeLayers = Set<String>()
        for path in files {
            if progress.isCancelled { throw ModPackageError.cancelled }
            let parts = path.split(separator: "/")
            guard let name = parts.last else { continue }
            if name.lowercased() == "runtime.json" { manifests.append(path); continue }
            if isDocumentation(name.lowercased()) { continue }
            for i in parts.indices.dropLast() {
                let component = parts[i].lowercased()
                if component == "romfs", i > 0, parts[i-1].utf8.count == 16,
                   parts[i-1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
                    return true
                }
                if component == "rom" || component.hasPrefix("rom_") {
                    nativeLayers.insert(parts[..<i].joined(separator: "/"))
                }
            }
        }
        var manifestParents = Set<String>()
        for layer in nativeLayers {
            var components = layer.split(separator: "/")[...]
            while !components.isEmpty {
                components = components.dropLast()
                if !manifestParents.insert(components.joined(separator: "/")).inserted { break }
            }
        }
        var metadataBudget = 8 * metadataLimit
        for manifest in manifests {
            if progress.isCancelled { throw ModPackageError.cancelled }
            let parent = manifest.split(separator: "/").dropLast().joined(separator: "/")
            let prefix = parent.isEmpty ? "" : parent + "/"
            guard manifestParents.contains(parent), let raw = try readConfig(root.appendingPathComponent(manifest)) else { continue }
            metadataBudget -= raw.count
            guard metadataBudget >= 0 else { throw ModPackageError.limitExceeded }
            guard let item = try? JSONDecoder().decode(Prepared.self, from: Data(raw)),
                  ["pjdv-runtime-mod-v1", "pjdv-runtime-model-v1", "pjdv-runtime-song-v1"].contains(item.format),
                  (1...4).contains(item.layers.count) else { continue }
            if item.layers.contains(where: { nativeLayers.contains(prefix + $0) }) { return true }
        }
        return false
    }

    private static func isDocumentation(_ name: String) -> Bool {
        if ["readme", "license", "licence", "copying", "changelog", "credits"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        if ["md", "rst"].contains(ext) { return true }
        // An ordinary .txt under rom/ can be a database or a chart input.
        let stem = (name as NSString).deletingPathExtension
        return ["txt","rtf","html"].contains(ext) &&
            ["readme","license","licence","copying","changelog","credits"].contains(where: { stem.hasPrefix($0) })
    }

    private static func withRegularFile<T>(_ url: URL, _ body: (Int32, Int64) throws -> T) throws -> T {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ModPackageError.specialFile }
        return try body(fd, info.st_size)
    }

    private static func bytes(_ fd: Int32, at position: Int64, count: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        try result.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var read = 0
            while read < count {
                let n = pread(fd, base.advanced(by: read), count-read, position + Int64(read))
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard n > 0 else { throw ModPackageError.changedSource }
                read += n
            }
        }
        return result
    }

    private static func readConfig(_ url: URL) throws -> [UInt8]? {
        try withRegularFile(url) { fd, size in
            guard size > 0, size <= metadataLimit else { return nil }
            return try bytes(fd, at: 0, count: Int(size))
        }
    }

    private static func isWindowsImage(_ url: URL) throws -> Bool {
        try withRegularFile(url) { fd, size in
            guard size >= 64 else { return false }
            let dos = try bytes(fd, at: 0, count: 64)
            guard dos[0] == 0x4d, dos[1] == 0x5a else { return false }
            let offset = (0..<4).reduce(Int64(0)) { $0 | (Int64(dos[60+$1]) << (8*$1)) }
            guard offset >= 64, offset <= size-94 else { return false }
            let pe = try bytes(fd, at: offset, count: 94)
            func word(_ at: Int) -> Int { Int(pe[at]) | (Int(pe[at+1]) << 8) }
            let sections = word(6), optionalSize = word(20)
            guard pe.starts(with: [0x50,0x45,0,0]), word(4) != 0,
                  (1...96).contains(sections), word(22) & 2 != 0,
                  optionalSize >= 70, [0x10b,0x20b].contains(word(24)),
                  Int64(24 + optionalSize + sections*40) <= size-offset else { return false }
            // EFI firmware, Xbox and ordinary COFF objects also use PE/COFF.
            return [1,2,3,9,16].contains(word(92))
        }
    }
}

/// Reads the MM+ loader's top-level dll assignment. Skip complete TOML values,
/// including multiline descriptions, arrays and comments. Unknown syntax never
/// supplies evidence for a Windows-only classification.
private enum DLLDeclaration {
    static func plugin(in bytes: [UInt8]) -> String? {
        guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
        var i = bytes.starts(with: [0xef,0xbb,0xbf]) ? 3 : 0
        var statement = [UInt8](), depth = 0, quote: UInt8?, multiline = false
        while i <= bytes.count {
            let end = i == bytes.count, c: UInt8 = end ? 10 : bytes[i]
            if let q = quote {
                guard !end else { return nil }
                statement.append(c)
                if q == 34, c == 92 {
                    i += 1
                    guard i < bytes.count else { return nil }
                    statement.append(bytes[i])
                } else if c == q {
                    if multiline {
                        var until = i+1
                        while until < bytes.count, bytes[until] == q { until += 1 }
                        if until-i >= 3 {
                            guard until-i <= 5 else { return nil }
                            statement.append(contentsOf: bytes[(i+1)..<until])
                            i = until-1
                            quote = nil
                        }
                    } else { quote = nil }
                } else if !multiline, c == 10 || c == 13 { return nil }
            } else if c == 35 {
                while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                continue
            } else if c == 34 || c == 39 {
                quote = c; multiline = i+2 < bytes.count && bytes[i+1] == c && bytes[i+2] == c
                statement.append(c)
                if multiline { statement.append(contentsOf: [c,c]); i += 2 }
            } else if c == 91 || c == 123 {
                depth += 1
                statement.append(c)
            } else if c == 93 || c == 125 {
                guard depth > 0 else { return nil }
                depth -= 1
                statement.append(c)
            } else if (c == 10 || c == 13) && depth == 0 {
                let text = String(decoding: statement, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("[") { break }
                if let eq = text.firstIndex(of: "=") {
                    let key = text[..<eq].trimmingCharacters(in: .whitespaces)
                    if ["dll","'dll'","\"dll\""].contains(key) {
                        return library(in: text[text.index(after:eq)...])
                    }
                }
                statement.removeAll(keepingCapacity: true)
            } else { statement.append(c) }
            i += 1
        }
        return nil
    }

    private static func library(in value: Substring) -> String? {
        var input = value[...]
        func whitespace() { input = input.drop(while: { $0.isWhitespace }) }
        func string() -> String? {
            guard let q = input.first, q == "\"" || q == "'" else { return nil }
            let start = input.startIndex
            var i = input.index(after: start)
            while i < input.endIndex {
                let c = input[i]; i = input.index(after: i)
                if c == q {
                    let raw = input[start..<i]
                    input = input[i...]
                    if q == "'" { return String(raw.dropFirst().dropLast()) }
                    return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
                }
                if q == "\"", c == "\\" {
                    guard i < input.endIndex else { return nil }
                    i = input.index(after:i)
                }
            }
            return nil
        }
        whitespace()
        let array = input.first == "["
        if array { input = input.dropFirst(); whitespace() }
        var plugin: String?
        while !input.isEmpty {
            if array, input.first == "]" { break }
            guard let path = string() else { return nil }
            let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
            if plugin == nil, ["dll","asi"].contains((name as NSString).pathExtension.lowercased()),
               name.utf8.count <= 255, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                plugin = name
            }
            whitespace()
            if !array || input.first != "," { break }
            input = input.dropFirst(); whitespace()
        }
        if array {
            guard input.first == "]" else { return nil }
            input = input.dropFirst(); whitespace()
        }
        return input.isEmpty ? plugin : nil
    }
}
