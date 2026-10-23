#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__);abort(); } while(0)
#include "../nvn/pjdv_clip_depth.inc"
static int checks,failures;
#define CHECK(x,msg) do{checks++;if(!(x)){failures++;fprintf(stderr,"FAIL %s\n",msg);}else printf("PASS %s\n",msg);}while(0)
int main(void){@autoreleasepool{
 id<MTLDevice>d=MTLCreateSystemDefaultDevice();if(!d){fprintf(stderr,"No GPU\n");return 2;}id<MTLCommandQueue>q=[d newCommandQueue];NSError*err=nil;
 NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out{float4 gl_Position [[position]];};\nvertex main0_out main0(uint id [[vertex_id]],constant float2& zw [[buffer(0)]]){\n main0_out out;\n out.gl_Position=float4(id==1?3:-1,id==2?3:-1,zw.x,zw.y);\n    if (zw.y > 0) {\n        return out;\n    }\n    return out;\n}\nfragment float4 fs(){return float4(1,0,0,1);}";
 NSString *adapted=pjdv_clip_depth_source(source,YES);
 CHECK([[adapted componentsSeparatedByString:@"// PJDV GL clip depth"] count]==3,"early and final vertex returns both adapted");
 CHECK([pjdv_clip_depth_source(adapted,YES) isEqual:adapted],"depth adaptation is idempotent");
 CHECK([pjdv_clip_depth_source(source,NO) isEqual:source],"near-zero depth mode remains unchanged");
 float A=19.999834060668945f,B=.00016666666488163173f,focus=2.2221386432647705f;
 float raw=(1/focus-B)/A;float values[]={-1,-.5,0,raw,.75,1};float observed[2][6]={0};
 for(int mode=0;mode<2;mode++){
  id<MTLLibrary>lib=[d newLibraryWithSource:mode?adapted:source options:nil error:&err];if(!lib){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 2;}
  MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"main0"];pd.fragmentFunction=[lib newFunctionWithName:@"fs"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
  id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithDescriptor:pd error:&err];if(!ps){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 2;}
  MTLDepthStencilDescriptor*ds=[MTLDepthStencilDescriptor new];ds.depthWriteEnabled=YES;ds.depthCompareFunction=MTLCompareFunctionAlways;id<MTLDepthStencilState>depthState=[d newDepthStencilStateWithDescriptor:ds];
  for(int i=0;i<6;i++){
   MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture>depth=[d newTextureWithDescriptor:td];td.pixelFormat=MTLPixelFormatRGBA8Unorm;id<MTLTexture>color=[d newTextureWithDescriptor:td];
   MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=color;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.depthAttachment.texture=depth;rp.depthAttachment.clearDepth=.123;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;
   id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLRenderCommandEncoder>en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];[en setDepthStencilState:depthState];float zw[]={values[i]*2,2};[en setVertexBytes:zw length:8 atIndex:0];[en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[en endEncoding];
   id<MTLBuffer>rb=[d newBufferWithLength:64 options:MTLResourceStorageModeShared];id<MTLBlitCommandEncoder>bl=[cb blitCommandEncoder];[bl copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:64];[bl endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted,"GPU depth replay completes");float actual=((float*)rb.contents)[5];observed[mode][i]=actual;
   float expected=mode?.5f*(values[i]+1):(values[i]<0?.123f:values[i]);CHECK(fabsf(actual-expected)<.00001f,"homogeneous clipping and stored depth match NVN mode");
  }
 }
 float oldZ=1/((2*observed[0][3]-1)*A+B),newZ=1/((2*observed[1][3]-1)*A+B);
 printf("FOCUS expected=%.8g old=%.8g corrected=%.8g oldDepth=%.8g correctedDepth=%.8g\n",focus,oldZ,newZ,observed[0][3],observed[1][3]);
 CHECK(fabsf(newZ-focus)<.0001f,"captured M39 DOF formula reconstructs correct focus distance");CHECK(fabsf(oldZ-focus)>1,"negative control reproduces focus-distance error");
 printf("CLIP_DEPTH checks=%d failed=%d\n",checks,failures);return failures?1:0;
}}
