#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#define PJDV_HAS_METALFX 1
#define PJDV_FG_ALGORITHM_TEST 1
static _Atomic int g_pjdv_upscale_mode,g_pjdv_upscale_state;
#include "pjdv_game_fg.inc"
int main(){@autoreleasepool{
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device || ![MTLFXSpatialScalerDescriptor supportsDevice:device]){fprintf(stderr,"SKIP: MetalFX Spatial unavailable\n");return 77;}
    id<MTLCommandQueue> queue=[device newCommandQueue];PJDVGameFG *fg=[PJDVGameFG new];
    const int w=320,h=180,ow=640,oh=360;
    NSCAssert([fg prepare:device width:w height:h format:MTLPixelFormatBGRA8Unorm],@"FG pipeline");
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;id<MTLTexture> src=[device newTextureWithDescriptor:td];
    td.width=ow;td.height=oh;td.pixelFormat=MTLPixelFormatBGRA8Unorm;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> dst=[device newTextureWithDescriptor:td];
    uint8_t *pixels=calloc(w*h,4),*out=calloc(ow*oh,4);
    for(int frame=0;frame<4;frame++){
        atomic_store(&g_pjdv_upscale_mode,frame!=3);
        for(int y=0;y<h;y++)for(int x=0;x<w;x++){int i=4*(y*w+x);pixels[i]=(x+frame*4)%256;pixels[i+1]=y%256;pixels[i+2]=((x/8+y/8)&1)?220:30;pixels[i+3]=255;}
        [src replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:pixels bytesPerRow:w*4];
        id<MTLBuffer> stats=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];memset(stats.contents,0,16);
        id<MTLCommandBuffer> cb=[queue commandBuffer];BOOL made=[fg source:src crop:NULL command:cb destination:dst stats:stats];
        [cb commit];[cb waitUntilCompleted];NSCAssert(cb.status==MTLCommandBufferStatusCompleted,@"%@",cb.error);
        NSCAssert(atomic_load(&g_pjdv_upscale_state)==(frame==3?0:1),@"Spatial bypassed selected mode");
        if(frame<3){PJDVFGSpatial *fx=(PJDVFGSpatial *)fg.spatial;NSCAssert(fx.output.width==ow && fx.output.height==oh,@"Wrong output size");}
        [dst getBytes:out bytesPerRow:ow*4 fromRegion:MTLRegionMake2D(0,0,ow,oh) mipmapLevel:0];
        unsigned sum=0;for(int i=0;i<ow*oh;i++)sum+=out[4*i]+out[4*i+1]+out[4*i+2];NSCAssert(sum>ow*oh*50,@"Empty upscale output");
        printf("frame=%d generated=%d Spatial=%d output=%dx%d GPUms=%.3f\n",frame,made,atomic_load(&g_pjdv_upscale_state),ow,oh,(cb.GPUEndTime-cb.GPUStartTime)*1000);
    }
    free(pixels);free(out);printf("PASS Spatial on first real and generated frames, off switch, output readback\n");
}return 0;}
