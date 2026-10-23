import Foundation
import Darwin

private func footprint() throws -> UInt64 {
    var info=task_vm_info_data_t()
    var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let status=withUnsafeMutablePointer(to:&info) {p in
        p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
            task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
        }
    }
    guard status==KERN_SUCCESS else {throw ImportFailure.invalid("Cannot sample process footprint")}
    return info.phys_footprint
}

// Regresses Darwin FileHandle/NSData autorelease retention in one long GCD
// work item. Reads 8 GiB from a 1 MiB generated file; no game data/keys needed.
@main struct StreamingMemoryTests {
    static func main() throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let source=folder.appendingPathComponent("stream-"+UUID().uuidString+".bin")
        try Data(repeating:0x5a,count:1024*1024).write(to:source,options:.withoutOverwriting)
        defer{try?FileManager.default.removeItem(at:source)}
        let done=DispatchSemaphore(value:0)
        var failure:Error?
        DispatchQueue(label:"pjdv.streaming-memory-test",autoreleaseFrequency:.workItem).async {
            defer{done.signal()}
            do {
                let file=try XCIFile(url:source)
                let start=try footprint();var peak=start
                var retained=try file.read(0,file.size)
                for i in 0..<8192 {
                    // Deliberately no caller-side pool: XCIFile must bound its own
                    // Foundation read temporaries for every consumer.
                    let bytes=try file.read(0,file.size)
                    guard bytes.count==file.size,bytes.first==0x5a,bytes.last==0x5a,
                          retained.count==file.size,retained.first==0x5a else {
                        throw ImportFailure.invalid("Data did not survive local pool drainage")
                    }
                    retained=bytes
                    if i%64==0 {
                        peak=max(peak,try footprint())
                        guard peak<start+128*1024*1024 else {
                            throw ImportFailure.invalid("Streaming memory grew by >128 MiB after \(i+1) MiB")
                        }
                    }
                }
                do {_=try file.read(file.size,1);throw ImportFailure.invalid("Accepted truncated read")}
                catch ImportFailure.invalid(let message) where message=="资源范围越界或文件已截断" {}
                print("PASS 8 GiB streamed in one work item; memory start=\(start), peak=\(peak); returned Data and read bounds preserved")
            } catch {failure=error}
        }
        done.wait()
        if let failure {fputs("FAIL: \(failure.localizedDescription)\n",stderr);exit(1)}
    }
}
