#include "pjdv_gpu_policy.h"
// Single directional-light visibility for an authenticated opaque stage pair.
// This is shared by the runtime and the GPU validation harness.
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
static _Atomic int g_pjdv_rt_stage_mode, g_pjdv_rt_stage_status;
static id<MTLFunction> g_pjdv_rt_active_fn;
int pjdv_rt_stage_supported(void *device) {
    id<MTLDevice> d=(__bridge id<MTLDevice>)device;
    if (@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *))
        return !pjdv_entry_gpu(d) && d.supportsRaytracing && d.supportsRaytracingFromRender;
    return 0;
}
void pjdv_set_rt_stage_mode(int mode) { atomic_store(&g_pjdv_rt_stage_mode,mode==1 && pjdv_rt_stage_supported((__bridge void *)MTLCreateSystemDefaultDevice())); }
int pjdv_rt_stage_mode(void) { return atomic_load(&g_pjdv_rt_stage_mode); }
int pjdv_rt_stage_status(void) { return atomic_load(&g_pjdv_rt_stage_status); }

static NSString *pjdv_rt_stage_source(NSString *source) {
    NSData *bytes=[source dataUsingEncoding:NSUTF8StringEncoding];uint8_t digest[32];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *hash=[NSMutableString string];for(int n=0;n<32;n++)[hash appendFormat:@"%02x",digest[n]];
    pjdv_rt_check([hash isEqual:@"88c750d9f82d34185d702455a5cd13e55185429aa0c899e84e35a61b6aa44678"],@"RT stage shader fingerprint changed; original shader retained");
    NSString *entry=@"fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])";
    NSString *point=@"    float _431 = _427;";
    pjdv_rt_check([source componentsSeparatedByString:entry].count==2 &&
                  [source componentsSeparatedByString:point].count==2,@"Stage lighting shader schema changed");
    NSMutableString *s=[source mutableCopy];
    [s insertString:@"#include <metal_raytracing>\n" atIndex:0];
    [s replaceOccurrencesOfString:entry withString:@"fragment main0_out pjdvStageRT(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], metal::raytracing::instance_acceleration_structure pjdvScene [[buffer(1)]], constant float4& pjdvRT [[buffer(2)]], device atomic_uint* pjdvStats [[buffer(3)]], float4 pjdvPixel [[position]])" options:0 range:NSMakeRange(0,s.length)];
    // World position is cameraPosition - the original world-space view vector.
    // cb1[23] is the same surface-to-light vector used by the original N.L.
    // The existing ESM supplies other (including character) casters. Combine
    // visibility with min, never multiply the same shadow twice. Correct only
    // the analytically separated direct diffuse/specular terms; ambient and
    // the original NPR branch retain their exact original result.
    NSString *code=@
    "    float pjdvVisibility = 1.0;\n"
    "    if (!_342 && in.m_68.w > 0.0 && _346 > 0.0) {\n"
    "        float3 light = (*spvDescriptorSet0.fp_c4)._m0[23].xyz;\n"
    "        float3 world = (*spvDescriptorSet0.fp_c4)._m0[68].xyz - in.m_66.xyz;\n"
    "        float3 normal = in.m_64.xyz;\n"
    "        float l2=dot(light,light),n2=dot(normal,normal);\n"
    "        if (all(isfinite(world)) && isfinite(l2) && l2>.5 && l2<1.5 && isfinite(n2) && n2>1.e-8) {\n"
    "            using namespace metal::raytracing;\n"
    "            ray r; r.direction=light*rsqrt(l2);\n"
    "            normal*=rsqrt(n2); normal*=dot(normal,r.direction)>=0.0?1.0:-1.0;\n"
    "            r.origin=world+normal*pjdvRT.x; r.min_distance=pjdvRT.x; r.max_distance=pjdvRT.y;\n"
    "            intersector<triangle_data,instancing> query; query.accept_any_intersection(true);\n"
    "            pjdvVisibility=query.intersect(r,pjdvScene,1).type==intersection_type::none?1.0:0.0;\n"
    "            if (pjdvRT.z>0.0 && (uint(pjdvPixel.x)&7u)==0 && (uint(pjdvPixel.y)&7u)==0) {\n"
    "                atomic_fetch_add_explicit(pjdvStats,1u,memory_order_relaxed);\n"
    "                if(pjdvVisibility==0.0)atomic_fetch_add_explicit(pjdvStats+1,1u,memory_order_relaxed);\n"
    "            }\n"
    "            float combined=min(_332,pjdvVisibility);\n"
    "            float3 prior=_412?float3(_330,_310,_312):float3(_330);\n"
    "            float3 next=combined*(*spvDescriptorSet0.fp_c4)._m0[53].xyz+(*spvDescriptorSet0.fp_c4)._m0[52].xyz;\n"
    "            if(!_412)next=next.xxx;\n"
    "            float3 diffuse=in.m_58.xyz*_346*(*spvDescriptorSet0.fp_c4)._m0[24].xyz*float3(_222,_220,_224)*(*spvDescriptorSet0.fp_c1)._m0[4].w;\n"
    "            float3 specular=_406.xyz*in.m_74.xyz*_344*(*spvDescriptorSet0.fp_c4)._m0[25].xyz*(*spvDescriptorSet0.fp_c4)._m0[13].xyz;\n"
    "            float3 delta=diffuse*(next-prior)+specular*(combined-_332);\n"
    "            if(pjdvVisibility==0.0) {_425+=delta.x; _427+=delta.y; _429+=delta.z;}\n"
    "        }\n"
    "    }\n";
    [s replaceOccurrencesOfString:point withString:[code stringByAppendingString:point] options:0 range:NSMakeRange(0,s.length)];
    [s replaceOccurrencesOfString:@"    return out;" withString:@"    if(pjdvRT.w>0.0)out.m_77.xyz=float3(pjdvVisibility);\n    return out;" options:NSBackwardsSearch range:NSMakeRange(0,s.length)];
    return s;
}

