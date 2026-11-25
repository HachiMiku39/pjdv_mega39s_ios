import Foundation
import Darwin
import PJDVArchive

/// The same stream performs inventory and extraction. A solid archive does not
/// need a second decode, and paths are checked before creating any output.
enum ModRARReader {
    static func read(_ source: URL, to stage: URL? = nil, progress: Progress,
                     reserve: (UInt64) throws -> Void = { _ in },
                     report: (String, UInt64, UInt64) -> Void = { _,_,_ in }) throws -> ModInspection {
        if progress.isCancelled { throw ModPackageError.cancelled }
        let fd = source.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw ModPackageError.specialFile }
        try checkSignature(fd)
        guard let reader = archive_read_new() else { throw ModPackageError.unsupportedRAR }
        defer { archive_read_free(reader) }
        guard archive_read_support_filter_none(reader) == ARCHIVE_OK,
              archive_read_support_format_rar(reader) == ARCHIVE_OK, archive_read_support_format_rar5(reader) == ARCHIVE_OK,
              archive_read_open_fd(reader, fd, 64 * 1024) == ARCHIVE_OK else { throw ModPackageError.invalidRAR }

        var index = ModDirectoryIndex(), entries = 0, lastReport = Date.distantPast
        var expanded: UInt64 = 0
        let length = UInt64(before.st_size), limit: UInt64 = 32 * 1024 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        progress.totalUnitCount = max(1, before.st_size)
        while true {
            if progress.isCancelled { throw ModPackageError.cancelled }
            var entry: OpaquePointer?
            let result = archive_read_next_header(reader, &entry)
            if result == ARCHIVE_EOF { break }
            guard result == ARCHIVE_OK, let entry else { throw readError(reader) }
            entries += 1
            guard entries <= ModDirectoryIndex.maximumEntries else { throw ModPackageError.limitExceeded }
            try autoreleasepool {
                guard archive_entry_is_encrypted(entry) == 0 else { throw ModPackageError.unsupportedRAR }
                let type = archive_entry_filetype(entry)
                let directory = type == S_IFDIR
                guard (directory || type == S_IFREG), archive_entry_symlink(entry) == nil,
                      archive_entry_hardlink(entry) == nil, archive_entry_sparse_count(entry) == 0 else { throw ModPackageError.specialFile }
                guard let chars = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                      let name = String(validatingUTF8: chars) else { throw ModPackageError.unsafePath }
                let path = name.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
                let size = archive_entry_size(entry)
                guard size >= 0, directory ? size == 0 : archive_entry_size_is_set(entry) != 0 else { throw ModPackageError.invalidRAR }
                guard UInt64(size) <= limit - expanded else { throw ModInstallError.tooLarge }
                expanded += UInt64(size)
                try index.add(path, directory: directory, size: UInt64(size))
                let parts = path.split(separator: "/")
                guard let stage, !parts.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" || $0.hasPrefix("._") }) else {
                    guard archive_read_data_skip(reader) == ARCHIVE_OK else { throw readError(reader) }
                    return
                }
                let url = parts.reduce(stage) { $0.appendingPathComponent(String($1)) }
                let fm = FileManager.default
                if directory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    return
                }
                try reserve(UInt64(size))
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let output = url.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
                guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let file = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                var remaining = UInt64(size)
                while true {
                    if progress.isCancelled { throw ModPackageError.cancelled }
                    let n = try buffer.withUnsafeMutableBytes { ptr -> Int in
                        let n = archive_read_data(reader, ptr.baseAddress, ptr.count)
                        guard n >= 0 else { throw readError(reader) }
                        guard UInt64(n) <= remaining else { throw ModPackageError.invalidRAR }
                        if n > 0 {
                            try file.write(contentsOf: Data(bytesNoCopy: ptr.baseAddress!,count:n,deallocator:.none))
                        }
                        return n
                    }
                    if n == 0 { break }
                    remaining -= UInt64(n)
                    if Date().timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = Date()
                        let position = min(length, UInt64(max(0, archive_filter_bytes(reader, -1))))
                        progress.completedUnitCount = Int64(position)
                        report(path,position,length)
                    }
                }
                guard remaining == 0 else { throw ModPackageError.invalidRAR }
                try file.close()
            }
        }
        guard archive_read_has_encrypted_entries(reader) <= 0 else { throw ModPackageError.unsupportedRAR }
        guard archive_read_close(reader) == ARCHIVE_OK else { throw readError(reader) }
        var after = stat()
        guard fstat(fd,&after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ModPackageError.changedSource }
        progress.completedUnitCount = progress.totalUnitCount
        return try index.finish()
    }

    private static func readError(_ archive: OpaquePointer) -> Error {
        let reason = archive_error_string(archive).map { String(cString:$0).lowercased() } ?? ""
        if ["encrypt","passphrase","multi-volume","multivolume","unsupported","not supported"].contains(where:reason.contains) {
            return ModPackageError.unsupportedRAR
        }
        return ModPackageError.invalidRAR
    }

    // Reject split archives even when every file in the first volume is whole.
    // A signature at offset zero also excludes self-extracting executables.
    private static func checkSignature(_ fd: Int32) throws {
        var bytes = [UInt8](repeating:0,count:128)
        let n = bytes.withUnsafeMutableBytes { pread(fd,$0.baseAddress,$0.count,0) }
        guard n >= 15, bytes.prefix(6).elementsEqual([82,97,114,33,26,7]) else { throw ModPackageError.invalidRAR }
        if bytes[6] == 0 {
            guard bytes[9] == 0x73 else { throw ModPackageError.invalidRAR }
            guard bytes[10] & 0x81 == 0 else { throw ModPackageError.unsupportedRAR }
            return
        }
        guard bytes[6] == 1, bytes[7] == 0 else { throw ModPackageError.unsupportedRAR }
        var offset = 12
        func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from:0,through:63,by:7) {
                guard offset < n else { throw ModPackageError.invalidRAR }
                let b = bytes[offset]; offset += 1
                guard shift < 63 || b <= 1 else { throw ModPackageError.invalidRAR }
                value |= UInt64(b & 127) << shift
                if b & 128 == 0 { return value }
            }
            throw ModPackageError.invalidRAR
        }
        _ = try integer()
        let type = try integer()
        if type == 4 { throw ModPackageError.unsupportedRAR }
        guard type == 1 else { throw ModPackageError.invalidRAR }
        let flags = try integer()
        if flags & 1 != 0 { _ = try integer() }
        if flags & 2 != 0 { _ = try integer() }
        guard try integer() & 1 == 0 else { throw ModPackageError.unsupportedRAR }
    }
}
