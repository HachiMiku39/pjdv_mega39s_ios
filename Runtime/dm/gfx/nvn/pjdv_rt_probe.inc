// Opt-in GPU ray tracing validation. It does not alter any game render pass.
// The standalone harness and the device runtime compile this same code.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include <math.h>

static void pjdv_rt_check(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"PJDVRTValidation" reason:message userInfo:nil];
}
static double pjdv_rt_clock(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSString *const pjdv_rt_probe_msl = @
"#include <metal_stdlib>\n#include <metal_raytracing>\nusing namespace metal;using namespace metal::raytracing;\n"
"kernel void pjdv_rt_probe(constant float4* p [[buffer(0)]],instance_acceleration_structure scene [[buffer(1)]],device float4* out [[buffer(2)]],uint2 tid [[thread_position_in_grid]]){\n"
" uint w=uint(p[2].x),h=uint(p[2].y);if(tid.x>=w||tid.y>=h)return;\n"
" ray r;r.origin=float3(p[0].xy+(float2(tid)+.5)/float2(w,h)*p[0].zw,p[1].x);r.direction=float3(0,0,1);uint axis=uint(p[2].z);if(axis==1){r.origin=r.origin.xzy;r.direction=float3(0,1,0);}else if(axis==2){r.origin=r.origin.zxy;r.direction=float3(1,0,0);}r.min_distance=.001;r.max_distance=p[1].y;\n"
" intersector<triangle_data,instancing> q;q.accept_any_intersection(false);\n"
" auto hit=q.intersect(r,scene,uint(p[1].z));out[tid.y*w+tid.x]=hit.type==intersection_type::none?float4(0,-1,0,0):float4(1,hit.distance,hit.triangle_barycentric_coord);}\n";

API_AVAILABLE(ios(26.0), macos(26.0), macCatalyst(26.0))
@interface PJDVRTProbe : NSObject {
@public
    id<MTLDevice> dev;
    id<MTLResidencySet> residency;
    NSMutableArray *keep;
    id<MTLBuffer> vertices, indices, instances, scratch, params, output;
    id<MTLAccelerationStructure> blas, tlas;
    id<MTLComputePipelineState> pipeline;
    MTLIndirectAccelerationStructureInstanceDescriptor instance;
    simd_float3 triangle[3];
    NSUInteger resolution;
    uint64_t ticket;
#if DM_NVN_M3
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> cb;
    MTLPrimitiveAccelerationStructureDescriptor *bd;
    MTLInstanceAccelerationStructureDescriptor *td;
#else
    id<MTL4CommandQueue> queue;
    id<MTL4CommandBuffer> cb;
    id<MTL4CommandAllocator> allocator;
    id<MTL4ArgumentTable> arguments;
    id<MTLSharedEvent> done;
    MTL4PrimitiveAccelerationStructureDescriptor *bd;
    MTL4InstanceAccelerationStructureDescriptor *td;
#endif
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)begin;
- (void)build:(BOOL)bottom refit:(BOOL)refit;
- (void)traceWithMask:(uint32_t)mask maximumDistance:(float)distance;
- (void)encodeTrace;
- (void)setMeshVertices:(NSData *)data indices:(NSData *)indexData;
- (NSDictionary *)finish;
- (NSDictionary *)verifyMask:(uint32_t)mask maximumDistance:(double)maximum translation:(simd_double3)translation;
@end

@implementation PJDVRTProbe
- (void)resident:(id<MTLAllocation>)resource {
    pjdv_rt_check(resource!=nil,@"GPU resource allocation failed");
    [residency addAllocation:resource];[keep addObject:resource];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self=[super init]))return nil;
    dev=device;resolution=256;keep=[NSMutableArray array];NSError *error=nil;
    residency=[dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    pjdv_rt_check(residency!=nil,error.localizedDescription?:@"Residency set unavailable");
    vertices=[dev newBufferWithLength:sizeof(triangle) options:MTLResourceStorageModeShared];
    instances=[dev newBufferWithLength:sizeof(instance) options:MTLResourceStorageModeShared];
    params=[dev newBufferWithLength:48 options:MTLResourceStorageModeShared];
    output=[dev newBufferWithLength:resolution*resolution*16 options:MTLResourceStorageModeShared];
    for(id resource in @[vertices,instances,params,output])[self resident:resource];
    triangle[0]=(simd_float3){-.5,-.5,0};triangle[1]=(simd_float3){.5,-.5,0};triangle[2]=(simd_float3){0,.5,0};
    memcpy(vertices.contents,triangle,sizeof(triangle));
#if DM_NVN_M3
    queue=[dev newCommandQueue];
    MTLAccelerationStructureTriangleGeometryDescriptor *geometry=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    geometry.vertexBuffer=vertices;
    bd=[MTLPrimitiveAccelerationStructureDescriptor descriptor];
    td=[MTLInstanceAccelerationStructureDescriptor descriptor];td.instanceDescriptorBuffer=instances;
#else
    queue=[dev newMTL4CommandQueue];allocator=[dev newCommandAllocator];done=[dev newSharedEvent];
    pjdv_rt_check(queue && allocator && done,@"Metal 4 command objects unavailable");
    [queue addResidencySet:residency];
    MTL4AccelerationStructureTriangleGeometryDescriptor *geometry=[MTL4AccelerationStructureTriangleGeometryDescriptor new];
    geometry.vertexBuffer=(MTL4BufferRange){vertices.gpuAddress,vertices.length};
    bd=[MTL4PrimitiveAccelerationStructureDescriptor new];
    td=[MTL4InstanceAccelerationStructureDescriptor new];td.instanceDescriptorBuffer=(MTL4BufferRange){instances.gpuAddress,instances.length};
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new];ad.maxBufferBindCount=3;
    arguments=[dev newArgumentTableWithDescriptor:ad error:&error];pjdv_rt_check(arguments!=nil,error.localizedDescription);
    [keep addObject:arguments];
