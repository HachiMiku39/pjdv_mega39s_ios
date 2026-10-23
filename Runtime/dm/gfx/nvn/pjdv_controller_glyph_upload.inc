static void pjdv_glyph_hue(float p[4],float rotation){
    float r=p[0]/255.f,g=p[1]/255.f,b=p[2]/255.f,hi=fmaxf(r,fmaxf(g,b)),lo=fminf(r,fminf(g,b)),delta=hi-lo;
    if(delta<.03f || hi<.03f)return;float h=hi==r?fmodf((g-b)/delta+6,6):hi==g?(b-r)/delta+2:(r-g)/delta+4;
    h=fmodf(h+rotation/60.f+12,6);float x=delta*(1-fabsf(fmodf(h,2)-1)),v=hi-delta;float a[3];
    if(h<1){a[0]=delta;a[1]=x;a[2]=0;}else if(h<2){a[0]=x;a[1]=delta;a[2]=0;}else if(h<3){a[0]=0;a[1]=delta;a[2]=x;}else if(h<4){a[0]=0;a[1]=x;a[2]=delta;}else if(h<5){a[0]=x;a[1]=0;a[2]=delta;}else{a[0]=delta;a[1]=0;a[2]=x;}
    for(int i=0;i<3;i++)p[i]=(a[i]+v)*255;
}
static id<MTLTexture> pjdv_glyph_texture(NvPkg *pk,const tex_t *t){
    int family=atomic_load(&g_pjdv_glyph_family);
    if(pk->glyphFamily!=family){if(pk->glyph){defer_obj_release(pk->glyph);pk->glyph=nil;}pk->glyphFamily=family;}
    if(!family)return pk->tex;if(pk->glyph)return pk->glyph;
    pjdv_glyph_register(t);
    pthread_mutex_lock(&g_pjdv_glyph_mu);NSDictionary *recipe=g_pjdv_glyph_serials[@(t->serial)];NSArray *edits=recipe[@"edits"];
    if(!edits.count){pthread_mutex_unlock(&g_pjdv_glyph_mu);return pk->tex;}
    NSMutableArray *patches=[NSMutableArray array];BOOL ready=YES;
    for(NSDictionary *edit in edits){NSArray *rect=edit[@"rect"];int box[4];if(!pjdv_glyph_rect(rect,t->d.width,t->d.height,box)){ready=NO;break;}
        NSData *pixels=nil;int sw=0,sh=0;
        if(edit[@"footer"]){pixels=pjdv_glyph_footer(family,edit[@"footer"],box[2],box[3]);sw=box[2];sh=box[3];}
        else{NSDictionary *source=edit[family==1?@"ps":@"xbox"];if(!source)continue;NSArray *r=source[@"rect"];
            pixels=g_pjdv_glyph_crops[pjdv_glyph_crop_key(source[@"atlas"],r)];sw=[r[2] intValue];sh=[r[3] intValue];}
        if(!pixels || pixels.length!=(size_t)sw*sh*4){ready=NO;break;}
        [patches addObject:@{@"edit":edit,@"pixels":pixels,@"w":@(sw),@"h":@(sh)}];
    }
    pthread_mutex_unlock(&g_pjdv_glyph_mu);
    if(!ready || !patches.count)return pk->tex;
    BOOL ycc=t->d.format==0x4b;if(ycc && t->d.levels!=2)return pk->tex;
    // Decode the original RGBA only to recover the original footer ink colors.
    NSData *original=pjdv_glyph_rgba(t);if(!original)return pk->tex;
    NSMutableArray *planes=[NSMutableArray array];for(unsigned level=0;level<t->d.levels;level++){NSData *p=pjdv_glyph_level(t,level);if(!p)return pk->tex;[planes addObject:[p mutableCopy]];}
    for(NSDictionary *patch in patches){NSDictionary *edit=patch[@"edit"];NSArray *r=edit[@"rect"];int b[4];if(!pjdv_glyph_rect(r,t->d.width,t->d.height,b))return pk->tex;
        NSData *rgba=patch[@"pixels"];const uint8_t *s=rgba.bytes;int sw=[patch[@"w"] intValue],sh=[patch[@"h"] intValue];
        float bright[3]={255,255,255},dark[3]={0,0,0};
        if(edit[@"footer"]){const uint8_t *o=original.bytes;int min=766,max=-1;
            for(int y=b[1];y<b[1]+b[3];y++)for(int x=b[0];x<b[0]+b[2];x++){const uint8_t *p=o+((size_t)y*t->d.width+x)*4;if(p[3]<220)continue;int l=p[0]+p[1]+p[2];
                if(l<min){min=l;for(int c=0;c<3;c++)dark[c]=p[c];}if(l>max){max=l;for(int c=0;c<3;c++)bright[c]=p[c];}}
        }
        for(unsigned lv=0;lv<t->d.levels;lv++){
            unsigned W=MAX(1,t->d.width>>lv),H=MAX(1,t->d.height>>lv);int scale=1<<lv,x0=b[0]/scale,y0=b[1]/scale,x1=(b[0]+b[2]+scale-1)/scale,y1=(b[1]+b[3]+scale-1)/scale;
            uint8_t *d=[planes[lv] mutableBytes];int bpp=ycc?2:4;
            for(int y=y0;y<y1 && y<(int)H;y++)for(int x=x0;x<x1 && x<(int)W;x++){
                float px[4];pjdv_glyph_pixel(s,sw,sh,((x+.5f)*scale-b[0])*sw/b[2]-.5f,((y+.5f)*scale-b[1])*sh/b[3]-.5f,px);
                if(edit[@"footer"])for(int c=0;c<3;c++)px[c]=dark[c]+(bright[c]-dark[c])*px[c]/255.f;
                else if(family==2 && edit[@"xbox"][@"hueRotation"])pjdv_glyph_hue(px,[edit[@"xbox"][@"hueRotation"] floatValue]);
                size_t at=((size_t)(H-1-y)*W+x)*bpp;
                if(ycc){float R=px[0],G=px[1],B=px[2];
                    if(!lv){d[at]=pjdv_glyph_byte(16+.257f*R+.504f*G+.098f*B);d[at+1]=pjdv_glyph_byte(px[3]);}
                    else{d[at]=pjdv_glyph_byte(128-.148f*R-.291f*G+.439f*B);d[at+1]=pjdv_glyph_byte(128+.439f*R-.368f*G-.071f*B);}
                }else for(int c=0;c<4;c++)d[at+c]=pjdv_glyph_byte(px[c]);
            }
        }
    }
    uint32_t pf;int bpp;if(!nvn_bc_unpacked(t->d.format,&pf,&bpp))return pk->tex;
    MTLTextureDescriptor *d=tex_desc(t,1);d.pixelFormat=(MTLPixelFormat)pf;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture=[g_dev newTextureWithDescriptor:d];if(!texture)return pk->tex;
    texture.label=[NSString stringWithFormat:@"pjdv.glyph.%d.%llu",family,(unsigned long long)t->serial];res_add(texture);
    size_t total=0;for(unsigned lv=0;lv<t->d.levels;lv++){unsigned w=MAX(1,t->d.width>>lv),h=MAX(1,t->d.height>>lv);total+=(((size_t)w*bpp+255)&~255ull)*h;}
    id<MTLBuffer> staging=[g_dev newBufferWithLength:total options:MTLResourceStorageModeShared];if(!staging){res_remove(texture);return pk->tex;}res_add(staging);
    up_begin();[g_up_keep addObject:staging];
    size_t off=0;for(unsigned lv=0;lv<t->d.levels;lv++){unsigned w=MAX(1,t->d.width>>lv),h=MAX(1,t->d.height>>lv);size_t row=((size_t)w*bpp+255)&~255ull;
        const uint8_t *src=[planes[lv] bytes];for(unsigned y=0;y<h;y++)memcpy((uint8_t *)staging.contents+off+y*row,src+(size_t)y*w*bpp,(size_t)w*bpp);
        up_blit_add(staging,off,row,row*h,MTLSizeMake(w,h,1),texture,0,lv);off+=row*h;
    }
    [g_up_texs addObject:texture];up_flush();pk->glyph=texture;atomic_fetch_add(&g_ser_gen,1);
    MLOG("PJDV glyph applied family=%d ser=%llu edits=%lu bytes=%zu",family,(unsigned long long)t->serial,(unsigned long)patches.count,total);return texture;
}
