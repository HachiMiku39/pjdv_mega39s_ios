// Final tone-mapped color only: Spatial does not generate frames or alter song time.
// The original game has already composited its chart; separate high-resolution
// chart rendering requires a later NVN render-graph hook, not a claim here.
static _Atomic int g_pjdv_upscale_mode, g_pjdv_upscale_state;
static _Atomic uint64_t g_pjdv_fx_direct_frames, g_pjdv_fx_copy_frames;
void pjdv_set_upscale_mode(int mode) { atomic_store(&g_pjdv_upscale_mode, mode == 1); }
int pjdv_upscale_status(void) { return atomic_load(&g_pjdv_upscale_state); }
int pjdv_metalfx_supported(void *device) {
#if PJDV_HAS_METALFX
    if (pjdv_test_macos11_api()) return 0;
    if (@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *)) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
#if DM_NVN_M3
    return dev && [MTLFXSpatialScalerDescriptor supportsDevice:dev];
#else
    return dev && [MTLFXSpatialScalerDescriptor supportsMetal4FX:dev];
#endif
    }
    return 0;
#else
    (void)device; return 0;
#endif
}
#if PJDV_HAS_METALFX
API_AVAILABLE(macos(13.0), macCatalyst(16.0), ios(16.0))
@interface PJDVSpatialSlot : NSObject
@property(nonatomic, strong) id<MTLFXSpatialScalerBase> scaler;
@property(nonatomic, strong) id<MTLTexture> input, output;
@end
@implementation PJDVSpatialSlot @end
static PJDVSpatialSlot *g_pjdv_spatial[3] API_AVAILABLE(macos(13.0), macCatalyst(16.0), ios(16.0));
#if !DM_NVN_M3
static id<MTL4Compiler> g_pjdv_fx_compiler;
#endif
#endif
static id<MTLTexture> pjdv_spatial_encode_impl(CBUF cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int slotIndex) API_AVAILABLE(macos(13.0), macCatalyst(16.0), ios(16.0)) {
    if (!atomic_load(&g_pjdv_upscale_mode)) { atomic_store(&g_pjdv_upscale_state, 0); return nil; }
    if(!cb || !src || !dst || slotIndex<0 || slotIndex>=3){atomic_store(&g_pjdv_upscale_state,3);return nil;}
#if PJDV_HAS_METALFX
    if (!pjdv_metalfx_supported((__bridge void *)g_dev)) { atomic_store(&g_pjdv_upscale_state, 2); return nil; }
    NSUInteger x=0,y=0,w=src.width,h=src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0]<0 || crop[1]<0 || crop[2]<=0 || crop[3]<=0 ||
            (uint64_t)crop[0]+crop[2]>src.width || (uint64_t)crop[1]+crop[3]>src.height) { atomic_store(&g_pjdv_upscale_state,3); return nil; }
        x=crop[0];y=crop[1];w=crop[2];h=crop[3];
    }
    double scale=fmin((double)dst.width/w,(double)dst.height/h);
    NSUInteger ow=(NSUInteger)llround(w*scale),oh=(NSUInteger)llround(h*scale);
    if (scale<=1.0 || (src.pixelFormat!=MTLPixelFormatRGBA8Unorm && src.pixelFormat!=MTLPixelFormatBGRA8Unorm)) {
        atomic_store(&g_pjdv_upscale_state,3);return nil;
    }
    PJDVSpatialSlot *slot=g_pjdv_spatial[slotIndex];
    if (!slot || slot.scaler.inputWidth!=w || slot.scaler.inputHeight!=h || slot.scaler.colorTextureFormat!=src.pixelFormat ||
        slot.output.width!=ow || slot.output.height!=oh || slot.output.pixelFormat!=dst.pixelFormat) {
        MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];
        d.inputWidth=w;d.inputHeight=h;d.outputWidth=ow;d.outputHeight=oh;
        d.colorTextureFormat=src.pixelFormat;d.outputTextureFormat=dst.pixelFormat;
        d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
        PJDVSpatialSlot *next=[PJDVSpatialSlot new];
#if DM_NVN_M3
        next.scaler=[d newSpatialScalerWithDevice:g_dev];
