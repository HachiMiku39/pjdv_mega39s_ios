import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let expected = try Data(contentsOf: root.appendingPathComponent("golden.bin"))
let reader = try ResourceVolumeReader(directory: root.appendingPathComponent("good"))
try reader.verifyAll()
check(try reader.read(at: 0, count: expected.count) == expected, "Full virtual file differs")
for start in stride(from: 0, to: expected.count, by: 37) {
    let count = min(799, expected.count - start)
    let actual = try reader.read(at: UInt64(start), count: count)
    check(actual == expected.subdata(in: start..<(start + count)), "Cross-volume read differs")
}
check(try reader.read(at: UInt64(expected.count), count: 0).isEmpty, "EOF empty read failed")
do {
    _ = try reader.read(at: UInt64(expected.count), count: 1)
    fatalError("Out-of-bounds read accepted")
} catch ResourceVolumeReader.Failure.invalidRange {}
do {
    _ = try reader.read(at: 0, count: -1)
    fatalError("Negative count accepted")
} catch ResourceVolumeReader.Failure.invalidRange {}
let corrupt = try ResourceVolumeReader(directory: root.appendingPathComponent("corrupt"))
do {
    _ = try corrupt.read(at: 0, count: 1)
    fatalError("Corrupt part returned data")
} catch ResourceVolumeReader.Failure.integrity {}
do {
    _ = try ResourceVolumeReader(directory: root.appendingPathComponent("gap"))
    fatalError("Noncontiguous volumes accepted")
} catch ResourceVolumeReader.Failure.invalidManifest {}
do {
    _ = try ResourceVolumeReader(directory: root.appendingPathComponent("missing"))
    fatalError("Missing part accepted")
} catch ResourceVolumeReader.Failure.missingVolume {}
print("Swift resource-volume integration: PASS (cross-volume data, SHA256, bounds, corruption, gaps, missing volumes)")
