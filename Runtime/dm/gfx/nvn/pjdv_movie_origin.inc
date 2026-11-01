// The NV12 movie producer uses the guest's bottom-left backing surface, while
// the translated postprocess chain samples its active region at the top left.
// Reflect the video rectangle and its decoder UV together. Full-surface movies
// retain their orientation; sub-resolution backgrounds occupy the same active
// corner as the scene. Do not apply this to arbitrary sprites or 3D geometry.
static NSString *pjdv_movie_origin_source(NSString *source,NSString *path) {
    const char *override=getenv("PJDV_MOVIE_ORIGIN");
    if(override && !strcmp(override,"0"))return source;
    NSString *key=[[[path lastPathComponent] componentsSeparatedByString:@"_"] firstObject];
    if(![key isEqualToString:@"36f85460a1ac1b59"] ||
       [source rangeOfString:@"// PJDV movie surface origin"].location!=NSNotFound)return source;
    // This authenticated NV12 producer has position/color/UV attributes and a
    // direct decoder UV. Refuse an unknown interface instead of guessing.
    NSRegularExpression *input=[NSRegularExpression regularExpressionWithPattern:@"float[24]\\s+(\\w+)\\s*\\[\\[attribute\\(2\\)\\]\\]" options:0 error:nil];
    NSRegularExpression *output=[NSRegularExpression regularExpressionWithPattern:@"float[24]\\s+(\\w+)\\s*\\[\\[user\\(locn1\\)\\]\\]" options:0 error:nil];
    NSArray *inputs=[input matchesInString:source options:0 range:NSMakeRange(0,source.length)];
    NSArray *outputs=[output matchesInString:source options:0 range:NSMakeRange(0,source.length)];
    if(inputs.count!=1 || outputs.count!=1 || [source rangeOfString:@"vertex main0_out main0("].location==NSNotFound){
        MLOG("PJDV movie origin: unknown vertex interface; original shader retained");return source;
    }
    NSString *uvIn=[source substringWithRange:[inputs[0] rangeAtIndex:1]],*uvOut=[source substringWithRange:[outputs[0] rangeAtIndex:1]];
    for(NSString *axis in @[@"x",@"y"]){
        NSString *assignment=[NSString stringWithFormat:@"out.%@.%@ = in.%@.%@;",uvOut,axis,uvIn,axis];
        if([source rangeOfString:assignment].location==NSNotFound){MLOG("PJDV movie origin: non-direct UV; original shader retained");return source;}
    }
    NSRange ret=[source rangeOfString:@"    return out;" options:NSBackwardsSearch];
    if(ret.location==NSNotFound){MLOG("PJDV movie origin: return unavailable; original shader retained");return source;}
    NSMutableString *fixed=[source mutableCopy];
    [fixed insertString:[NSString stringWithFormat:@"    // PJDV movie surface origin\n    out.gl_Position.y = -out.gl_Position.y;\n    out.%@.y = 1.0 - out.%@.y;\n",uvOut,uvOut] atIndex:ret.location];
    return fixed;
}
