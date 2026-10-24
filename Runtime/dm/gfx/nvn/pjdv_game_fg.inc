// Experimental image-based interpolation of actual NVN game frames. This is
// intentionally NOT called MetalFX: there are no authenticated game motion
// vectors/depth/UI layer in this compatibility layer yet. All UI is in color.
#import <simd/simd.h>
#include "pjdv_game_fg_shader.inc"
#include "pjdv_fg_policy.h"
#include "pjdv_fg_spatial.inc"
#ifdef PJDV_FG_ALGORITHM_TEST
static int pjdv_game_frame_generation_mode(void) { return 2; }
#endif
@interface PJDVGameFG : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLRenderPipelineState> capturePSO, displayPSO;
@property(nonatomic,strong) id<MTLComputePipelineState> flowPSO, midpointPSO;
@property(nonatomic,strong) id<MTLTexture> previous, current, midpoint, forward, backward;
@property(nonatomic,strong) NSObject *spatial;
@property(nonatomic) BOOL history, pendingReal;
@property(nonatomic) NSUInteger width,height;
@property(nonatomic) MTLPixelFormat displayFormat;
@property(nonatomic) double lastSourceTime;
@property(nonatomic) uint64_t epoch;
- (BOOL)prepare:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format;
- (void)copy:(id<MTLCommandBuffer>)cb source:(id<MTLTexture>)source destination:(id<MTLTexture>)destination rect:(vector_float4)rect;
- (BOOL)source:(id<MTLTexture>)source crop:(const int *)crop command:(id<MTLCommandBuffer>)cb destination:(id<MTLTexture>)destination stats:(id<MTLBuffer>)stats;
@end
@implementation PJDVGameFG
- (BOOL)prepare:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format {
    if(self.current && self.width==width && self.height==height && self.displayFormat==format)return YES;
    if(width<16 || height<16 || width>1920 || height>1080 || format==MTLPixelFormatRGBA16Float)return NO;
    self.device=device;NSError *error=nil;
    id<MTLLibrary> lib=[device newLibraryWithSource:pjdv_game_fg_shader options:nil error:&error];
    if(!lib){NSLog(@"PJDV game FG shader error: %@",error);return NO;}
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"fgVertex"];pd.fragmentFunction=[lib newFunctionWithName:@"fgCopy"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    self.capturePSO=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    pd.colorAttachments[0].pixelFormat=format;
    self.displayPSO=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    self.flowPSO=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fgFlow"] error:&error];
    self.midpointPSO=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fgMidpoint"] error:&error];
    if(!self.capturePSO || !self.displayPSO || !self.flowPSO || !self.midpointPSO){NSLog(@"PJDV game FG pipeline error: %@",error);return NO;}
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    self.previous=[device newTextureWithDescriptor:d];self.current=[device newTextureWithDescriptor:d];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;self.midpoint=[device newTextureWithDescriptor:d];
    d.width=(width+15)/16;d.height=(height+15)/16;d.pixelFormat=MTLPixelFormatRGBA16Float;
    self.forward=[device newTextureWithDescriptor:d];self.backward=[device newTextureWithDescriptor:d];
    if(!self.previous || !self.current || !self.midpoint || !self.forward || !self.backward)return NO;
    self.previous.label=@"PJDV FG previous real NVN frame";self.current.label=@"PJDV FG current real NVN frame";
    self.midpoint.label=@"PJDV FG motion-compensated midpoint";
    self.width=width;self.height=height;self.displayFormat=format;self.history=NO;self.pendingReal=NO;
    return YES;
}
- (void)copy:(id<MTLCommandBuffer>)cb source:(id<MTLTexture>)source destination:(id<MTLTexture>)destination rect:(vector_float4)rect {
#if PJDV_HAS_METALFX
    if(destination!=self.current && destination!=self.previous){
        if(@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)){
            if(!self.spatial)self.spatial=[PJDVFGSpatial new];
            id<MTLTexture> scaled=[(PJDVFGSpatial *)self.spatial encode:cb source:source destination:destination device:self.device];
            if(scaled)source=scaled;
        }
    }