#endif
    geometry.vertexFormat=MTLAttributeFormatFloat3;geometry.vertexStride=sizeof(simd_float3);geometry.triangleCount=1;geometry.opaque=YES;
    bd.geometryDescriptors=@[geometry];bd.usage=MTLAccelerationStructureUsageRefit;
    td.instanceCount=1;td.instanceDescriptorStride=sizeof(instance);td.instanceDescriptorType=MTLAccelerationStructureInstanceDescriptorTypeIndirect;
    td.usage=MTLAccelerationStructureUsageRefit;
    MTLAccelerationStructureSizes bs=[dev accelerationStructureSizesWithDescriptor:bd],ts=[dev accelerationStructureSizesWithDescriptor:td];
    blas=[dev newAccelerationStructureWithSize:bs.accelerationStructureSize];tlas=[dev newAccelerationStructureWithSize:ts.accelerationStructureSize];
    scratch=[dev newBufferWithLength:MAX(MAX(bs.buildScratchBufferSize,bs.refitScratchBufferSize),MAX(ts.buildScratchBufferSize,ts.refitScratchBufferSize)) options:MTLResourceStorageModePrivate];
    for(id resource in @[blas,tlas,scratch])[self resident:resource];
    memset(&instance,0,sizeof(instance));instance.transformationMatrix.columns[0].x=1;instance.transformationMatrix.columns[1].y=1;instance.transformationMatrix.columns[2].z=1;
    instance.mask=1;instance.accelerationStructureID=blas.gpuResourceID;memcpy(instances.contents,&instance,sizeof(instance));
    id<MTLLibrary> library=[dev newLibraryWithSource:pjdv_rt_probe_msl options:nil error:&error];
    pjdv_rt_check(library!=nil,error.localizedDescription?:@"RT shader compilation failed");
    pipeline=[dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"pjdv_rt_probe"] error:&error];
    pjdv_rt_check(pipeline!=nil,error.localizedDescription?:@"RT pipeline creation failed");
    [keep addObject:pipeline];
    return self;
}
- (void)setMeshVertices:(NSData *)data indices:(NSData *)indexData {
    // Call only after completion; old resources stay retained by this probe.
    pjdv_rt_check(data.length>0 && data.length%16==0 && indexData.length>0 && indexData.length%12==0,@"Invalid mesh layout");
    vertices=[dev newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared];
    indices=[dev newBufferWithBytes:indexData.bytes length:indexData.length options:MTLResourceStorageModeShared];
    [self resident:vertices];[self resident:indices];
#if DM_NVN_M3
    MTLAccelerationStructureTriangleGeometryDescriptor *geometry=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    geometry.vertexBuffer=vertices;geometry.indexBuffer=indices;
#else
    MTL4AccelerationStructureTriangleGeometryDescriptor *geometry=[MTL4AccelerationStructureTriangleGeometryDescriptor new];
    geometry.vertexBuffer=(MTL4BufferRange){vertices.gpuAddress,vertices.length};
    geometry.indexBuffer=(MTL4BufferRange){indices.gpuAddress,indices.length};
#endif
    geometry.vertexFormat=MTLAttributeFormatFloat3;geometry.vertexStride=16;geometry.indexType=MTLIndexTypeUInt32;
    geometry.triangleCount=indexData.length/12;geometry.opaque=YES;bd.geometryDescriptors=@[geometry];
    MTLAccelerationStructureSizes bs=[dev accelerationStructureSizesWithDescriptor:bd],ts=[dev accelerationStructureSizesWithDescriptor:td];
    blas=[dev newAccelerationStructureWithSize:bs.accelerationStructureSize];tlas=[dev newAccelerationStructureWithSize:ts.accelerationStructureSize];
    scratch=[dev newBufferWithLength:MAX(MAX(bs.buildScratchBufferSize,bs.refitScratchBufferSize),MAX(ts.buildScratchBufferSize,ts.refitScratchBufferSize)) options:MTLResourceStorageModePrivate];
    [self resident:blas];[self resident:tlas];[self resident:scratch];
    instance.accelerationStructureID=blas.gpuResourceID;memcpy(instances.contents,&instance,sizeof(instance));
}
- (void)begin {
#if DM_NVN_M3
    cb=[queue commandBuffer];
#else
    // Each previous submit is complete before the allocator or shared buffers
    // are reset/reused. Production animation must use per-flight storage.
    [allocator reset];cb=[dev newCommandBuffer];[cb beginCommandBufferWithAllocator:allocator];
#endif
    pjdv_rt_check(cb!=nil,@"RT command buffer unavailable");
}
- (void)build:(BOOL)bottom refit:(BOOL)refit {
    id<MTLAccelerationStructure> target=bottom?blas:tlas;
#if DM_NVN_M3
    id<MTLAccelerationStructureCommandEncoder> encoder=[cb accelerationStructureCommandEncoder];
    MTLAccelerationStructureDescriptor *descriptor=bottom?bd:td;
    if(refit)[encoder refitAccelerationStructure:target descriptor:descriptor destination:target scratchBuffer:scratch scratchBufferOffset:0];
    else [encoder buildAccelerationStructure:target descriptor:descriptor scratchBuffer:scratch scratchBufferOffset:0];
    [encoder endEncoding];
#else
    id<MTL4ComputeCommandEncoder> encoder=[cb computeCommandEncoder];
    [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    MTL4AccelerationStructureDescriptor *descriptor=bottom?bd:td;MTL4BufferRange range={scratch.gpuAddress,scratch.length};
    if(refit)[encoder refitAccelerationStructure:target descriptor:descriptor destination:target scratchBuffer:range];
    else [encoder buildAccelerationStructure:target descriptor:descriptor scratchBuffer:range];
    [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[encoder endEncoding];
#endif
}
- (void)traceWithMask:(uint32_t)mask maximumDistance:(float)maximum {
    float data[12]={-1,-1,4,4,-1,maximum,mask,0,resolution,resolution,0,0};memcpy(params.contents,data,sizeof(data));
    [self encodeTrace];
}
- (void)encodeTrace {
    // NaN initialization catches missing dispatches/writes, independently of
    // the reference intersection algorithm.
    float *results=output.contents;for(NSUInteger i=0;i<output.length/4;i++)results[i]=NAN;
#if DM_NVN_M3
    id<MTLComputeCommandEncoder> encoder=[cb computeCommandEncoder];
    [encoder setBuffer:params offset:0 atIndex:0];[encoder setAccelerationStructure:tlas atBufferIndex:1];[encoder setBuffer:output offset:0 atIndex:2];
    [encoder useResource:blas usage:MTLResourceUsageRead];[encoder setComputePipelineState:pipeline];
    [encoder dispatchThreads:MTLSizeMake(resolution,resolution,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
#else
    id<MTL4ComputeCommandEncoder> encoder=[cb computeCommandEncoder];
    [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [arguments setAddress:params.gpuAddress atIndex:0];[arguments setResource:tlas.gpuResourceID atBufferIndex:1];[arguments setAddress:output.gpuAddress atIndex:2];
    [encoder setArgumentTable:arguments];[encoder setComputePipelineState:pipeline];
    [encoder dispatchThreads:MTLSizeMake(resolution,resolution,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[encoder endEncoding];
#endif
}
- (NSDictionary *)finish {
    double start=pjdv_rt_clock();[residency commit];double gpuMilliseconds=-1;
#if DM_NVN_M3
    [cb commit];[cb waitUntilCompleted];pjdv_rt_check(cb.status==MTLCommandBufferStatusCompleted,cb.error.localizedDescription?:@"RT GPU execution failed");
    gpuMilliseconds=(cb.GPUEndTime-cb.GPUStartTime)*1000;
#else
    [cb endCommandBuffer];MTL4CommitOptions *options=[MTL4CommitOptions new];
    dispatch_semaphore_t feedbackReady=dispatch_semaphore_create(0);
    __block NSError *gpuError=nil;__block double duration=-1;NSArray *resources=[keep copy];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback){
        (void)resources.count;gpuError=feedback.error;duration=(feedback.GPUEndTime-feedback.GPUStartTime)*1000;dispatch_semaphore_signal(feedbackReady);
    }];
    id<MTL4CommandBuffer> list[]={cb};[queue commit:list count:1 options:options];[queue signalEvent:done value:++ticket];
    pjdv_rt_check([done waitUntilSignaledValue:ticket timeoutMS:15000],@"RT completion event timed out");
    pjdv_rt_check(dispatch_semaphore_wait(feedbackReady,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"RT feedback timed out");
    pjdv_rt_check(!gpuError,gpuError.localizedDescription);gpuMilliseconds=duration;
#endif
    return @{@"gpu_workload_ms":@(gpuMilliseconds),@"cpu_submit_and_wait_ms":@((pjdv_rt_clock()-start)*1000)};
}
- (NSDictionary *)verifyMask:(uint32_t)mask maximumDistance:(double)maximum translation:(simd_double3)translation {
    simd_double3 a=(simd_double3){triangle[0].x,triangle[0].y,triangle[0].z}+translation;
    simd_double3 b=(simd_double3){triangle[1].x,triangle[1].y,triangle[1].z}+translation;
    simd_double3 c=(simd_double3){triangle[2].x,triangle[2].y,triangle[2].z}+translation;
    simd_double3 direction={0,0,1},e1=b-a,e2=c-a,p=simd_cross(direction,e2);double det=simd_dot(e1,p),inverse=1/det;
    NSUInteger mismatches=0,hits=0;double maxDistanceError=0,maxBarycentricError=0;float *gpu=output.contents;
    for(NSUInteger y=0;y<resolution;y++)for(NSUInteger x=0;x<resolution;x++){
        simd_double3 origin={-1+(x+.5)*4/resolution,-1+(y+.5)*4/resolution,-1},s=origin-a,q=simd_cross(s,e1);
        double u=simd_dot(s,p)*inverse,v=simd_dot(direction,q)*inverse,distance=simd_dot(e2,q)*inverse;
        BOOL hit=mask && fabs(det)>1e-12 && u>=0 && v>=0 && u+v<=1 && distance>=.001 && distance<=maximum;
        float *r=gpu+(y*resolution+x)*4;
        if(!isfinite(r[0])||!isfinite(r[1])||!isfinite(r[2])||!isfinite(r[3])||((r[0]>.5)!=hit)){mismatches++;continue;}
        if(hit){hits++;maxDistanceError=MAX(maxDistanceError,fabs(r[1]-distance));maxBarycentricError=MAX(maxBarycentricError,MAX(fabs(r[2]-u),fabs(r[3]-v)));}
    }
    pjdv_rt_check(mismatches==0 && maxDistanceError<1e-4 && maxBarycentricError<1e-4,[NSString stringWithFormat:@"RT mismatch=%lu distance=%g barycentric=%g",(unsigned long)mismatches,maxDistanceError,maxBarycentricError]);
    return @{@"rays":@(resolution*resolution),@"hits":@(hits),@"mismatches":@(mismatches),@"max_distance_error":@(maxDistanceError),@"max_barycentric_error":@(maxBarycentricError)};
}
@end

static NSDictionary *pjdv_rt_probe_validate(id<MTLDevice> device) API_AVAILABLE(ios(26.0), macos(26.0), macCatalyst(26.0)) {
    if (@available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *)) {} else
        return @{@"status":@"SKIP",@"reason":@"RT diagnostic requires OS 26"};
    @try {
        if(!device.supportsRaytracing || ![device supportsFamily:MTLGPUFamilyApple9])return @{@"status":@"SKIP",@"reason":@"Apple9 ray tracing unavailable"};
        PJDVRTProbe *probe=[[PJDVRTProbe alloc] initWithDevice:device];NSMutableArray *cases=[NSMutableArray array];
        for(int i=0;i<6;i++){
            simd_double3 translation={0,0,0};uint32_t mask=i==4?0:1;float maximum=i==5?3:16;
            if(i>=1){translation=(simd_double3){1,1,2};}
            if(i>=3){translation=(simd_double3){2,-.5,3.5};}
            if(i==2){for(int v=0;v<3;v++)probe->triangle[v].y+=.5;memcpy(probe->vertices.contents,probe->triangle,sizeof(probe->triangle));}
            probe->instance.transformationMatrix.columns[3]=(MTLPackedFloat3){translation.x,translation.y,translation.z};
            memcpy(probe->instances.contents,&probe->instance,sizeof(probe->instance));
            [probe begin];
            if(i==0){[probe build:YES refit:NO];[probe build:NO refit:NO];}
            if(i==1 || i==3)[probe build:NO refit:YES];
            if(i==2){[probe build:YES refit:YES];[probe build:NO refit:YES];}
            [probe traceWithMask:mask maximumDistance:maximum];
            NSMutableDictionary *result=[[probe finish] mutableCopy];[result addEntriesFromDictionary:[probe verifyMask:mask maximumDistance:maximum translation:translation]];
            result[@"case"]=@[@"BLAS_TLAS_build",@"instance_transform_refit",@"deformed_geometry_refit",@"second_instance_transform",@"instance_mask_rejection",@"maximum_distance_rejection"][i];[cases addObject:result];
        }
        return @{@"status":@"PASS",@"scope":@"Synthetic opaque triangle GPU validation; not game RT integration",@"backend":DM_NVN_M3?@"Metal 3":@"Metal 4",@"device":device.name,@"cases":cases,@"allocation_bytes":@(probe->vertices.allocatedSize+probe->instances.allocatedSize+probe->scratch.allocatedSize+probe->params.allocatedSize+probe->output.allocatedSize+probe->blas.allocatedSize+probe->tlas.allocatedSize)};
    } @catch(NSException *exception) { return @{@"status":@"FAIL",@"reason":exception.reason?:exception.name}; }
}
