#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__); abort(); } while(0)
#define MLOG(...) do { fprintf(stderr,__VA_ARGS__); fputc('\n',stderr); } while(0)
#include "pjdv_movie_origin.inc"
static id<MTLDevice> device;
static NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
"struct main0_in {float2 m_24 [[attribute(0)]]; float2 m_26 [[attribute(2)]];};\n"
"struct main0_out {float4 gl_Position [[position]]; float2 m_31 [[user(locn1)]];};\n"
"vertex main0_out main0(main0_in in [[stage_in]]) {\n"
"    main0_out out;out.gl_Position=float4(in.m_24,0,1);\n"
"    out.m_31.x = in.m_26.x;\n    out.m_31.y = in.m_26.y;\n"
"    return out;\n}\n"
"fragment float4 sampleMovie(main0_out in [[stage_in]],texture2d<float> image [[texture(0)]]) {constexpr sampler s(coord::normalized,filter::nearest);return image.sample(s,in.m_31);}\n";
static NSData *render(BOOL fixed,int width,int height,int activeW,int activeH){
 NSError *error=nil;NSString *msl=fixed?pjdv_movie_origin_source(source,@"36f85460a1ac1b59_b.metallib"):source;
 id<MTLLibrary> lib=[device newLibraryWithSource:msl options:nil error:&error];NSCAssert(lib,@"%@",error);
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"main0"];d.fragmentFunction=[lib newFunctionWithName:@"sampleMovie"];
 d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;d.vertexDescriptor=[MTLVertexDescriptor vertexDescriptor];
 for(int i=0;i<2;i++){int a=i?2:0;d.vertexDescriptor.attributes[a].format=MTLVertexFormatFloat2;d.vertexDescriptor.attributes[a].offset=i*8;d.vertexDescriptor.attributes[a].bufferIndex=0;}d.vertexDescriptor.layouts[0].stride=16;
 id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:d error:&error];NSCAssert(pipeline,@"%@",error);
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
 id<MTLTexture> output=[device newTextureWithDescriptor:td];td.width=activeW;td.height=activeH;td.usage=MTLTextureUsageShaderRead;id<MTLTexture> input=[device newTextureWithDescriptor:td];
 NSMutableData *pixels=[NSMutableData dataWithLength:activeW*activeH*4];uint8_t *p=pixels.mutableBytes;
 for(int y=0;y<activeH;y++)for(int x=0;x<activeW;x++){int i=(y*activeW+x)*4;p[i]=x+17;p[i+1]=y+31;p[i+2]=x+y+53;p[i+3]=255;}
 [input replaceRegion:MTLRegionMake2D(0,0,activeW,activeH) mipmapLevel:0 withBytes:p bytesPerRow:activeW*4];
 float right=2.0f*activeW/width-1,top=1-2.0f*(height-activeH)/height;
 // The captured producer's active rectangle ends at the backing surface bottom.
 float vertices[]={-1,top,0,0, -1,-1,0,1, right,top,1,0, right,-1,1,1};
 id<MTLCommandQueue> q=[device newCommandQueue];id<MTLCommandBuffer> cb=[q commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
 id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:pipeline];[e setVertexBytes:vertices length:sizeof vertices atIndex:0];[e setFragmentTexture:input atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];[cb commit];[cb waitUntilCompleted];NSCAssert(cb.status==MTLCommandBufferStatusCompleted,@"%@",cb.error);
 NSMutableData *data=[NSMutableData dataWithLength:width*height*4];[output getBytes:data.mutableBytes bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
 if(fixed){const uint8_t *v=data.bytes;for(int y=0;y<activeH;y++)for(int x=0;x<activeW;x++)NSCAssert(!memcmp(v+(y*width+x)*4,p+(y*activeW+x)*4,4),@"active movie pixel/orientation at %d,%d",x,y);}
 return data;
}
int main(int argc,const char **argv){@autoreleasepool{
 unsetenv("PJDV_MOVIE_ORIGIN");device=MTLCreateSystemDefaultDevice();if(!device)return 77;
 NSString *patched=pjdv_movie_origin_source(source,@"36f85460a1ac1b59_b.metallib");NSCAssert([patched isEqual:pjdv_movie_origin_source(patched,@"36f85460a1ac1b59_b.metallib")],@"idempotence");NSCAssert([source isEqual:pjdv_movie_origin_source(source,@"unrelated_b.metallib")],@"unrelated shader changed");
 NSCAssert([@"unknown" isEqual:pjdv_movie_origin_source(@"unknown",@"36f85460a1ac1b59_b.metallib")],@"unknown interface must preserve original");
 if(argc>1){NSString *actual=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];NSCAssert(actual,@"actual cache required");NSString *fixed=pjdv_movie_origin_source(actual,@"36f85460a1ac1b59_b.metallib");NSCAssert(![actual isEqual:fixed],@"actual cache was not patched");NSError *err=nil;id<MTLLibrary> lib=[device newLibraryWithSource:fixed options:nil error:&err];NSCAssert(lib,@"actual cache compile %@",err);}
 setenv("PJDV_MOVIE_ORIGIN","0",1);NSCAssert([source isEqual:pjdv_movie_origin_source(source,@"36f85460a1ac1b59_b.metallib")],@"A/B bypass");unsetenv("PJDV_MOVIE_ORIGIN");
 NSCAssert([render(NO,32,18,32,18) isEqual:render(YES,32,18,32,18)],@"full-frame video regressed");
 NSData *old=render(NO,32,18,22,12),*fixed=render(YES,32,18,22,12);NSCAssert(![old isEqual:fixed],@"sub-resolution reproduction absent");render(YES,32,18,30,16);render(YES,32,18,16,9);
 puts("PASS actual GPU: asymmetric movie pixels, 3 active resolutions, full-surface preservation, shader isolation, idempotence and A/B bypass");
}return 0;}
