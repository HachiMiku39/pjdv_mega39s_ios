// M39 v1.0.9: immutable sprite-atlas host copies, selected by controller family.
// Recipes contain hashes/coordinates only. Artwork comes from the running guest;
// original archives, guest memory, chart selection and input masks are untouched.
#import <CommonCrypto/CommonDigest.h>
@import CoreText;
static _Atomic int g_pjdv_glyph_family;
static pthread_mutex_t g_pjdv_glyph_mu=PTHREAD_MUTEX_INITIALIZER;
static NSArray *g_pjdv_glyph_recipes;
static NSMutableDictionary *g_pjdv_glyph_serials,*g_pjdv_glyph_crops;
void pjdv_set_controller_glyphs(int family){
    family=family>=0 && family<=2?family:0;
    if(atomic_exchange(&g_pjdv_glyph_family,family)!=family){atomic_fetch_add(&g_ser_gen,1);MLOG("PJDV glyph family=%s",family==1?"PS":family==2?"Xbox":"Switch");}
}
static void pjdv_glyph_init(void){static dispatch_once_t once;dispatch_once(&once,^{
    NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"ControllerGlyphs/recipes.json"];
    NSDictionary *doc=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url]?:[NSData data] options:0 error:nil];
    if([doc[@"version"] intValue]==1)g_pjdv_glyph_recipes=doc[@"atlases"];
    g_pjdv_glyph_serials=[NSMutableDictionary dictionary];g_pjdv_glyph_crops=[NSMutableDictionary dictionary];
});}
static NSString *pjdv_glyph_crop_key(NSString *atlas,NSArray *r){return [NSString stringWithFormat:@"%@:%@,%@,%@,%@",atlas,r[0],r[1],r[2],r[3]];}
static int pjdv_glyph_rect(NSArray *r,int W,int H,int out[4]){
    if(r.count!=4)return 0;for(int i=0;i<4;i++)out[i]=[r[i] intValue];
    return out[0]>=0 && out[1]>=0 && out[2]>0 && out[3]>0 && out[0]+out[2]<=W && out[1]+out[3]<=H;
}
static NSMutableData *pjdv_glyph_level(const tex_t *t,unsigned level){
    uint32_t row,rows,z,bpb;uint64_t base;unsigned th,td;
    if(nvn_deswizzle_geom(&t->d,level,0,&row,&rows,&z,&base,&th,&td,&bpb) || z!=1 || base+(uint64_t)row*rows>t->L.size)return nil;
    NSMutableData *linear=[NSMutableData dataWithLength:(size_t)row*rows];
    if(nvn_deswizzle(&t->d,level,0,t->mem,linear.mutableBytes,row))return nil;
    unsigned w=MAX(1,t->d.width>>level),h=MAX(1,t->d.height>>level);int bpp=t->d.format==0x4b?2:4;
    NSMutableData *pixels=[NSMutableData dataWithLength:(size_t)w*h*bpp];
    if(nvn_bc_decode(t->d.format,linear.bytes,row,w,h,pixels.mutableBytes,(size_t)w*bpp))return nil;
    return pixels;
}
static uint8_t pjdv_glyph_byte(float f){return (uint8_t)lrintf(fminf(255,fmaxf(0,f)));}
// Return upright RGBA. BC5 UI atlases pack Y/A in level 0, Cb/Cr in level 1.
static NSMutableData *pjdv_glyph_rgba(const tex_t *t){
    NSMutableData *a=pjdv_glyph_level(t,0);if(!a)return nil;
    unsigned w=t->d.width,h=t->d.height;NSMutableData *out=[NSMutableData dataWithLength:(size_t)w*h*4];uint8_t *d=out.mutableBytes;const uint8_t *s=a.bytes;
    if(t->d.format!=0x4b){for(unsigned y=0;y<h;y++)memcpy(d+(size_t)y*w*4,s+(size_t)(h-1-y)*w*4,(size_t)w*4);return out;}
    if(t->d.levels!=2)return nil;
    NSData *chroma=pjdv_glyph_level(t,1);if(!chroma)return nil;const uint8_t *c=chroma.bytes;unsigned cw=MAX(1,w>>1),ch=MAX(1,h>>1);
    for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){
        size_t i=((size_t)(h-1-y)*w+x)*2,ci=((size_t)(ch-1-MIN(y/2,ch-1))*cw+MIN(x/2,cw-1))*2,di=((size_t)y*w+x)*4;
        float Y=(s[i]-16)*255.f/219.f,Cb=c[ci]-128,Cr=c[ci+1]-128;
        d[di]=pjdv_glyph_byte(Y+1.596f*Cr);d[di+1]=pjdv_glyph_byte(Y-.392f*Cb-.813f*Cr);d[di+2]=pjdv_glyph_byte(Y+2.017f*Cb);d[di+3]=s[i+1];
    }return out;
}
// Fast rejection samples 512 bytes in their original linear block positions.
// A full SHA-256 check is required before any sprite is recognized or changed.
static NSDictionary *pjdv_glyph_match(const tex_t *t){
    if(!t || !t->serial || !t->has_layout || !t->mem || t->d.target!=1 || (t->d.format!=0x44 && t->d.format!=0x4b))return nil;
    NSMutableArray *candidates=[NSMutableArray array];for(NSDictionary *r in g_pjdv_glyph_recipes)
        if([r[@"width"] unsignedIntValue]==t->d.width && [r[@"height"] unsignedIntValue]==t->d.height && [r[@"format"] intValue]==t->d.format)[candidates addObject:r];
    if(!candidates.count)return nil;
    uint32_t row,rows,z,bpb;uint64_t base;unsigned th,td;
    if(nvn_deswizzle_geom(&t->d,0,0,&row,&rows,&z,&base,&th,&td,&bpb) || z!=1)return nil;
    uint64_t count=(uint64_t)row*rows/16;if(!count)return nil;uint64_t hash=1469598103934665603ull;
    for(unsigned i=0;i<32;i++){uint64_t linear=(count-1)*i/31*16;uint32_t x=(uint32_t)(linear%row),y=(uint32_t)(linear/row);
        uint64_t off=base+nvn_bl_offset(x,y,0,row,rows,th,td);if(off+16>t->L.size)return nil;
        for(unsigned j=0;j<16;j++)hash=(hash^((uint8_t *)t->mem)[off+j])*1099511628211ull;}
    NSString *sample=[NSString stringWithFormat:@"%016llx",(unsigned long long)hash];BOOL maybe=NO;for(NSDictionary *r in candidates)if([r[@"sample"] isEqual:sample])maybe=YES;if(!maybe)return nil;
    NSMutableData *linear=[NSMutableData dataWithLength:(size_t)row*rows];if(nvn_deswizzle(&t->d,0,0,t->mem,linear.mutableBytes,row))return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(linear.bytes,(CC_LONG)linear.length,digest);char hex[65];for(int i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    NSString *sha=[NSString stringWithUTF8String:hex];for(NSDictionary *r in candidates)if([r[@"sha256"] isEqual:sha])return r;return nil;
}
static void pjdv_glyph_register(const tex_t *t){
    pjdv_glyph_init();if(!t || !t->serial || !g_pjdv_glyph_recipes.count)return;
    static int trace; if(getenv("PJDV_GLYPH_DIAG") && t->has_layout && t->mem && trace++<60)MLOG("PJDV glyph scan ser=%llu %ux%u format=%x levels=%u target=%d",(unsigned long long)t->serial,t->d.width,t->d.height,t->d.format,t->d.levels,t->d.target);
    pthread_mutex_lock(&g_pjdv_glyph_mu);
    if(g_pjdv_glyph_serials[@(t->serial)]){pthread_mutex_unlock(&g_pjdv_glyph_mu);return;}
    NSDictionary *r=pjdv_glyph_match(t);
    if(r){
        g_pjdv_glyph_serials[@(t->serial)]=r;
        if([r[@"sources"] count]){
            NSMutableData *rgba=pjdv_glyph_rgba(t);const uint8_t *pixels=rgba.bytes;
            if(pixels)for(NSArray *box in r[@"sources"]){int b[4];if(!pjdv_glyph_rect(box,t->d.width,t->d.height,b))continue;
                NSMutableData *crop=[NSMutableData dataWithLength:(size_t)b[2]*b[3]*4];uint8_t *d=crop.mutableBytes;
                for(int y=0;y<b[3];y++)memcpy(d+(size_t)y*b[2]*4,pixels+((size_t)(y+b[1])*t->d.width+b[0])*4,(size_t)b[2]*4);
                g_pjdv_glyph_crops[pjdv_glyph_crop_key(r[@"sha256"],box)]=crop;
            }
        }
        atomic_fetch_add(&g_ser_gen,1);
        MLOG("PJDV glyph atlas ser=%llu %ux%u fmt=%x levels=%u edits=%lu sources=%lu",(unsigned long long)t->serial,t->d.width,t->d.height,t->d.format,t->d.levels,(unsigned long)[r[@"edits"] count],(unsigned long)[r[@"sources"] count]);
    }
    pthread_mutex_unlock(&g_pjdv_glyph_mu);
}
static NSMutableData *pjdv_glyph_footer(int family,NSString *original,int w,int h){
    NSString *ch=original;NSDictionary *map=family==2?@{@"X":@"Y",@"Y":@"X",@"A":@"B",@"B":@"A"}:@{@"X":@"△",@"Y":@"□",@"A":@"○",@"B":@"×"};ch=map[original];if(!ch)return nil;
    int W=w*4,H=h*4;NSMutableData *rgba=[NSMutableData dataWithLength:(size_t)W*H*4];CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef c=CGBitmapContextCreate(rgba.mutableBytes,W,H,8,W*4,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(cs);if(!c)return nil;
    BOOL outline=w>=56;CGFloat diameter=MIN(W,H)-8,ox=(W-diameter)/2,oy=(H-diameter)/2;CGContextSetRGBFillColor(c,1,1,1,1);CGContextSetRGBStrokeColor(c,1,1,1,1);CGContextSetLineWidth(c,MAX(4,diameter*.033));
    if(outline)CGContextStrokeEllipseInRect(c,CGRectMake(ox+2,oy+2,diameter-4,diameter-4));else CGContextFillEllipseInRect(c,CGRectMake(ox,oy,diameter,diameter));
    CGFloat ink=outline?1:0;CGContextSetRGBFillColor(c,ink,ink,ink,1);CGContextSetRGBStrokeColor(c,ink,ink,ink,1);CGContextSetLineWidth(c,diameter*.075);CGContextSetLineJoin(c,kCGLineJoinRound);CGContextSetLineCap(c,kCGLineCapRound);
    CGFloat cx=W/2.,cy=H/2.,r=diameter*.225;
    if(family==1){
        if([ch isEqual:@"△"]){CGContextMoveToPoint(c,cx,cy+r*1.1);CGContextAddLineToPoint(c,cx-r,cy-r*.8);CGContextAddLineToPoint(c,cx+r,cy-r*.8);CGContextClosePath(c);CGContextStrokePath(c);}
        else if([ch isEqual:@"□"])CGContextStrokeRect(c,CGRectMake(cx-r,cy-r,r*2,r*2));
        else if([ch isEqual:@"○"])CGContextStrokeEllipseInRect(c,CGRectMake(cx-r,cy-r,r*2,r*2));
        else{CGContextMoveToPoint(c,cx-r,cy-r);CGContextAddLineToPoint(c,cx+r,cy+r);CGContextMoveToPoint(c,cx-r,cy+r);CGContextAddLineToPoint(c,cx+r,cy-r);CGContextStrokePath(c);}
    }else{
        CTFontRef font=CTFontCreateWithName(outline?CFSTR("HelveticaNeue-Medium"):CFSTR("HelveticaNeue-BoldItalic"),diameter*.77,NULL);
        UniChar u=[ch characterAtIndex:0];CGGlyph glyph;CTFontGetGlyphsForCharacters(font,&u,&glyph,1);CGPathRef path=CTFontCreatePathForGlyph(font,glyph,NULL);
        if(path){CGRect b=CGPathGetBoundingBox(path);CGContextSaveGState(c);CGContextTranslateCTM(c,cx-CGRectGetMidX(b),cy-CGRectGetMidY(b));CGContextAddPath(c,path);CGContextFillPath(c);CGContextRestoreGState(c);CGPathRelease(path);}CFRelease(font);
    }
    CGContextRelease(c);NSMutableData *out=[NSMutableData dataWithLength:(size_t)w*h*4];uint8_t *d=out.mutableBytes,*s=rgba.mutableBytes;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)for(int k=0;k<4;k++){unsigned sum=0;for(int yy=0;yy<4;yy++)for(int xx=0;xx<4;xx++)sum+=s[((size_t)(y*4+yy)*W+x*4+xx)*4+k];d[((size_t)y*w+x)*4+k]=sum/16;}
    // Bitmap row order is top-to-bottom; convert premultiplied channels once.
    for(size_t i=0;i<(size_t)w*h;i++)if(d[i*4+3])for(int k=0;k<3;k++)d[i*4+k]=(uint8_t)MIN(255,(unsigned)d[i*4+k]*255/d[i*4+3]);
    return out;
}
static void pjdv_glyph_pixel(const uint8_t *s,int W,int H,float x,float y,float out[4]){
    x=fmaxf(0,fminf(W-1,x));y=fmaxf(0,fminf(H-1,y));int x0=(int)x,y0=(int)y,x1=MIN(W-1,x0+1),y1=MIN(H-1,y0+1);float dx=x-x0,dy=y-y0;
    for(int c=0;c<4;c++)out[c]=(s[((size_t)y0*W+x0)*4+c]*(1-dx)+s[((size_t)y0*W+x1)*4+c]*dx)*(1-dy)+(s[((size_t)y1*W+x0)*4+c]*(1-dx)+s[((size_t)y1*W+x1)*4+c]*dx)*dy;
}
// Defined after the upload helpers. It returns an uncompressed view-compatible
// copy, retaining the original BC texture as the reversible Switch baseline.
static id<MTLTexture> pjdv_glyph_texture(NvPkg *pk,const tex_t *t);
static int pjdv_glyph_variant(id<MTLTexture> t){return [t.label hasPrefix:@"pjdv.glyph."];}
static void pjdv_glyph_session_end(void){pthread_mutex_lock(&g_pjdv_glyph_mu);[g_pjdv_glyph_serials removeAllObjects];[g_pjdv_glyph_crops removeAllObjects];pthread_mutex_unlock(&g_pjdv_glyph_mu);}