#else
        if (!g_pjdv_fx_compiler) { NSError *error=nil;
            g_pjdv_fx_compiler=[g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
            if (!g_pjdv_fx_compiler) MLOG("PJDV MetalFX compiler: %s",error.description.UTF8String);
        }
        if(g_pjdv_fx_compiler)next.scaler=[d newSpatialScalerWithDevice:g_dev compiler:g_pjdv_fx_compiler];
#endif
        if (!next.scaler) { atomic_store(&g_pjdv_upscale_state,4);return nil; }
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst.pixelFormat width:ow height:oh mipmapped:NO];
        td.storageMode=MTLStorageModePrivate;td.usage=next.scaler.outputTextureUsage|MTLTextureUsageShaderRead;
        next.output=[g_dev newTextureWithDescriptor:td];
        if(!next.output){atomic_store(&g_pjdv_upscale_state,4);return nil;}
        next.output.label=@"PJDV MetalFX display-size output";
#if !DM_NVN_M3
        next.scaler.fence=[g_dev newFence];
#endif
        // Caller waited for this ring slot's GPU completion before reuse/retirement.
        if(slot){slot.scaler.colorTexture=nil;if(slot.input)res_remove(slot.input);res_remove(slot.output);}
        res_add(next.output);res_commit();
        g_pjdv_spatial[slotIndex]=next;slot=next;
        MLOG("PJDV MetalFX Spatial slot=%d %lux%lu -> %lux%lu, perceptual, no frame generation",slotIndex,
            (unsigned long)w,(unsigned long)h,(unsigned long)ow,(unsigned long)oh);
    }
    // Full-size, compatible NVN swapchain textures can be sampled directly.
    // The present ticket owns the source until completion; cropped/incompatible
    // sources retain the exact-copy fallback, with one scratch texture per slot.
    BOOL direct=x==0 && y==0 && w==src.width && h==src.height &&
        (src.usage & slot.scaler.colorTextureUsage)==slot.scaler.colorTextureUsage;
    if(!direct && !slot.input) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:w height:h mipmapped:NO];
        td.storageMode=MTLStorageModePrivate;td.usage=slot.scaler.colorTextureUsage;
        slot.input=[g_dev newTextureWithDescriptor:td];
        if(!slot.input){atomic_store(&g_pjdv_upscale_state,4);return nil;}
        slot.input.label=@"PJDV MetalFX exact crop fallback";res_add(slot.input);res_commit();
    }
    BENC copy=nil;
#if DM_NVN_M3
    if(!direct)copy=[cb blitCommandEncoder];
#else
    copy=[cb computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    if(!direct)[copy copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(w,h,1)
                toTexture:slot.input destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
#if !DM_NVN_M3
    [copy updateFence:slot.scaler.fence afterEncoderStages:MTLStageAll];
    [copy barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    [copy endEncoding];
    slot.scaler.colorTexture=direct?src:slot.input;slot.scaler.outputTexture=slot.output;
    if(direct)atomic_fetch_add(&g_pjdv_fx_direct_frames,1);else atomic_fetch_add(&g_pjdv_fx_copy_frames,1);
    slot.scaler.inputContentWidth=w;slot.scaler.inputContentHeight=h;
#if DM_NVN_M3
    [(id<MTLFXSpatialScaler>)slot.scaler encodeToCommandBuffer:cb];
#else
    [(id<MTL4FXSpatialScaler>)slot.scaler encodeToCommandBuffer:cb];
#endif
    atomic_store(&g_pjdv_upscale_state,1);return slot.output;
#else
    (void)cb;(void)src;(void)dst;(void)crop;(void)slotIndex;
    atomic_store(&g_pjdv_upscale_state,2);return nil;
#endif
}


static id<MTLTexture> pjdv_spatial_encode(CBUF cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int slotIndex) {
    if (@available(macOS 13.0, macCatalyst 16.0, iOS 16.0, *))
        return pjdv_spatial_encode_impl(cb,src,dst,crop,slotIndex);
    atomic_store(&g_pjdv_upscale_state,atomic_load(&g_pjdv_upscale_mode)?2:0);
    return nil;
}
