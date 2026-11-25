// Run on an Apple Silicon Mac with the NVN runtime directory and its include/
// directory on the header search path. Exercises the production copy encoder.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn.h"

#define DM_NVN_M3 1
#define CENC id<MTLComputeCommandEncoder>
#define MLOG(fmt, ...) fprintf(stderr, fmt "\n", ##__VA_ARGS__)

static id<MTLDevice> g_dev;
static id<MTLCommandBuffer> g_cb;
static id<MTLBlitCommandEncoder> g_blit;

// The test uses Metal 3's retained command buffers. The runtime's residency,
// deferred-release and render-state hooks have no work in this fixture.
static void res_add(id resource) {}
static void defer_obj_release(id resource) {}
static void rp_end(void) {}
static void args_dirty_all(void) {}
static NSUInteger mip_extent(NSUInteger size, NSUInteger level) { return MAX(size >> level, 1u); }
static long pjdv_raster_edge(long edge, int promoted) { return promoted ? lround(1.5 * edge) : edge; }

static id<MTLBlitCommandEncoder> blit(void) {
    if (!g_blit) g_blit = [g_cb blitCommandEncoder];
    return g_blit;
}
static void enc_b_end(id encoder) { [encoder endEncoding]; }
static id<MTLComputeCommandEncoder> enc_c_begin(id descriptor) { return [g_cb computeCommandEncoder]; }
static void enc_c_end(id encoder) { [encoder endEncoding]; }
static void enc_c_pso(id encoder, id pipeline) { [encoder setComputePipelineState:pipeline]; }
static void enc_c_dispatch(id encoder, MTLSize groups, MTLSize threads) {
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
}
static void enc_b_copy_texture_buffer(id encoder, id texture, NSUInteger slice, NSUInteger level,
                                      MTLOrigin origin, MTLSize size, id buffer, NSUInteger offset,
                                      NSUInteger rowBytes, NSUInteger imageBytes) {
    [encoder copyFromTexture:texture sourceSlice:slice sourceLevel:level sourceOrigin:origin
                  sourceSize:size toBuffer:buffer destinationOffset:offset
      destinationBytesPerRow:rowBytes destinationBytesPerImage:imageBytes];
}
static void enc_b_copy_buffer_texture(id encoder, id buffer, NSUInteger offset, NSUInteger rowBytes,
                                      NSUInteger imageBytes, MTLSize size, id texture, NSUInteger slice,
                                      NSUInteger level, MTLOrigin origin) {
    [encoder copyFromBuffer:buffer sourceOffset:offset sourceBytesPerRow:rowBytes sourceBytesPerImage:imageBytes
                 sourceSize:size toTexture:texture destinationSlice:slice destinationLevel:level destinationOrigin:origin];
}
#include "pjdv_internal_transfer.inc"

static BOOL checkFormat(id<MTLCommandQueue> queue, MTLPixelFormat format, int bpp) {
    const int w = 17, h = 11, offset = 4, row = w * bpp + 13;
    const size_t length = offset + row * h + 16;
    const uint8_t guard = 0x9e;
    NVNcopyRegion guest = {.xoffset=1, .yoffset=3, .width=w, .height=h, .depth=1};
    NVNcopyRegion physical = pjdv_physical_region(guest, 1);
    if (physical.xoffset != 2 || physical.yoffset != 5 || physical.width != 25 || physical.height != 16) return NO;

    id<MTLBuffer> input = [g_dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> result = [g_dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    const size_t physicalRow = ((size_t)physical.width * bpp + 255) & ~(size_t)255;
    id<MTLBuffer> raster = [g_dev newBufferWithLength:physical.height * physicalRow options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                  width:physical.xoffset + physical.width + 4
                                                                                 height:physical.yoffset + physical.height + 4 mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:desc];
    if (!input || !result || !raster || !texture) return NO;

    uint8_t *source = input.contents, *actual = result.contents;
    memset(source, 0x28, length);
    memset(actual, guard, length);
    for (int y = 0; y < h; y++) {
        for (int i = 0; i < w * bpp; i++) source[offset + y * row + i] = (uint8_t)(3 * i + 13 * y);
    }
    PJDVCopySurface from = {.buffer=input, .offset=offset, .row=row, .region=guest};
    PJDVCopySurface to = {.buffer=result, .offset=offset, .row=row, .region=guest};
    PJDVCopySurface target = {.texture=texture, .region=physical};
    PJDVCopySurface invalid = from;
    invalid.row = w * bpp - 1;
    if (pjdv_surface_valid(invalid, bpp)) return NO;
    g_cb = [queue commandBuffer];
    if (!pjdv_copy_guest_pixels(from, target, bpp)) return NO;
    enc_b_copy_texture_buffer(blit(), texture, 0, 0, MTLOriginMake(physical.xoffset, physical.yoffset, 0),
                              MTLSizeMake(physical.width, physical.height, 1), raster, 0, physicalRow, physical.height * physicalRow);
    if (!pjdv_copy_guest_pixels(target, to, bpp)) return NO;
    if (g_blit) { [g_blit endEncoding]; g_blit = nil; }
    [g_cb commit];
    [g_cb waitUntilCompleted];
    if (g_cb.status != MTLCommandBufferStatusCompleted) { NSLog(@"%@", g_cb.error); return NO; }

    for (int y = 0; y < physical.height; y++) {
        int sourceY = (int)floor((y + 0.5) * h / physical.height);
        for (int x = 0; x < physical.width; x++) {
            int sourceX = (int)floor((x + 0.5) * w / physical.width);
            const uint8_t *expected = source + offset + sourceY * row + sourceX * bpp;
            const uint8_t *pixel = (const uint8_t *)raster.contents + y * physicalRow + x * bpp;
            if (memcmp(expected, pixel, bpp)) return NO;
        }
    }
    for (size_t i = 0; i < length; i++) {
        BOOL used = i >= offset && i < offset + row * h && (i - offset) % row < (size_t)w * bpp;
        if (actual[i] != (used ? source[i] : guard)) return NO;
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        g_dev = MTLCreateSystemDefaultDevice();
        if (!g_dev) { fputs("A Metal device is required.\n", stderr); return 77; }
        id<MTLCommandQueue> queue = [g_dev newCommandQueue];
        const struct { MTLPixelFormat format; int bytes; } cases[] = {
            {MTLPixelFormatR8Unorm, 1}, {MTLPixelFormatRG16Float, 4}, {MTLPixelFormatRGBA8Unorm, 4},
            {MTLPixelFormatRGBA16Float, 8}, {MTLPixelFormatDepth16Unorm, 2}, {MTLPixelFormatDepth32Float, 4}
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            if (!checkFormat(queue, cases[i].format, cases[i].bytes)) {
                fprintf(stderr, "Framebuffer transfer failed for Metal format %lu\n", (unsigned long)cases[i].format);
                return 1;
            }
        }
        printf("%s: all 6 framebuffer transfers passed (physical samples, round trip and buffer guards).\n", g_dev.name.UTF8String);
    }
    return 0;
}