@interface PJDVRTStageScene : NSObject {
@public
    NSData *world,*indexData;
    NSMutableArray *resources;
    id<MTLBuffer> vertexBuffer,indexBuffer,instances,scratch,stats;
    id<MTLAccelerationStructure> blas,tlas;
    float bias,maximum;
    BOOL built;
    uint64_t statsFrame;
    simd_float3 lower,upper;
    NSArray<PJDVRTStageScene *> *children;
    NSData *instanceTransforms;
    void (^releaseResources)(NSArray *);
#if DM_NVN_M3
    MTLPrimitiveAccelerationStructureDescriptor *bd;
    MTLInstanceAccelerationStructureDescriptor *td;
#else
    MTL4PrimitiveAccelerationStructureDescriptor *bd;
    MTL4InstanceAccelerationStructureDescriptor *td;
#endif
}
- (instancetype)initWithDevice:(id<MTLDevice>)device vertices:(NSData *)v indices:(NSData *)i;
- (instancetype)initWithDevice:(id<MTLDevice>)device meshes:(NSArray<PJDVRTStageScene *> *)meshes;
- (instancetype)initWithDevice:(id<MTLDevice>)device meshes:(NSArray<PJDVRTStageScene *> *)meshes transforms:(NSData *)transforms;
- (void)encodeBuild:(CBUF)cb;
@end
@implementation PJDVRTStageScene
- (instancetype)initWithDevice:(id<MTLDevice>)device vertices:(NSData *)v indices:(NSData *)i {
    if (@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, *)) {
    if(!(self=[super init]))return nil;
    pjdv_rt_check(v.length && v.length%16==0 && v.length<=16*1024*1024 && i.length && i.length%12==0 && i.length<=4*1024*1024,@"RT stage mesh limits exceeded");
    world=v;indexData=i;resources=[NSMutableArray array];statsFrame=UINT64_MAX;
    simd_float3 lo=((simd_float3){INFINITY,INFINITY,INFINITY}),hi=((simd_float3){-INFINITY,-INFINITY,-INFINITY});
    const simd_float4 *p=v.bytes;const uint32_t *ix=i.bytes;
    for(NSUInteger n=0;n<i.length/4;n++) {
        pjdv_rt_check(ix[n]<v.length/16,@"RT stage index outside buffer");
        simd_float3 f=p[ix[n]].xyz;pjdv_rt_check(isfinite(f.x)&&isfinite(f.y)&&isfinite(f.z),@"RT stage position nonfinite");lo=simd_min(lo,f);hi=simd_max(hi,f);
    }
    lower=lo;upper=hi;
    float span=simd_length(hi-lo);pjdv_rt_check(isfinite(span)&&span>1.e-4 && span<1.e7,@"RT stage invalid bounds");
    bias=fminf(.02f,fmaxf(.0005f,span*1.e-5f));maximum=span*2;
    vertexBuffer=[device newBufferWithBytes:v.bytes length:v.length options:MTLResourceStorageModeShared];
    indexBuffer=[device newBufferWithBytes:i.bytes length:i.length options:MTLResourceStorageModeShared];
    instances=[device newBufferWithLength:sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) options:MTLResourceStorageModeShared];
    stats=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];
