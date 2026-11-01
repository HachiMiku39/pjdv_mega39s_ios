import Foundation
import AVFoundation
import VideoToolbox

@_silgen_name("pjdv_mod_vp9_create") private func softwareVP9Create(_ width:Int32,_ height:Int32)->UnsafeMutableRawPointer?
@_silgen_name("pjdv_mod_vp9_destroy") private func softwareVP9Destroy(_ decoder:UnsafeMutableRawPointer)
@_silgen_name("pjdv_mod_vp9_decode") private func softwareVP9Decode(_ decoder:UnsafeMutableRawPointer,_ data:UnsafeRawPointer,_ count:UInt)->Int32
@_silgen_name("pjdv_mod_vp9_copy_pixel") private func softwareVP9CopyPixel(_ decoder:UnsafeMutableRawPointer)->UnsafeMutableRawPointer?

// Resource conversion only: one unencrypted USM channel containing IVF/VP9.
// Disk input is streamed a frame at a time. The writer applies backpressure;
// no movie, decoded-frame queue, executable or external converter is loaded.
enum PCModVideo {
    typealias F=ModFormats
    struct Info {let width:Int,height:Int,rate:Int,scale:Int,declared:Int}
    final class Encoder {
        let writer:AVAssetWriter,input:AVAssetWriterInput,adaptor:AVAssetWriterInputPixelBufferAdaptor,progress:Progress
        var software:UnsafeMutableRawPointer?,session:VTDecompressionSession?,format:CMVideoFormatDescription?,failure:Error?,decoded=0
        init(_ output:URL,info:Info,config:Data,progress:Progress)throws {
            self.progress=progress
            writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
            input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:info.width,AVVideoHeightKey:info.height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000,AVVideoAllowFrameReorderingKey:false]])
            input.expectsMediaDataInRealTime=false
            adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferWidthKey as String:info.width,kCVPixelBufferHeightKey as String:info.height])
            var initialized=false
            defer{if !initialized{if let software{softwareVP9Destroy(software);self.software=nil};if let session{VTDecompressionSessionInvalidate(session);self.session=nil};writer.cancelWriting()}}
            guard writer.canAdd(input) else{throw ModLoadError.unsupported};writer.add(input)
            let extensions=[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:["vpcC":config]] as CFDictionary
            guard CMVideoFormatDescriptionCreate(allocator:nil,codecType:kCMVideoCodecType_VP9,width:Int32(info.width),height:Int32(info.height),extensions:extensions,formatDescriptionOut:&format)==noErr,let format else{throw ModLoadError.unsupported}
            if #available(iOS 26.2, macCatalyst 26.2, *) {
                VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            }
            var callback=VTDecompressionOutputCallbackRecord(decompressionOutputCallback:{context,_,status,_,buffer,pts,_ in
                guard let context else{return};let self_=Unmanaged<Encoder>.fromOpaque(context).takeUnretainedValue()
                do {
                    guard status==noErr,let buffer else{throw ModLoadError.unsupported}
                    try self_.append(buffer,time:pts)
                }catch{self_.failure=error}
            },decompressionOutputRefCon:Unmanaged.passUnretained(self).toOpaque())
            let native=VTDecompressionSessionCreate(allocator:nil,formatDescription:format,decoderSpecification:nil,imageBufferAttributes:[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,outputCallback:&callback,decompressionSessionOut:&session)
            if native != noErr || ProcessInfo.processInfo.environment["PJDV_MOD_FORCE_SOFTWARE_VP9"]=="1" {
                if let session{VTDecompressionSessionInvalidate(session);self.session=nil}
                software=softwareVP9Create(Int32(info.width),Int32(info.height));guard software != nil else{throw ModLoadError.unsupported}
            }
            guard writer.startWriting() else{throw writer.error ?? ModLoadError.invalid};writer.startSession(atSourceTime:.zero);initialized=true
        }
        deinit{if let software{softwareVP9Destroy(software)};if let session{VTDecompressionSessionInvalidate(session)};if writer.status == .writing{writer.cancelWriting()}}
        func append(_ buffer:CVPixelBuffer,time:CMTime)throws {
            let deadline=Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                try PCModelConverter.check(progress);guard writer.status == .writing,Date()<deadline else{throw writer.error ?? ModLoadError.unsupported};Thread.sleep(forTimeInterval:0.002)
            }
            guard adaptor.append(buffer,withPresentationTime:time) else{throw writer.error ?? ModLoadError.invalid};decoded+=1
        }
        func frame(_ data:Data,time:CMTime)throws {
            try PCModelConverter.check(progress)
            if let software {
                let status=data.withUnsafeBytes{softwareVP9Decode(software,$0.baseAddress!,UInt(data.count))}
                guard status==0 else{NSLog("PJDV MOD VP9 software status %d",status);throw ModLoadError.unsupported}
                let deadline=Date().addingTimeInterval(30);var pixel:UnsafeMutableRawPointer?
                while pixel==nil {
                    try PCModelConverter.check(progress);guard writer.status == .writing,Date()<deadline else{throw ModLoadError.limit}
                    pixel=softwareVP9CopyPixel(software);if pixel==nil{Thread.sleep(forTimeInterval:0.002)}
                }
                let buffer=Unmanaged<CVPixelBuffer>.fromOpaque(pixel!).takeRetainedValue();try append(buffer,time:time);return
            }
            guard let session,let format else{throw ModLoadError.invalid}
            var block:CMBlockBuffer?,sample:CMSampleBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:data.count,blockAllocator:nil,customBlockSource:nil,offsetToData:0,dataLength:data.count,flags:0,blockBufferOut:&block)==noErr,let block else{throw ModLoadError.limit}
            let copied=data.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:data.count)}
            var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:time,decodeTimeStamp:.invalid),size=data.count
            guard copied==noErr,CMSampleBufferCreateReady(allocator:nil,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)==noErr,let sample else{throw ModLoadError.invalid}
            // Drain each submission before reading another frame. This bounds
            // decoded memory and keeps callback state on this serial worker.
            let status=VTDecompressionSessionDecodeFrame(session,sampleBuffer:sample,flags:[],frameRefcon:nil,infoFlagsOut:nil)
            guard status==noErr else{throw ModLoadError.unsupported}
            guard VTDecompressionSessionWaitForAsynchronousFrames(session)==noErr else{throw ModLoadError.unsupported}
            if let failure{throw failure}
        }
        func finish(expected:Int)throws {
            if let session {guard VTDecompressionSessionFinishDelayedFrames(session)==noErr,VTDecompressionSessionWaitForAsynchronousFrames(session)==noErr else{throw ModLoadError.unsupported}}
            else{guard software != nil else{throw ModLoadError.invalid}}
            if let failure{throw failure};guard decoded==expected else{throw ModLoadError.invalid}
            input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()}
            let deadline=Date().addingTimeInterval(30)
            while done.wait(timeout:.now()+0.1) != .success {try PCModelConverter.check(progress);guard Date()<deadline else{throw ModLoadError.invalid}}
            guard writer.status == .completed else{throw writer.error ?? ModLoadError.invalid}
        }
    }
    static func vp9Configuration(_ data:Data,info:Info)throws->Data {
        var bit=0
        func read(_ n:Int)throws->Int {guard bit+n<=data.count*8 else{throw ModLoadError.invalid};var v=0;for _ in 0..<n{v=(v<<1)|Int((data[bit/8] >> (7-bit%8))&1);bit+=1};return v}
        guard try read(2)==2 else{throw ModLoadError.unsupported};let low=try read(1),high=try read(1)
        guard low==0,high==0,try read(1)==0,try read(1)==0 else{throw ModLoadError.unsupported}
        _=try read(1);_=try read(1);guard try read(24)==0x498342 else{throw ModLoadError.invalid}
        let color=try read(3);guard color != 7,color != 6 else{throw ModLoadError.unsupported};let full=try read(1)
        let width=try read(16)+1,height=try read(16)+1
        guard width==info.width,height==info.height else{throw ModLoadError.unsupported}
        let matrix:UInt8 = color==2 ? 1 : (color==5 ? 9 : (color==0 ? 2 : 6))
        return Data([1,0,0,0,0,10,UInt8(0x82|full),matrix,matrix,matrix,0,0])
    }
    static func convert(_ source:URL,to output:URL,progress:Progress,report:((ModInstallUpdate)->Void)?=nil)throws {
        let fm=FileManager.default
        guard !fm.fileExists(atPath:output.path),source.standardizedFileURL != output.standardizedFileURL else{throw ModLoadError.invalid}
        let before=try PCModelConverter.hash(source,progress:progress)
        guard before.bytes<=16*1024*1024*1024 else{throw ModLoadError.limit}
        let file=try FileHandle(forReadingFrom:source);defer{try? file.close()}
        var lastReport=Date.distantPast
        var offset:UInt64=0,info:Info?,encoder:Encoder?,frames=0,last = -1,step=0,ended=false,success=false
        defer{if !success{encoder?.writer.cancelWriting();try? fm.removeItem(at:output)}}
        func bytes(_ at:UInt64,_ count:Int)throws->Data {
            guard at<=before.bytes,UInt64(count)<=before.bytes-at,count>=0,count<=16*1024*1024 else{throw ModLoadError.invalid}
            try file.seek(toOffset:at);let b=try file.read(upToCount:count) ?? Data();guard b.count==count else{throw ModLoadError.invalid};return b
        }
        while offset<before.bytes {
            try PCModelConverter.check(progress);let h=try bytes(offset,32),tag=String(data:h.prefix(4),encoding:.ascii) ?? ""
            guard offset != 0 || tag=="CRID",["CRID","@SFV","@SFA","@SBT","@CUE","@ALP"].contains(tag) else{throw ModLoadError.unsupported}
            let length=try F.u(h,4,4,true),header=try F.u(h,8,2,true),padding=try F.u(h,10,2,true)
            let end=offset+8+UInt64(length),start=offset+8+UInt64(header)
            guard header>=24,end<=before.bytes,padding<=length,end>=UInt64(padding),start<=end-UInt64(padding),end>offset else{throw ModLoadError.invalid}
            let stop=end-UInt64(padding);var at=start
            if tag=="@ALP",h[15]==0{throw ModLoadError.unsupported}
            if tag=="@SFV",h[15]==2 {ended = try bytes(at,min(32,Int(stop-at))).starts(with:Data("#CONTENTS END".utf8)) || ended}
            if tag=="@SFV",h[15]==0 {
                guard h[12]==0 else{throw ModLoadError.unsupported}
                if info==nil {
                    guard stop-at>=32 else{throw ModLoadError.invalid};let b=try bytes(at,32);at+=32
                    guard b.starts(with:Data("DKIF".utf8)),b.subdata(in:8..<12)==Data("VP90".utf8),try F.u(b,4,2)==0,try F.u(b,6,2)==32 else{throw ModLoadError.unsupported}
                    let w=try F.u(b,12,2),ht=try F.u(b,14,2),rate=try F.u(b,16),scale=try F.u(b,20),count=try F.u(b,24)
                    guard (1...4096).contains(w),(1...4096).contains(ht) else{throw ModLoadError.limit}
                    try F.ivfTimebase(rate:rate,scale:scale)
                    info=Info(width:w,height:ht,rate:rate,scale:scale,declared:count)
                }
                while at<stop {
                    try autoreleasepool {
                        try PCModelConverter.check(progress);guard stop-at>=12,let meta=info else{throw ModLoadError.invalid}
                        let header=try bytes(at,12),size=try F.u(header,0),stamp=try F.u(header,4,8);at+=12
                        guard size>0,size<=16*1024*1024,UInt64(size)<=stop-at,stamp>last,stamp<=1_000_000_000_000 else{throw ModLoadError.invalid}
                        let data=try bytes(at,size);at+=UInt64(size)
                        if encoder==nil {encoder=try Encoder(output,info:meta,config:vp9Configuration(data,info:meta),progress:progress)}
                        let time=CMTime(value:Int64(stamp)*Int64(meta.scale),timescale:Int32(meta.rate))
                        try encoder!.frame(data,time:time);if last>=0{step=stamp-last};last=stamp;frames+=1
                        guard frames<=1_000_000 else{throw ModLoadError.limit}
                    }
                }
                if Date().timeIntervalSince(lastReport)>0.2 {
                    lastReport=Date();report?(.init(phase:"正在转换 MOD 视频…",file:"",completed:end,total:before.bytes))
                }
                let space=try fm.attributesOfFileSystem(forPath:output.deletingLastPathComponent().path)
                guard (space[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0>=64*1024*1024 else{throw ModInstallError.storage}
            }
            offset=end
        }
        guard let info,let encoder,frames>0 else{throw ModLoadError.invalid}
        if info.declared != 0 && info.declared != frames {
            guard info.rate==1000,info.scale==1,ended,step>0,info.declared>=last,info.declared-last<=step+2 else{throw ModLoadError.invalid}
        }
        try encoder.finish(expected:frames)
        let after=try PCModelConverter.hash(source,progress:progress);guard before.bytes==after.bytes,before.sha256==after.sha256 else{throw ModPackageError.changedSource}
        success=true
    }
}
