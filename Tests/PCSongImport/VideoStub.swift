import Foundation
// This unit target tests recognition/chart boundaries only. Real VP9 conversion
// is exercised separately with both native and software integration samples.
enum PCModVideo {
    static func convert(_ source:URL,to output:URL,progress:Progress,report:((ModInstallUpdate)->Void)?=nil)throws {throw ModLoadError.unsupported}
}