#if DM_NVN_M3
    MTLAccelerationStructureTriangleGeometryDescriptor *g=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];g.vertexBuffer=vertexBuffer;g.indexBuffer=indexBuffer;
    bd=[MTLPrimitiveAccelerationStructureDescriptor descriptor];td=[MTLInstanceAccelerationStructureDescriptor descriptor];td.instanceDescriptorBuffer=instances;
#else
    MTL4AccelerationStructureTriangleGeometryDescriptor *g=[MTL4AccelerationStructureTriangleGeometryDescriptor new];
    g.vertexBuffer=(MTL4BufferRange){vertexBuffer.gpuAddress,vertexBuffer.length};g.indexBuffer=(MTL4BufferRange){indexBuffer.gpuAddress,indexBuffer.length};
    bd=[MTL4PrimitiveAccelerationStructureDescriptor new];td=[MTL4InstanceAccelerationStructureDescriptor new];td.instanceDescriptorBuffer=(MTL4BufferRange){instances.gpuAddress,instances.length};
#endif
    g.vertexFormat=MTLAttributeFormatFloat3;g.vertexStride=16;g.indexType=MTLIndexTypeUInt32;g.triangleCount=i.length/12;g.opaque=YES;
    bd.geometryDescriptors=@[g];
    td.instanceCount=1;td.instanceDescriptorStride=sizeof(MTLIndirectAccelerationStructureInstanceDescriptor);td.instanceDescriptorType=MTLAccelerationStructureInstanceDescriptorTypeIndirect;
    MTLAccelerationStructureSizes b=[device accelerationStructureSizesWithDescriptor:bd],t=[device accelerationStructureSizesWithDescriptor:td];
    blas=[device newAccelerationStructureWithSize:b.accelerationStructureSize];tlas=[device newAccelerationStructureWithSize:t.accelerationStructureSize];
    scratch=[device newBufferWithLength:MAX(b.buildScratchBufferSize,t.buildScratchBufferSize) options:MTLResourceStorageModePrivate];
    pjdv_rt_check(vertexBuffer&&indexBuffer&&instances&&stats&&blas&&tlas&&scratch,@"RT stage allocation failed");
    MTLIndirectAccelerationStructureInstanceDescriptor d={0};d.transformationMatrix.columns[0].x=1;d.transformationMatrix.columns[1].y=1;d.transformationMatrix.columns[2].z=1;d.mask=1;d.accelerationStructureID=blas.gpuResourceID;memcpy(instances.contents,&d,sizeof d);
    [resources addObjectsFromArray:@[vertexBuffer,indexBuffer,instances,stats,blas,tlas,scratch]];
    return self;

    }
    return nil;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device meshes:(NSArray<PJDVRTStageScene *> *)meshes {return [self initWithDevice:device meshes:meshes transforms:nil];}
