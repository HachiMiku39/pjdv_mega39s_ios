// Opt-in readback of the source and optional MetalFX / HDR / drawable stages
// from one present command buffer. Scene screenshots precede MetalFX and cannot
// validate the scaler's output. No readback is encoded during normal play.
static _Atomic int g_pjdv_capture_busy;
static NSDictionary *pjdv_fx_capture_encode(CBUF cb,id<MTLTexture> source,id<MTLTexture> output,
        id<MTLTexture> mapped,id<MTLTexture> drawable,const int crop[4],uint64_t frame,int slot) {
    static int enabled=-1,stages;static uint64_t previous=UINT64_MAX;
    if(enabled<0){const char *e=getenv("PJDV_PRESENT_CAPTURE"),*legacy=getenv("PJDV_FX_CAPTURE");
        stages=e && !strcmp(e,"1");enabled=stages || (legacy && !strcmp(legacy,"1"));}
    if(!enabled || frame!=g_pjdv_dump_frame || frame==previous || (!stages && !output))return nil;
    if(atomic_exchange(&g_pjdv_capture_busy,1))return nil;
    previous=frame;
    NSMutableArray *textures=[NSMutableArray arrayWithObject:source],*names=[NSMutableArray arrayWithObject:@"input"];
    if(output){[textures addObject:output];[names addObject:@"output"];}
    if(stages && mapped){[textures addObject:mapped];[names addObject:@"hdr"];}
    if(stages && drawable && !drawable.framebufferOnly){[textures addObject:drawable];[names addObject:@"present"];}
    // No partial set: preflight all formats and the combined readback budget.
    // One request is in flight through both GPU completion and disk writing.
    const NSUInteger budget=96*1024*1024;NSUInteger total=0;
    for(id<MTLTexture> t in textures){
        NSUInteger bpp=(t.pixelFormat==MTLPixelFormatRGBA16Float ? 8 : t.pixelFormat==MTLPixelFormatRGBA32Float ? 16 :
            (t.pixelFormat==MTLPixelFormatRGBA8Unorm || t.pixelFormat==MTLPixelFormatBGRA8Unorm ||
             t.pixelFormat==MTLPixelFormatRGBA8Unorm_sRGB || t.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB) ? 4 : 0);
        NSUInteger row=(t.width*bpp+255)&~(NSUInteger)255;
        if(!bpp || !t.width || !t.height || t.width>8192 || t.height>8192 || t.sampleCount!=1 ||
           t.textureType!=MTLTextureType2D || row>budget/t.height || total>budget-row*t.height){
            MLOG("PJDV present capture rejected: format/extent/budget");atomic_store(&g_pjdv_capture_busy,0);return nil;
        }total+=row*t.height;
    }
    NSMutableArray *items=[NSMutableArray array];
    for(NSUInteger i=0;i<textures.count;i++){
        id<MTLTexture> t=textures[i];NSUInteger bpp=t.pixelFormat==MTLPixelFormatRGBA16Float ? 8 : t.pixelFormat==MTLPixelFormatRGBA32Float ? 16 : 4;
        NSUInteger row=(t.width*bpp+255)&~(NSUInteger)255;
        id<MTLBuffer> buffer=[g_dev newBufferWithLength:row*t.height options:MTLResourceStorageModeShared];
        if(!buffer){atomic_store(&g_pjdv_capture_busy,0);return nil;}
        [items addObject:@{@"buffer":buffer,@"name":names[i],@"width":@(t.width),@"height":@(t.height),@"format":@(t.pixelFormat),@"row":@(row)}];
    }
    for(NSDictionary *item in items)res_add(item[@"buffer"]);res_commit();
#if DM_NVN_M3
    BENC encoder=[cb blitCommandEncoder];
#else
    BENC encoder=[cb computeCommandEncoder];
    [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#if PJDV_HAS_METALFX
    if(output)[encoder waitForFence:g_pjdv_spatial[slot].scaler.fence beforeEncoderStages:MTLStageBlit];
#endif
#endif
    for(NSUInteger i=0;i<items.count;i++){
        NSDictionary *item=items[i];id<MTLTexture> t=textures[i];NSUInteger row=[item[@"row"] unsignedIntegerValue];
        [encoder copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(t.width,t.height,1)
                       toBuffer:item[@"buffer"] destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*t.height];
    }
#if !DM_NVN_M3
    [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#endif
    [encoder endEncoding];
    const char *temp=getenv("DM_TEMP");NSString *directory=temp?@(temp):NSTemporaryDirectory();
    return @{@"items":items,@"prefix":[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"pjdv-fx-F%llu",(unsigned long long)frame]],
             @"frame":@(frame),@"crop":@[@(crop?crop[0]:0),@(crop?crop[1]:0),@(crop?crop[2]:0),@(crop?crop[3]:0)],
             @"spatial_applied":@(output!=nil),@"hdr_applied":@(mapped!=nil),@"present_captured":@(stages && drawable && !drawable.framebufferOnly),@"readback_bytes":@(total),@"direct_frames":@(atomic_load(&g_pjdv_fx_direct_frames)),@"copy_frames":@(atomic_load(&g_pjdv_fx_copy_frames))};
}
static void pjdv_fx_capture_complete(NSDictionary *capture,BOOL success){
    if(!capture)return;for(NSDictionary *item in capture[@"items"])res_remove(item[@"buffer"]);
    if(!success){atomic_store(&g_pjdv_capture_busy,0);return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        NSMutableArray *description=[NSMutableArray array];BOOL saved=YES;
        for(NSDictionary *item in capture[@"items"]){
            id<MTLBuffer> buffer=item[@"buffer"];NSString *path=[capture[@"prefix"] stringByAppendingFormat:@"-%@.raw",item[@"name"]];
            NSString *header=[NSString stringWithFormat:@"%@ %@ %@ %@\n",item[@"width"],item[@"height"],item[@"format"],item[@"row"]];
            FILE *file=fopen(path.UTF8String,"wb");if(file){NSData *h=[header dataUsingEncoding:NSUTF8StringEncoding];
                saved &= fwrite(h.bytes,1,h.length,file)==h.length && fwrite(buffer.contents,1,buffer.length,file)==buffer.length;fclose(file);
            }else saved=NO;
            NSMutableDictionary *d=[item mutableCopy];[d removeObjectForKey:@"buffer"];[description addObject:d];
        }
        NSMutableDictionary *meta=[capture mutableCopy];meta[@"items"]=description;
        meta[@"scope"]=@"Same present command buffer: tone-mapped source, optional Spatial output, optional HDR mapping and optional final drawable. No UI/motion/depth separation.";meta[@"saved"]=@(saved);
        [[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[capture[@"prefix"] stringByAppendingString:@".json"] atomically:YES];
        MLOG("PJDV present stages capture F%llu saved=%d",[capture[@"frame"] unsignedLongLongValue],saved);
        atomic_store(&g_pjdv_capture_busy,0);
    }});
}
