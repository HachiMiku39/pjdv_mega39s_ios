// M39's default NVN depth mode is NEAR_IS_MINUS_W. Metal clips at zero.
// Transform homogeneous Z at every vertex return, including early returns.
// Preserve XY/W and all material / DOF constants; never transform fragments.
static NSString *pjdv_clip_depth_source(NSString *source,BOOL minusW) {
    NSRange entry=[source rangeOfString:@"vertex main0_out main0("];
    if(!minusW || entry.location==NSNotFound || [source rangeOfString:@"// PJDV GL clip depth"].location!=NSNotFound)return source;
    NSRange open=[source rangeOfString:@"{" options:0 range:NSMakeRange(entry.location,source.length-entry.location)];
    if(open.location==NSNotFound)MDIE("PJDV clip depth vertex body unavailable");
    NSUInteger end=open.location+1;int depth=1;
    for(;end<source.length && depth;end++){unichar ch=[source characterAtIndex:end];if(ch=='{')depth++;else if(ch=='}')depth--;}
    if(depth)MDIE("PJDV clip depth vertex braces changed");
    NSRange range=NSMakeRange(open.location+1,end-open.location-2);NSString *body=[source substringWithRange:range];
    NSRegularExpression *returns=[NSRegularExpression regularExpressionWithPattern:@"(?m)^([ \\t]*)return out;" options:0 error:nil];
    if(![returns numberOfMatchesInString:body options:0 range:NSMakeRange(0,body.length)])MDIE("PJDV clip depth vertex return unavailable");
    NSString *fixed=[returns stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0,body.length)
        withTemplate:@"$1// PJDV GL clip depth\n$1out.gl_Position.z = fma(out.gl_Position.z, 0.5, out.gl_Position.w * 0.5);\n$1return out;"];
    NSMutableString *result=[source mutableCopy];[result replaceCharactersInRange:range withString:fixed];return result;
}