- (instancetype)initWithDevice:(id<MTLDevice>)device meshes:(NSArray<PJDVRTStageScene *> *)meshes transforms:(NSData *)transforms {
    if (@available(macOS 14.0, macCatalyst 17.0, iOS 17.0, *)) {
    if(!(self=[super init]))return nil;
    pjdv_rt_check(!transforms || transforms.length==meshes.count*48,@"RT stage transform count mismatch");instanceTransforms=[transforms copy];
    pjdv_rt_check(meshes.count>0 && meshes.count<=96,@"RT stage instance limit");
    children=[meshes copy];resources=[NSMutableArray array];statsFrame=UINT64_MAX;
    lower=(simd_float3){INFINITY,INFINITY,INFINITY};upper=-lower;
    instances=[device newBufferWithLength:meshes.count*sizeof(MTLIndirectAccelerationStructureInstanceDescriptor) options:MTLResourceStorageModeShared];
    MTLIndirectAccelerationStructureInstanceDescriptor *d=instances.contents;NSUInteger n=0;
    for(PJDVRTStageScene *mesh in meshes){
        const float identity[12]={1,0,0,0,0,1,0,0,0,0,1,0};const float *m=transforms?(const float *)transforms.bytes+n*12:identity;
        for(int corner=0;corner<8;corner++){simd_float3 p={corner&1?mesh->upper.x:mesh->lower.x,corner&2?mesh->upper.y:mesh->lower.y,corner&4?mesh->upper.z:mesh->lower.z},w;
            for(int r=0;r<3;r++)w[r]=fmaf(1,m[r*4+3],fmaf(p.z,m[r*4+2],fmaf(p.y,m[r*4+1],p.x*m[r*4])));lower=simd_min(lower,w);upper=simd_max(upper,w);}
        d[n]=(MTLIndirectAccelerationStructureInstanceDescriptor){0};
        for(int c=0;c<4;c++){d[n].transformationMatrix.columns[c].x=m[c];d[n].transformationMatrix.columns[c].y=m[4+c];d[n].transformationMatrix.columns[c].z=m[8+c];}
        d[n].mask=1;d[n].accelerationStructureID=mesh->blas.gpuResourceID;n++;}
    float span=simd_length(upper-lower);bias=fminf(.02f,fmaxf(.0005f,span*1.e-5f));maximum=span*2;
#if DM_NVN_M3
    td=[MTLInstanceAccelerationStructureDescriptor descriptor];td.instanceDescriptorBuffer=instances;
#else
    td=[MTL4InstanceAccelerationStructureDescriptor new];td.instanceDescriptorBuffer=(MTL4BufferRange){instances.gpuAddress,instances.length};
#endif
    td.instanceCount=meshes.count;td.instanceDescriptorStride=sizeof(*d);td.instanceDescriptorType=MTLAccelerationStructureInstanceDescriptorTypeIndirect;
    MTLAccelerationStructureSizes t=[device accelerationStructureSizesWithDescriptor:td];
    tlas=[device newAccelerationStructureWithSize:t.accelerationStructureSize];scratch=[device newBufferWithLength:t.buildScratchBufferSize options:MTLResourceStorageModePrivate];stats=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    pjdv_rt_check(instances&&tlas&&scratch&&stats,@"RT stage instance allocation failed");[resources addObjectsFromArray:@[instances,tlas,scratch,stats]];return self;

    }
    return nil;
}
- (void)dealloc { if(releaseResources)releaseResources(resources); }
- (void)encodeBuild:(CBUF)cb {
    if(built)return;
    for(PJDVRTStageScene *child in children)[child encodeBuild:cb];
#if DM_NVN_M3
    id<MTLAccelerationStructureCommandEncoder> e=[cb accelerationStructureCommandEncoder];
    for(PJDVRTStageScene *child in children)[e useResource:child->blas usage:MTLResourceUsageRead];
    if(bd)[e buildAccelerationStructure:blas descriptor:bd scratchBuffer:scratch scratchBufferOffset:0];
    [e buildAccelerationStructure:tlas descriptor:td scratchBuffer:scratch scratchBufferOffset:0];[e endEncoding];
#else
    id<MTL4ComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    MTL4BufferRange range={scratch.gpuAddress,scratch.length};
    if(bd)[e buildAccelerationStructure:blas descriptor:bd scratchBuffer:range];
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[e endEncoding];
    e=[cb computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e buildAccelerationStructure:tlas descriptor:td scratchBuffer:range];
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[e endEncoding];
#endif
    built=YES;
}
@end
