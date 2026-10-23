// Runs after Spatial, before presentation. SDR video/menu stays <= reference white.
static id<MTLComputePipelineState> g_pjdv_hdr_pso;
static id<MTLTexture> g_pjdv_hdr_output[3];
static id<MTLBuffer> g_pjdv_hdr_params[3],g_pjdv_hdr_stats[3];
#if !DM_NVN_M3
static id<MTL4ArgumentTable> g_pjdv_hdr_args[3];
#endif
static const char *pjdv_hdr_msl=
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct P{float4 crop;float headroom;float valid;float2 pad;};\n"
"float3 linearize(float3 c){return select(c/12.92,pow((c+0.055)/1.055,float3(2.4)),c>0.04045);}\n"
"kernel void mapHDR(texture2d<float> final [[texture(0)]],texture2d<float> raw [[texture(1)]],texture2d<float> reference [[texture(2)]],texture2d<float,access::write> out [[texture(3)]],constant P& p [[buffer(0)]],device atomic_uint* stats [[buffer(1)]],uint2 gid [[thread_position_in_grid]]){\n"
" if(gid.x>=out.get_width()||gid.y>=out.get_height())return;constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);\n"
" float2 uv=(float2(gid)+0.5)/float2(out.get_width(),out.get_height());float3 encoded=clamp(final.sample(s,uv*p.crop.zw+p.crop.xy).rgb,0.0,1.0);float3 c=linearize(encoded);float rawPeak=0;\n"
" if(p.valid>0.5){float3 scene=max(raw.sample(s,uv).rgb,0.0);if(all(isfinite(scene))){rawPeak=max(scene.r,max(scene.g,scene.b));float3 base=clamp(reference.sample(s,uv).rgb,0.0,1.0);\n"
" float difference=max(abs(base.r-encoded.r),max(abs(base.g-encoded.g),abs(base.b-encoded.b)));float mask=1.0-smoothstep(0.035,0.12,difference);\n"
" float shoulder=smoothstep(0.60,0.95,dot(encoded,float3(0.2126,0.7152,0.0722)));float excess=max(rawPeak-1.0,0.0);float gain=(p.headroom-1.0)*(1.0-exp(-excess/4.0))*mask*shoulder;c*=1.0+gain;}}\n"
" c=clamp(c,0.0,p.headroom);float peak=max(c.r,max(c.g,c.b));out.write(float4(c,1),gid);\n"
" if((gid.x&15)==0 && (gid.y&15)==0){atomic_fetch_max_explicit(stats+0,as_type<uint>(rawPeak),memory_order_relaxed);atomic_fetch_max_explicit(stats+1,as_type<uint>(peak),memory_order_relaxed);if(peak>1.001)atomic_fetch_add_explicit(stats+2,1,memory_order_relaxed);}}\n";
static id<MTLTexture> pjdv_hdr_encode(CBUF cb,id<MTLTexture> color,id<MTLTexture> dst,const int crop[4],int slot,PJDVHDRScene *scene) {
    if(dst.pixelFormat!=MTLPixelFormatRGBA16Float){
        if(!atomic_load(&g_pjdv_hdr_mode))for(int i=0;i<3;i++)if(g_pjdv_hdr_output[i]){defer_obj_release(g_pjdv_hdr_output[i]);g_pjdv_hdr_output[i]=nil;}
        return nil;
    }
    NSError *error=nil;
    if(!g_pjdv_hdr_pso){
        id<MTLLibrary> lib=[g_dev newLibraryWithSource:@(pjdv_hdr_msl) options:nil error:&error];
        if(lib)g_pjdv_hdr_pso=[g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mapHDR"] error:&error];
        if(!g_pjdv_hdr_pso){MLOG("PJDV HDR mapper failed: %s",error.description.UTF8String);atomic_store(&g_pjdv_hdr_state,4);return nil;}
    }
    NSUInteger x=0,y=0,w=color.width,h=color.height;
    if(crop && crop[2]>0 && crop[3]>0){x=crop[0];y=crop[1];w=crop[2];h=crop[3];}
    if(!w || !h || x+w>color.width || y+h>color.height)return nil;
    id<MTLTexture> out=g_pjdv_hdr_output[slot];
    if(!out || out.width!=w || out.height!=h){
        if(out)defer_obj_release(out);
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        out=[g_dev newTextureWithDescriptor:d];g_pjdv_hdr_output[slot]=out;if(!out)return nil;res_add(out);
    }
    if(!g_pjdv_hdr_params[slot]){
        g_pjdv_hdr_params[slot]=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        g_pjdv_hdr_stats[slot]=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
        res_add(g_pjdv_hdr_params[slot]);res_add(g_pjdv_hdr_stats[slot]);
#if !DM_NVN_M3
        MTL4ArgumentTableDescriptor *d=[MTL4ArgumentTableDescriptor new];d.maxTextureBindCount=4;d.maxBufferBindCount=2;
        g_pjdv_hdr_args[slot]=[g_dev newArgumentTableWithDescriptor:d error:&error];
        if(!g_pjdv_hdr_args[slot])return nil;
#endif
    }
    BOOL valid=atomic_load(&g_pjdv_hdr_mode) && scene.hdr && scene.ldr;
    float *p=g_pjdv_hdr_params[slot].contents;
    p[0]=(float)x/color.width;p[1]=(float)y/color.height;p[2]=(float)w/color.width;p[3]=(float)h/color.height;
    p[4]=atomic_load(&g_pjdv_hdr_headroom);p[5]=valid?1:0;p[6]=p[7]=0;
    memset(g_pjdv_hdr_stats[slot].contents,0,256);res_commit();
    CENC ce=[cb computeCommandEncoder];
#if DM_NVN_M3
    [ce setTexture:color atIndex:0];[ce setTexture:valid?scene.hdr:color atIndex:1];[ce setTexture:valid?scene.ldr:color atIndex:2];[ce setTexture:out atIndex:3];
    [ce setBuffer:g_pjdv_hdr_params[slot] offset:0 atIndex:0];[ce setBuffer:g_pjdv_hdr_stats[slot] offset:0 atIndex:1];
#else
    [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#if PJDV_HAS_METALFX
    if(g_pjdv_spatial[slot].output==color)[ce waitForFence:g_pjdv_spatial[slot].scaler.fence beforeEncoderStages:MTLStageDispatch];
#endif
    id<MTL4ArgumentTable> a=g_pjdv_hdr_args[slot];[ce setArgumentTable:a];
    [a setTexture:color.gpuResourceID atIndex:0];[a setTexture:(valid?scene.hdr:color).gpuResourceID atIndex:1];
    [a setTexture:(valid?scene.ldr:color).gpuResourceID atIndex:2];[a setTexture:out.gpuResourceID atIndex:3];
    [a setAddress:g_pjdv_hdr_params[slot].gpuAddress atIndex:0];[a setAddress:g_pjdv_hdr_stats[slot].gpuAddress atIndex:1];
#endif
    [ce setComputePipelineState:g_pjdv_hdr_pso];[ce dispatchThreadgroups:MTLSizeMake((w+15)/16,(h+7)/8,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)];m4_end(ce);
    atomic_store(&g_pjdv_hdr_state,valid?1:2);return out;
}
static void pjdv_hdr_complete(PJDVHDRScene *scene,id<MTLBuffer> stats,uint64_t frame,BOOL okay) {
    // Holding scene through this callback keeps both copied inputs resident.
    if(!okay){atomic_store(&g_pjdv_hdr_state,4);return;}
    if(!stats)return;
    const uint32_t *p=stats.contents;float raw=0,out=0;memcpy(&raw,p,4);memcpy(&out,p+1,4);
    static uint64_t count;
    if(++count%120==0 || (p[2]>0 && count<120))
        MLOG("PJDV HDR frame=%llu matchedScene=%d rawPeak=%.4f outputPeak=%.4f extendedSamples=%u headroom=%.3f",(unsigned long long)frame,scene!=nil,raw,out,p[2],atomic_load(&g_pjdv_hdr_headroom));
}