#endif
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=destination;rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
#if PJDV_HAS_METALFX
    if(@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)){
        PJDVFGSpatial *fx=(PJDVFGSpatial *)self.spatial;
        if(fx && source==fx.output)[en waitForFence:fx.scaler.fence beforeStages:MTLRenderStageFragment];
    }
#endif
    // Exact-size snapshots fill the texture; display preserves the game aspect.
    double w=destination.width,h=destination.height,aspect=self.width/(double)self.height;
    if(destination==self.current || destination==self.previous)aspect=w/h;
    double vw=fmin(w,h*aspect),vh=vw/aspect;
    [en setViewport:(MTLViewport){floor((w-vw)/2),floor((h-vh)/2),round(vw),round(vh),0,1}];
    [en setRenderPipelineState:destination.pixelFormat==MTLPixelFormatRGBA8Unorm?self.capturePSO:self.displayPSO];
    [en setFragmentTexture:source atIndex:0];[en setFragmentBytes:&rect length:sizeof rect atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[en endEncoding];
}
- (BOOL)source:(id<MTLTexture>)source crop:(const int *)crop command:(id<MTLCommandBuffer>)cb destination:(id<MTLTexture>)destination stats:(id<MTLBuffer>)stats {
    double now=CACurrentMediaTime();
    if(self.lastSourceTime && now-self.lastSourceTime>5.0/pjdv_fg_source_hz(pjdv_game_frame_generation_mode()))self.history=NO;
    self.lastSourceTime=now;
    id<MTLTexture> old=self.previous;self.previous=self.current;self.current=old;
    vector_float4 rect={0,0,1,1};
    if(crop && (crop[2] || crop[3]))rect=(vector_float4){crop[0]/(float)source.width,crop[1]/(float)source.height,crop[2]/(float)source.width,crop[3]/(float)source.height};
    [self copy:cb source:source destination:self.current rect:rect];
    BOOL generated=self.history;
    if(generated){
        for(int direction=0;direction<2;direction++){
            id<MTLComputeCommandEncoder> en=[cb computeCommandEncoder];[en setComputePipelineState:self.flowPSO];
            [en setTexture:direction?self.current:self.previous atIndex:0];[en setTexture:direction?self.previous:self.current atIndex:1];
            [en setTexture:direction?self.backward:self.forward atIndex:2];[en setBuffer:stats offset:0 atIndex:0];
            [en dispatchThreads:MTLSizeMake(self.forward.width,self.forward.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[en endEncoding];
        }
        id<MTLComputeCommandEncoder> en=[cb computeCommandEncoder];[en setComputePipelineState:self.midpointPSO];
        [en setTexture:self.previous atIndex:0];[en setTexture:self.current atIndex:1];[en setTexture:self.forward atIndex:2];
        [en setTexture:self.backward atIndex:3];[en setTexture:self.midpoint atIndex:4];[en setBuffer:stats offset:0 atIndex:0];
        [en dispatchThreads:MTLSizeMake(self.width,self.height,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];[en endEncoding];
    }
    [self copy:cb source:generated?self.midpoint:self.current destination:destination rect:(vector_float4){0,0,1,1}];
    self.history=YES;self.pendingReal=YES;return generated;
}
@end

#ifndef PJDV_FG_ALGORITHM_TEST
extern double pjdv_presented_fps(void) __attribute__((weak_import));
static PJDVGameFG *g_game_fg;
#if !DM_NVN_M3
static id<MTLSharedEvent> g_fg_return_event;
static uint64_t g_fg_return_value;
#endif
static _Atomic int g_fg_capture;
static void pjdv_fg_capture_complete(NSArray *items,NSUInteger w,NSUInteger h){
    const char *root=getenv("DM_TEMP");if(!root)return;
    for(NSArray *item in items){id<MTLBuffer> buffer=item[1];NSString *name=item[0];
        NSUInteger iw=item.count>2?[item[2] unsignedIntegerValue]:w,ih=item.count>3?[item[3] unsignedIntegerValue]:h;
        BOOL bgra=item.count>4 && [item[4] boolValue];
        CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();CGContextRef cx=CGBitmapContextCreate(buffer.contents,iw,ih,8,iw*4,cs,bgra?(kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little):(kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big));
        CGImageRef image=cx?CGBitmapContextCreateImage(cx):NULL;
        NSURL *url=[NSURL fileURLWithPath:[@(root) stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]];
        CGImageDestinationRef dst=image?CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL):NULL;
        if(dst){CGImageDestinationAddImage(dst,image,NULL);CGImageDestinationFinalize(dst);CFRelease(dst);}if(image)CGImageRelease(image);if(cx)CGContextRelease(cx);CGColorSpaceRelease(cs);
    }
}
static _Atomic uint64_t g_game_fg_epoch;
static _Atomic uint64_t g_fg_source_count,g_fg_generated_count,g_fg_real_count,g_fg_cut_count,g_fg_errors,g_fg_bypass_count;
static _Atomic double g_fg_gpu_ms,g_fg_real_gpu_ms,g_fg_source_rate,g_fg_generated_rate;
double pjdv_game_fg_source_fps(void){return atomic_load(&g_fg_source_rate);}
double pjdv_game_fg_generated_fps(void){return atomic_load(&g_fg_generated_rate);}
static void pjdv_game_fg_reset(void){atomic_fetch_add(&g_game_fg_epoch,1);}
static void pjdv_game_fg_report(void){
    static double last;static uint64_t sources,generated;double now=CACurrentMediaTime();if(now-last<1)return;
    uint64_t sc=atomic_load(&g_fg_source_count),gc=atomic_load(&g_fg_generated_count);
    double dt=last?now-last:0;atomic_store(&g_fg_source_rate,dt?(sc-sources)/dt:0);atomic_store(&g_fg_generated_rate,dt?(gc-generated)/dt:0);
    sources=sc;generated=gc;last=now;
    if(getenv("PJDV_FG_CAPTURE")){
        static unsigned long long previous;char path[1600];const char *root=getenv("DM_TEMP");
        if(root){snprintf(path,sizeof path,"%s/fg-capture.request",root);FILE *file=fopen(path,"r");unsigned long long token=0;
            if(file){if(fscanf(file,"%llu",&token)==1 && token && token!=previous){previous=token;atomic_store(&g_fg_capture,1);}fclose(file);}}
    }
    const char *root=getenv("DM_TEMP");if(!root)return;
    NSDictionary *data=@{@"mode":@(pjdv_game_frame_generation_mode()),@"backend":@"image-based bidirectional block flow; NOT MetalFX",@"gameAttached":@YES,
        @"sourceFPS":@(atomic_load(&g_fg_source_rate)),@"generatedFPS":@(atomic_load(&g_fg_generated_rate)),@"sourceFrames":@(sc),
        @"generatedPresented":@(gc),@"realPresented":@(atomic_load(&g_fg_real_count)),@"cutBypasses":@(atomic_load(&g_fg_cut_count)),
        @"errors":@(atomic_load(&g_fg_errors)),@"lastFGGPUms":@(atomic_load(&g_fg_gpu_ms)),@"sourceTarget":@(pjdv_fg_source_hz(pjdv_game_frame_generation_mode())),@"displayTarget":@(pjdv_fg_output_hz(pjdv_game_frame_generation_mode())),@"lastRealCopyGPUms":@(atomic_load(&g_fg_real_gpu_ms)),@"bypassPresented":@(atomic_load(&g_fg_bypass_count)),
        @"presentedFPS":@(pjdv_presented_fps?pjdv_presented_fps():0),@"upscaleStatus":@(pjdv_upscale_status()),
        @"scope":pjdv_game_frame_generation_mode()==2?@"source60 retained; whole color frame including chart/UI; extra display latency; rhythm timing not qualified":@"whole color frame including chart/UI; source pacing changed; rhythm timing not qualified"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[@(root) stringByAppendingPathComponent:@"game-fg.json"] atomically:YES];
}
static void pjdv_game_fg_commit(id<MTLCommandBuffer> cb,id<CAMetalDrawable> dr,uint64_t ticket,BOOL generated,id<MTLBuffer> stats){
    pthread_mutex_lock(&g_pq_mu);g_pq_inflight++;pthread_mutex_unlock(&g_pq_mu);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done){
        if(done.error){atomic_fetch_add(&g_fg_errors,1);pjdv_set_game_frame_generation(0);MLOG("PJDV game FG GPU error, reverting native60: %s",done.error.description.UTF8String);}
        else{
            if(stats)atomic_store(&g_fg_gpu_ms,(done.GPUEndTime-done.GPUStartTime)*1000);
            else atomic_store(&g_fg_real_gpu_ms,(done.GPUEndTime-done.GPUStartTime)*1000);
            if(stats){const uint32_t *s=stats.contents;if(s[0] && s[1]*2>s[0])atomic_fetch_add(&g_fg_cut_count,1);}
#if TARGET_OS_SIMULATOR
            extern void pjdv_frame_presented(double);pjdv_frame_presented(done.GPUEndTime);
            BOOL bypass=NO;if(generated && stats){const uint32_t *s=stats.contents;bypass=s[0] && s[1]*2>s[0];}
            atomic_fetch_add(bypass?&g_fg_bypass_count:generated?&g_fg_generated_count:&g_fg_real_count,1);
#endif
        }
        pthread_mutex_lock(&g_pq_mu);if(ticket>g_pq_done)g_pq_done=ticket;g_pq_inflight--;pthread_cond_broadcast(&g_pq_cv);pthread_mutex_unlock(&g_pq_mu);
    }];
#if !TARGET_OS_SIMULATOR
    [dr addPresentedHandler:^(id<MTLDrawable> d){if(d.presentedTime>0){extern void pjdv_frame_presented(double);pjdv_frame_presented(d.presentedTime);
        BOOL bypass=NO;if(generated && stats){const uint32_t *s=stats.contents;bypass=s[0] && s[1]*2>s[0];}
            atomic_fetch_add(bypass?&g_fg_bypass_count:generated?&g_fg_generated_count:&g_fg_real_count,1);if(ticket)g_pres[ticket%PRING]=(pres_ent){ticket,d.presentedTime};}}];
#endif
#if !DM_NVN_M3
    // Returning the source ticket alone does not order later Metal4 writes
    // against this traditional queue. Enqueue the return barrier before any
    // subsequent link tick can coalesce tickets and release a swapchain image.
    if(!g_fg_return_event)g_fg_return_event=[g_dev newSharedEvent];
    uint64_t value=++g_fg_return_value;[cb encodeSignalEvent:g_fg_return_event value:value];
    [cb presentDrawable:dr];[cb commit];[g_q4 waitForEvent:g_fg_return_event value:value];
#else
    [cb presentDrawable:dr];[cb commit];
#endif
    pjdv_game_fg_report();
}
static int pjdv_game_fg_pending(id<CAMetalDrawable> dr){
    if(!g_game_fg || !pjdv_game_frame_generation_mode() || !g_game_fg.pendingReal)return 0;
    if(g_game_fg.epoch!=atomic_load(&g_game_fg_epoch)){g_game_fg.pendingReal=NO;g_game_fg.history=NO;return 0;}
    id<MTLCommandBuffer> cb=[g_q commandBuffer];if(!cb)return 0;
    [g_game_fg copy:cb source:g_game_fg.current destination:dr.texture rect:(vector_float4){0,0,1,1}];g_game_fg.pendingReal=NO;
    pjdv_game_fg_commit(cb,dr,0,NO,nil);return 1;
}
static int pjdv_game_fg_present(id<MTLTexture> src,const int crop[4],id<CAMetalDrawable> dr,uint64_t frame,uint64_t ticket,uint64_t sourceFence){
    if(!pjdv_game_frame_generation_mode()){if(g_game_fg){g_game_fg.history=NO;g_game_fg.pendingReal=NO;pjdv_game_fg_report();}return 0;}
    NSUInteger w=src.width,h=src.height;
    if(crop && (crop[2] || crop[3])){
        if(crop[0]<0 || crop[1]<0 || crop[2]<=0 || crop[3]<=0 || (uint64_t)crop[0]+crop[2]>w || (uint64_t)crop[1]+crop[3]>h){pjdv_set_game_frame_generation(0);return 0;}
        w=crop[2];h=crop[3];
    }
    if(!g_game_fg)g_game_fg=[PJDVGameFG new];
    if(![g_game_fg prepare:g_dev width:w height:h format:dr.texture.pixelFormat]){pjdv_set_game_frame_generation(0);MLOG("PJDV game FG unavailable for this surface, reverting native60");return 0;}
    uint64_t epoch=atomic_load(&g_game_fg_epoch);if(g_game_fg.epoch!=epoch){g_game_fg.history=NO;g_game_fg.pendingReal=NO;g_game_fg.epoch=epoch;}
    id<MTLCommandBuffer> cb=[g_q commandBuffer];if(!cb){pjdv_set_game_frame_generation(0);return 0;}
#if !DM_NVN_M3
    // The immutable fence is captured when this game image is enqueued. Never
    // wait on the submit thread's mutable latest fence (cross-queue deadlock).
    [cb encodeWaitForEvent:g_ev value:sourceFence];
#endif
    id<MTLBuffer> stats=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];if(!stats){pjdv_set_game_frame_generation(0);return 0;}
    memset(stats.contents,0,16);
    BOOL generated=[g_game_fg source:src crop:crop command:cb destination:dr.texture stats:stats];
    if(generated && atomic_exchange(&g_fg_capture,0)){
        NSMutableArray *items=[NSMutableArray array];id<MTLBlitCommandEncoder> en=[cb blitCommandEncoder];
        NSMutableArray *textures=[@[g_game_fg.previous,g_game_fg.current,g_game_fg.midpoint] mutableCopy];NSMutableArray *names=[@[@"fg-previous",@"fg-current",@"fg-generated"] mutableCopy];
#if PJDV_HAS_METALFX
        if(@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)){
            PJDVFGSpatial *fx=(PJDVFGSpatial *)g_game_fg.spatial;
            if(fx.output){[textures addObject:fx.output];[names addObject:@"fg-spatial-output"];}
        }
#endif
        for(NSUInteger i=0;i<textures.count;i++){id<MTLTexture> texture=textures[i];NSUInteger tw=texture.width,th=texture.height;id<MTLBuffer> buffer=[g_dev newBufferWithLength:tw*th*4 options:MTLResourceStorageModeShared];
            [en copyFromTexture:textures[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(tw,th,1)
                toBuffer:buffer destinationOffset:0 destinationBytesPerRow:tw*4 destinationBytesPerImage:tw*th*4];[items addObject:@[names[i],buffer,@(tw),@(th),@(texture.pixelFormat==MTLPixelFormatBGRA8Unorm)]];}
        [en endEncoding];NSArray *immutable=[items copy];[cb addCompletedHandler:^(id<MTLCommandBuffer> done){if(!done.error)pjdv_fg_capture_complete(immutable,w,h);}];
    }
    atomic_fetch_add(&g_fg_source_count,1);
    pjdv_game_fg_commit(cb,dr,ticket,generated,stats);(void)frame;return 1;
}
#endif
