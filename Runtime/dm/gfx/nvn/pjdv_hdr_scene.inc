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
static BOOL pjdv_hdr_region(const tex_t *guest, id<MTLTexture> src, const float vp[4], MTLRegion *region) {
    if (!guest || !src || src.sampleCount != 1 || src.textureType != MTLTextureType2D) return NO;
    double x=vp[0], y=vp[1], w=vp[2], h=vp[3];
    if (!isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h) ||
        x<0 || y<0 || w<640 || h<360 || fabs(w/h-16.0/9.0)>0.03 ||
        x+w>guest->d.width || y+h>guest->d.height) return NO;
    BOOL promoted=pjdv_is_promoted(guest,src);
    if (!promoted && (src.width!=guest->d.width || src.height!=guest->d.height)) return NO;
    double scale=(double)src.width/guest->d.width;
    // Rasterize both edges independently. Half-integer origins must not shift
    // the right/bottom edge when the two snapshots have different backings.
    long x0=lround(x*scale), y0=lround(y*scale), x1=lround((x+w)*scale), y1=lround((y+h)*scale);
    if (x1<=x0 || y1<=y0 || (NSUInteger)x1>src.width || (NSUInteger)y1>src.height) return NO;
    *region=MTLRegionMake2D(x0,y0,x1-x0,y1-y0);
    return YES;
}
static id<MTLTexture> pjdv_hdr_copy(id<MTLTexture> src, MTLRegion region) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:region.size.width height:region.size.height mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];if(!out)return nil;
    out.label=@"PJDV same-frame HDR scene snapshot";res_add(out);res_commit();
    enc_b_copy_texture(blit(),src,0,0,region.origin,region.size,out,0,0,MTLOriginMake(0,0,0));
    return out;
}
static PJDVHDRScene *pjdv_hdr_before_draw(NvProg *pr) {
    if(!atomic_load(&g_pjdv_hdr_mode) || !pjdv_hdr_tonemap(pr))return nil;
    uint64_t frame=atomic_load(&g_cur_frame);
    pjdv_hdr_init_lock();
    @synchronized(g_pjdv_hdr_lock) { [g_pjdv_hdr_scenes removeObjectForKey:@(frame)]; }
    if(!R.rt.color[0] || !S.has_vp)return nil;
    const view_t *view=R.rt.has_cview[0]?&R.rt.cview[0]:NULL;
    if(view && ((view->set_levels && view->base_level) || (view->set_layers && view->min_layer)))return nil;
    int tid=(int)(S.tex[1][0]&0xfffff);
    MTLRegion region;
    id<MTLTexture> raw=nil;
    pthread_mutex_lock(&g_rmu);
    if (tid>0 && tid<g_ntreg && g_treg[tid].ok) {
        raw=tex_by_id(tid);
        if (!pjdv_hdr_region(&g_treg[tid].t,raw,S.vp[0],&region)) raw=nil;
    }
    pthread_mutex_unlock(&g_rmu);
    static int logged; if(logged++<12)MLOG("PJDV HDR tonemap=%s rawFmt=%lu raw=%lux%lu vp=%.0f,%.0f %.0fx%.0f",pr->sh[1]->key,(unsigned long)raw.pixelFormat,(unsigned long)raw.width,(unsigned long)raw.height,S.vp[0][0],S.vp[0][1],S.vp[0][2],S.vp[0][3]);
    if(!raw || (raw.pixelFormat!=MTLPixelFormatRGBA16Float && raw.pixelFormat!=MTLPixelFormatRGBA32Float))return nil;
    PJDVHDRScene *s=[PJDVHDRScene new];s.frame=frame;
    s.hdr=pjdv_hdr_copy(raw,region);return s.hdr?s:nil;
}
static void pjdv_hdr_after_draw(PJDVHDRScene *s) {
    if(!s)return;
    const tex_t *target=R.rt.color[0];
    id<MTLTexture> tone=target?tex_mtl(target):nil;
    MTLRegion region;
    if(!pjdv_hdr_region(target,tone,S.vp[0],&region) || g_pass.tw!=tone.width || g_pass.th!=tone.height)return;
    s.ldr=pjdv_hdr_copy(tone,region);
    if(!s.ldr)return;
    pjdv_hdr_init_lock();@synchronized(g_pjdv_hdr_lock){
        g_pjdv_hdr_scenes[@(s.frame)]=s;
        for(NSNumber *k in [g_pjdv_hdr_scenes.allKeys copy])if(k.unsignedLongLongValue+6<s.frame)[g_pjdv_hdr_scenes removeObjectForKey:k];
    }
}
