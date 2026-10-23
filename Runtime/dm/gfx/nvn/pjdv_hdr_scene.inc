#include "pjdv_gpu_policy.h"
// Experimental scene-derived EDR mapping. The original tone mapper still runs.
// Only authenticated pre-tonemap HDR + matching post-tonemap scene are copied.
// No highlight reconstruction from 8-bit video/menu frames and no SDR gain hack.
static _Atomic int g_pjdv_hdr_mode, g_pjdv_hdr_state;
static _Atomic float g_pjdv_hdr_headroom = 1;
static void pjdv_hdr_discard(void);
void pjdv_set_hdr_mode(int mode, float headroom) {
    mode = mode==1 && !pjdv_entry_gpu(MTLCreateSystemDefaultDevice());
    atomic_store(&g_pjdv_hdr_headroom, isfinite(headroom) ? fminf(fmaxf(headroom,1),4) : 1);
    atomic_store(&g_pjdv_hdr_mode, mode==1);
    if (!mode) { atomic_store(&g_pjdv_hdr_state,0); pjdv_hdr_discard(); }
}
int pjdv_hdr_status(void) { return atomic_load(&g_pjdv_hdr_state); }
@interface PJDVHDRScene : NSObject
@property(nonatomic,strong) id<MTLTexture> hdr, ldr;
@property(nonatomic) uint64_t frame;
@end
@implementation PJDVHDRScene
- (void)dealloc { defer_obj_release(_hdr); defer_obj_release(_ldr); }
@end
static NSMutableDictionary<NSNumber *,PJDVHDRScene *> *g_pjdv_hdr_scenes;
static NSObject *g_pjdv_hdr_lock;
static void pjdv_hdr_init_lock(void) { static dispatch_once_t once; dispatch_once(&once,^{g_pjdv_hdr_lock=[NSObject new];g_pjdv_hdr_scenes=[NSMutableDictionary dictionary];}); }
static void pjdv_hdr_discard(void) { pjdv_hdr_init_lock(); @synchronized(g_pjdv_hdr_lock) { [g_pjdv_hdr_scenes removeAllObjects]; } }
static PJDVHDRScene *pjdv_hdr_scene(uint64_t frame) {
    pjdv_hdr_init_lock(); @synchronized(g_pjdv_hdr_lock) { return g_pjdv_hdr_scenes[@(frame)]; }
}
static int pjdv_hdr_tonemap(NvProg *pr) {
    if (!pr || !pr->sh[1]) return 0;
    static const char *keys[]={"928b646c4a03638d","7cbe65574de0ca8a","f4227ee8b5e293cd","9c421ba59ca5d025",
        "aba1e8887a9b1355","4f47ba97900a48fe","1a96732495186357","7fb2adfd65a956c0",
        "0ace5e41d88cc97f","7370cce382a85151","73ac65f4e9b25f0b","059e4055533f7f08","7d715d1691b57c96","a49bd92af1946c51"};
    for (unsigned i=0;i<sizeof(keys)/sizeof(*keys);i++) if(!strncmp(pr->sh[1]->key,keys[i],16))return 1;
    return 0;
}
static id<MTLTexture> pjdv_hdr_copy(id<MTLTexture> src, NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h) {
    if(!src || !w || !h || x+w>src.width || y+h>src.height || src.sampleCount!=1 || src.textureType!=MTLTextureType2D)return nil;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];if(!out)return nil;
    out.label=@"PJDV same-frame HDR scene snapshot";res_add(out);res_commit();
    enc_b_copy_texture(blit(),src,0,0,MTLOriginMake(x,y,0),MTLSizeMake(w,h,1),out,0,0,MTLOriginMake(0,0,0));
    return out;
}
static PJDVHDRScene *pjdv_hdr_before_draw(NvProg *pr) {
    if(!atomic_load(&g_pjdv_hdr_mode) || !pjdv_hdr_tonemap(pr) || !R.rt.color[0] || !S.has_vp)return nil;
    int tid=(int)(S.tex[1][0]&0xfffff);
    const tex_t *t=tid>0 && tid<g_ntreg && g_treg[tid].ok?&g_treg[tid].t:NULL;id<MTLTexture> raw=t?tex_mtl(t):nil;
    static int logged; if(logged++<12)MLOG("PJDV HDR tonemap=%s rawFmt=%lu raw=%lux%lu vp=%.0f,%.0f %.0fx%.0f",pr->sh[1]->key,(unsigned long)raw.pixelFormat,(unsigned long)raw.width,(unsigned long)raw.height,S.vp[0][0],S.vp[0][1],S.vp[0][2],S.vp[0][3]);
    if(!raw || (raw.pixelFormat!=MTLPixelFormatRGBA16Float && raw.pixelFormat!=MTLPixelFormatRGBA32Float))return nil;
    NSUInteger x=(NSUInteger)fmaxf(S.vp[0][0],0),y=(NSUInteger)fmaxf(S.vp[0][1],0),w=(NSUInteger)S.vp[0][2],h=(NSUInteger)S.vp[0][3];
    if(w<640 || h<360 || fabs((double)w/h-16.0/9.0)>0.03)return nil;
    PJDVHDRScene *s=[PJDVHDRScene new];s.frame=atomic_load(&g_cur_frame);
    s.hdr=pjdv_hdr_copy(raw,x,y,w,h);return s.hdr?s:nil;
}
static void pjdv_hdr_after_draw(PJDVHDRScene *s) {
    if(!s)return;
    id<MTLTexture> tone=R.rt.color[0]?tex_mtl(R.rt.color[0]):nil;
    s.ldr=pjdv_hdr_copy(tone,(NSUInteger)fmaxf(S.vp[0][0],0),(NSUInteger)fmaxf(S.vp[0][1],0),s.hdr.width,s.hdr.height);
    if(!s.ldr)return;
    pjdv_hdr_init_lock();@synchronized(g_pjdv_hdr_lock){
        g_pjdv_hdr_scenes[@(s.frame)]=s;
        for(NSNumber *k in [g_pjdv_hdr_scenes.allKeys copy])if(k.unsignedLongLongValue+6<s.frame)[g_pjdv_hdr_scenes removeObjectForKey:k];
    }
}
