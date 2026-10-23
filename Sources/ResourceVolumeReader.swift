import Foundation
import CryptoKit
import Darwin

/// A bounded random-access reader for prepared resources. It does not decrypt
/// XCI/NCA, mount RomFS, or load unsigned executable code.
final class ResourceVolumeReader {
    struct Manifest: Codable {
        let format: String
        let content_kind: String
        let total_bytes: UInt64
        let sha256: String
        let parts: [Part]
    }
    struct Part: Codable {
        let file: String
        let offset: UInt64
        let bytes: UInt64
        let sha256: String
    }
    enum Failure: Error {
        case invalidManifest, missingVolume(String), invalidRange
        case shortRead(String), integrity(String)
    }
    private let lock = NSLock()
    let manifest: Manifest
    private var descriptors: [Int32] = []
    private var verified = Set<Int>()
    private static let block = 1024 * 1024

    init(directory: URL) throws {
        let url = directory.appendingPathComponent("manifest.json")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4 * Self.block else { throw Failure.invalidManifest }
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.format == "pjdv-resource-volumes-v1",
              ["romfs", "opaque"].contains(manifest.content_kind),
              manifest.total_bytes <= UInt64(Int64.max),
              manifest.parts.count <= 4096, Self.validHash(manifest.sha256) else {
            throw Failure.invalidManifest
        }
        var end: UInt64 = 0
        var names = Set<String>()
        do {
            for part in manifest.parts {
                guard part.file.range(of: "^resources\\.[0-9]{5}\\.part$", options: .regularExpression) != nil,
                      names.insert(part.file).inserted, part.offset == end,
                      part.bytes > 0, part.bytes <= 2 * 1024 * 1024 * 1024,
                      part.bytes <= manifest.total_bytes - min(end, manifest.total_bytes),
                      Self.validHash(part.sha256) else { throw Failure.invalidManifest }
                let fd = open(directory.appendingPathComponent(part.file).path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw Failure.missingVolume(part.file) }
                descriptors.append(fd)
                var st = stat()
                guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                      st.st_size == Int64(part.bytes) else { throw Failure.missingVolume(part.file) }
                end += part.bytes
            }
            guard end == manifest.total_bytes else { throw Failure.invalidManifest }
        } catch {
            descriptors.forEach { _ = Darwin.close($0) }
            descriptors.removeAll()
            throw error
        }
    }

    deinit { descriptors.forEach { _ = Darwin.close($0) } }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    private func chunk(fd: Int32, offset: UInt64, count: Int, name: String) throws -> Data {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            var done = 0
            while done < count {
                let n = pread(fd, raw.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return done }
                done += n
            }
            return done
        }
        guard got == count else { throw Failure.shortRead(name) }
        return data
    }
    private func verifyPart(_ i: Int, whole: inout SHA256?) throws {
        let part = manifest.parts[i], fd = descriptors[i]
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw Failure.integrity(part.file) }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < part.bytes {
            let data = try chunk(fd: fd, offset: offset, count: Int(min(UInt64(Self.block), part.bytes - offset)), name: part.file)
            hash.update(data: data)
            whole?.update(data: data)
            offset += UInt64(data.count)
        }
        guard Self.hex(hash.finalize()) == part.sha256, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.integrity(part.file) }
        verified.insert(i)
    }
    /// Call on a worker queue: verification streams through a 1 MiB buffer.
    func verifyAll() throws {
        lock.lock(); defer { lock.unlock() }
        var whole: SHA256? = SHA256()
        for i in manifest.parts.indices { try verifyPart(i, whole: &whole) }
        guard let digest = whole?.finalize(), Self.hex(digest) == manifest.sha256 else {
            throw Failure.integrity("complete resource")
        }
    }
    /// Each first-use volume is verified before returning data. No concatenated
    /// 40 GiB temporary file is created. Call off the main/render thread.
    func read(at offset: UInt64, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= 16 * Self.block, offset <= manifest.total_bytes,
              UInt64(count) <= manifest.total_bytes - offset else { throw Failure.invalidRange }
        var position = offset, remaining = count, result = Data()
        result.reserveCapacity(count)
        while remaining > 0 {
            guard let i = manifest.parts.lastIndex(where: { $0.offset <= position }) else { throw Failure.invalidManifest }
            let part = manifest.parts[i]
            if !verified.contains(i) { var whole: SHA256?; try verifyPart(i, whole: &whole) }
            let relative = position - part.offset
            let take = min(remaining, Int(part.bytes - relative))
            result.append(try chunk(fd: descriptors[i], offset: relative, count: take, name: part.file))
            position += UInt64(take); remaining -= take
        }
        return result
    }
}
