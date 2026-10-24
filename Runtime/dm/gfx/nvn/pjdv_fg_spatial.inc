// The image-flow experiment uses a conventional command buffer even when the
// game uses Metal 4. Keep Spatial on that same queue for both real and generated
// frames; do not silently replace the user's MetalFX output with linear scaling.
#if PJDV_HAS_METALFX
API_AVAILABLE(macos(13.0), macCatalyst(16.0), ios(16.0))
@interface PJDVFGSpatial : NSObject
@property(nonatomic,strong) id<MTLFXSpatialScaler> scaler;
@property(nonatomic,strong) id<MTLTexture> input,output;
- (id<MTLTexture>)encode:(id<MTLCommandBuffer>)cb source:(id<MTLTexture>)src destination:(id<MTLTexture>)dst device:(id<MTLDevice>)device;
@end
@implementation PJDVFGSpatial
- (id<MTLTexture>)encode:(id<MTLCommandBuffer>)cb source:(id<MTLTexture>)src destination:(id<MTLTexture>)dst device:(id<MTLDevice>)device {
    if(!atomic_load(&g_pjdv_upscale_mode)){atomic_store(&g_pjdv_upscale_state,0);return nil;}
    if(![MTLFXSpatialScalerDescriptor supportsDevice:device]){atomic_store(&g_pjdv_upscale_state,2);return nil;}
    double scale=fmin((double)dst.width/src.width,(double)dst.height/src.height);
    if(scale<=1){atomic_store(&g_pjdv_upscale_state,3);return nil;}
    NSUInteger ow=llround(src.width*scale),oh=llround(src.height*scale);
    if(!self.scaler || self.scaler.inputWidth!=src.width || self.scaler.inputHeight!=src.height || self.output.width!=ow || self.output.height!=oh || self.output.pixelFormat!=dst.pixelFormat){
        MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];
        d.inputWidth=src.width;d.inputHeight=src.height;d.outputWidth=ow;d.outputHeight=oh;
        d.colorTextureFormat=src.pixelFormat;d.outputTextureFormat=dst.pixelFormat;
        d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLFXSpatialScaler> next=[d newSpatialScalerWithDevice:device];
        if(!next){atomic_store(&g_pjdv_upscale_state,4);return nil;}
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width height:src.height mipmapped:NO];
        td.storageMode=MTLStorageModePrivate;td.usage=next.colorTextureUsage;
        id<MTLTexture> input=[device newTextureWithDescriptor:td];
        td.width=ow;td.height=oh;td.pixelFormat=dst.pixelFormat;td.usage=next.outputTextureUsage|MTLTextureUsageShaderRead;
        id<MTLTexture> output=[device newTextureWithDescriptor:td];
        if(!input || !output){atomic_store(&g_pjdv_upscale_state,4);return nil;}
        next.fence=[device newFence];self.scaler=next;self.input=input;self.output=output;
        self.output.label=@"PJDV FG MetalFX Spatial display output";
        NSLog(@"PJDV FG MetalFX Spatial %lux%lu -> %lux%lu",src.width,src.height,ow,oh);
    }
    BOOL direct=(src.usage&self.scaler.colorTextureUsage)==self.scaler.colorTextureUsage;
    if(!direct){id<MTLBlitCommandEncoder> en=[cb blitCommandEncoder];
        [en copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(src.width,src.height,1) toTexture:self.input destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[en endEncoding];}
    self.scaler.colorTexture=direct?src:self.input;self.scaler.outputTexture=self.output;
    self.scaler.inputContentWidth=src.width;self.scaler.inputContentHeight=src.height;
    [self.scaler encodeToCommandBuffer:cb];atomic_store(&g_pjdv_upscale_state,1);return self.output;
}
@end
#endif
