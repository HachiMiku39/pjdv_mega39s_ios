// This triangle reads the upright scene color and transparency buffer, using
// the guest's active width/height scale in vp_c3[0].yz for both textures.
// Only reflect clip Y; reflecting UVs would sample outside a partial viewport.
static BOOL pjdv_transparency_library(NSString *path) {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    return [name isEqualToString:@"ae69a82033f2da08_b"] ||
           [name isEqualToString:@"ae69a82033f2da08_b_sim"];
}

static NSString *pjdv_transparency_origin(NSString *source) {
    if ([source containsString:@"// PJDV top-left screen quad"] ||
        ![source containsString:@"vertex main0_out main0("] ||
        ![source containsString:@"uint gl_VertexIndex [[vertex_id]]"] ||
        [source containsString:@"[[attribute("]) return source;
    NSRange uv = [source rangeOfString:@"out\\.gl_Position\\.y = (_\\d+);\\s*out\\.\\w+\\.y = spvFMul\\(fma\\(\\1, 0\\.5, 0\\.5\\),"
                              options:NSRegularExpressionSearch];
    NSRange end = [source rangeOfString:@"    return out;" options:NSBackwardsSearch];
    if (uv.location == NSNotFound || end.location == NSNotFound || NSMaxRange(uv) > end.location)
        return source;
    NSMutableString *result = [source mutableCopy];
    [result insertString:@"    // PJDV top-left screen quad\n    out.gl_Position.y = -out.gl_Position.y;\n"
                 atIndex:end.location];
    return result;
}

// Old metal libraries have no editable source. This is the three-vertex
// equivalent for this one known shader, with the original argument-buffer ABI.
// Clip depth follows the same option as the translated-source path.
static NSString *pjdv_transparency_binary_source(BOOL minusW) {
    return [NSString stringWithFormat:
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct Uniforms { constant float4 *scene [[id(0)]]; };\n"
         "struct Vertex { float4 uv [[user(locn0)]]; float4 position [[position]]; float pointSize [[point_size]]; };\n"
         "vertex Vertex main0(constant Uniforms &uniforms [[buffer(0)]], uint id [[vertex_id]]) {\n"
         "    float2 uv = float2(float(id >> 1), float(((id + 2u) %% 3u) >> 1)) * 2.0;\n"
         "    float2 clip = uv * 2.0 - 1.0;\n"
         "    Vertex out;\n"
         "    out.position = float4(clip.x, -clip.y, %@, 1.0);\n"
         "    out.uv = float4(uv * uniforms.scene[0].yz, 0.0, 1.0);\n"
         "    out.pointSize = 1.0;\n"
         "    return out;\n"
         "}\n", minusW ? @"0.5" : @"0.0"];
}
