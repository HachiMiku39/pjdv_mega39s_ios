// Guest buffers always describe logical texels. Resample raw pixel bytes only
// when a copy crosses a promoted framebuffer. Channel packing (including
// depth float bits and sRGB bytes) and the caller's row padding are preserved.
typedef struct {
    id<MTLTexture> __unsafe_unretained texture;
    id<MTLBuffer> __unsafe_unretained buffer;
    NSUInteger offset, row, level, slice;
    NVNcopyRegion region;
} PJDVCopySurface;

static NVNcopyRegion pjdv_physical_region(NVNcopyRegion r, int promoted) {
    int x = (int)pjdv_raster_edge(r.xoffset, promoted);
    int y = (int)pjdv_raster_edge(r.yoffset, promoted);
    r.width = (int)pjdv_raster_edge((long)r.xoffset+r.width, promoted)-x;
    r.height = (int)pjdv_raster_edge((long)r.yoffset+r.height, promoted)-y;
    r.xoffset=x;
    r.yoffset=y;
    return r;
}
static int pjdv_surface_valid(PJDVCopySurface a, int bpp) {
    NVNcopyRegion r=a.region;
    if(r.width<1 || r.height<1 || r.xoffset<0 || r.yoffset<0 || r.zoffset!=0 || r.depth>1 || bpp<1 || bpp>8) return 0;
    if(a.texture) return a.texture.textureType==MTLTextureType2D && a.level<a.texture.mipmapLevelCount && a.slice==0 &&
        (uint64_t)r.xoffset+r.width<=mip_extent(a.texture.width,a.level) &&
        (uint64_t)r.yoffset+r.height<=mip_extent(a.texture.height,a.level);
    return a.buffer && a.row>=(uint64_t)r.width*bpp && a.row<=UINT32_MAX &&
        a.offset<=a.buffer.length && (uint64_t)(r.height-1)*a.row+(uint64_t)r.width*bpp<=a.buffer.length-a.offset;
}
static id<MTLBuffer> pjdv_transfer_buffer(PJDVCopySurface *surface, int bytesPerPixel) {
    if(surface->buffer) return surface->buffer;
    surface->row=((size_t)surface->region.width*bytesPerPixel+255)&~(size_t)255;
    id<MTLBuffer> b=[g_dev newBufferWithLength:surface->row*surface->region.height options:MTLResourceStorageModePrivate];
    if(b) res_add(b);
    return b;
}
static BOOL pjdv_copy_guest_pixels(PJDVCopySurface src, PJDVCopySurface dst, int bpp) {
    if(!pjdv_surface_valid(src,bpp) || !pjdv_surface_valid(dst,bpp)) return NO;
    static id<MTLComputePipelineState> pipeline;
    if(!pipeline) {
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void resizeBytes(device const uchar *s [[buffer(0)]], device uchar *d [[buffer(1)]], constant uint *p [[buffer(2)]], uint2 xy [[thread_position_in_grid]]){"
        "if(xy.x>=p[2] || xy.y>=p[3]) return;"
        "uint2 at=((2*xy+1)*uint2(p[0],p[1]))/(2*uint2(p[2],p[3]));"
        "uint si=at.y*p[4]+at.x*p[6], di=xy.y*p[5]+xy.x*p[6]; for(uint i=0;i<p[6];i++) d[di+i]=s[si+i];}";
        NSError *error=nil;
        id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> resize=[lib newFunctionWithName:@"resizeBytes"];
        if(resize) pipeline=[g_dev newComputePipelineStateWithFunction:resize error:&error];
        if(!pipeline) { MLOG("PJDV internal copy pipeline: %s", error.localizedDescription.UTF8String); return NO; }
    }
    id<MTLBuffer> in=pjdv_transfer_buffer(&src,bpp), out=pjdv_transfer_buffer(&dst,bpp);
    uint32_t params[]={(uint32_t)src.region.width,(uint32_t)src.region.height,(uint32_t)dst.region.width,
                       (uint32_t)dst.region.height,(uint32_t)src.row,(uint32_t)dst.row,(uint32_t)bpp};
#if !DM_NVN_M3
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount=3;
    id<MTL4ArgumentTable> table=[g_dev newArgumentTableWithDescriptor:ad error:nil];
    id<MTLBuffer> pb=[g_dev newBufferWithBytes:params length:sizeof params options:MTLResourceStorageModeShared];
    BOOL ready=in && out && table && pb;
#else
    BOOL ready=in && out;
#endif
    if(ready) {
        if(src.texture) enc_b_copy_texture_buffer(blit(),src.texture,src.slice,src.level,MTLOriginMake(src.region.xoffset,src.region.yoffset,0),
            MTLSizeMake(src.region.width,src.region.height,1),in,0,src.row,src.row*src.region.height);
        rp_end();
        if(g_blit) { enc_b_end(g_blit);g_blit=nil; }
        CENC ce=enc_c_begin(NULL);enc_c_pso(ce,pipeline);
#if DM_NVN_M3
        [ce setBuffer:in offset:src.offset atIndex:0]; [ce setBuffer:out offset:dst.offset atIndex:1];
        [ce setBytes:params length:sizeof params atIndex:2];
#else
        res_add(pb);
        [table setAddress:pjdv_buffer_address(in)+src.offset atIndex:0];
        [table setAddress:pjdv_buffer_address(out)+dst.offset atIndex:1];
        [table setAddress:pjdv_buffer_address(pb) atIndex:2];
        [ce setArgumentTable:table];
#endif
        enc_c_dispatch(ce,MTLSizeMake((dst.region.width+7)/8,(dst.region.height+7)/8,1),MTLSizeMake(8,8,1));
        enc_c_end(ce);args_dirty_all();
        if(dst.texture) enc_b_copy_buffer_texture(blit(),out,0,dst.row,dst.row*dst.region.height,
            MTLSizeMake(dst.region.width,dst.region.height,1),dst.texture,dst.slice,dst.level,MTLOriginMake(dst.region.xoffset,dst.region.yoffset,0));
#if !DM_NVN_M3
        defer_obj_release(pb);defer_obj_unref(table);
#endif
    }
    if(src.texture && in) defer_obj_release(in);
    if(dst.texture && out) defer_obj_release(out);
    return ready;
}
