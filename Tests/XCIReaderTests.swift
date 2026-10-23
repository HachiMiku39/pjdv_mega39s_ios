import Foundation
@main struct XCIReaderTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let valid=try xciSecureEntries(XCIFile(url:root.appendingPathComponent("valid.xci")));assert(valid.isEmpty)
  for f in ["truncated.xci","bad-magic.xci","overflow.xci","unsafe-name.xci","overlap.xci","duplicate.xci"] {
   var rejected=false
   do {_=try xciSecureEntries(XCIFile(url:root.appendingPathComponent(f)))}catch{rejected=true}
   assert(rejected,"Malformed XCI accepted: "+f)
  }
  var badKeys=false
  do{_=try XCIKeys(url:root.appendingPathComponent("bad.keys"))}catch{badKeys=true}
  assert(badKeys)
  print("Bounded XCI tests passed: empty valid HFS, truncation, magic, overflow, unsafe names, overlap, duplicate names and invalid keys")
 }
}
