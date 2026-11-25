#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include "pjdv_transparency_origin.inc"

// The red/green channels expose independent scene coordinates, as sampled by
// both inputs of the transparency pass. No game resource is needed for this test.
static NSString *const fixture =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct Args { constant float4 *c [[id(0)]]; };\n"
     "struct main0_out { float4 gl_Position [[position]]; float4 uv [[user(locn0)]]; };\n"
     "vertex main0_out main0(constant Args &a [[buffer(0)]], uint gl_VertexIndex [[vertex_id]]) {\n"
     "    main0_out out = {};\n"
     "    float _10 = float(gl_VertexIndex >> 1) * 4.0 - 1.0;\n"
     "    float _11 = float(((gl_VertexIndex + 2) % 3) >> 1) * 4.0 - 1.0;\n"
     "    out.gl_Position.w = 1.0;\n"
     "    out.gl_Position.x = _10;\n"
     "    out.uv.x = spvFMul(fma(_10, 0.5, 0.5), a.c[0].y);\n"
     "    out.gl_Position.y = _11;\n"
     "    out.uv.y = spvFMul(fma(_11, 0.5, 0.5), a.c[0].z);\n"
     "    return out;\n}\n";

static void verifyPixels(id<MTLDevice> device, NSString *source, BOOL upright,
                         float scaleX, float scaleY, float expectedDepth) {
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> vertexLibrary = [device newLibraryWithSource:source options:options error:&error];
    NSCAssert(vertexLibrary, @"vertex compile: %@", error);
    NSString *fragmentSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct In { float4 uv [[user(locn0)]]; };\n"
        "fragment float4 coordinates(In in [[stage_in]], float4 p [[position]]) {"
        "return float4(in.uv.xy, p.z, 1.0); }";
    id<MTLLibrary> fragmentLibrary = [device newLibraryWithSource:fragmentSource options:options error:&error];
    NSCAssert(fragmentLibrary, @"fragment compile: %@", error);
    MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
    pipeline.vertexFunction = [vertexLibrary newFunctionWithName:@"main0"];
    pipeline.fragmentFunction = [fragmentLibrary newFunctionWithName:@"coordinates"];
    pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
    NSCAssert(state, @"pipeline: %@", error);

    enum { width = 8, height = 6 };
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                         width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> output = [device newTextureWithDescriptor:desc];
    const float scale[] = {0, scaleX, scaleY, 0};
    id<MTLBuffer> uniform = [device newBufferWithBytes:scale length:sizeof scale options:MTLResourceStorageModeShared];
    id<MTLArgumentEncoder> args = [pipeline.vertexFunction newArgumentEncoderWithBufferIndex:0];
    NSCAssert(args.encodedLength == 8, @"unexpected argument-buffer ABI");
    id<MTLBuffer> bindings = [device newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];
    [args setArgumentBuffer:bindings offset:0];
    [args setBuffer:uniform offset:0 atIndex:0];

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:state];
    [encoder setVertexBuffer:bindings offset:0 atIndex:0];
    [encoder useResource:uniform usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    NSCAssert(command.status == MTLCommandBufferStatusCompleted, @"GPU: %@", command.error);
    float pixels[height][width][4];
    [output getBytes:pixels bytesPerRow:width * sizeof pixels[0][0]
          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            float u = (x + 0.5f) / width;
            float v = (y + 0.5f) / height;
            const float *actual = pixels[y][x];
            NSCAssert(fabsf(actual[0] - u * scaleX) < 1e-5f &&
                      fabsf(actual[1] - (upright ? v : 1 - v) * scaleY) < 1e-5f &&
                      fabsf(actual[2] - expectedDepth) < 1e-5f && actual[3] == 1,
                      @"wrong scene coordinate/depth at %lu,%lu: %g, %g, %g",
                      (unsigned long)x, (unsigned long)y, actual[0], actual[1], actual[2]);
        }
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSCAssert(pjdv_transparency_library(@"cache/ae69a82033f2da08_b.metallib") &&
                  pjdv_transparency_library(@"ae69a82033f2da08_b_sim.metallib") &&
                  !pjdv_transparency_library(@"ae69a82033f2da08_extra.metallib") &&
                  !pjdv_transparency_library(@"50b39085d17008cf_b.metallib"), @"stage isolation");
        NSString *old = [@"#define spvFMul(a,b) ((a)*(b))\n" stringByAppendingString:fixture];
        if (argc > 1) {
            NSError *error = nil;
            old = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
            NSCAssert(old, @"read original vertex source: %@", error);
        }
        NSString *corrected = pjdv_transparency_origin(old);
        NSCAssert(![corrected isEqual:old] && [pjdv_transparency_origin(corrected) isEqual:corrected], @"single conversion");
        NSCAssert([pjdv_transparency_origin(@"unknown interface") isEqual:@"unknown interface"], @"schema guard");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "A Metal GPU is required for raster readback\n"); return 77; }
        for (NSNumber *scale in @[@1.0f, @0.625f]) {
            float x = scale.floatValue, y = x == 1.0f ? 1.0f : 0.8125f;
            verifyPixels(device, old, NO, x, y, 0);
            verifyPixels(device, corrected, YES, x, y, 0);
            verifyPixels(device, pjdv_transparency_binary_source(NO), YES, x, y, 0);
            verifyPixels(device, pjdv_transparency_binary_source(YES), YES, x, y, 0.5);
        }
        printf("PASS %s: old inversion, upright source and binary fallback, full and partial UV scale, depth and ABI\n",
               device.name.UTF8String);
    }
    return 0;
}
