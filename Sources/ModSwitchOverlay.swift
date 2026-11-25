import Foundation
import CryptoKit

/// Imports a data-only LayeredFS RomFS into the same verified catalog used by
/// converted packs. Only the owned staging copy is rearranged.
enum ModSwitchOverlay {
    static func adopt(_ package: InstalledMod, base: URL, catalog: RuntimeModCatalog,
                      progress: Progress) throws -> RuntimeMod? {
        let fm = FileManager.default
        let expectedTitle = Mega39Content.title(Mega39Content.applicationID)
        guard package.inspection.declaredTitleIDs.allSatisfy({ $0 == expectedTitle }),
              !package.inspection.containsCode else { return nil }
        let resourceRoots: Set<String> = ["rom","rom_ps4","rom_ps4_dlc","rom_ps4_patch","rom_switch","rom_switch_cn","rom_switch_tw","rom_switch_kr","rom_switch_en","rom_switch_dlc","shader"]
        func children(_ folder: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at:folder, includingPropertiesForKeys:[.isRegularFileKey]).filter { url in
                let name = url.lastPathComponent.lowercased()
                if name == "__macosx" || name == ".ds_store" || name.hasPrefix("._") { return false }
                let isDocument = ["readme","license","licence","changelog","credits"].contains(url.deletingPathExtension().lastPathComponent.lowercased())
                    && ["","txt","md","rst"].contains(url.pathExtension.lowercased())
                if isDocument, try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { return false }
                return true
            }
        }
        // A PC DML rom/ directory alone is ambiguous. Require an explicit
        // romfs wrapper or one of the game's Switch-specific resource roots.
        var folder = package.root
        var isRomFS = package.name.lowercased() == "romfs"
        for _ in 0..<64 {
            try PCModelConverter.check(progress)
            let contents = try children(folder)
            let names = Set(contents.map { $0.lastPathComponent })
            if !names.isEmpty, names.isSubset(of:resourceRoots),
               isRomFS || names.contains(where:{ $0.hasPrefix("rom_switch") }) { break }
            guard !isRomFS, contents.count == 1,
                  let next = contents.first, try next.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { return nil }
            let name = next.lastPathComponent.lowercased()
            if name.utf8.count == 16, UInt64(name,radix:16) != nil, name.uppercased() != expectedTitle { return nil }
            // Never reinterpret another loader's resource subtree as a native pack.
            guard !resourceRoots.contains(name), !["mods","tools","plugins","exefs","exefs_patches"].contains(name) else { return nil }
            isRomFS = name == "romfs"
            folder = next
        }

        let roots = try children(folder)
        guard !roots.isEmpty, roots.allSatisfy({ resourceRoots.contains($0.lastPathComponent) }),
              isRomFS || roots.contains(where: { $0.lastPathComponent.hasPrefix("rom_switch") }) else { return nil }
        var files = [RuntimeMod.Check]()
        let binaryExtensions:Set<String> = ["dll","asi","exe","com","bat","cmd","dylib","so","elf","nso","nro","npdm","ips","pchtxt"]
        for root in roots {
            guard try root.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { return nil }
            var failure: Error?
            guard let it = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey],
                                         options:[],errorHandler:{ _,error in failure=error; return false }) else { throw ModPackageError.changedSource }
            for case let file as URL in it {
                try PCModelConverter.check(progress)
                let meta = try file.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard meta.isSymbolicLink != true else { throw ModPackageError.specialFile }
                let name = file.lastPathComponent.lowercased()
                guard !name.hasPrefix("."), !["mods","exefs","exefs_patches","config.toml","runtime.json"].contains(name),
                      !binaryExtensions.contains(file.pathExtension.lowercased()) else { return nil }
                if meta.isDirectory == true { continue }
                guard meta.isRegularFile == true else { throw ModPackageError.specialFile }
                let rel = String(file.path.dropFirst(folder.path.count + 1))
                let row = try PCModelConverter.hash(file,progress:progress)
                files.append(.init(path:"0/"+rel,bytes:row.bytes,sha256:row.sha256))
            }
            if let failure { throw failure }
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.path < $1.path }
        let anchorPath = "rom_switch/rom/gm_module_tbl.farc"
        let anchor = try PCModelConverter.hash(base.appendingPathComponent(anchorPath),progress:progress)
        let baseline = RuntimeMod.Check(path:anchorPath,bytes:anchor.bytes,sha256:anchor.sha256)
        var digest = SHA256()
        digest.update(data:Data(("pjdv-layeredfs-v1\n"+expectedTitle+"\n"+anchor.sha256+"\n").utf8))
        for row in files { digest.update(data:Data((row.path+"\n"+row.sha256+"\n").utf8)) }
        let bytes = Array(digest.finalize().prefix(16))
        let id = UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                            bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        let mod = RuntimeMod(format:"pjdv-runtime-mod-v1",id:id,name:package.name,notes:"",layers:["0"],baseChecks:[baseline],files:files)
        let scratch = package.root.deletingLastPathComponent().appendingPathComponent(".switch-"+UUID().uuidString)
        try fm.createDirectory(at:scratch,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:scratch) }
        let layer = scratch.appendingPathComponent("0")
        try fm.createDirectory(at:layer,withIntermediateDirectories:false)
        for root in roots { try fm.moveItem(at:root,to:layer.appendingPathComponent(root.lastPathComponent)) }
        try JSONEncoder().encode(mod).write(to:scratch.appendingPathComponent("runtime.json"),options:.atomic)
        return try catalog.adoptPrepared(from:scratch,progress:progress)
    }
}
