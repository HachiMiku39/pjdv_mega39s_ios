@interface PJDVGlyphShadow : NSObject { @public tex_t t; NSMutableData *storage; unsigned levelsReady; NvPkg *host; } @end
@implementation PJDVGlyphShadow
- (void)dealloc { if(host && host->glyph){defer_obj_release(host->glyph);host->glyph=nil;} }
@end
static NSMutableDictionary *g_pjdv_glyph_shadows;
static NSDictionary *pjdv_glyph_match_linear(const tex_t *t,const uint8_t *bytes,size_t pitch){
    int bw,bh;int bytesPerBlock=nvn_fmt_bpb(t->d.format,&bw,&bh);if(bytesPerBlock!=16)return nil;
    size_t row=(size_t)((t->d.width+bw-1)/bw)*bytesPerBlock,rows=(t->d.height+bh-1)/bh,n=row*rows;
    NSMutableArray *candidates=[NSMutableArray array];for(NSDictionary *r in g_pjdv_glyph_recipes)
        if([r[@"width"] unsignedIntValue]==t->d.width && [r[@"height"] unsignedIntValue]==t->d.height && [r[@"format"] intValue]==t->d.format)[candidates addObject:r];
    if(!candidates.count || pitch<row)return nil;uint64_t hash=1469598103934665603ull,count=n/16;
    for(unsigned i=0;i<32;i++){uint64_t off=(count-1)*i/31*16;const uint8_t *p=bytes+(off/row)*pitch+off%row;for(unsigned j=0;j<16;j++)hash=(hash^p[j])*1099511628211ull;}
    NSString *sample=[NSString stringWithFormat:@"%016llx",(unsigned long long)hash];BOOL maybe=NO;for(NSDictionary *r in candidates)if([r[@"sample"] isEqual:sample])maybe=YES;if(!maybe)return nil;
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);for(size_t y=0;y<rows;y++)CC_SHA256_Update(&ctx,bytes+y*pitch,(CC_LONG)row);uint8_t digest[32];CC_SHA256_Final(digest,&ctx);char hex[65];for(int i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    NSString *sha=[NSString stringWithUTF8String:hex];for(NSDictionary *r in candidates)if([r[@"sha256"] isEqual:sha])return r;return nil;
}
static void pjdv_glyph_forget(uint64_t serial){
    pthread_mutex_lock(&g_pjdv_glyph_mu);
    [g_pjdv_glyph_shadows removeObjectForKey:@(serial)];[g_pjdv_glyph_serials removeObjectForKey:@(serial)];pthread_mutex_unlock(&g_pjdv_glyph_mu);
}
static void pjdv_glyph_capture(const tex_t *t,unsigned level,unsigned layer,const NVNcopyRegion *r,const uint8_t *bytes,size_t pitch){
    pjdv_glyph_init();if(!t || !bytes || t->d.target!=1 || t->d.levels>2 || (t->d.format!=0x44 && t->d.format!=0x4b) || layer || r->xoffset || r->yoffset || r->zoffset || r->depth!=1 ||
        r->width!=MAX(1,t->d.width>>level) || r->height!=MAX(1,t->d.height>>level))return;
    pthread_mutex_lock(&g_pjdv_glyph_mu);if(!g_pjdv_glyph_shadows)g_pjdv_glyph_shadows=[NSMutableDictionary dictionary];
    PJDVGlyphShadow *shadow=g_pjdv_glyph_shadows[@(t->serial)];pthread_mutex_unlock(&g_pjdv_glyph_mu);
    if(!level){
        NSDictionary *recipe=pjdv_glyph_match_linear(t,bytes,pitch);
        if(!recipe){if(shadow){pjdv_glyph_forget(t->serial);atomic_fetch_add(&g_ser_gen,1);}return;}
        if(shadow)pjdv_glyph_forget(t->serial);
        shadow=[PJDVGlyphShadow new];shadow->t=*t;shadow->storage=[NSMutableData dataWithLength:t->L.size];shadow->t.mem=shadow->storage.mutableBytes;shadow->t.has_layout=1;
        pthread_mutex_lock(&g_pjdv_glyph_mu);g_pjdv_glyph_shadows[@(t->serial)]=shadow;pthread_mutex_unlock(&g_pjdv_glyph_mu);
    }
    if(!shadow)return;
    if(nvn_swizzle(&shadow->t.d,level,0,bytes,pitch,shadow->storage.mutableBytes))return;
    shadow->levelsReady|=1u<<level;
    if(shadow->levelsReady==((1u<<t->d.levels)-1))pjdv_glyph_register(&shadow->t);
}
static id<MTLTexture> pjdv_glyph_select(id<MTLTexture> original,const tex_t *t){
    pthread_mutex_lock(&g_pjdv_glyph_mu);PJDVGlyphShadow *shadow=g_pjdv_glyph_shadows[@(t->serial)];pthread_mutex_unlock(&g_pjdv_glyph_mu);if(!shadow || shadow->levelsReady!=((1u<<t->d.levels)-1))return original;
    if(!shadow->host){shadow->host=[NvPkg new];shadow->host->glyphOnly=1;shadow->host->tex=original;}
    return pjdv_glyph_texture(shadow->host,&shadow->t);
}
static void pjdv_glyph_dynamic_end(void){for(PJDVGlyphShadow *s in g_pjdv_glyph_shadows.allValues)if(s->host && s->host->glyph){defer_obj_release(s->host->glyph);s->host->glyph=nil;}[g_pjdv_glyph_shadows removeAllObjects];}
