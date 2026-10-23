// Regression: fragment depth outputs need a Metal depth attachment even when
// NVN depth test/write are disabled. Exercise production replay and read pixels.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
void pjdv_begin_game_graphics(void){}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static int failed,checks;
#define CHECK(s,v) do{checks++;if(!(v)){failed++;printf("FAIL %s\n",s);}else printf("PASS %s\n",s);}while(0)
static void emit(uint8_t *p,size_t *n,unsigned op,const void *a,size_t z){size_t len=(8+z+7)&~7ull;op_hdr h={op,(uint32_t)len};memcpy(p+*n,&h,8);if(z)memcpy(p+*n+8,a,z);*n+=len;}
static void run(int late,int metadata){
    static NvProg *keep[16];static int keep_n;static uint64_t serial=61000;
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\nfragment float4 blue(){return float4(0,0,1,1);}\nstruct O{float4 c[[color(0)]];float d[[depth(any)]];};fragment O red(){return {float4(1,0,0,1),0.25};}\n";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];CHECK("test library",library!=nil);if(!library)return;
    prog_t programs[2]={{0}};
    for(int i=0;i<2;i++){
        programs[i].serial=serial++;
        NvProg *p=[NvProg new];p->sh[0]=[NvShader new];p->sh[1]=[NvShader new];
        p->sh[0]->fn=[library newFunctionWithName:@"v"];p->sh[1]->fn=[library newFunctionWithName:i?@"red":@"blue"];p->sh[1]->stage=1;p->sh[1]->rf.writes_depth=i&&metadata;
        keep[keep_n++]=p;serial_put(programs[i].serial,p);
    }
    tex_t color={.serial=serial++},depth={.serial=serial++};
    color.d.width=color.d.height=depth.d.width=depth.d.height=8;
    color.d.depth=color.d.samples=color.d.levels=depth.d.depth=depth.d.samples=depth.d.levels=1;
    color.d.target=depth.d.target=NVN_TEXTURE_TARGET_2D;color.d.format=NVN_FORMAT_RGBA8;depth.d.format=NVN_FORMAT_DEPTH32F;
    id<MTLTexture> depthTexture=tex_mtl(&depth);
    // Seed depth outside the NVN command stream; an NVN clear in the stream
    // would itself retain the attachment and fail to exercise the regression.
    id<MTLCommandBuffer> seed=[g_q commandBuffer];MTLRenderPassDescriptor *pd=[MTLRenderPassDescriptor renderPassDescriptor];
    pd.depthAttachment.texture=depthTexture;pd.depthAttachment.loadAction=MTLLoadActionClear;pd.depthAttachment.clearDepth=0.75;pd.depthAttachment.storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder=[seed renderCommandEncoderWithDescriptor:pd];[encoder endEncoding];[seed commit];[seed waitUntilCompleted];
    uint8_t *commands=NULL;posix_memalign((void **)&commands,getpagesize(),65536);memset(commands,0,65536);mtl_pool_add(commands,65536);size_t n=0;
    p_set_rt rt={.n=1,.depth=&depth};rt.color[0]=&color;emit(commands,&n,OP_SET_RT,&rt,sizeof rt);
    p_viewports vp={.n=1};vp.v[0][2]=vp.v[0][3]=8;emit(commands,&n,OP_VIEWPORTS,&vp,sizeof vp);p_scissor sc={0,0,8,8};emit(commands,&n,OP_SCISSOR,&sc,sizeof sc);
    p_clear_color clear={.index=0,.mask=15,.rgba={0,0,1,1}};emit(commands,&n,OP_CLEAR_COLOR,&clear,sizeof clear);
    ds_st ds={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,1,1,1,1,1,1};p_bind_state state={.kind=5};memcpy(state.bytes,&ds,sizeof ds);emit(commands,&n,OP_BIND_STATE,&state,sizeof state);
    p_draw draw={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3};
    if(late){p_bind_program bp={&programs[0],3};emit(commands,&n,OP_BIND_PROGRAM,&bp,sizeof bp);emit(commands,&n,OP_DRAW,&draw,sizeof draw);}
    p_bind_program bp={&programs[1],3};emit(commands,&n,OP_BIND_PROGRAM,&bp,sizeof bp);emit(commands,&n,OP_DRAW,&draw,sizeof draw);emit(commands,&n,OP_END,NULL,0);
    state_reset();memset(&R,0,sizeof R);vis_clear();g_vis_on=g_vis_counting=0;
    mtl_sub_begin();uint64_t handle=(uint64_t)commands;mtl_sub_index(&handle,1);mtl_exec(commands);
    id<MTLBuffer> read=[g_dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(&color) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [blit() copyFromTexture:depthTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:read destinationOffset:256 destinationBytesPerRow:32 destinationBytesPerImage:256];
    uint64_t fence=mtl_sub_commit();CHECK("submission completes",mtl_wait(fence,5000000000ull));CHECK("Metal execution succeeds",!mtl_last_commit_error());
    const uint8_t *pixels=read.contents;const float *z=(const float *)(pixels+256);int red=1,blue=1,preserve=1;
    for(int i=0;i<64;i++){red&=pixels[4*i]==255&&pixels[4*i+1]==0&&pixels[4*i+2]==0;blue&=pixels[4*i]==0&&pixels[4*i+2]==255;preserve&=z[i]==0.75f;}
    CHECK(metadata?(late?"late depth shader survives attachment elision":"first depth shader survives attachment elision"):"negative control reproduces dropped draw",metadata?red:blue);
    CHECK("NVN depth write disabled preserves all depth pixels",preserve);
}
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);setenv("DM_NVN_TBDR","1",1);mtl_init();run(0,0);run(0,1);run(1,1);printf("FRAGMENT_DEPTH checks=%d failed=%d\n",checks,failed);return failed!=0;}}
