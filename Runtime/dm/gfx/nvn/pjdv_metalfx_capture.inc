// Opt-in paired readback of the exact input and actual MetalFX output from one
// present command buffer. Existing scene screenshots precede MetalFX and cannot
// validate the scaler's output. No readback is encoded during normal play.
static NSDictionary *pjdv_fx_capture_encode(CBUF cb,id<MTLTexture> source,id<MTLTexture> output,uint64_t frame,int slot) {
    static int enabled=-1;static uint64_t previous=UINT64_MAX;
    if(enabled<0){const char *e=getenv("PJDV_FX_CAPTURE");enabled=e && !strcmp(e,"1");}
    if(!enabled || frame!=g_pjdv_dump_frame || frame==previous || !output)return nil;
    previous=frame;
    NSMutableArray *items=[NSMutableArray array];
    NSArray *textures=@[source,output],*names=@[@"input",@"output"];
    for(int i=0;i<2;i++){
        id<MTLTexture> t=textures[i];if(t.pixelFormat!=MTLPixelFormatRGBA8Unorm && t.pixelFormat!=MTLPixelFormatBGRA8Unorm)return nil;
        NSUInteger row=(t.width*4+255)&~255u;
        id<MTLBuffer> buffer=[g_dev newBufferWithLength:row*t.height options:MTLResourceStorageModeShared];if(!buffer)return nil;
        [items addObject:@{@"buffer":buffer,@"name":names[i],@"width":@(t.width),@"height":@(t.height),@"format":@(t.pixelFormat),@"row":@(row)}];
    }
    for(NSDictionary *item in items)res_add(item[@"buffer"]);res_commit();
#if DM_NVN_M3
    BENC encoder=[cb blitCommandEncoder];
#else
    BENC encoder=[cb computeCommandEncoder];
    [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
#if PJDV_HAS_METALFX
    [encoder waitForFence:g_pjdv_spatial[slot].scaler.fence beforeEncoderStages:MTLStageBlit];
#endif
#endif
    for(int i=0;i<2;i++){
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
             @"frame":@(frame),@"direct_frames":@(atomic_load(&g_pjdv_fx_direct_frames)),@"copy_frames":@(atomic_load(&g_pjdv_fx_copy_frames))};
}
static void pjdv_fx_capture_complete(NSDictionary *capture,BOOL success){
    if(!capture)return;for(NSDictionary *item in capture[@"items"])res_remove(item[@"buffer"]);
    if(!success)return;
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
        meta[@"scope"]=@"Paired source and actual MetalFX output from the same present command buffer; no UI/motion/depth separation.";
        [[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[capture[@"prefix"] stringByAppendingString:@".json"] atomically:YES];
        MLOG("PJDV MetalFX paired capture F%llu saved=%d",[capture[@"frame"] unsignedLongLongValue],saved);
    }});
}
