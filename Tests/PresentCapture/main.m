#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#define DM_NVN_M3 1
#define PJDV_HAS_METALFX 0
#define CBUF id<MTLCommandBuffer>
#define BENC id<MTLBlitCommandEncoder>
#define MLOG(...) do { fprintf(stderr,__VA_ARGS__); fputc('\n',stderr); } while(0)
static id<MTLDevice> g_dev;
static uint64_t g_pjdv_dump_frame=42;
static _Atomic uint64_t g_pjdv_fx_direct_frames,g_pjdv_fx_copy_frames;
static _Atomic int residents;
static void res_add(id value){if(value)atomic_fetch_add(&residents,1);}
static void res_remove(id value){if(value)atomic_fetch_sub(&residents,1);}
static void res_commit(void){}
#include "pjdv_metalfx_capture.inc"
@interface OversizedTexture:NSObject
@end
@implementation OversizedTexture
-(NSUInteger)width{return 8192;}-(NSUInteger)height{return 8192;}
-(NSUInteger)sampleCount{return 1;}-(MTLTextureType)textureType{return MTLTextureType2D;}
-(MTLPixelFormat)pixelFormat{return MTLPixelFormatRGBA32Float;}
-(BOOL)framebufferOnly{return NO;}
@end
static id<MTLTexture> texture(MTLPixelFormat format,NSUInteger bpp,uint8_t value){
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:17 height:9 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 id<MTLTexture> t=[g_dev newTextureWithDescriptor:d];NSCAssert(t,@"texture");
 NSMutableData *data=[NSMutableData dataWithLength:17*9*bpp];memset(data.mutableBytes,value,data.length);
 [t replaceRegion:MTLRegionMake2D(0,0,17,9) mipmapLevel:0 withBytes:data.bytes bytesPerRow:17*bpp];return t;
}
static void completed(NSDictionary *capture,id<MTLCommandBuffer> cb){
 [cb commit];[cb waitUntilCompleted];NSCAssert(cb.status==MTLCommandBufferStatusCompleted,@"%@",cb.error);
 pjdv_fx_capture_complete(capture,YES);
 for(int i=0;i<1000 && atomic_load(&g_pjdv_capture_busy);i++)[NSThread sleepForTimeInterval:0.002];
 NSCAssert(!atomic_load(&g_pjdv_capture_busy) && !atomic_load(&residents),@"readback lifetime leaked");
}
int main(int argc,const char **argv){@autoreleasepool{
 NSCAssert(argc==3,@"output and mode required");NSString *root=@(argv[1]);
 NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:root],@"fresh output only");
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
 setenv("DM_TEMP",root.UTF8String,1);BOOL disabled=!strcmp(argv[2],"off"),legacy=!strcmp(argv[2],"legacy");
 if(!disabled)setenv(legacy?"PJDV_FX_CAPTURE":"PJDV_PRESENT_CAPTURE","1",1);
 g_dev=MTLCreateSystemDefaultDevice();if(!g_dev)return 77;id<MTLCommandQueue> q=[g_dev newCommandQueue];
 id<MTLTexture> a=texture(MTLPixelFormatRGBA8Unorm,4,0x11),b=texture(MTLPixelFormatBGRA8Unorm,4,0x33),c=texture(MTLPixelFormatRGBA16Float,8,0x55),d=texture(MTLPixelFormatBGRA8Unorm,4,0x77);
 id<MTLCommandBuffer> cb=[q commandBuffer];int crop[]={1,2,13,5};
 NSDictionary *cap=pjdv_fx_capture_encode(cb,a,b,c,d,crop,42,0);
 if(disabled){NSCAssert(!cap && !atomic_load(&residents),@"disabled path did work");puts("PASS disabled: no readback or files");return 0;}
 NSCAssert(cap && [cap[@"items"] count]==(legacy?2:4),@"all stages captured");
 g_pjdv_dump_frame=43;NSCAssert(!pjdv_fx_capture_encode(cb,a,b,c,d,crop,43,0),@"only one in flight");
 completed(cap,cb);
 NSArray *expected=legacy?@[@0x11,@0x33]:@[@0x11,@0x33,@0x55,@0x77];
 for(NSUInteger i=0;i<[cap[@"items"] count];i++){
  NSDictionary *item=cap[@"items"][i];NSData *data=[NSData dataWithContentsOfFile:[cap[@"prefix"] stringByAppendingFormat:@"-%@.raw",item[@"name"]]];
  const uint8_t *bytes=data.bytes;NSUInteger start=0;while(start<data.length && bytes[start]!='\n')start++;start++;
  NSUInteger bpp=i==2?8:4,row=[item[@"row"] unsignedIntegerValue];
  NSCAssert(data.length==start+row*9,@"format/pitch");
  for(NSUInteger y=0;y<9;y++)for(NSUInteger x=0;x<17*bpp;x++)NSCAssert(bytes[start+y*row+x]==[expected[i] unsignedCharValue],@"different stage/pixel bytes");
 }
 NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[cap[@"prefix"] stringByAppendingString:@".json"]] options:0 error:nil];
 NSCAssert(([meta[@"saved"] boolValue] && [meta[@"crop"] isEqual:@[@1,@2,@13,@5]]),@"receipt");
 if(!legacy){
  g_pjdv_dump_frame=44;cb=[q commandBuffer];cap=pjdv_fx_capture_encode(cb,a,nil,nil,d,NULL,44,0);
  NSCAssert([cap[@"items"] count]==2 && ![cap[@"spatial_applied"] boolValue] && ![cap[@"hdr_applied"] boolValue],@"SDR without Spatial");completed(cap,cb);
  g_pjdv_dump_frame=45;cb=[q commandBuffer];NSCAssert(!pjdv_fx_capture_encode(cb,(id)[OversizedTexture new],nil,nil,nil,NULL,45,0),@"budget");
  g_pjdv_dump_frame=46;NSCAssert(!pjdv_fx_capture_encode(cb,texture(MTLPixelFormatR8Unorm,1,5),nil,nil,nil,NULL,46,0),@"unsupported format");
  NSCAssert(!atomic_load(&g_pjdv_capture_busy) && !atomic_load(&residents),@"rejection cleanup");
 }
 puts("PASS actual GPU readback: stage identity, RGBA16F, padded rows, SDR bypass, legacy mode, bounds and lifetime");
}return 0;}
